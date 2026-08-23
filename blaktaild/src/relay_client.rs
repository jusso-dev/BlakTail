//! Relay data-path client. When a peer's direct UDP path fails (hard NAT),
//! blaktaild repoints that peer's WireGuard endpoint at a local forwarder
//! socket; encrypted datagrams are then carried through the BlakTail relay
//! inside REGISTER/SEND/FORWARDED frames. WireGuard sees an ordinary localhost
//! endpoint, so the tunnel layer does not change.

use rand::{rngs::OsRng, RngCore};
use std::{
    collections::HashMap,
    io,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::{atomic::AtomicBool, Arc, Mutex},
    time::Duration,
};
use tokio::{net::UdpSocket, sync::Notify, task::AbortHandle};
use uuid::Uuid;

pub const REGISTER: u8 = 1;
pub const SEND: u8 = 2;
pub const FORWARDED: u8 = 3;
pub const PING: u8 = 4;
pub const OBSERVED: u8 = 5;
pub const DIRECT: u8 = 6;
pub const PUNCH: u8 = 7;
pub const PUNCH_ACK: u8 = 8;
pub const ID_LEN: usize = 16;
pub const TOKEN_LEN: usize = 32;
const HEADER: usize = 1 + ID_LEN;
const OBSERVED_FRAME: usize = HEADER + 1 + 16 + 2;
const MAX_PAYLOAD: usize = 2_048;
/// Must stay below relay's default 120-second idle timeout.
const KEEPALIVE_SECS: u64 = 30;
const DIRECT_REACHABLE_SECS: u64 = 5;
const RELAY_STARTUP_GRACE_SECS: u64 = 10;
const RELAY_HEALTH_SECS: u64 = 75;

struct Creds {
    token_raw: Vec<u8>,
    expires_at_unix: u64,
}

struct Forwarder {
    socket: Arc<UdpSocket>,
    task: AbortHandle,
    transport: Arc<Mutex<Transport>>,
    punch_nonce: u64,
    last_punch_ack: Arc<Mutex<Option<(SocketAddr, std::time::Instant)>>>,
}

#[derive(Clone, Copy)]
enum Transport {
    Relay(Option<SocketAddr>),
    Direct(SocketAddr),
}

impl Transport {
    fn candidate(self) -> Option<SocketAddr> {
        match self {
            Self::Relay(endpoint) => endpoint,
            Self::Direct(endpoint) => Some(endpoint),
        }
    }
}

struct Shared {
    relay_addr: SocketAddr,
    /// The address our WireGuard implementation listens on; incoming relayed
    /// datagrams are injected here so they appear to come from the peer's
    /// configured endpoint (the forwarder port on localhost).
    wg_listen: SocketAddr,
    self_id: [u8; ID_LEN],
    creds: Mutex<Creds>,
    /// Peer id -> forwarder socket whose local port is used as that peer's WG
    /// endpoint. Outgoing WG datagrams arrive here; we wrap and forward them.
    forwarders: Mutex<HashMap<Uuid, Forwarder>>,
    relay_socket: Arc<UdpSocket>,
    observed_endpoint: Mutex<Option<(SocketAddr, std::time::Instant)>>,
    started_at: std::time::Instant,
    stopped: AtomicBool,
    stop_notify: Notify,
}

#[derive(Clone)]
pub struct RelayMesh {
    shared: Arc<Shared>,
}

impl RelayMesh {
    /// Spawns the relay session. `wg_listen` must be the WireGuard listen
    /// socket (ip:port) on this machine.
    pub fn spawn(
        relay_addr: SocketAddr,
        wg_listen: SocketAddr,
        self_id: Uuid,
        relay_token_hex: &str,
        relay_expires_at_unix: u64,
        fwmark: Option<u32>,
    ) -> io::Result<Self> {
        let token_raw = hex_decode(relay_token_hex)
            .ok_or_else(|| io::Error::other("relay token is not valid hex"))?;
        if token_raw.len() != TOKEN_LEN {
            return Err(io::Error::other("relay token must be 32 bytes"));
        }
        let bind_addr = if relay_addr.is_ipv4() {
            "0.0.0.0:0"
        } else {
            "[::]:0"
        };
        let std_socket = std::net::UdpSocket::bind(bind_addr)?;
        set_fwmark(&std_socket, fwmark)?;
        std_socket.set_nonblocking(true)?;
        let relay_socket = Arc::new(UdpSocket::from_std(std_socket)?);
        let shared = Arc::new(Shared {
            relay_addr,
            wg_listen,
            self_id: *self_id.as_bytes(),
            creds: Mutex::new(Creds {
                token_raw,
                expires_at_unix: relay_expires_at_unix,
            }),
            forwarders: Mutex::new(HashMap::new()),
            relay_socket,
            observed_endpoint: Mutex::new(None),
            started_at: std::time::Instant::now(),
            stopped: AtomicBool::new(false),
            stop_notify: Notify::new(),
        });
        let mesh = Self { shared };
        tokio::spawn(mesh.clone().run());
        Ok(mesh)
    }

