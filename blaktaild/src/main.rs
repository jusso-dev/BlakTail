use blaktaild::{
    ensure_private_key, read_state, sync_once, validate_interface, write_state, Coordinator,
    LinuxNetwork, Network, DEFAULT_INTERFACE, DEFAULT_STATE_DIR,
};
use clap::{Parser, Subcommand};
use std::{fs, path::PathBuf, time::Duration};
use tracing::{info, warn};

#[derive(Parser)]
#[command(
    name = "blaktaild",
    about = "BlakTail Linux WireGuard node agent",
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
        #[arg(long)]
        join_key: String,
        #[arg(long, default_value = DEFAULT_INTERFACE)]
        interface: String,
        #[arg(long)]
        name: Option<String>,
        /// Public UDP endpoint advertised to peers, for example 203.0.113.5:51820.
        #[arg(long)]
        endpoint: Option<String>,
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
async fn run(cli: Cli) -> Result<(), blaktaild::Error> {
    match cli.command {
        Command::Up {
            coord,
            mut join_key,
            interface,
            name,
            endpoint,
            poll_seconds,
        } => {
            validate_interface(&interface)?;
            let (key_path, public_key) = ensure_private_key(&cli.state_dir)?;
            let coordinator = Coordinator::new(&coord)?;
            let name = name.unwrap_or_else(|| {
                fs::read_to_string("/etc/hostname")
                    .unwrap_or_else(|_| "blaktail-node".into())
                    .trim()
                    .to_owned()
            });
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
            use zeroize::Zeroize;
            join_key.zeroize();
            let mut network = LinuxNetwork;
            if let Err(error) = network.setup(&interface, &key_path, &state.assigned_ip) {
                if !resumed {
                    let _ = coordinator.revoke(&state).await;
                }
                return Err(error);
            }
            write_state(&cli.state_dir, &state)?;
            info!(node_id = %state.node_id, address = %state.assigned_ip, interface, "tailnet joined");
            loop {
                match sync_once(&coordinator, &mut network, &mut state, &cli.state_dir).await {
                    Ok(changes) if changes > 0 => info!(changes, "WireGuard peers synchronized"),
                    Ok(_) => {}
                    Err(error) => {
                        warn!(%error, "coordinator unavailable; retaining existing tunnel configuration")
                    }
                }
                tokio::select! {
                    _ = tokio::signal::ctrl_c() => { info!("stopping peer sync; interface remains configured"); break; }
                    _ = tokio::time::sleep(Duration::from_secs(poll_seconds.max(1))) => {}
                }
            }
        }
        Command::Status => {
            let state = read_state(&cli.state_dir)?;
            println!(
                "node: {}\ninterface: {}\naddress: {}\ncoordinator: {}\npeers: {}",
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
            LinuxNetwork.down(&state.interface)?;
            fs::remove_file(cli.state_dir.join("state.json"))?;
            println!("node revoked and {} removed", state.interface);
        }
    }
    Ok(())
}
