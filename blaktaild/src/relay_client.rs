//! Relay data-path client. When a peer's direct UDP path fails (hard NAT),
//! blaktaild repoints that peer's WireGuard endpoint at a local forwarder
//! socket; encrypted datagrams are then carried through the BlakTail relay
//! inside REGISTER/SEND/FORWARDED frames. WireGuard sees an ordinary localhost
//! endpoint, so the tunnel layer does not change.

use std::{
    collections::HashMap,
    io,
    net::SocketAddr,
    sync::{atomic::AtomicBool, Arc, Mutex},
    time::Duration,
};
use tokio::{net::UdpSocket, sync::Notify, task::AbortHandle};
use uuid::Uuid;

pub const REGISTER: u8 = 1;
pub const SEND: u8 = 2;
pub const FORWARDED: u8 = 3;
pub const ID_LEN: usize = 16;
pub const TOKEN_LEN: usize = 32;
const MAX_PAYLOAD: usize = 2_048;
/// Must stay below relay's default 120-second idle timeout.
const KEEPALIVE_SECS: u64 = 30;

struct Creds {
    token_raw: Vec<u8>,
    expires_at_unix: u64,
}

struct Forwarder {
    socket: Arc<UdpSocket>,
    task: AbortHandle,
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
                    if source != self.shared.relay_addr {
                        continue;
                    }
                    if len < 1 + ID_LEN || buf[0] != FORWARDED {
                        continue;
                    }
                    let mut source_id = [0u8; ID_LEN];
                    source_id.copy_from_slice(&buf[1..1 + ID_LEN]);
                    let Ok(source_peer) = Uuid::from_slice(&source_id) else { continue };
                    let Some(socket) = self.shared.forwarders.lock().ok()
                        .and_then(|f| f.get(&source_peer).map(|forwarder| forwarder.socket.clone())) else {
                        continue;
                    };
                    // Inject with the forwarder socket as source so the source
                    // matches the endpoint configured on the WG peer.
                    let _ = socket.send_to(&buf[1 + ID_LEN..len], self.shared.wg_listen).await;
                }
                _ = keepalive.tick() => {
                    if let Some(frame) = self.register_frame() {
                        let _ = self.shared.relay_socket.send_to(&frame, self.shared.relay_addr).await;
                    }
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

    /// Ensures a localhost forwarder exists for `peer_id`; returns the local
    /// port to install as that peer's WireGuard endpoint.
    pub async fn ensure_forwarder(&self, peer_id: Uuid) -> io::Result<u16> {
        if let Some(port) = self.forwarder_port(peer_id) {
            return Ok(port);
        }
        let socket = Arc::new(UdpSocket::bind("127.0.0.1:0").await?);
        let port = socket.local_addr()?.port();

        // Outgoing: anything arriving on this forwarder socket comes from the
        // local WireGuard interface; wrap it in a SEND frame for this peer.
        let shared = self.shared.clone();
        let task_socket = socket.clone();
        let task = tokio::spawn(async move {
            let mut buf = vec![0u8; 65_535];
            loop {
                let received = task_socket.recv_from(&mut buf).await;
                let (len, source) = match received {
                    Ok(r) => r,
                    Err(_) => return,
                };
                if source != shared.wg_listen || len > MAX_PAYLOAD {
                    continue;
                }
                let mut frame = Vec::with_capacity(1 + ID_LEN + len);
                frame.push(SEND);
                frame.extend_from_slice(peer_id.as_bytes());
                frame.extend_from_slice(&buf[..len]);
                if shared
                    .relay_socket
                    .send_to(&frame, shared.relay_addr)
                    .await
                    .is_err()
                {
                    return;
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
            },
        );
        Ok(port)
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

        let node_a = Uuid::new_v4();
        let node_b = Uuid::new_v4();
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
        )
        .unwrap();
        let mesh_b = RelayMesh::spawn(
            relay_addr,
            wg_b_addr,
            node_b,
            &capability(node_b, expires, &secret()),
            expires,
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

    #[test]
    fn registration_keepalive_precedes_default_idle_reap() {
        assert!(KEEPALIVE_SECS < blaktail_relay::RelayConfig::default().idle_secs);
        assert_eq!(MAX_PAYLOAD, blaktail_relay::MAX_PAYLOAD);
    }
}
