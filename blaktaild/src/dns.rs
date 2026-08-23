use crate::{Error, NodeState};
#[cfg(not(target_os = "macos"))]
use std::process::{Command, Stdio};
use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::Write,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
use tokio::{net::UdpSocket, task::AbortHandle};

const DNS_PORT: u16 = 53;
const DNS_HEADER_LEN: usize = 12;
const DNS_TTL_SECS: u32 = 30;
const MANAGED_MARKER: &str = "# Managed by blaktaild";
pub const MODE_MACOS_RESOLVER: &str = "macos-resolver";
pub const MODE_SYSTEMD_RESOLVED: &str = "systemd-resolved";
pub const MODE_RESOLVCONF: &str = "resolvconf";
pub const MODE_RESOLV_CONF: &str = "resolv-conf";

#[derive(Clone, Default)]
struct Records {
    domain: String,
    addresses: HashMap<String, Ipv4Addr>,
}

pub struct MagicDns {
    records: Arc<Mutex<Records>>,
    task: AbortHandle,
    bind_ip: IpAddr,
    listen_addr: SocketAddr,
    domain: String,
}

impl MagicDns {
    pub async fn spawn(state: &NodeState) -> Result<Self, Error> {
        let bind_ip = state_ip(state)?;
        let domain = dns_domain(&state.dns_name).ok_or_else(|| {
            Error::Message("coordinator returned an invalid MagicDNS name".into())
        })?;
        Self::spawn_at(SocketAddr::new(bind_ip, DNS_PORT), state, domain).await
    }

    async fn spawn_at(bind: SocketAddr, state: &NodeState, domain: String) -> Result<Self, Error> {
        let socket = UdpSocket::bind(bind).await?;
        let listen_addr = socket.local_addr()?;
        let bind_ip = listen_addr.ip();
        let records = Arc::new(Mutex::new(records_from_state(state, &domain)));
        let task_records = records.clone();
        let task = tokio::spawn(async move {
            let mut request = [0u8; 1_232];
            loop {
                let (length, source) = match socket.recv_from(&mut request).await {
                    Ok(received) => received,
                    Err(_) => return,
                };
                let records = match task_records.lock() {
                    Ok(records) => records.clone(),
                    Err(_) => return,
                };
                if let Some(response) = answer(&request[..length], &records) {
                    let _ = socket.send_to(&response, source).await;
                }
            }
        });
        Ok(Self {
            records,
            task: task.abort_handle(),
            bind_ip,
            listen_addr,
            domain,
        })
    }

    pub fn matches(&self, state: &NodeState) -> bool {
        state_ip(state).ok() == Some(self.bind_ip)
            && dns_domain(&state.dns_name).as_deref() == Some(self.domain.as_str())
    }

    pub fn update(&self, state: &NodeState) {
        if let Ok(mut records) = self.records.lock() {
            *records = records_from_state(state, &self.domain);
        }
    }

    pub fn bind_ip(&self) -> IpAddr {
        self.bind_ip
    }

    pub fn domain(&self) -> &str {
        &self.domain
    }

    pub fn listen_addr(&self) -> SocketAddr {
        self.listen_addr
    }

    pub fn stop(self) {
        self.task.abort();
    }
}

impl Drop for MagicDns {
    fn drop(&mut self) {
        self.task.abort();
    }
}

pub fn dns_domain(dns_name: &str) -> Option<String> {
    let (_, domain) = dns_name.trim_end_matches('.').split_once('.')?;
    valid_domain(domain).then(|| domain.to_ascii_lowercase())
}

fn valid_domain(domain: &str) -> bool {
    !domain.is_empty()
        && domain.len() <= 253
        && domain.ends_with(".blaktail")
        && domain.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
}

fn state_ip(state: &NodeState) -> Result<IpAddr, Error> {
    state
        .assigned_ip
        .split('/')
        .next()
        .and_then(|value| value.parse().ok())
        .ok_or_else(|| Error::Message("assigned tailnet address is invalid".into()))
}

fn records_from_state(state: &NodeState, domain: &str) -> Records {
    let mut addresses = HashMap::new();
    insert_record(
        &mut addresses,
        &state.dns_name,
        state.assigned_ip.as_str(),
        domain,
    );
    for peer in &state.peers {
        if let Some(address) = peer.allowed_ips.first() {
            insert_record(&mut addresses, &peer.dns_name, address, domain);
        }
    }
    Records {
        domain: domain.into(),
        addresses,
    }
}

