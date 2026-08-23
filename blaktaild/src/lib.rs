use base64::{engine::general_purpose::STANDARD, Engine};
use rand::rngs::OsRng;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap},
    fs::{self, OpenOptions},
    io::{self, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};
use thiserror::Error;
use uuid::Uuid;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroize;

pub mod dns;
pub mod relay_client;
pub use dns::{configure_system_dns, dns_domain, remove_system_dns, MagicDns};
pub use relay_client::RelayMesh;

pub const DEFAULT_STATE_DIR: &str = "/var/lib/blaktail";
pub const DEFAULT_INTERFACE: &str = "blaktail0";
pub const TUNNEL_MTU: &str = "1280";

#[derive(Debug, Error)]
pub enum Error {
    #[error("{0}")]
    Message(String),
    #[error("I/O error: {0}")]
    Io(#[from] io::Error),
    #[error("coordinator request failed: {0}")]
    Http(#[from] reqwest::Error),
    #[error("invalid state: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Peer {
    pub id: Uuid,
    pub name: String,
    pub wg_public_key: String,
    pub endpoint: Option<String>,
    pub allowed_ips: Vec<String>,
    #[serde(default)]
    pub dns_name: String,
    #[serde(default)]
    pub tags: Vec<String>,
    /// Reflexive UDP address of the peer's relay-client socket. A nonce exchange
    /// proves reachability before opaque WireGuard ciphertext uses this path.
    #[serde(default)]
    pub relay_endpoint: Option<String>,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PeerChange {
    Remove(String),
    Upsert(Peer),
}

pub fn peer_diff(current: &[Peer], desired: &[Peer]) -> Vec<PeerChange> {
    let old: BTreeMap<_, _> = current.iter().map(|p| (&p.wg_public_key, p)).collect();
    let new: BTreeMap<_, _> = desired.iter().map(|p| (&p.wg_public_key, p)).collect();
    let mut changes = vec![];
    for key in old.keys() {
        if !new.contains_key(key) {
            changes.push(PeerChange::Remove((*key).clone()));
        }
    }
    for (key, peer) in new {
        if old.get(key).copied() != Some(peer) {
            changes.push(PeerChange::Upsert(peer.clone()));
        }
    }
    changes
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct NodeState {
    pub node_id: Uuid,
    pub node_token: String,
    pub coord: String,
    pub interface: String,
    pub assigned_ip: String,
    #[serde(default)]
    pub dns_name: String,
    #[serde(default)]
    pub credential_expires_at: i64,
    #[serde(default)]
    pub peers: Vec<Peer>,
    /// Advertised relay endpoints (host:port UDP) and our capability token.
    #[serde(default)]
    pub relays: Vec<String>,
    #[serde(default)]
    pub relay_token: String,
    #[serde(default)]
    pub relay_expires_at: u64,
    #[serde(default)]
    pub relay_endpoint: Option<String>,
    #[serde(default)]
    pub relay_endpoint_reported_at: u64,
    #[serde(default)]
    pub dns_mode: Option<String>,
}
#[derive(Serialize)]
struct RegisterRequest<'a> {
    join_key: &'a str,
    name: &'a str,
    wg_public_key: &'a str,
    endpoint: Option<&'a str>,
    allowed_ips: Vec<String>,
}
#[derive(Serialize)]
struct DeviceAuthorizationRequest<'a> {
    name: &'a str,
    wg_public_key: &'a str,
}
#[derive(Debug, Deserialize)]
pub struct DeviceAuthorization {
    pub device_code: String,
    pub user_code: String,
    pub verification_url: String,
    pub expires_at: i64,
    pub interval_seconds: u64,
}
#[derive(Deserialize)]
struct DeviceAuthorizationStatus {
    status: String,
}
#[derive(Deserialize)]
struct RegisterResponse {
    id: Uuid,
    node_token: String,
    assigned_ip: String,
    #[serde(default)]
    dns_name: String,
    #[serde(default)]
    credential_expires_at: i64,
    #[serde(default)]
    relays: Vec<String>,
    #[serde(default)]
    relay_token: String,
    #[serde(default)]
    relay_expires_at: u64,
}
#[derive(Deserialize)]
struct PeersResponse {
    peers: Vec<Peer>,
    #[serde(default)]
    dns_name: String,
    #[serde(default)]
    credential_expires_at: i64,
    #[serde(default)]
    relays: Vec<String>,
    #[serde(default)]
    relay_token: String,
    #[serde(default)]
    relay_expires_at: u64,
}

#[derive(Serialize)]
struct ReauthRequest<'a> {
    join_key: &'a str,
}

#[derive(Deserialize)]
struct ReauthResponse {
    node_token: String,
    credential_expires_at: i64,
}

#[derive(Deserialize)]
struct ApiErrorResponse {
    error: String,
}

#[derive(Clone)]
pub struct Coordinator {
    base: String,
    client: reqwest::Client,
}
impl Coordinator {
    pub fn new(base: &str) -> Result<Self, Error> {
        let base = base.trim_end_matches('/').to_owned();
        if !(base.starts_with("https://")
            || base.starts_with("http://127.0.0.1")
            || base.starts_with("http://localhost"))
        {
            return Err(Error::Message(
                "coordinator must use HTTPS (HTTP is allowed only for localhost)".into(),
            ));
        }
        Ok(Self {
            base,
            client: reqwest::Client::new(),
        })
    }
    pub async fn begin_device_authorization(
        &self,
        name: &str,
        public_key: &str,
    ) -> Result<DeviceAuthorization, Error> {
        let response = self
            .client
            .post(format!("{}/v1/device-authorizations", self.base))
            .json(&DeviceAuthorizationRequest {
                name,
                wg_public_key: public_key,
            })
            .send()
            .await?;
        if !response.status().is_success() {
            let status = response.status();
            let message = response
                .json::<ApiErrorResponse>()
                .await
                .map(|body| body.error)
                .unwrap_or_else(|_| format!("coordinator returned {status}"));
            return Err(Error::Message(format!(
                "could not start browser enrollment: {message}"
            )));
        }
        Ok(response.json().await?)
    }
    pub async fn device_authorization_approved(&self, device_code: &str) -> Result<bool, Error> {
        let response = self
            .client
            .get(format!(
                "{}/v1/device-authorizations/{device_code}",
                self.base
            ))
            .send()
            .await?;
        let status = response.status();
        if status == reqwest::StatusCode::GONE || status == reqwest::StatusCode::UNAUTHORIZED {
            let message = response
                .json::<ApiErrorResponse>()
                .await
                .map(|body| body.error)
                .unwrap_or_else(|_| "device authorization expired or was rejected".into());
            return Err(Error::Message(message));
        }
        if status != reqwest::StatusCode::OK && status != reqwest::StatusCode::ACCEPTED {
            return Err(Error::Message(format!(
                "device authorization polling failed ({status})"
            )));
        }
        let body: DeviceAuthorizationStatus = response.json().await?;
        match (status, body.status.as_str()) {
            (reqwest::StatusCode::OK, "approved") => Ok(true),
            (reqwest::StatusCode::ACCEPTED, "pending") => Ok(false),
            _ => Err(Error::Message(
                "coordinator returned an invalid device authorization state".into(),
            )),
        }
    }
    pub async fn register(
        &self,
        key: &str,
        name: &str,
        public_key: &str,
        endpoint: Option<&str>,
        interface: &str,
    ) -> Result<NodeState, Error> {
        let response = self
            .client
            .post(format!("{}/v1/nodes/register", self.base))
            .json(&RegisterRequest {
                join_key: key,
                name,
                wg_public_key: public_key,
                endpoint,
                allowed_ips: vec![],
            })
            .send()
            .await?;
        if !response.status().is_success() {
            return Err(Error::Message(format!(
                "join rejected by coordinator ({})",
                response.status()
            )));
        }
        let r: RegisterResponse = response.json().await?;
        Ok(NodeState {
            node_id: r.id,
            node_token: r.node_token,
            coord: self.base.clone(),
            interface: interface.into(),
            assigned_ip: r.assigned_ip,
            dns_name: r.dns_name,
            credential_expires_at: r.credential_expires_at,
            peers: vec![],
            relays: r.relays,
            relay_token: r.relay_token,
            relay_expires_at: r.relay_expires_at,
            relay_endpoint: None,
            relay_endpoint_reported_at: 0,
            dns_mode: None,
        })
    }
    pub async fn peers(&self, state: &mut NodeState) -> Result<Vec<Peer>, Error> {
        let response = self
            .client
            .get(format!("{}/v1/nodes/{}/peers", self.base, state.node_id))
            .bearer_auth(&state.node_token)
            .send()
            .await?;
        if response.status() == reqwest::StatusCode::UNAUTHORIZED {
            let message = response
                .json::<ApiErrorResponse>()
                .await
                .map(|body| body.error)
                .unwrap_or_else(|_| "node authentication rejected".into());
            return Err(Error::Message(message));
        }
        let body: PeersResponse = response.error_for_status()?.json().await?;
        state.dns_name = body.dns_name;
        state.credential_expires_at = body.credential_expires_at;
        state.relays = body.relays;
        state.relay_token = body.relay_token;
        state.relay_expires_at = body.relay_expires_at;
        Ok(body.peers)
    }
    pub async fn reauth(&self, state: &mut NodeState, join_key: &str) -> Result<(), Error> {
        let response = self
            .client
            .post(format!("{}/v1/nodes/{}/reauth", self.base, state.node_id))
            .bearer_auth(&state.node_token)
            .json(&ReauthRequest { join_key })
            .send()
            .await?;
        if !response.status().is_success() {
            return Err(Error::Message(format!(
                "re-authentication rejected by coordinator ({})",
                response.status()
            )));
        }
        let renewed: ReauthResponse = response.json().await?;
        state.node_token = renewed.node_token;
        state.credential_expires_at = renewed.credential_expires_at;
        Ok(())
    }
    pub async fn revoke(&self, state: &NodeState) -> Result<(), Error> {
        self.client
            .delete(format!("{}/v1/nodes/{}", self.base, state.node_id))
            .bearer_auth(&state.node_token)
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }
    pub async fn report_relay_endpoint(
        &self,
        state: &NodeState,
        endpoint: std::net::SocketAddr,
    ) -> Result<(), Error> {
        self.client
            .put(format!(
                "{}/v1/nodes/{}/relay-endpoint",
                self.base, state.node_id
            ))
            .bearer_auth(&state.node_token)
            .json(&serde_json::json!({"endpoint": endpoint.to_string()}))
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }
}

pub fn ensure_private_key(dir: &Path) -> Result<(PathBuf, String), Error> {
    fs::create_dir_all(dir)?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    let path = dir.join("private.key");
    if !path.exists() {
        let secret = StaticSecret::random_from_rng(OsRng);
        let mut encoded = STANDARD.encode(secret.to_bytes());
        write_secret(&path, encoded.as_bytes())?;
        encoded.zeroize();
    }
    let mode = fs::metadata(&path)?.permissions().mode() & 0o777;
    if mode != 0o600 {
        return Err(Error::Message(format!(
            "{} must have mode 0600 (found {mode:04o})",
            path.display()
        )));
    }
    let mut encoded = fs::read_to_string(&path)?;
    let bytes = STANDARD
        .decode(encoded.trim())
        .map_err(|_| Error::Message("private key file is not valid base64".into()))?;
    encoded.zeroize();
    let raw: [u8; 32] = bytes
        .try_into()
        .map_err(|_| Error::Message("private key must contain 32 bytes".into()))?;
    let public = STANDARD.encode(PublicKey::from(&StaticSecret::from(raw)).as_bytes());
    Ok((path, public))
}
pub fn write_state(dir: &Path, state: &NodeState) -> Result<(), Error> {
    write_secret(&dir.join("state.json"), &serde_json::to_vec_pretty(state)?)
}
fn write_secret(path: &Path, bytes: &[u8]) -> Result<(), Error> {
    let tmp = path.with_extension("tmp");
    let mut f = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&tmp)?;
    f.write_all(bytes)?;
    f.sync_all()?;
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))?;
    fs::rename(tmp, path)?;
    Ok(())
}
pub fn read_state(dir: &Path) -> Result<NodeState, Error> {
    Ok(serde_json::from_slice(&fs::read(dir.join("state.json"))?)?)
}