    async fn run(self) {
        if let Some(frame) = self.register_frame() {
            let _ = self
                .shared
                .relay_socket
                .send_to(&frame, self.shared.relay_addr)
                .await;
        }
        let _ = self
            .shared
            .relay_socket
            .send_to(&self.ping_frame(), self.shared.relay_addr)
            .await;
        let mut keepalive = tokio::time::interval(Duration::from_secs(KEEPALIVE_SECS));
        keepalive.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut buf = vec![0u8; 65_535];
        loop {
            if self
                .shared
                .stopped
                .load(std::sync::atomic::Ordering::Relaxed)
            {
                return;
            }
            tokio::select! {
                received = self.shared.relay_socket.recv_from(&mut buf) => {
                    let (len, source) = match received { Ok(r) => r, Err(_) => return };
                    if len < HEADER {
                        continue;
                    }
                    let mut source_id = [0u8; ID_LEN];
                    source_id.copy_from_slice(&buf[1..HEADER]);
                    if source == self.shared.relay_addr && buf[0] == OBSERVED {
                        if let Some(endpoint) = self.parse_observed(&buf[..len]) {
                            if let Ok(mut observed) = self.shared.observed_endpoint.lock() {
                                *observed = Some((endpoint, std::time::Instant::now()));
                            }
                        }
                        continue;
                    }
                    let Ok(source_peer) = Uuid::from_slice(&source_id) else { continue };
                    let Some((socket, transport, punch_nonce, last_punch_ack)) = self.shared.forwarders.lock().ok()
                        .and_then(|forwarders| forwarders.get(&source_peer).map(|forwarder| {
                            (
                                forwarder.socket.clone(),
                                forwarder.transport.clone(),
                                forwarder.punch_nonce,
                                forwarder.last_punch_ack.clone(),
                            )
                        })) else {
                        continue;
                    };
                    let payload = if source == self.shared.relay_addr
                        && buf[0] == FORWARDED
                        && len <= HEADER + MAX_PAYLOAD
                    {
                        Some(&buf[HEADER..len])
                    } else if matches!(buf[0], DIRECT | PUNCH | PUNCH_ACK) {
                        let expected = transport.lock().ok().and_then(|mode| mode.candidate());
                        if expected != Some(source) {
                            continue;
                        }
                        match buf[0] {
                            DIRECT if len <= HEADER + MAX_PAYLOAD => Some(&buf[HEADER..len]),
                            PUNCH if len == HEADER + 8 => {
                                let mut ack = vec![PUNCH_ACK];
                                ack.extend_from_slice(&self.shared.self_id);
                                ack.extend_from_slice(&buf[HEADER..len]);
                                let _ = self.shared.relay_socket.send_to(&ack, source).await;
                                None
                            }
                            PUNCH_ACK if len == HEADER + 8 => {
                                let received_nonce = u64::from_be_bytes(
                                    buf[HEADER..len].try_into().expect("length checked")
                                );
                                if received_nonce == punch_nonce {
                                    if let Ok(mut last_ack) = last_punch_ack.lock() {
                                        *last_ack = Some((source, std::time::Instant::now()));
                                    }
                                }
                                None
                            }
                            _ => None,
                        }
                    } else {
                        None
                    };
                    if let Some(payload) = payload {
                        // Inject with forwarder socket as source so WireGuard
                        // sees the configured localhost peer endpoint.
                        let _ = socket.send_to(payload, self.shared.wg_listen).await;
                    }
                }
                _ = keepalive.tick() => {
                    if let Some(frame) = self.register_frame() {
                        let _ = self.shared.relay_socket.send_to(&frame, self.shared.relay_addr).await;
                    }
                    let _ = self.shared.relay_socket.send_to(&self.ping_frame(), self.shared.relay_addr).await;
                }
                _ = self.shared.stop_notify.notified() => return,
            }
        }
    }