fn insert_record(records: &mut HashMap<String, Ipv4Addr>, name: &str, address: &str, domain: &str) {
    let name = name.trim_end_matches('.').to_ascii_lowercase();
    if !name.ends_with(&format!(".{domain}")) {
        return;
    }
    let Some(address) = address
        .split('/')
        .next()
        .and_then(|value| value.parse::<Ipv4Addr>().ok())
    else {
        return;
    };
    if let Some((label, _)) = name.split_once('.') {
        records.insert(label.into(), address);
    }
    records.insert(name, address);
}

fn answer(query: &[u8], records: &Records) -> Option<Vec<u8>> {
    if query.len() < DNS_HEADER_LEN {
        return None;
    }
    let flags = u16::from_be_bytes([query[2], query[3]]);
    let questions = u16::from_be_bytes([query[4], query[5]]);
    if flags & 0x8000 != 0 || flags & 0x7800 != 0 || questions != 1 {
        return error_response(query, 1);
    }
    let (name, name_end) = parse_name(query, DNS_HEADER_LEN)?;
    if name_end + 4 > query.len() {
        return error_response(query, 1);
    }
    let question_end = name_end + 4;
    let query_type = u16::from_be_bytes([query[name_end], query[name_end + 1]]);
    let query_class = u16::from_be_bytes([query[name_end + 2], query[name_end + 3]]);
    let name = name.to_ascii_lowercase();
    let in_domain = !name.contains('.')
        || name == records.domain
        || name.ends_with(&format!(".{}", records.domain));
    let address = records.addresses.get(&name).copied();
    let response_code = if !in_domain {
        5 // REFUSED: this authoritative stub never forwards public DNS.
    } else if address.is_none() {
        3 // NXDOMAIN prevents a private name from leaking to another resolver.
    } else {
        0
    };
    let has_answer = response_code == 0 && query_type == 1 && query_class == 1;
    let mut response = Vec::with_capacity(question_end + 16);
    response.extend_from_slice(&query[..2]);
    let response_flags = 0x8000 | 0x0400 | (flags & 0x0100) | response_code;
    response.extend_from_slice(&response_flags.to_be_bytes());
    response.extend_from_slice(&1u16.to_be_bytes());
    response.extend_from_slice(&(has_answer as u16).to_be_bytes());
    response.extend_from_slice(&0u16.to_be_bytes());
    response.extend_from_slice(&0u16.to_be_bytes());
    response.extend_from_slice(&query[DNS_HEADER_LEN..question_end]);
    if has_answer {
        response.extend_from_slice(&[0xc0, 0x0c]);
        response.extend_from_slice(&1u16.to_be_bytes());
        response.extend_from_slice(&1u16.to_be_bytes());
        response.extend_from_slice(&DNS_TTL_SECS.to_be_bytes());
        response.extend_from_slice(&4u16.to_be_bytes());
        response.extend_from_slice(&address.expect("answer checked").octets());
    }
    Some(response)
}

fn error_response(query: &[u8], response_code: u16) -> Option<Vec<u8>> {
    if query.len() < DNS_HEADER_LEN {
        return None;
    }
    let flags = u16::from_be_bytes([query[2], query[3]]);
    let mut response = Vec::with_capacity(DNS_HEADER_LEN);
    response.extend_from_slice(&query[..2]);
    response.extend_from_slice(&(0x8000 | (flags & 0x0100) | response_code).to_be_bytes());
    response.extend_from_slice(&[0; 8]);
    Some(response)
}

fn parse_name(packet: &[u8], mut offset: usize) -> Option<(String, usize)> {
    let mut labels = Vec::new();
    let mut encoded_len = 0usize;
    loop {
        let length = *packet.get(offset)? as usize;
        offset += 1;
        if length == 0 {
            break;
        }
        if length > 63 || offset + length > packet.len() {
            return None;
        }
        encoded_len += length + 1;
        if encoded_len > 255 {
            return None;
        }
        let label = std::str::from_utf8(&packet[offset..offset + length]).ok()?;
        if !label
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        {
            return None;
        }
        labels.push(label);
        offset += length;
    }
    Some((labels.join("."), offset))
}

