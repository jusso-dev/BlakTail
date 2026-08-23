use blaktaild::{
    ensure_private_key, read_state, sync_once, validate_interface, write_state, Coordinator,
    Network, DEFAULT_INTERFACE, DEFAULT_STATE_DIR,
};
use clap::{Parser, Subcommand};
use std::{fs, io::Read as _, path::PathBuf, process, time::Duration};
use tracing::{info, warn};
use zeroize::Zeroize;

#[derive(Parser)]
#[command(
    name = "blaktaild",
    about = "BlakTail WireGuard node agent (Linux and macOS)",
    version
)]
struct Cli {
    #[arg(long, global = true, default_value = DEFAULT_STATE_DIR, hide = true)]
    state_dir: PathBuf,
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    /// Join a tailnet and keep WireGuard peers synchronized.
    Up {
        #[arg(long)]
        coord: String,
        /// Single-use join key. Omit to read it from stdin.
        #[arg(long, hide_env_values = true, env = "BLAKTAIL_JOIN_KEY")]
        join_key: Option<String>,
        #[arg(long, default_value = DEFAULT_INTERFACE)]
        interface: String,
        #[arg(long)]
        name: Option<String>,
        /// Public UDP endpoint advertised to peers, for example 203.0.113.5:51820.
        #[arg(long)]
        endpoint: Option<String>,
        #[arg(long, default_value_t = 30)]
        poll_seconds: u64,
        /// Exit after the first successful peer sync; launchd or systemd keeps syncing via `run`.
        #[arg(long)]
        exit_after_join: bool,
    },
    /// Resume the persisted enrollment and keep WireGuard peers synchronized.
    Run {
        #[arg(long, default_value_t = 30)]
        poll_seconds: u64,
    },
    /// Show persisted node and peer status without exposing credentials.
    Status,
    /// Revoke this node and remove its WireGuard interface.
    Down,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();
    if let Err(error) = run(Cli::parse()).await {
        eprintln!("blaktaild: {error}");
        std::process::exit(1);
    }
}

fn detect_hostname() -> String {
    fs::read_to_string("/etc/hostname")
        .ok()
        .map(|h| h.trim().to_owned())
        .filter(|h| !h.is_empty())
        .or_else(|| {
            process::Command::new("hostname")
                .output()
                .ok()
                .filter(|out| out.status.success())
                .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_owned())
                .filter(|h| !h.is_empty())
        })
        .unwrap_or_else(|| "blaktail-node".into())
}

/// Join keys arrive on stdin (never argv) when the caller is another program.
fn resolve_join_key(provided: Option<String>) -> Result<String, blaktaild::Error> {
    if let Some(key) = provided {
        let key = key.trim().to_owned();
        if key.is_empty() {
            return Err(blaktaild::Error::Message(
                "join key must not be empty".into(),
            ));
        }
        return Ok(key);
    }
    use std::io::IsTerminal;
    if std::io::stdin().is_terminal() {
        return Err(blaktaild::Error::Message(
            "a join key is required: pass --join-key or pipe it to stdin".into(),
        ));
    }
    let mut key = String::new();
    std::io::stdin()
        .read_to_string(&mut key)
        .map_err(|e| blaktaild::Error::Message(format!("could not read join key: {e}")))?;
    let key = key.trim().to_owned();
    if key.is_empty() {
        return Err(blaktaild::Error::Message(
            "join key must not be empty".into(),
        ));
    }
    Ok(key)
}

fn make_network() -> Box<dyn Network> {
    #[cfg(target_os = "macos")]
    {
        Box::new(blaktaild::MacOsNetwork::new())
    }
    #[cfg(not(target_os = "macos"))]
    {
        Box::new(blaktaild::LinuxNetwork)
    }
}

