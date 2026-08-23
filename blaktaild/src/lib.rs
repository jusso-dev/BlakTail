use base64::{engine::general_purpose::STANDARD, Engine};
use rand::rngs::OsRng;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
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

pub const DEFAULT_STATE_DIR: &str = "/var/lib/blaktail";
pub const DEFAULT_INTERFACE: &str = "blaktail0";

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
    pub peers: Vec<Peer>,
}
#[derive(Serialize)]
struct RegisterRequest<'a> {
    join_key: &'a str,
    name: &'a str,
    wg_public_key: &'a str,
    endpoint: Option<&'a str>,
    allowed_ips: Vec<String>,
}
#[derive(Deserialize)]
struct RegisterResponse {
    id: Uuid,
    node_token: String,
    assigned_ip: String,
}
#[derive(Deserialize)]
struct PeersResponse {
    peers: Vec<Peer>,
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
            peers: vec![],
        })
    }
    pub async fn peers(&self, state: &NodeState) -> Result<Vec<Peer>, Error> {
        let r = self
            .client
            .get(format!("{}/v1/nodes/{}/peers", self.base, state.node_id))
            .bearer_auth(&state.node_token)
            .send()
            .await?
            .error_for_status()?;
        Ok(r.json::<PeersResponse>().await?.peers)
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
}
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
}
pub async fn sync_once<N: Network>(
    coord: &Coordinator,
    network: &mut N,
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
    fn peer(key: &str, endpoint: Option<&str>) -> Peer {
        Peer {
            id: Uuid::nil(),
            name: key.into(),
            wg_public_key: key.into(),
            endpoint: endpoint.map(str::to_owned),
            allowed_ips: vec!["100.64.0.1/32".into()],
            dns_name: format!("{key}.tail.blaktail"),
            tags: vec![],
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