#[cfg(any(not(target_os = "macos"), test))]
fn managed_resolv_conf(original: &str, dns_ip: IpAddr, domain: &str) -> String {
    let search = original
        .lines()
        .find_map(|line| {
            let line = line.trim();
            line.strip_prefix("search ")
                .or_else(|| line.strip_prefix("domain "))
        })
        .unwrap_or("");
    let mut content = format!("{MANAGED_MARKER}\nsearch {domain}");
    for suffix in search
        .split_whitespace()
        .filter(|suffix| *suffix != domain)
        .take(5)
    {
        content.push(' ');
        content.push_str(suffix);
    }
    content.push_str(&format!("\nnameserver {dns_ip}\n"));
    for line in original.lines() {
        let trimmed = line.trim();
        if !trimmed.starts_with("search ") && !trimmed.starts_with("domain ") {
            content.push_str(line);
            content.push('\n');
        }
    }
    content
}

pub fn configure_system_dns(
    state_dir: &Path,
    interface: &str,
    dns_ip: IpAddr,
    domain: &str,
) -> Result<String, Error> {
    if !valid_domain(domain) {
        return Err(Error::Message("invalid MagicDNS search domain".into()));
    }
    configure_platform_dns(state_dir, interface, dns_ip, domain)
}

pub fn remove_system_dns(
    state_dir: &Path,
    interface: &str,
    domain: &str,
    mode: Option<&str>,
) -> Result<(), Error> {
    remove_platform_dns(state_dir, interface, domain, mode)
}

#[cfg(target_os = "macos")]
fn configure_platform_dns(
    _state_dir: &Path,
    _interface: &str,
    dns_ip: IpAddr,
    domain: &str,
) -> Result<String, Error> {
    let directory = Path::new("/etc/resolver");
    fs::create_dir_all(directory)?;
    let path = directory.join(domain);
    let desired = format!(
        "{MANAGED_MARKER}\nnameserver {dns_ip}\nport {DNS_PORT}\nsearch {domain}\nsearch_order 1\ntimeout 1\n"
    );
    refuse_unmanaged_file(&path)?;
    write_atomic(&path, desired.as_bytes(), 0o644)?;
    Ok(MODE_MACOS_RESOLVER.into())
}

#[cfg(target_os = "macos")]
fn remove_platform_dns(
    _state_dir: &Path,
    _interface: &str,
    domain: &str,
    mode: Option<&str>,
) -> Result<(), Error> {
    if (mode.is_some() && mode != Some(MODE_MACOS_RESOLVER)) || !valid_domain(domain) {
        return Ok(());
    }
    remove_managed_file(&Path::new("/etc/resolver").join(domain))
}

#[cfg(not(target_os = "macos"))]
fn configure_platform_dns(
    state_dir: &Path,
    interface: &str,
    dns_ip: IpAddr,
    domain: &str,
) -> Result<String, Error> {
    if run_quiet("resolvectl", &["dns", interface, &dns_ip.to_string()]).is_ok() {
        let route_only = format!("~{domain}");
        if run_quiet("resolvectl", &["domain", interface, domain, &route_only]).is_ok() {
            return Ok(MODE_SYSTEMD_RESOLVED.into());
        }
        let _ = run_quiet("resolvectl", &["revert", interface]);
    }

    let mut child = Command::new("resolvconf")
        .args(["-a", &format!("{interface}.blaktail")])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    if let Ok(ref mut child) = child {
        if let Some(stdin) = child.stdin.as_mut() {
            let _ = write!(stdin, "nameserver {dns_ip}\nsearch {domain}\n");
        }
        if child.wait().is_ok_and(|status| status.success()) {
            return Ok(MODE_RESOLVCONF.into());
        }
    }

    configure_resolv_conf(state_dir, dns_ip, domain)?;
    Ok(MODE_RESOLV_CONF.into())
}

