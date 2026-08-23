use anyhow::{bail, Context, Result};
use blaktaild::{decode_key, Peer, State, Tunnel};
use boringtun::device::{DeviceConfig, DeviceHandle};
use std::{
    fs,
    io::{Read, Write},
    os::unix::net::UnixStream,
    path::PathBuf,
    process::Command,
    thread,
    time::Duration,
};

pub struct MacTunnel {
    _device: DeviceHandle,
    name: String,
    private_hex: String,
    listen_port: u16,
}
impl MacTunnel {
    pub fn start(state: &State) -> Result<Self> {
        let name_file = tempfile::Builder::new()
            .prefix("blaktail-utun-")
            .tempfile()?
            .into_temp_path();
        let name_path = name_file.to_path_buf();
        std::env::set_var("WG_TUN_NAME_FILE", &name_path);
        let device = DeviceHandle::new("utun", DeviceConfig::default())
            .context("open userspace utun (blaktaild must run as root)")?;
        let name = wait_for_name(&name_path)?;
        std::env::remove_var("WG_TUN_NAME_FILE");
        run(
            "/sbin/ifconfig",
            &[
                &name,
                "inet",
                address_ip(&state.address)?,
                address_ip(&state.address)?,
                "up",
            ],
        )?;
        Ok(Self {
            _device: device,
            name,
            private_hex: hex::encode(decode_key(&state.private_key)?),
            listen_port: state.listen_port,
        })
    }
}
impl Tunnel for MacTunnel {
    fn replace_peers(&mut self, peers: &[Peer]) -> Result<()> {
        let mut request = format!(
            "set=1\nprivate_key={}\nlisten_port={}\nreplace_peers=true\n",
            self.private_hex, self.listen_port
        );
        for peer in peers {
            request.push_str(&format!(
                "public_key={}\nreplace_allowed_ips=true\npersistent_keepalive_interval=25\n",
                hex::encode(decode_key(&peer.wg_public_key)?)
            ));
            if let Some(endpoint) = &peer.endpoint {
                request.push_str(&format!("endpoint={endpoint}\n"));
            }
            for ip in &peer.allowed_ips {
                request.push_str(&format!("allowed_ip={ip}\n"));
            }
        }
        request.push('\n');
        uapi(&self.name, &request)?;
        for peer in peers {
            for ip in &peer.allowed_ips {
                let network = ip.split('/').next().unwrap_or(ip);
                run(
                    "/sbin/route",
                    &["-n", "add", "-host", network, "-interface", &self.name],
                )
                .or_else(|_| {
                    run(
                        "/sbin/route",
                        &["-n", "change", "-host", network, "-interface", &self.name],
                    )
                })?;
            }
        }
        Ok(())
    }
}
fn address_ip(address: &str) -> Result<&str> {
    address
        .split('/')
        .next()
        .filter(|s| !s.is_empty())
        .context("invalid tunnel address")
}
fn wait_for_name(path: &PathBuf) -> Result<String> {
    for _ in 0..50 {
        if let Ok(name) = fs::read_to_string(path) {
            if !name.is_empty() {
                return Ok(name);
            }
        }
        thread::sleep(Duration::from_millis(20));
    }
    bail!("utun name was not reported")
}
fn uapi(name: &str, request: &str) -> Result<()> {
    let path = format!("/var/run/wireguard/{name}.sock");
    let mut stream =
        UnixStream::connect(&path).with_context(|| format!("connect WireGuard UAPI {path}"))?;
    stream.write_all(request.as_bytes())?;
    stream.shutdown(std::net::Shutdown::Write)?;
    let mut response = String::new();
    stream.read_to_string(&mut response)?;
    if !response.contains("errno=0") {
        bail!("WireGuard UAPI rejected peer configuration")
    }
    Ok(())
}
fn run(program: &str, args: &[&str]) -> Result<()> {
    let status = Command::new(program)
        .args(args)
        .status()
        .with_context(|| format!("run {program}"))?;
    if !status.success() {
        bail!("{} failed ({})", program, status)
    }
    Ok(())
}