    fn register_frame(&self) -> Option<Vec<u8>> {
        let creds = self.shared.creds.lock().ok()?;
        let expiry = creds.expires_at_unix;
        let mut frame = vec![REGISTER];
        frame.extend_from_slice(&self.shared.self_id);
        frame.extend_from_slice(&expiry.to_be_bytes());
        frame.extend_from_slice(&creds.token_raw);
        Some(frame)
    }

    fn ping_frame(&self) -> Vec<u8> {
        let mut frame = vec![PING];
        frame.extend_from_slice(&self.shared.self_id);
        frame
    }

    fn parse_observed(&self, frame: &[u8]) -> Option<SocketAddr> {
        if frame.len() != OBSERVED_FRAME
            || frame[0] != OBSERVED
            || frame[1..HEADER] != self.shared.self_id
        {
            return None;
        }
        let ip_bytes: [u8; 16] = frame[HEADER + 1..HEADER + 17].try_into().ok()?;
        let ip = match frame[HEADER] {
            4 => IpAddr::V4(Ipv4Addr::new(
                ip_bytes[12],
                ip_bytes[13],
                ip_bytes[14],
                ip_bytes[15],
            )),
            6 => IpAddr::V6(Ipv6Addr::from(ip_bytes)),
            _ => return None,
        };
        let port = u16::from_be_bytes(frame[HEADER + 17..OBSERVED_FRAME].try_into().ok()?);
        (port != 0).then(|| SocketAddr::new(ip, port))
    }

    pub fn observed_endpoint(&self) -> Option<SocketAddr> {
        self.shared
            .observed_endpoint
            .lock()
            .ok()?
            .filter(|(_, seen)| seen.elapsed() < Duration::from_secs(RELAY_HEALTH_SECS))
            .map(|(endpoint, _)| endpoint)
    }

    pub fn relay_addr(&self) -> SocketAddr {
        self.shared.relay_addr
    }

    pub fn relay_healthy(&self) -> bool {
        self.shared
            .observed_endpoint
            .lock()
            .ok()
            .and_then(|observed| *observed)
            .is_some_and(|(_, seen)| seen.elapsed() < Duration::from_secs(RELAY_HEALTH_SECS))
            || self.shared.started_at.elapsed() < Duration::from_secs(RELAY_STARTUP_GRACE_SECS)
    }

