use blaktaild::{
    configure_system_dns, dns_domain, ensure_private_key, peer_key_hex, read_state,
    remove_system_dns, restore_peers, sync_once, validate_interface, write_state, Coordinator,
    MagicDns, Network, RelayMesh, DEFAULT_INTERFACE, DEFAULT_STATE_DIR, DIRECT_GRACE_SECS,
    DIRECT_RETRY_SECS, HANDSHAKE_FRESH_SECS,
};
use clap::{Parser, Subcommand};
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::Read as _,
    path::PathBuf,
    process,
    time::{Duration, Instant},
};
use tracing::{info, warn};
use uuid::Uuid;
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
    /// Renew this enrollment with a fresh join key without changing its tailnet IP.
    Reauth {
        /// Fresh join key. Omit to read it from stdin.
        #[arg(long, hide_env_values = true, env = "BLAKTAIL_JOIN_KEY")]
        join_key: Option<String>,
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
    let mut mesh: Option<RelayMesh> = None;
    let mut dns: Option<MagicDns> = None;
    let mut paths: HashMap<Uuid, PeerPath> = HashMap::new();
    loop {
        match sync_once(coordinator, network, state, state_dir).await {
            Ok(changes) if changes > 0 => info!(changes, "WireGuard peers synchronized"),
            Ok(_) => {}
            Err(error) => {
                warn!(%error, "peer synchronization failed; retaining existing tunnel configuration")
            }
        }
        manage_magic_dns(&mut dns, state, state_dir).await;
        manage_paths(network, &mut mesh, state, &mut paths).await;
        report_relay_endpoint(coordinator, mesh.as_ref(), state, state_dir).await;
        if exit_after_join {
            if let Some(active) = mesh.take() {
                active.stop();
            }
            shutdown_magic_dns(&mut dns, state, state_dir);
            info!("initial peer sync complete; handing over to the service manager");
            return Ok(());
        }
        tokio::select! {
            _ = tokio::signal::ctrl_c() => { info!("stopping peer sync; interface remains configured"); break; }
            _ = tokio::time::sleep(Duration::from_secs(poll_seconds.max(1))) => {}
        }
    }
    if let Some(active) = mesh.take() {
        active.stop();
    }
    shutdown_magic_dns(&mut dns, state, state_dir);
    Ok(())
}

async fn manage_magic_dns(
    dns: &mut Option<MagicDns>,
    state: &mut blaktaild::NodeState,
    state_dir: &std::path::Path,
) {
    let Some(domain) = dns_domain(&state.dns_name) else {
        return;
    };
    if dns.as_ref().is_some_and(|active| !active.matches(state)) {
        let old_domain = dns
            .as_ref()
            .map(|active| active.domain().to_owned())
            .expect("active resolver checked");
        if let Err(error) = remove_system_dns(
            state_dir,
            &state.interface,
            &old_domain,
            state.dns_mode.as_deref(),
        ) {
            warn!(%error, "could not remove stale MagicDNS configuration");
            return;
        }
        if let Some(active) = dns.take() {
            active.stop();
        }
        state.dns_mode = None;
    }
    if dns.is_none() {
        let created = match MagicDns::spawn(state).await {
            Ok(created) => created,
            Err(error) => {
                warn!(%error, "could not bind local MagicDNS resolver");
                return;
            }
        };
        let mode =
            match configure_system_dns(state_dir, &state.interface, created.bind_ip(), &domain) {
                Ok(mode) => mode,
                Err(error) => {
                    created.stop();
                    warn!(%error, "could not configure system MagicDNS routing");
                    return;
                }
            };
        info!(%domain, mode, "MagicDNS resolver active");
        state.dns_mode = Some(mode);
        if let Err(error) = write_state(state_dir, state) {
            warn!(%error, "could not persist MagicDNS configuration state");
        }
        *dns = Some(created);
    }
    if let Some(active) = dns.as_ref() {
        active.update(state);
    }
}