#[cfg(not(target_os = "macos"))]
fn remove_platform_dns(
    state_dir: &Path,
    interface: &str,
    _domain: &str,
    mode: Option<&str>,
) -> Result<(), Error> {
    match mode {
        Some(MODE_SYSTEMD_RESOLVED) => run_quiet("resolvectl", &["revert", interface]),
        Some(MODE_RESOLVCONF) => run_quiet("resolvconf", &["-d", &format!("{interface}.blaktail")]),
        Some(MODE_RESOLV_CONF) => restore_resolv_conf(state_dir),
        _ => Ok(()),
    }
}

#[cfg(not(target_os = "macos"))]
fn configure_resolv_conf(state_dir: &Path, dns_ip: IpAddr, domain: &str) -> Result<(), Error> {
    let path = Path::new("/etc/resolv.conf");
    if fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(Error::Message(
            "resolvectl and resolvconf failed; refusing to replace symlinked /etc/resolv.conf"
                .into(),
        ));
    }
    let backup = resolv_backup(state_dir);
    let current = fs::read_to_string(path)?;
    if backup.exists() && !current.starts_with(MANAGED_MARKER) {
        return Err(Error::Message(format!(
            "/etc/resolv.conf changed after BlakTail configured it; preserved backup at {}",
            backup.display()
        )));
    }
    if !backup.exists() && current.starts_with(MANAGED_MARKER) {
        return Err(Error::Message(
            "managed /etc/resolv.conf exists but its BlakTail backup is missing".into(),
        ));
    }
    if !backup.exists() {
        fs::copy(path, &backup)?;
    }
    let original = fs::read_to_string(&backup)?;
    let content = managed_resolv_conf(&original, dns_ip, domain);
    let mode = fs::metadata(path)?.permissions().mode() & 0o777;
    write_atomic(path, content.as_bytes(), mode)
}

#[cfg(not(target_os = "macos"))]
fn restore_resolv_conf(state_dir: &Path) -> Result<(), Error> {
    let path = Path::new("/etc/resolv.conf");
    let backup = resolv_backup(state_dir);
    if !backup.exists() {
        return Ok(());
    }
    if !fs::read_to_string(path)?.starts_with(MANAGED_MARKER) {
        return Err(Error::Message(format!(
            "/etc/resolv.conf changed after BlakTail configured it; preserved backup at {}",
            backup.display()
        )));
    }
    fs::copy(&backup, path)?;
    fs::remove_file(backup)?;
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn resolv_backup(state_dir: &Path) -> PathBuf {
    state_dir.join("resolv.conf.before-blaktail")
}

#[cfg(not(target_os = "macos"))]
fn run_quiet(program: &str, args: &[&str]) -> Result<(), Error> {
    let status = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|error| Error::Message(format!("could not execute {program}: {error}")))?;
    if status.success() {
        Ok(())
    } else {
        Err(Error::Message(format!("{program} exited unsuccessfully")))
    }
}