    /// Ensures a localhost forwarder exists for `peer_id`; returns the local
    /// port to install as that peer's WireGuard endpoint.
    pub async fn ensure_forwarder(&self, peer_id: Uuid) -> io::Result<u16> {
        if let Some(port) = self.forwarder_port(peer_id) {
            return Ok(port);
        }
        let socket = Arc::new(UdpSocket::bind("127.0.0.1:0").await?);
        let port = socket.local_addr()?.port();

        // Outgoing: anything arriving on this forwarder socket comes from the
        // local WireGuard interface. Relay mode wraps SEND to relay; direct
        // mode sends authenticated WireGuard ciphertext to the
        // peer's coordinator-advertised reflexive address.
        let shared = self.shared.clone();
        let task_socket = socket.clone();
        let transport = Arc::new(Mutex::new(Transport::Relay(None)));
        let task_transport = transport.clone();
        let mut rng = OsRng;
        let punch_nonce = rng.next_u64();
        let last_punch_ack = Arc::new(Mutex::new(None));
        let task = tokio::spawn(async move {
            let mut buf = vec![0u8; 65_535];
            let mut punch = tokio::time::interval(Duration::from_secs(1));
            punch.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                tokio::select! {
                    received = task_socket.recv_from(&mut buf) => {
                        let (len, source) = match received {
                            Ok(r) => r,
                            Err(_) => return,
                        };
                        if source != shared.wg_listen || len > MAX_PAYLOAD {
                            continue;
                        }
                        let mode = match task_transport.lock() {
                            Ok(mode) => *mode,
                            Err(_) => return,
                        };
                        let (opcode, id, destination) = match mode {
                            Transport::Relay(_) => (SEND, *peer_id.as_bytes(), shared.relay_addr),
                            Transport::Direct(candidate) => {
                                (DIRECT, shared.self_id, candidate)
                            }
                        };
                        let mut frame = Vec::with_capacity(HEADER + len);
                        frame.push(opcode);
                        frame.extend_from_slice(&id);
                        frame.extend_from_slice(&buf[..len]);
                        if shared.relay_socket.send_to(&frame, destination).await.is_err() {
                            return;
                        }
                    }
                    _ = punch.tick() => {
                        let candidate = task_transport
                            .lock()
                            .ok()
                            .and_then(|mode| mode.candidate());
                        if let Some(candidate) = candidate {
                            let mut frame = vec![PUNCH];
                            frame.extend_from_slice(&shared.self_id);
                            frame.extend_from_slice(&punch_nonce.to_be_bytes());
                            let _ = shared.relay_socket.send_to(&frame, candidate).await;
                        }
                    }
                }
            }
        });
        let abort = task.abort_handle();
        let mut forwarders = self
            .shared
            .forwarders
            .lock()
            .map_err(|_| io::Error::other("poisoned"))?;
        if let Some(existing) = forwarders.get(&peer_id) {
            task.abort();
            return existing.socket.local_addr().map(|address| address.port());
        }
        forwarders.insert(
            peer_id,
            Forwarder {
                socket: socket.clone(),
                task: abort,
                transport,
                punch_nonce,
                last_punch_ack,
            },
        );
        Ok(port)
    }

    pub fn use_peer_direct(&self, peer_id: Uuid, endpoint: SocketAddr) -> bool {
        self.set_transport(peer_id, Transport::Direct(endpoint))
    }

    pub fn use_relay(&self, peer_id: Uuid, peer_endpoint: Option<SocketAddr>) -> bool {
        self.set_transport(peer_id, Transport::Relay(peer_endpoint))
    }

    pub fn is_peer_direct(&self, peer_id: Uuid) -> bool {
        self.shared
            .forwarders
            .lock()
            .ok()
            .and_then(|forwarders| {
                forwarders
                    .get(&peer_id)
                    .and_then(|forwarder| forwarder.transport.lock().ok())
                    .map(|transport| matches!(*transport, Transport::Direct(_)))
            })
            .unwrap_or(false)
    }

    pub fn peer_direct_reachable(&self, peer_id: Uuid, endpoint: SocketAddr) -> bool {
        self.shared
            .forwarders
            .lock()
            .ok()
            .and_then(|forwarders| {
                forwarders
                    .get(&peer_id)
                    .and_then(|forwarder| forwarder.last_punch_ack.lock().ok())
                    .and_then(|last_ack| *last_ack)
            })
            .is_some_and(|(source, last_ack)| {
                source == endpoint
                    && last_ack.elapsed() < Duration::from_secs(DIRECT_REACHABLE_SECS)
            })
    }

    fn set_transport(&self, peer_id: Uuid, next: Transport) -> bool {
        let Ok(forwarders) = self.shared.forwarders.lock() else {
            return false;
        };
        let Some(forwarder) = forwarders.get(&peer_id) else {
            return false;
        };
        let Ok(mut transport) = forwarder.transport.lock() else {
            return false;
        };
        *transport = next;
        true
    }

    /// Stops relaying for a peer and drops its forwarder socket.
    pub fn drop_forwarder(&self, peer_id: Uuid) {
        if let Ok(mut forwarders) = self.shared.forwarders.lock() {
            if let Some(forwarder) = forwarders.remove(&peer_id) {
                forwarder.task.abort();
            }
        }
    }

    pub fn forwarder_port(&self, peer_id: Uuid) -> Option<u16> {
        self.shared
            .forwarders
            .lock()
            .ok()?
            .get(&peer_id)
            .and_then(|forwarder| forwarder.socket.local_addr().ok())
            .map(|a| a.port())
    }

    pub fn has_forwarder(&self, peer_id: Uuid) -> bool {
        self.forwarder_port(peer_id).is_some()
    }

    /// Installs refreshed credentials handed down by the coordinator poll.
    pub fn update_credentials(&self, relay_token_hex: &str, relay_expires_at_unix: u64) {
        let Some(raw) = hex_decode(relay_token_hex) else {
            return;
        };
        if raw.len() != TOKEN_LEN {
            return;
        }
        if let Ok(mut creds) = self.shared.creds.lock() {
            creds.token_raw = raw;
            creds.expires_at_unix = relay_expires_at_unix;
        }
    }

    pub fn stop(&self) {
        if self
            .shared
            .stopped
            .swap(true, std::sync::atomic::Ordering::Relaxed)
        {
            return;
        }
        self.shared.stop_notify.notify_one();
        if let Ok(mut forwarders) = self.shared.forwarders.lock() {
            for (_, forwarder) in forwarders.drain() {
                forwarder.task.abort();
            }
        }
    }
}