fn shutdown_magic_dns(
    dns: &mut Option<MagicDns>,
    state: &mut blaktaild::NodeState,
    state_dir: &std::path::Path,
) {
    let Some(active) = dns.take() else {
        return;
    };
    let domain = active.domain().to_owned();
    active.stop();
    match remove_system_dns(
        state_dir,
        &state.interface,
        &domain,
        state.dns_mode.as_deref(),
    ) {
        Ok(()) => {
            state.dns_mode = None;
            if let Err(error) = write_state(state_dir, state) {
                warn!(%error, "could not persist MagicDNS shutdown state");
            }
        }
        Err(error) => warn!(%error, "could not remove MagicDNS configuration"),
    }
}

const RELAY_ENDPOINT_REPORT_SECS: u64 = 60;

#[derive(Clone, Copy, Debug)]
enum PeerPath {
    Direct { since: Instant },
    Relayed { since: Instant },
    DirectProbe { since: Instant, baseline: u64 },
    PeerDirect { last_fresh: Instant },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PathAction {
    None,
    MaintainRelay,
    MaintainPeerDirect,
    UseRelay,
    ProbeNativeDirect,
    DirectRecovered,
    PeerDirectRecovered,
}

fn path_action(
    path: PeerPath,
    direct_handshake_fresh: bool,
    latest_handshake: u64,
    has_native_endpoint: bool,
    peer_endpoint: Option<std::net::SocketAddr>,
    peer_direct_reachable: bool,
) -> PathAction {
    match path {
        PeerPath::Direct { since }
            if !direct_handshake_fresh && since.elapsed().as_secs() >= DIRECT_GRACE_SECS =>
        {
            PathAction::UseRelay
        }
        PeerPath::Relayed { .. } if peer_endpoint.is_some() && peer_direct_reachable => {
            PathAction::PeerDirectRecovered
        }
        PeerPath::Relayed { since, .. } if since.elapsed().as_secs() >= DIRECT_RETRY_SECS => {
            if has_native_endpoint {
                PathAction::ProbeNativeDirect
            } else {
                PathAction::MaintainRelay
            }
        }
        PeerPath::Relayed { .. } => PathAction::MaintainRelay,
        PeerPath::DirectProbe { baseline, .. } if latest_handshake > baseline => {
            PathAction::DirectRecovered
        }
        PeerPath::DirectProbe { since, .. } if since.elapsed().as_secs() >= DIRECT_GRACE_SECS => {
            PathAction::UseRelay
        }
        PeerPath::PeerDirect { .. } if peer_endpoint.is_none() => PathAction::UseRelay,
        PeerPath::PeerDirect { .. } if direct_handshake_fresh => PathAction::MaintainPeerDirect,
        PeerPath::PeerDirect { last_fresh }
            if last_fresh.elapsed().as_secs() >= DIRECT_GRACE_SECS =>
        {
            PathAction::UseRelay
        }
        PeerPath::PeerDirect { .. } => PathAction::MaintainPeerDirect,
        _ => PathAction::None,
    }
}

/// Keeps each peer on its best available transport. Failed direct paths move
/// to a relay-assisted localhost forwarder. Encrypted relay traffic continues
/// while that forwarder attempts a coordinator-mediated UDP hole punch.
async fn manage_paths(
    network: &mut dyn Network,
    mesh: &mut Option<RelayMesh>,
    state: &blaktaild::NodeState,
    paths: &mut HashMap<Uuid, PeerPath>,
) {
    let now_unix = blaktaild_now();
    if state.relays.is_empty() || state.relay_token.is_empty() || state.relay_expires_at <= now_unix
    {
        disable_relay(network, mesh, state, paths);
        return;
    }
    let interface = &state.interface;
    let failed_relay = mesh.as_ref().and_then(|active| {
        (!active.relay_healthy()).then(|| {
            let address = active.relay_addr();
            warn!(%address, "relay health probe expired; trying another endpoint");
            address
        })
    });
    if failed_relay.is_some() {
        if let Some(active) = mesh.take() {
            active.stop();
        }
    }
    if mesh.is_none() {
        let Some(relay_addr) = resolve_relay(&state.relays, failed_relay).await else {
            warn!("could not resolve any advertised relay; direct paths only");
            return;
        };
        let listen = match network.listen_endpoint(interface) {
            Ok(Some(listen)) => listen,
            Ok(None) => return,
            Err(error) => {
                warn!(%error, "could not read WireGuard listen port; direct paths only");
                return;
            }
        };
        match RelayMesh::spawn(
            relay_addr,
            listen,
            state.node_id,
            &state.relay_token,
            state.relay_expires_at,
        ) {
            Ok(created) => *mesh = Some(created),
            Err(error) => warn!(%error, "could not start relay client; direct paths only"),
        }
    } else if let Some(active) = mesh.as_ref() {
        active.update_credentials(&state.relay_token, state.relay_expires_at);
    }
    let Some(mesh) = mesh.as_ref() else {
        return;
    };

    let handshakes = network.latest_handshakes(interface).unwrap_or_default();
    let current_peers: HashSet<Uuid> = state.peers.iter().map(|peer| peer.id).collect();
    let removed: Vec<Uuid> = paths
        .keys()
        .filter(|peer_id| !current_peers.contains(peer_id))
        .copied()
        .collect();
    for peer_id in removed {
        mesh.drop_forwarder(peer_id);
        paths.remove(&peer_id);
    }

    for peer in &state.peers {
        let stamp = handshakes
            .get(&peer_key_hex(&peer.wg_public_key).unwrap_or_default())
            .copied()
            .unwrap_or(0);
        let fresh = stamp > now_unix.saturating_sub(HANDSHAKE_FRESH_SECS);
        let path = paths.entry(peer.id).or_insert_with(|| PeerPath::Direct {
            since: Instant::now(),
        });
        let current = *path;
        let peer_endpoint = peer
            .relay_endpoint
            .as_deref()
            .and_then(|endpoint| endpoint.parse::<std::net::SocketAddr>().ok());
        let peer_direct_reachable =
            peer_endpoint.is_some_and(|endpoint| mesh.peer_direct_reachable(peer.id, endpoint));
        let next = match path_action(
            current,
            fresh,
            stamp,
            peer.endpoint.is_some(),
            peer_endpoint,
            peer_direct_reachable,
        ) {
            PathAction::UseRelay => {
                if switch_to_relay(network, mesh, interface, peer).await {
                    Some(PeerPath::Relayed {
                        since: Instant::now(),
                    })
                } else {
                    Some(PeerPath::Direct {
                        since: Instant::now(),
                    })
                }
            }
            PathAction::MaintainRelay => {
                if switch_to_relay(network, mesh, interface, peer).await {
                    Some(current)
                } else {
                    Some(PeerPath::Direct {
                        since: Instant::now(),
                    })
                }
            }
            PathAction::PeerDirectRecovered => {
                let endpoint = peer_endpoint.expect("action requires peer endpoint");
                if switch_to_peer_direct(network, mesh, interface, peer, endpoint).await {
                    info!(peer = %peer.name, %endpoint, "peer-direct UDP path established");
                    Some(PeerPath::PeerDirect {
                        last_fresh: Instant::now(),
                    })
                } else {
                    let _ = switch_to_relay(network, mesh, interface, peer).await;
                    Some(PeerPath::Relayed {
                        since: Instant::now(),
                    })
                }
            }
            PathAction::MaintainPeerDirect => {
                let endpoint = peer_endpoint.expect("action requires peer endpoint");
                if switch_to_peer_direct(network, mesh, interface, peer, endpoint).await {
                    Some(if fresh {
                        PeerPath::PeerDirect {
                            last_fresh: Instant::now(),
                        }
                    } else {
                        current
                    })
                } else {
                    let _ = switch_to_relay(network, mesh, interface, peer).await;
                    Some(PeerPath::Relayed {
                        since: Instant::now(),
                    })
                }
            }
            PathAction::ProbeNativeDirect => {
                let endpoint = peer.endpoint.as_deref().expect("action requires endpoint");
                match network.set_peer_endpoint(interface, &peer.wg_public_key, endpoint) {
                    Ok(()) => {
                        mesh.drop_forwarder(peer.id);
                        info!(peer = %peer.name, "probing direct path");
                        Some(PeerPath::DirectProbe {
                            since: Instant::now(),
                            baseline: stamp,
                        })
                    }
                    Err(error) => {
                        warn!(%error, peer = %peer.name, "could not probe direct endpoint");
                        Some(current)
                    }
                }
            }
            PathAction::DirectRecovered => {
                info!(peer = %peer.name, "direct path recovered; leaving relay");
                Some(PeerPath::Direct {
                    since: Instant::now(),
                })
            }
            PathAction::None => None,
        };
        if let Some(next) = next {
            paths.insert(peer.id, next);
        }
    }
}

async fn switch_to_relay(
    network: &mut dyn Network,
    mesh: &RelayMesh,
    interface: &str,
    peer: &blaktaild::Peer,
) -> bool {
    let already_relayed = mesh.has_forwarder(peer.id);
    match mesh.ensure_forwarder(peer.id).await {
        Ok(port) => {
            let peer_endpoint = peer
                .relay_endpoint
                .as_deref()
                .and_then(|endpoint| endpoint.parse::<std::net::SocketAddr>().ok());
            if !mesh.use_relay(peer.id, peer_endpoint) {
                return false;
            }
            let local = format!("127.0.0.1:{port}");
            if let Err(error) = network.set_peer_endpoint(interface, &peer.wg_public_key, &local) {
                warn!(%error, peer = %peer.name, "could not switch to relay path");
                mesh.drop_forwarder(peer.id);
                false
            } else {
                if !already_relayed {
                    info!(peer = %peer.name, %local, "using relay-assisted path");
                }
                true
            }
        }
        Err(error) => {
            warn!(%error, peer = %peer.name, "relay forwarder failed");
            false
        }
    }
}

async fn switch_to_peer_direct(
    network: &mut dyn Network,
    mesh: &RelayMesh,
    interface: &str,
    peer: &blaktaild::Peer,
    endpoint: std::net::SocketAddr,
) -> bool {
    match mesh.ensure_forwarder(peer.id).await {
        Ok(port) => {
            if !mesh.use_peer_direct(peer.id, endpoint) {
                return false;
            }
            let local = format!("127.0.0.1:{port}");
            if let Err(error) = network.set_peer_endpoint(interface, &peer.wg_public_key, &local) {
                warn!(%error, peer = %peer.name, "could not use peer-direct path");
                mesh.drop_forwarder(peer.id);
                false
            } else {
                true
            }
        }
        Err(error) => {
            warn!(%error, peer = %peer.name, "peer-direct forwarder failed");
            false
        }
    }
}

async fn report_relay_endpoint(
    coordinator: &Coordinator,
    mesh: Option<&RelayMesh>,
    state: &mut blaktaild::NodeState,
    state_dir: &std::path::Path,
) {
    let Some(endpoint) = mesh.and_then(RelayMesh::observed_endpoint) else {
        return;
    };
    let now = blaktaild_now();
    let endpoint_text = endpoint.to_string();
    let unchanged = state.relay_endpoint.as_deref() == Some(endpoint_text.as_str());
    if unchanged
        && now.saturating_sub(state.relay_endpoint_reported_at) < RELAY_ENDPOINT_REPORT_SECS
    {
        return;
    }
    match coordinator.report_relay_endpoint(state, endpoint).await {
        Ok(()) => {
            if !unchanged {
                info!(%endpoint, "reported reflexive UDP endpoint");
            }
            state.relay_endpoint = Some(endpoint_text);
            state.relay_endpoint_reported_at = now;
            if let Err(error) = write_state(state_dir, state) {
                warn!(%error, "could not persist reported relay endpoint");
            }
        }
        Err(error) => warn!(%error, "could not report reflexive UDP endpoint"),
    }
}

fn disable_relay(
    network: &mut dyn Network,
    mesh: &mut Option<RelayMesh>,
    state: &blaktaild::NodeState,
    paths: &mut HashMap<Uuid, PeerPath>,
) {
    if let Some(active) = mesh.take() {
        for peer in &state.peers {
            if active.has_forwarder(peer.id) {
                if let Some(endpoint) = peer.endpoint.as_deref() {
                    let _ =
                        network.set_peer_endpoint(&state.interface, &peer.wg_public_key, endpoint);
                }
            }
        }
        active.stop();
    }
    paths.clear();
}

async fn resolve_relay(
    relays: &[String],
    excluded: Option<std::net::SocketAddr>,
) -> Option<std::net::SocketAddr> {
    let mut fallback = None;
    for relay in relays {
        if let Ok(mut addresses) = tokio::net::lookup_host(relay).await {
            for address in &mut addresses {
                fallback.get_or_insert(address);
                if Some(address) != excluded {
                    return Some(address);
                }
            }
        }
    }
    fallback
}

fn blaktaild_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
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
            let restored = restore_peers(network.as_mut(), &state)?;
            if restored > 0 {
                info!(restored, "restored persisted WireGuard peers");
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
            let restored = restore_peers(network.as_mut(), &state)?;
            if restored > 0 {
                info!(restored, "restored persisted WireGuard peers");
            }
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
        Command::Reauth { join_key } => {
            let mut state = read_state(&cli.state_dir)?;
            let coordinator = Coordinator::new(&state.coord)?;
            let mut join_key = resolve_join_key(join_key)?;
            let result = coordinator.reauth(&mut state, &join_key).await;
            join_key.zeroize();
            result?;
            write_state(&cli.state_dir, &state)?;
            println!(
                "node credential renewed\n{}",
                credential_status(state.credential_expires_at, blaktaild_now() as i64)
            );
        }
        Command::Status => {
            let state = read_state(&cli.state_dir)?;
            println!(
                "joined\nnode: {}\ninterface: {}\naddress: {}\ndns: {}\ncoordinator: {}\ncredential: {}\npeers: {}",
                state.node_id,
                state.interface,
                state.assigned_ip,
                if state.dns_name.is_empty() { "unknown" } else { &state.dns_name },
                state.coord,
                credential_status(state.credential_expires_at, blaktaild_now() as i64),
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
            if let Some(domain) = dns_domain(&state.dns_name) {
                remove_system_dns(
                    &cli.state_dir,
                    &state.interface,
                    &domain,
                    state.dns_mode.as_deref(),
                )?;
            }
            let coordinator = Coordinator::new(&state.coord)?;
            coordinator.revoke(&state).await?;
            make_network().down(&state.interface)?;
            fs::remove_file(cli.state_dir.join("state.json"))?;
            println!("node revoked and {} removed", state.interface);
        }
    }
    Ok(())
}

fn credential_status(expires_at: i64, now: i64) -> String {
    if expires_at == 0 {
        return "expiry unknown; run the agent to refresh status".into();
    }
    if expires_at <= now {
        return format!("expired at Unix {expires_at}; run blaktaild reauth");
    }
    let days = (expires_at - now + 86_399) / 86_400;
    format!("expires at Unix {expires_at} (in {days} day(s))")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relayed_handshake_does_not_masquerade_as_direct_recovery() {
        let candidate = std::net::SocketAddr::from(([198, 51, 100, 1], 40_001));
        let path = PeerPath::Relayed {
            since: Instant::now(),
        };
        assert_eq!(
            path_action(path, true, 100, true, Some(candidate), false),
            PathAction::MaintainRelay
        );
    }

    #[test]
    fn relayed_path_uses_proven_peer_direct_or_retries_native() {
        let candidate = std::net::SocketAddr::from(([198, 51, 100, 1], 40_001));
        let path = PeerPath::Relayed {
            since: Instant::now() - Duration::from_secs(DIRECT_RETRY_SECS + 1),
        };
        assert_eq!(
            path_action(path, true, 100, true, Some(candidate), true),
            PathAction::PeerDirectRecovered
        );
        assert_eq!(
            path_action(path, true, 100, true, Some(candidate), false),
            PathAction::ProbeNativeDirect
        );
        assert_eq!(
            path_action(path, true, 100, false, Some(candidate), false),
            PathAction::MaintainRelay
        );
        let waiting = PeerPath::Relayed {
            since: Instant::now(),
        };
        assert_eq!(
            path_action(waiting, true, 100, true, Some(candidate), false),
            PathAction::MaintainRelay
        );
    }

    #[test]
    fn direct_probe_requires_new_handshake_or_falls_back() {
        let probing = PeerPath::DirectProbe {
            since: Instant::now(),
            baseline: 100,
        };
        assert_eq!(
            path_action(probing, true, 101, true, Some(candidate()), false),
            PathAction::DirectRecovered
        );
        let timed_out = PeerPath::DirectProbe {
            since: Instant::now() - Duration::from_secs(DIRECT_GRACE_SECS + 1),
            baseline: 100,
        };
        assert_eq!(
            path_action(timed_out, false, 100, true, None, false),
            PathAction::UseRelay
        );
    }

    #[test]
    fn stale_direct_path_falls_back_after_grace() {
        let path = PeerPath::Direct {
            since: Instant::now() - Duration::from_secs(DIRECT_GRACE_SECS + 1),
        };
        assert_eq!(
            path_action(path, false, 0, true, Some(candidate()), false),
            PathAction::UseRelay
        );
        assert_eq!(
            path_action(path, true, 100, true, Some(candidate()), false),
            PathAction::None
        );
    }

    #[test]
    fn peer_direct_path_returns_to_relay_when_stale_or_candidate_disappears() {
        let healthy = PeerPath::PeerDirect {
            last_fresh: Instant::now(),
        };
        assert_eq!(
            path_action(healthy, true, 100, true, Some(candidate()), true),
            PathAction::MaintainPeerDirect
        );
        assert_eq!(
            path_action(healthy, false, 100, true, None, false),
            PathAction::UseRelay
        );
        let stale = PeerPath::PeerDirect {
            last_fresh: Instant::now() - Duration::from_secs(DIRECT_GRACE_SECS + 1),
        };
        assert_eq!(
            path_action(stale, false, 100, true, Some(candidate()), false),
            PathAction::UseRelay
        );
    }

    #[tokio::test]
    async fn relay_resolution_rotates_away_from_failed_address() {
        let first = std::net::SocketAddr::from(([127, 0, 0, 1], 3478));
        let second = std::net::SocketAddr::from(([127, 0, 0, 2], 3478));
        let relays = vec![first.to_string(), second.to_string()];
        assert_eq!(resolve_relay(&relays, None).await, Some(first));
        assert_eq!(resolve_relay(&relays, Some(first)).await, Some(second));
        assert_eq!(resolve_relay(&relays[..1], Some(first)).await, Some(first));
    }

    #[test]
    fn credential_status_is_actionable() {
        assert!(credential_status(0, 100).contains("unknown"));
        assert!(credential_status(99, 100).contains("reauth"));
        assert!(credential_status(86_500, 100).contains("1 day"));
    }

    fn candidate() -> std::net::SocketAddr {
        std::net::SocketAddr::from(([198, 51, 100, 1], 40_001))
    }
}