#[cfg(target_os = "macos")]
fn refuse_unmanaged_file(path: &Path) -> Result<(), Error> {
    if path.exists() && !fs::read_to_string(path)?.starts_with(MANAGED_MARKER) {
        return Err(Error::Message(format!(
            "refusing to replace unmanaged resolver file {}",
            path.display()
        )));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn remove_managed_file(path: &Path) -> Result<(), Error> {
    if !path.exists() {
        return Ok(());
    }
    if !fs::read_to_string(path)?.starts_with(MANAGED_MARKER) {
        return Err(Error::Message(format!(
            "refusing to remove unmanaged resolver file {}",
            path.display()
        )));
    }
    fs::remove_file(path)?;
    Ok(())
}

fn write_atomic(path: &Path, bytes: &[u8], mode: u32) -> Result<(), Error> {
    let temporary = PathBuf::from(format!("{}.blaktail.tmp", path.display()));
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(mode)
        .open(&temporary)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(mode))?;
    fs::rename(temporary, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Peer;
    use uuid::Uuid;

    fn state() -> NodeState {
        NodeState {
            node_id: Uuid::from_u128(1),
            node_token: "secret".into(),
            coord: "http://localhost:3000".into(),
            interface: "blaktail0".into(),
            assigned_ip: "100.64.0.1/32".into(),
            dns_name: "self.12345678.blaktail".into(),
            credential_expires_at: 1,
            advertised_routes: vec![],
            exit_node: None,
            exit_node_active: false,
            router_previous_ipv4_forward: None,
            peers: vec![Peer {
                id: Uuid::from_u128(2),
                name: "peer".into(),
                wg_public_key: "key".into(),
                endpoint: None,
                allowed_ips: vec!["100.64.0.2/32".into()],
                dns_name: "peer.12345678.blaktail".into(),
                tags: vec![],
                relay_endpoint: None,
            }],
            relays: vec![],
            relay_token: String::new(),
            relay_expires_at: 0,
            relay_endpoint: None,
            relay_endpoint_reported_at: 0,
            dns_mode: None,
        }
    }

    fn query(name: &str, query_type: u16) -> Vec<u8> {
        let mut packet = vec![0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
        for label in name.split('.') {
            packet.push(label.len() as u8);
            packet.extend_from_slice(label.as_bytes());
        }
        packet.push(0);
        packet.extend_from_slice(&query_type.to_be_bytes());
        packet.extend_from_slice(&1u16.to_be_bytes());
        packet
    }

    #[test]
    fn answers_fqdn_and_short_a_records_without_forwarding_public_dns() {
        let state = state();
        let records = records_from_state(&state, "12345678.blaktail");
        for name in ["peer.12345678.blaktail", "peer"] {
            let request = query(name, 1);
            let response = answer(&request, &records).unwrap();
            assert_eq!(u16::from_be_bytes([response[6], response[7]]), 1);
            assert_eq!(response.len(), request.len() + 16);
            assert_eq!(
                u16::from_be_bytes([response[request.len() + 10], response[request.len() + 11]]),
                4
            );
            assert_eq!(&response[response.len() - 4..], &[100, 64, 0, 2]);
        }
        let private_missing = answer(&query("missing.12345678.blaktail", 1), &records).unwrap();
        assert_eq!(private_missing[3] & 0x0f, 3);
        let public = answer(&query("example.com", 1), &records).unwrap();
        assert_eq!(public[3] & 0x0f, 5);
    }

    #[test]
    fn known_name_returns_nodata_for_aaaa() {
        let state = state();
        let records = records_from_state(&state, "12345678.blaktail");
        let response = answer(&query("peer.12345678.blaktail", 28), &records).unwrap();
        assert_eq!(response[3] & 0x0f, 0);
        assert_eq!(u16::from_be_bytes([response[6], response[7]]), 0);
    }

    #[tokio::test]
    async fn udp_stub_serves_live_record_updates() {
        let mut state = state();
        let dns = MagicDns::spawn_at(
            "127.0.0.1:0".parse().unwrap(),
            &state,
            "12345678.blaktail".into(),
        )
        .await
        .unwrap();
        let client = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let mut response = [0u8; 512];
        client
            .send_to(&query("peer.12345678.blaktail", 1), dns.listen_addr())
            .await
            .unwrap();
        let length = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            client.recv(&mut response),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(&response[length - 4..length], &[100, 64, 0, 2]);

        state.peers[0].allowed_ips[0] = "100.64.0.9/32".into();
        dns.update(&state);
        client
            .send_to(&query("peer", 1), dns.listen_addr())
            .await
            .unwrap();
        let length = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            client.recv(&mut response),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(&response[length - 4..length], &[100, 64, 0, 9]);
        dns.stop();
    }

    #[test]
    fn domain_is_scoped_and_path_safe() {
        assert_eq!(
            dns_domain("node.12345678.blaktail"),
            Some("12345678.blaktail".into())
        );
        assert_eq!(dns_domain("node.example.com"), None);
        assert_eq!(dns_domain("node.../etc.blaktail"), None);
    }

    #[test]
    fn resolv_conf_fallback_preserves_upstream_servers_and_adds_search_first() {
        let original = "search office.example\nnameserver 192.0.2.53\noptions edns0\n";
        let managed = managed_resolv_conf(
            original,
            IpAddr::V4(Ipv4Addr::new(100, 64, 0, 1)),
            "12345678.blaktail",
        );
        assert!(managed.starts_with(
            "# Managed by blaktaild\nsearch 12345678.blaktail office.example\nnameserver 100.64.0.1\n"
        ));
        assert!(managed.contains("nameserver 192.0.2.53\n"));
        assert!(managed.contains("options edns0\n"));
    }
}