async fn sync_loop(
    coordinator: &Coordinator,
    network: &mut dyn Network,
    state: &mut blaktaild::NodeState,
    state_dir: &std::path::Path,
    poll_seconds: u64,
    exit_after_join: bool,
) -> Result<(), blaktaild::Error> {
    loop {
        match sync_once(coordinator, network, state, state_dir).await {
            Ok(changes) if changes > 0 => info!(changes, "WireGuard peers synchronized"),
            Ok(_) => {}
            Err(error) => {
                warn!(%error, "coordinator unavailable; retaining existing tunnel configuration")
            }
        }
        if exit_after_join {
            info!("initial peer sync complete; handing over to the service manager");
            return Ok(());
        }
        tokio::select! {
            _ = tokio::signal::ctrl_c() => { info!("stopping peer sync; interface remains configured"); break; }
            _ = tokio::time::sleep(Duration::from_secs(poll_seconds.max(1))) => {}
        }
    }
    Ok(())
}

async fn run(cli: Cli) -> Result<(), blaktaild::Error> {
    match cli.command {
        Command::Up {
            coord,
            join_key,
            interface,
            name,
            endpoint,
            poll_seconds,
            exit_after_join,
        } => {
            validate_interface(&interface)?;
            let mut join_key = resolve_join_key(join_key)?;
            let (key_path, public_key) = ensure_private_key(&cli.state_dir)?;
            let coordinator = Coordinator::new(&coord)?;
            let name = name.unwrap_or_else(detect_hostname);
            let resumed = cli.state_dir.join("state.json").exists();
            let mut state = match read_state(&cli.state_dir) {
                Ok(existing) if existing.coord == coord && existing.interface == interface => {
                    existing
                }
                Ok(_) => return Err(blaktaild::Error::Message(
                    "existing enrollment uses a different coordinator or interface; run down first"
                        .into(),
                )),
                Err(blaktaild::Error::Io(error))
                    if error.kind() == std::io::ErrorKind::NotFound =>
                {
                    coordinator
                        .register(
                            &join_key,
                            &name,
                            &public_key,
                            endpoint.as_deref(),
                            &interface,
                        )
                        .await?
                }
                Err(error) => return Err(error),
            };
            join_key.zeroize();
            let mut network = make_network();
            if let Err(error) = network.setup(&interface, &key_path, &state.assigned_ip) {
                if !resumed {
                    let _ = coordinator.revoke(&state).await;
                }
                return Err(error);
            }
            write_state(&cli.state_dir, &state)?;
            info!(node_id = %state.node_id, address = %state.assigned_ip, interface, "tailnet joined");
            println!(
                "joined\nnode: {}\ninterface: {}\naddress: {}\ncoordinator: {}",
                state.node_id, state.interface, state.assigned_ip, state.coord
            );
            sync_loop(
                &coordinator,
                network.as_mut(),
                &mut state,
                &cli.state_dir,
                poll_seconds,
                exit_after_join,
            )
            .await?;
        }
        Command::Run { poll_seconds } => {
            let mut state = read_state(&cli.state_dir)?;
            validate_interface(&state.interface)?;
            let (key_path, _) = ensure_private_key(&cli.state_dir)?;
            let coordinator = Coordinator::new(&state.coord)?;
            let mut network = make_network();
            network.setup(&state.interface, &key_path, &state.assigned_ip)?;
            write_state(&cli.state_dir, &state)?;
            info!(node_id = %state.node_id, interface = %state.interface, "resuming enrollment");
            sync_loop(
                &coordinator,
                network.as_mut(),
                &mut state,
                &cli.state_dir,
                poll_seconds,
                false,
            )
            .await?;
        }
        Command::Status => {
            let state = read_state(&cli.state_dir)?;
            println!(
                "joined\nnode: {}\ninterface: {}\naddress: {}\ncoordinator: {}\npeers: {}",
                state.node_id,
                state.interface,
                state.assigned_ip,
                state.coord,
                state.peers.len()
            );
            for peer in state.peers {
                println!(
                    "  {} {} {}",
                    peer.name,
                    peer.endpoint.as_deref().unwrap_or("endpoint unknown"),
                    peer.allowed_ips.join(",")
                );
            }
        }
        Command::Down => {
            let state = read_state(&cli.state_dir)?;
            let coordinator = Coordinator::new(&state.coord)?;
            coordinator.revoke(&state).await?;
            make_network().down(&state.interface)?;
            fs::remove_file(cli.state_dir.join("state.json"))?;
            println!("node revoked and {} removed", state.interface);
        }
    }
    Ok(())
}