pub trait Network {
    fn setup(&mut self, interface: &str, key: &Path, address: &str) -> Result<(), Error>;
    fn apply(&mut self, interface: &str, changes: &[PeerChange]) -> Result<(), Error>;
    fn down(&mut self, interface: &str) -> Result<(), Error>;
    /// Repoints one peer's transport endpoint without touching its other
    /// settings. Used to switch a peer between direct and relay paths.
    fn set_peer_endpoint(
        &mut self,
        interface: &str,
        peer_key_b64: &str,
        endpoint: &str,
    ) -> Result<(), Error>;
    /// Unix timestamps of the latest handshake per peer key (base64), if known.
    fn latest_handshakes(&mut self, interface: &str) -> Result<HashMap<String, u64>, Error>;
    /// The WireGuard listen endpoint on this machine (loopback IP + port).
    fn listen_endpoint(&mut self, interface: &str) -> Result<Option<std::net::SocketAddr>, Error>;
}
/// Normalises a base64 WireGuard public key to the hex form used by the
/// userspace UAPI, so path-management bookkeeping is uniform per platform.
pub fn peer_key_hex(peer_key_b64: &str) -> Option<String> {
    let raw = STANDARD.decode(peer_key_b64.trim()).ok()?;
    Some(raw.iter().map(|b| format!("{b:02x}")).collect())
}
/// Decides when a peer's direct path is considered dead (no handshake within
/// this window after first observation) and how long we keep re-trying it.
pub const DIRECT_GRACE_SECS: u64 = 30;
pub const HANDSHAKE_FRESH_SECS: u64 = 180;
pub const DIRECT_RETRY_SECS: u64 = 300;
#[derive(Default)]
pub struct LinuxNetwork;
impl LinuxNetwork {
    fn run(program: &str, args: &[&str]) -> Result<(), Error> {
        let out = Command::new(program)
            .args(args)
            .stdin(Stdio::null())
            .output()
            .map_err(|e| Error::Message(format!("could not execute {program}: {e}")))?;
        if out.status.success() {
            Ok(())
        } else {
            Err(Error::Message(format!(
                "{program} failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            )))
        }
    }
}
impl Network for LinuxNetwork {
    fn setup(&mut self, interface: &str, key: &Path, address: &str) -> Result<(), Error> {
        let _ = Command::new("ip")
            .args(["link", "delete", "dev", interface])
            .output();
        if Self::run(
            "ip",
            &["link", "add", "dev", interface, "type", "wireguard"],
        )
        .is_err()
        {
            Self::run("boringtun", &[interface]).map_err(|_| {
                Error::Message(
                    "kernel WireGuard is unavailable and boringtun could not be started".into(),
                )
            })?;
        }
        let key = key
            .to_str()
            .ok_or_else(|| Error::Message("private key path is not UTF-8".into()))?;
        Self::run("wg", &["set", interface, "private-key", key])?;
        Self::run("ip", &["address", "replace", address, "dev", interface])?;
        Self::run("ip", &["link", "set", "dev", interface, "mtu", TUNNEL_MTU])?;
        Self::run("ip", &["link", "set", "up", "dev", interface])
    }
    fn apply(&mut self, interface: &str, changes: &[PeerChange]) -> Result<(), Error> {
        for change in changes {
            match change {
                PeerChange::Remove(key) => {
                    Self::run("wg", &["set", interface, "peer", key, "remove"])?
                }
                PeerChange::Upsert(peer) => {
                    let ips = peer.allowed_ips.join(",");
                    let mut args = vec![
                        "set",
                        interface,
                        "peer",
                        peer.wg_public_key.as_str(),
                        "allowed-ips",
                        ips.as_str(),
                    ];
                    if let Some(endpoint) = &peer.endpoint {
                        args.extend(["endpoint", endpoint.as_str(), "persistent-keepalive", "25"]);
                    }
                    Self::run("wg", &args)?;
                }
            }
        }
        Ok(())
    }
    fn down(&mut self, interface: &str) -> Result<(), Error> {
        Self::run("ip", &["link", "delete", "dev", interface])
    }
    fn set_peer_endpoint(
        &mut self,
        interface: &str,
        peer_key_b64: &str,
        endpoint: &str,
    ) -> Result<(), Error> {
        Self::run(
            "wg",
            &[
                "set",
                interface,
                "peer",
                peer_key_b64.trim(),
                "endpoint",
                endpoint,
            ],
        )
    }
    fn latest_handshakes(&mut self, interface: &str) -> Result<HashMap<String, u64>, Error> {
        let out = Command::new("wg")
            .args(["show", interface, "latest-handshakes"])
            .stdin(Stdio::null())
            .output()
            .map_err(|e| Error::Message(format!("could not execute wg: {e}")))?;
        if !out.status.success() {
            return Err(Error::Message("wg latest-handshakes failed".into()));
        }
        let mut map = HashMap::new();
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            let Some((key, stamp)) = line.split_once('\t') else {
                continue;
            };
            if let (Some(hex), Ok(secs)) = (peer_key_hex(key), stamp.trim().parse::<u64>()) {
                map.insert(hex, secs);
            }
        }
        Ok(map)
    }
    fn listen_endpoint(&mut self, interface: &str) -> Result<Option<std::net::SocketAddr>, Error> {
        let out = Command::new("wg")
            .args(["show", interface, "listen-port"])
            .stdin(Stdio::null())
            .output()
            .map_err(|e| Error::Message(format!("could not execute wg: {e}")))?;
        if !out.status.success() {
            return Ok(None);
        }
        let port: u16 = String::from_utf8_lossy(&out.stdout)
            .trim()
            .parse()
            .map_err(|_| Error::Message("wg listen-port is not numeric".into()))?;
        Ok((port != 0).then(|| std::net::SocketAddr::from(([127, 0, 0, 1], port))))
    }
}

/// Userspace WireGuard backend for macOS. Opens a kernel `utun` device through
/// boringtun and drives it over the local UAPI socket, so no Network Extension
/// or kernel module is required.
#[cfg(target_os = "macos")]
pub struct MacOsNetwork {
    device: Option<boringtun::device::DeviceHandle>,
    name: Option<String>,
    private_hex: String,
    peers: Vec<Peer>,
}

#[cfg(target_os = "macos")]
impl MacOsNetwork {
    pub fn new() -> Self {
        Self {
            device: None,
            name: None,
            private_hex: String::new(),
            peers: vec![],
        }
    }

    fn utun_name(&self) -> Result<&str, Error> {
        self.name
            .as_deref()
            .ok_or_else(|| Error::Message("utun device is not open".into()))
    }

    fn read_private_hex(key: &Path) -> Result<String, Error> {
        let encoded = fs::read_to_string(key)?;
        let bytes = STANDARD
            .decode(encoded.trim())
            .map_err(|_| Error::Message("private key file is not valid base64".into()))?;
        Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
    }

    fn uapi(&self, request: &str) -> Result<(), Error> {
        let name = self.utun_name()?;
        let path = format!("/var/run/wireguard/{name}.sock");
        let mut stream = std::os::unix::net::UnixStream::connect(path.clone())
            .map_err(|e| Error::Message(format!("connect WireGuard UAPI {path}: {e}")))?;
        use std::io::{Read as _, Write as _};
        stream
            .write_all(request.as_bytes())
            .and_then(|_| stream.shutdown(std::net::Shutdown::Write))
            .map_err(|e| Error::Message(format!("write WireGuard UAPI {path}: {e}")))?;
        let mut response = String::new();
        stream.read_to_string(&mut response)?;
        if !response.contains("errno=0") {
            return Err(Error::Message(
                "WireGuard UAPI rejected the peer configuration".into(),
            ));
        }
        Ok(())
    }

    fn run(program: &str, args: &[&str]) -> Result<(), Error> {
        let out = Command::new(program)
            .args(args)
            .stdin(Stdio::null())
            .output()
            .map_err(|e| Error::Message(format!("could not execute {program}: {e}")))?;
        if out.status.success() {
            Ok(())
        } else {
            Err(Error::Message(format!(
                "{program} failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            )))
        }
    }

    /// Applies the full desired peer set with `replace_peers=true`, then pins a
    /// host route per allowed IP so tailnet traffic rides the utun device.
    fn push_config_and_routes(&self) -> Result<(), Error> {
        let mut request = format!(
            "set=1\nprivate_key={}\nreplace_peers=true\n",
            self.private_hex
        );
        for peer in &self.peers {
            request.push_str(&format!(
                "public_key={}\nreplace_allowed_ips=true\npersistent_keepalive_interval=25\n",
                peer.wg_public_key
            ));
            if let Some(endpoint) = &peer.endpoint {
                request.push_str(&format!("endpoint={endpoint}\n"));
            }
            for ip in &peer.allowed_ips {
                request.push_str(&format!("allowed_ip={ip}\n"));
            }
        }
        request.push('\n');
        self.uapi(&request)?;
        let name = self.utun_name()?.to_owned();
        for peer in &self.peers {
            for ip in &peer.allowed_ips {
                let host = ip.split('/').next().unwrap_or(ip);
                if host.is_empty() {
                    continue;
                }
                Self::run(
                    "/sbin/route",
                    &["-n", "add", "-host", host, "-interface", &name],
                )
                .or_else(|_| {
                    Self::run(
                        "/sbin/route",
                        &["-n", "change", "-host", host, "-interface", &name],
                    )
                })?;
            }
        }
        Ok(())
    }
}

#[cfg(target_os = "macos")]
impl Default for MacOsNetwork {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(target_os = "macos")]
impl Network for MacOsNetwork {
    fn setup(&mut self, _interface: &str, key: &Path, address: &str) -> Result<(), Error> {
        self.device = None;
        self.name = None;
        self.private_hex = Self::read_private_hex(key)?;
        let ip = address
            .split('/')
            .next()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| Error::Message("invalid tunnel address".into()))?
            .to_owned();
        let name_file = tempfile::Builder::new()
            .prefix("blaktail-utun-")
            .tempfile()?
            .into_temp_path();
        // boringtun reports the allocated utun index through this file.
        std::env::set_var("WG_TUN_NAME_FILE", &name_file);
        let device = boringtun::device::DeviceHandle::new("utun", Default::default())
            .map_err(|e| Error::Message(format!("open userspace utun (run as root): {e}")))?;
        std::env::remove_var("WG_TUN_NAME_FILE");
        let mut name = String::new();
        for _ in 0..50 {
            if let Ok(reported) = fs::read_to_string(&name_file) {
                name = reported.trim().to_owned();
                if !name.is_empty() {
                    break;
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        if name.is_empty() {
            return Err(Error::Message("utun name was not reported".into()));
        }
        Self::run("/sbin/ifconfig", &[&name, "mtu", TUNNEL_MTU])?;
        Self::run("/sbin/ifconfig", &[&name, "inet", &ip, &ip, "up"])?;
        self.device = Some(device);
        self.name = Some(name);
        self.peers.clear();
        Ok(())
    }
    fn apply(&mut self, _interface: &str, changes: &[PeerChange]) -> Result<(), Error> {
        if self.name.is_none() {
            return Err(Error::Message(
                "utun device is not open; run setup first".into(),
            ));
        }
        for change in changes {
            match change {
                PeerChange::Remove(key) => self.peers.retain(|p| &p.wg_public_key != key),
                PeerChange::Upsert(peer) => match self
                    .peers
                    .iter_mut()
                    .find(|p| p.wg_public_key == peer.wg_public_key)
                {
                    Some(existing) => *existing = peer.clone(),
                    None => self.peers.push(peer.clone()),
                },
            }
        }
        self.push_config_and_routes()
    }
    fn down(&mut self, _interface: &str) -> Result<(), Error> {
        self.device = None;
        self.name = None;
        self.peers.clear();
        Ok(())
    }
    fn set_peer_endpoint(
        &mut self,
        _interface: &str,
        peer_key_b64: &str,
        endpoint: &str,
    ) -> Result<(), Error> {
        let Some(hex) = peer_key_hex(peer_key_b64) else {
            return Err(Error::Message("peer key is not valid base64".into()));
        };
        let request = format!("set=1\npublic_key={hex}\nendpoint={endpoint}\n\n");
        self.uapi(&request)
    }
    fn latest_handshakes(&mut self, _interface: &str) -> Result<HashMap<String, u64>, Error> {
        let mut map = HashMap::new();
        let mut current_key: Option<String> = None;
        for (key, value) in self.uapi_pairs()? {
            match key.as_str() {
                "public_key" => current_key = Some(value.trim().to_owned()),
                "last_handshake_time_sec" => {
                    if let Some(hex_key) = &current_key {
                        map.insert(hex_key.clone(), value.trim().parse::<u64>().unwrap_or(0));
                    }
                }
                _ => {}
            }
        }
        Ok(map)
    }
    fn listen_endpoint(&mut self, _interface: &str) -> Result<Option<std::net::SocketAddr>, Error> {
        let port = self
            .uapi_pairs()?
            .into_iter()
            .find(|(k, _)| k == "listen_port")
            .and_then(|(_, v)| v.parse::<u16>().ok());
        match port {
            Some(port) if port != 0 => Ok(Some(std::net::SocketAddr::from(([127, 0, 0, 1], port)))),
            _ => Ok(None),
        }
    }
}

#[cfg(target_os = "macos")]
impl MacOsNetwork {
    /// UAPI `get=1` dump as ordered key/value pairs: per-peer blocks carry
    /// `public_key=<hex>` followed by `last_handshake_time_sec=<n>` (absent or
    /// zero when never handshaken). Keys repeat across peer blocks.
    fn uapi_pairs(&self) -> Result<Vec<(String, String)>, Error> {
        let name = self.utun_name()?;
        let path = format!("/var/run/wireguard/{name}.sock");
        let mut stream = std::os::unix::net::UnixStream::connect(path.clone())
            .map_err(|e| Error::Message(format!("connect WireGuard UAPI {path}: {e}")))?;
        use std::io::{Read as _, Write as _};
        stream
            .write_all(b"get=1\n\n")
            .and_then(|_| stream.shutdown(std::net::Shutdown::Write))
            .map_err(|e| Error::Message(format!("write WireGuard UAPI {path}: {e}")))?;
        let mut response = String::new();
        stream.read_to_string(&mut response)?;
        if !response.contains("errno=0") {
            return Err(Error::Message("WireGuard UAPI get failed".into()));
        }
        Ok(response
            .lines()
            .filter_map(|l| l.split_once('=').map(|(k, v)| (k.to_owned(), v.to_owned())))
            .collect())
    }
}
pub async fn sync_once(
    coord: &Coordinator,
    network: &mut dyn Network,
    state: &mut NodeState,
    dir: &Path,
) -> Result<usize, Error> {
    let desired = coord.peers(state).await?;
    let changes = peer_diff(&state.peers, &desired);
    network.apply(&state.interface, &changes)?;
    state.peers = desired;
    write_state(dir, state)?;
    Ok(changes.len())
}

/// Reinstalls the persisted peer set after a platform backend recreates its
/// WireGuard interface. This keeps the last known mesh usable during a
/// coordinator outage and makes daemon restarts deterministic.
pub fn restore_peers(network: &mut dyn Network, state: &NodeState) -> Result<usize, Error> {
    let changes: Vec<_> = state
        .peers
        .iter()
        .cloned()
        .map(PeerChange::Upsert)
        .collect();
    network.apply(&state.interface, &changes)?;
    Ok(changes.len())
}

pub fn validate_interface(name: &str) -> Result<(), Error> {
    if name.is_empty()
        || name.len() > 15
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
    {
        return Err(Error::Message(
            "interface must be 1-15 ASCII letters, digits, '_' or '-'".into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct RecordingNetwork {
        applied: Vec<PeerChange>,
    }

    impl Network for RecordingNetwork {
        fn setup(&mut self, _interface: &str, _key: &Path, _address: &str) -> Result<(), Error> {
            Ok(())
        }
        fn apply(&mut self, _interface: &str, changes: &[PeerChange]) -> Result<(), Error> {
            self.applied.extend_from_slice(changes);
            Ok(())
        }
        fn down(&mut self, _interface: &str) -> Result<(), Error> {
            Ok(())
        }
        fn set_peer_endpoint(
            &mut self,
            _interface: &str,
            _peer_key_b64: &str,
            _endpoint: &str,
        ) -> Result<(), Error> {
            Ok(())
        }
        fn latest_handshakes(&mut self, _interface: &str) -> Result<HashMap<String, u64>, Error> {
            Ok(HashMap::new())
        }
        fn listen_endpoint(
            &mut self,
            _interface: &str,
        ) -> Result<Option<std::net::SocketAddr>, Error> {
            Ok(None)
        }
    }

    fn peer(key: &str, endpoint: Option<&str>) -> Peer {
        Peer {
            id: Uuid::nil(),
            name: key.into(),
            wg_public_key: key.into(),
            endpoint: endpoint.map(str::to_owned),
            allowed_ips: vec!["100.64.0.1/32".into()],
            dns_name: format!("{key}.tail.blaktail"),
            tags: vec![],
            relay_endpoint: None,
        }
    }
    #[test]
    fn diff_removes_adds_and_updates() {
        assert_eq!(
            peer_diff(
                &[peer("gone", None), peer("changed", None)],
                &[peer("new", None), peer("changed", Some("192.0.2.1:51820"))]
            ),
            vec![
                PeerChange::Remove("gone".into()),
                PeerChange::Upsert(peer("changed", Some("192.0.2.1:51820"))),
                PeerChange::Upsert(peer("new", None))
            ]
        );
    }

    #[test]
    fn persisted_peers_are_reinstalled_after_interface_recreation() {
        let expected = peer("restored", Some("192.0.2.1:51820"));
        let state = NodeState {
            node_id: Uuid::nil(),
            node_token: "secret".into(),
            coord: "https://coord.example".into(),
            interface: "blaktail0".into(),
            assigned_ip: "100.64.0.1/32".into(),
            dns_name: "self.12345678.blaktail".into(),
            credential_expires_at: 1,
            peers: vec![expected.clone()],
            relays: vec![],
            relay_token: String::new(),
            relay_expires_at: 0,
            relay_endpoint: None,
            relay_endpoint_reported_at: 0,
            dns_mode: None,
        };
        let mut network = RecordingNetwork::default();
        assert_eq!(restore_peers(&mut network, &state).unwrap(), 1);
        assert_eq!(network.applied, vec![PeerChange::Upsert(expected)]);
    }
    #[test]
    fn key_file_is_created_with_0600() {
        let dir = std::env::temp_dir().join(format!("blaktail-key-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let (path, public) = ensure_private_key(&dir).unwrap();
        assert_eq!(
            fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert!(!public.is_empty());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn insecure_existing_key_fails_closed() {
        let dir = std::env::temp_dir().join(format!("blaktail-mode-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        ensure_private_key(&dir).unwrap();
        fs::set_permissions(dir.join("private.key"), fs::Permissions::from_mode(0o644)).unwrap();
        assert!(ensure_private_key(&dir).is_err());
        fs::remove_dir_all(dir).unwrap();
    }
}
