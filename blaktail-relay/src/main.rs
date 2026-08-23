use blaktail_relay::{is_australian_region, serve};
use clap::Parser;
use std::net::SocketAddr;
use tokio::net::UdpSocket;
use tracing::info;

#[derive(Debug, Parser)]
#[command(about = "Australia-pinned BlakTail UDP relay", version)]
struct Config {
    #[arg(long, env = "BLAKTAIL_REGION")]
    region: String,
    #[arg(long, env = "BLAKTAIL_RELAY_BIND", default_value = "0.0.0.0:3478")]
    bind: SocketAddr,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();
    let config = Config::parse();
    if !is_australian_region(&config.region) {
        return Err("relay region must be an approved Australian cloud region".into());
    }
    let socket = UdpSocket::bind(config.bind).await?;
    info!(region=config.region,bind=%config.bind,"starting Australia-pinned relay");
    serve(socket).await?;
    Ok(())
}