#[cfg(target_os = "linux")]
fn set_fwmark(socket: &std::net::UdpSocket, fwmark: Option<u32>) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    let Some(fwmark) = fwmark else {
        return Ok(());
    };
    // SAFETY: `socket` owns a valid UDP descriptor, and the pointer/length
    // describe a live `u32` for the duration of this `setsockopt` call.
    let result = unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_MARK,
            (&fwmark as *const u32).cast(),
            std::mem::size_of::<u32>() as libc::socklen_t,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(not(target_os = "linux"))]
fn set_fwmark(_socket: &std::net::UdpSocket, _fwmark: Option<u32>) -> io::Result<()> {
    Ok(())
}

pub fn hex_decode(input: &str) -> Option<Vec<u8>> {
    if !input.len().is_multiple_of(2) {
        return None;
    }
    (0..input.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&input[i..i + 2], 16).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn secret() -> Vec<u8> {
        b"mesh-test-secret".to_vec()
    }

    fn to_hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    fn capability(node: Uuid, expires_at: u64, key: &[u8]) -> String {
        to_hex(&blaktail_relay::mint_token(
            key,
            node.as_bytes(),
            expires_at,
        ))
    }

    #[tokio::test]
    async fn relayed_datagrams_cross_meshes() {
        // Real relay server on loopback.
        let relay = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let relay_addr = relay.local_addr().unwrap();
        let relay_task = tokio::spawn(blaktail_relay::serve_with_metrics(
            relay,
            blaktail_relay::RelayConfig {
                auth_secret: secret(),
                ..blaktail_relay::RelayConfig::default()
            },
            Arc::new(blaktail_relay::Metrics::default()),
        ));

        let node_a = Uuid::from_u128(1);
        let node_b = Uuid::from_u128(2);
        let expires = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 600;

        // Each node has its own "WireGuard" listener.
        let wg_a = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let wg_b = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let wg_a_addr = wg_a.local_addr().unwrap();
        let wg_b_addr = wg_b.local_addr().unwrap();

        let mesh_a = RelayMesh::spawn(
            relay_addr,
            wg_a_addr,
            node_a,
            &capability(node_a, expires, &secret()),
            expires,
            None,
        )
        .unwrap();
        let mesh_b = RelayMesh::spawn(
            relay_addr,
            wg_b_addr,
            node_b,
            &capability(node_b, expires, &secret()),
            expires,
            None,
        )
        .unwrap();

        // A wants to reach B over the relay; B likewise.
        let port_b = mesh_a.ensure_forwarder(node_b).await.unwrap();
        let port_a = mesh_b.ensure_forwarder(node_a).await.unwrap();
        tokio::time::sleep(Duration::from_millis(150)).await;

        // A's WireGuard sends toward B's forwarder endpoint (127.0.0.1:port_b),
        // exactly like kernel/userspace WG would after an endpoint rewrite.
        wg_a.send_to(b"hello-b", format!("127.0.0.1:{port_b}"))
            .await
            .unwrap();

        // B's WG listener receives the payload sourced from A's forwarder
        // endpoint (127.0.0.1:port_a).
        let mut buf = [0u8; 128];
        let (n, src) = tokio::time::timeout(Duration::from_secs(2), wg_b.recv_from(&mut buf))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&buf[..n], b"hello-b");
        assert_eq!(src.port(), port_a);

        // Reverse direction works too.
        wg_b.send_to(b"hi-a", format!("127.0.0.1:{port_a}"))
            .await
            .unwrap();
        let (n, src) = tokio::time::timeout(Duration::from_secs(2), wg_a.recv_from(&mut buf))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&buf[..n], b"hi-a");
        assert_eq!(src.port(), port_b);

        mesh_a.drop_forwarder(node_b);
        assert!(!mesh_a.has_forwarder(node_b));
        tokio::task::yield_now().await;
        let rebound = UdpSocket::bind(format!("127.0.0.1:{port_b}"))
            .await
            .unwrap();
        drop(rebound);

        mesh_a.stop();
        mesh_b.stop();
        relay_task.abort();
    }

    #[tokio::test]
    async fn peer_direct_datagrams_bypass_relay_after_reflexive_discovery() {
        let relay = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let relay_addr = relay.local_addr().unwrap();
        let relay_task = tokio::spawn(blaktail_relay::serve(
            relay,
            blaktail_relay::RelayConfig {
                auth_secret: secret(),
                ..blaktail_relay::RelayConfig::default()
            },
        ));
        let node_a = Uuid::from_u128(1);
        let node_b = Uuid::from_u128(2);
        let expires = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 600;
        let wg_a = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let wg_b = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let mesh_a = RelayMesh::spawn(
            relay_addr,
            wg_a.local_addr().unwrap(),
            node_a,
            &capability(node_a, expires, &secret()),
            expires,
            None,
        )
        .unwrap();
        let mesh_b = RelayMesh::spawn(
            relay_addr,
            wg_b.local_addr().unwrap(),
            node_b,
            &capability(node_b, expires, &secret()),
            expires,
            None,
        )
        .unwrap();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        while (mesh_a.observed_endpoint().is_none() || mesh_b.observed_endpoint().is_none())
            && tokio::time::Instant::now() < deadline
        {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let endpoint_a = mesh_a.observed_endpoint().unwrap();
        let endpoint_b = mesh_b.observed_endpoint().unwrap();
        let port_b = mesh_a.ensure_forwarder(node_b).await.unwrap();
        let port_a = mesh_b.ensure_forwarder(node_a).await.unwrap();
        assert!(mesh_a.use_relay(node_b, Some(endpoint_b)));
        assert!(mesh_b.use_relay(node_a, Some(endpoint_a)));
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        while !(mesh_a.peer_direct_reachable(node_b, endpoint_b)
            && mesh_b.peer_direct_reachable(node_a, endpoint_a))
            && tokio::time::Instant::now() < deadline
        {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(mesh_a.peer_direct_reachable(node_b, endpoint_b));
        assert!(mesh_b.peer_direct_reachable(node_a, endpoint_a));
        assert!(!mesh_a.peer_direct_reachable(
            node_b,
            SocketAddr::new(endpoint_b.ip(), endpoint_b.port().wrapping_add(1))
        ));

        // Discovery does not interrupt the working encrypted relay path.
        let mut buf = [0u8; 128];
        wg_a.send_to(b"during-punch", format!("127.0.0.1:{port_b}"))
            .await
            .unwrap();
        let (len, source) = tokio::time::timeout(Duration::from_secs(1), wg_b.recv_from(&mut buf))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&buf[..len], b"during-punch");
        assert_eq!(source.port(), port_a);

        assert!(mesh_a.use_peer_direct(node_b, endpoint_b));
        assert!(mesh_b.use_peer_direct(node_a, endpoint_a));

        // Relay is gone: successful delivery now proves peer-to-peer transport.
        relay_task.abort();
        wg_a.send_to(b"direct", format!("127.0.0.1:{port_b}"))
            .await
            .unwrap();
        let (len, source) = tokio::time::timeout(Duration::from_secs(1), wg_b.recv_from(&mut buf))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&buf[..len], b"direct");
        assert_eq!(source.port(), port_a);
        assert!(mesh_a.is_peer_direct(node_b));

        // A spoofed source id from a different UDP address cannot inject.
        let attacker = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let mut forged = vec![DIRECT];
        forged.extend_from_slice(node_a.as_bytes());
        forged.extend_from_slice(b"forged");
        attacker.send_to(&forged, endpoint_b).await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(150), wg_b.recv_from(&mut buf))
                .await
                .is_err()
        );

        mesh_a.stop();
        mesh_b.stop();
    }

    #[test]
    fn registration_keepalive_precedes_default_idle_reap() {
        assert!(KEEPALIVE_SECS < blaktail_relay::RelayConfig::default().idle_secs);
        assert_eq!(MAX_PAYLOAD, blaktail_relay::MAX_PAYLOAD);
    }

    #[test]
    fn ipv6_minimum_mtu_fits_relay_envelope() {
        const WIREGUARD_TRANSPORT_OVERHEAD: usize = 32;
        const IPV6_AND_UDP_OVERHEAD: usize = 40 + 8;
        assert_eq!(
            crate::TUNNEL_MTU.parse::<usize>().unwrap(),
            crate::TUNNEL_MTU_BYTES
        );
        let encrypted_packet = crate::TUNNEL_MTU_BYTES + WIREGUARD_TRANSPORT_OVERHEAD;
        assert!(encrypted_packet <= MAX_PAYLOAD);
        assert!(encrypted_packet + HEADER + IPV6_AND_UDP_OVERHEAD <= 1_500);
    }
}
