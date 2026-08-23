use anyhow::{bail, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use boringtun::x25519::{PublicKey, StaticSecret};
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    time::Duration,
};
use uuid::Uuid;

pub const DEFAULT_STATE_DIR: &str = "/Library/Application Support/BlakTail";
pub const POLL_INTERVAL: Duration = Duration::from_secs(30);
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct State {
    pub coordinator: String,
    pub node_id: Uuid,
    pub node_token: String,
    pub private_key: String,
    pub address: String,
    pub listen_port: u16,
}
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct Peer {
    pub id: Uuid,
    pub name: String,
    pub wg_public_key: String,
    pub allowed_ips: Vec<String>,
    pub endpoint: Option<String>,
}
#[derive(Deserialize)]
struct RegisterResponse {
    id: Uuid,
    node_token: String,
}
#[derive(Deserialize)]
struct PeersResponse {
    peers: Vec<Peer>,
}
pub trait Tunnel {
    fn replace_peers(&mut self, peers: &[Peer]) -> Result<()>;
}

pub fn new_keypair() -> (String, String) {
    let private = StaticSecret::random_from_rng(rand_core::OsRng);
    let public = PublicKey::from(&private);
    (
        STANDARD.encode(private.to_bytes()),
        STANDARD.encode(public.as_bytes()),
    )
}
#[allow(clippy::too_many_arguments)]
pub fn register(
    client: &Client,
    coordinator: &str,
    join_key: &str,
    name: &str,
    address: &str,
    endpoint: Option<&str>,
    listen_port: u16,
) -> Result<State> {
    let (private_key, public_key) = new_keypair();
    let response=client.post(format!("{}/v1/nodes/register",coordinator.trim_end_matches('/')))
        .json(&serde_json::json!({"join_key":join_key,"name":name,"wg_public_key":public_key,"allowed_ips":[address],"endpoint":endpoint}))
        .send().context("coordinator registration request failed")?;
    if !response.status().is_success() {
        bail!("coordinator rejected registration ({})", response.status())
    }
    let registered: RegisterResponse = response
        .json()
        .context("invalid coordinator registration response")?;
    Ok(State {
        coordinator: coordinator.trim_end_matches('/').into(),
        node_id: registered.id,
        node_token: registered.node_token,
        private_key,
        address: address.into(),
        listen_port,
    })
}
pub fn fetch_peers(client: &Client, state: &State) -> Result<Vec<Peer>> {
    let response = client
        .get(format!(
            "{}/v1/nodes/{}/peers",
            state.coordinator, state.node_id
        ))
        .bearer_auth(&state.node_token)
        .send()
        .context("peer sync request failed")?;
    if !response.status().is_success() {
        bail!("coordinator rejected peer sync ({})", response.status())
    }
    Ok(response.json::<PeersResponse>()?.peers)
}
pub fn sync_once<T: Tunnel>(client: &Client, state: &State, tunnel: &mut T) -> Result<usize> {
    let peers = fetch_peers(client, state)?;
    tunnel.replace_peers(&peers)?;
    Ok(peers.len())
}
pub fn state_file(dir: &Path) -> PathBuf {
    dir.join("agent.json")
}
pub fn save_state(dir: &Path, state: &State) -> Result<()> {
    fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    let path = state_file(dir);
    let mut options = OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&path)
        .with_context(|| format!("open {}", path.display()))?;
    serde_json::to_writer(&mut file, state)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}
pub fn load_state(dir: &Path) -> Result<State> {
    let path = state_file(dir);
    serde_json::from_slice(&fs::read(&path).with_context(|| format!("read {}", path.display()))?)
        .context("invalid agent state")
}
pub fn revoke(client: &Client, state: &State) -> Result<()> {
    let response = client
        .delete(format!("{}/v1/nodes/{}", state.coordinator, state.node_id))
        .bearer_auth(&state.node_token)
        .send()
        .context("node revocation request failed")?;
    if !response.status().is_success() {
        bail!(
            "coordinator rejected node revocation ({})",
            response.status()
        )
    }
    Ok(())
}
pub fn decode_key(value: &str) -> Result<[u8; 32]> {
    STANDARD
        .decode(value)
        .context("invalid WireGuard key")?
        .try_into()
        .map_err(|_| anyhow::anyhow!("WireGuard keys must be 32 bytes"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Default)]
    struct FakeTun(Vec<Peer>);
    impl Tunnel for FakeTun {
        fn replace_peers(&mut self, peers: &[Peer]) -> Result<()> {
            self.0 = peers.to_vec();
            Ok(())
        }
    }
    fn peer(name: &str) -> Peer {
        Peer {
            id: Uuid::nil(),
            name: name.into(),
            wg_public_key: STANDARD.encode([7; 32]),
            allowed_ips: vec!["100.64.0.2/32".into()],
            endpoint: Some("192.0.2.2:51820".into()),
        }
    }
    #[test]
    fn peer_apply_replaces_removed_peers_on_fake_tun() {
        let mut tun = FakeTun::default();
        tun.replace_peers(&[peer("a"), peer("b")]).unwrap();
        assert_eq!(tun.0.len(), 2);
        tun.replace_peers(&[peer("b")]).unwrap();
        assert_eq!(
            tun.0.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(),
            ["b"]
        );
    }
    #[test]
    fn state_is_written_with_owner_only_permissions() {
        let dir = tempfile::tempdir().unwrap();
        let state = State {
            coordinator: "https://coord.example".into(),
            node_id: Uuid::nil(),
            node_token: "secret".into(),
            private_key: STANDARD.encode([1; 32]),
            address: "100.64.0.1/32".into(),
            listen_port: 51820,
        };
        save_state(dir.path(), &state).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(state_file(dir.path()))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
    }
}
