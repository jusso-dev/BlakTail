use anyhow::{bail, Context, Result};
#[cfg(target_os = "macos")]
use blaktaild::POLL_INTERVAL;
use blaktaild::{load_state, register, revoke, save_state, state_file, DEFAULT_STATE_DIR};
use clap::{Parser, Subcommand};
use reqwest::blocking::Client;
#[cfg(target_os = "macos")]
use std::thread;
use std::{
    fs,
    io::{self, Read},
    path::{Path, PathBuf},
};
#[cfg(target_os = "macos")]
use tracing::{info, warn};
#[cfg(any(target_os = "macos", test))]
#[allow(dead_code)]
mod macos;

#[derive(Parser)]
#[command(name = "blaktaild", about = "BlakTail userspace WireGuard agent")]
struct Cli {
    #[arg(long,global=true,default_value=DEFAULT_STATE_DIR)]
    state_dir: PathBuf,
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    Up {
        #[arg(long)]
        coordinator: String,
        #[arg(long)]
        name: String,
        #[arg(long)]
        address: String,
        #[arg(long)]
        endpoint: Option<String>,
        #[arg(long, default_value_t = 51820)]
        listen_port: u16,
        #[arg(long, env = "BLAKTAIL_JOIN_KEY", hide_env_values = true)]
        join_key: Option<String>,
    },
    Run,
    Down,
    Status,
}
fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .without_time()
        .init();
    if let Err(error) = execute(Cli::parse()) {
        eprintln!("blaktaild: {error:#}");
        std::process::exit(1)
    }
}
fn execute(cli: Cli) -> Result<()> {
    let client = Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()?;
    match cli.command {
        Command::Up {
            coordinator,
            name,
            address,
            endpoint,
            listen_port,
            join_key,
        } => {
            if state_file(&cli.state_dir).exists() {
                bail!("already joined; run 'blaktaild down' first")
            };
            let key = match join_key {
                Some(k) => k,
                None => read_secret()?,
            };
            let state = register(
                &client,
                &coordinator,
                key.trim(),
                &name,
                &address,
                endpoint.as_deref(),
                listen_port,
            )?;
            save_state(&cli.state_dir, &state)?;
            drop(key);
            run_agent(&client, &cli.state_dir)
        }
        Command::Run => run_agent(&client, &cli.state_dir),
        Command::Down => {
            let state = load_state(&cli.state_dir)?;
            revoke(&client, &state)?;
            fs::remove_file(state_file(&cli.state_dir))?;
            println!("down");
            Ok(())
        }
        Command::Status => {
            let state = load_state(&cli.state_dir)?;
            println!(
                "joined\nnode: {}\naddress: {}\ncoordinator: {}",
                state.node_id, state.address, state.coordinator
            );
            Ok(())
        }
    }
}
fn read_secret() -> Result<String> {
    eprintln!("Join key (input is not logged):");
    let mut key = String::new();
    io::stdin()
        .read_to_string(&mut key)
        .context("read join key from stdin")?;
    if key.trim().is_empty() {
        bail!("join key is required via stdin, --join-key, or BLAKTAIL_JOIN_KEY")
    }
    Ok(key)
}
#[cfg(target_os = "macos")]
fn run_agent(client: &Client, dir: &Path) -> Result<()> {
    let state = load_state(dir)?;
    let mut tunnel = macos::MacTunnel::start(&state)?;
    loop {
        match blaktaild::sync_once(client, &state, &mut tunnel) {
            Ok(count) => info!(peer_count = count, "peer configuration applied"),
            Err(error) => warn!(%error,"peer sync failed; retrying"),
        };
        thread::sleep(POLL_INTERVAL)
    }
}
#[cfg(not(target_os = "macos"))]
fn run_agent(_: &Client, _: &Path) -> Result<()> {
    bail!("the userspace utun backend currently requires macOS")
}
