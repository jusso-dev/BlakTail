use blaktail_relay::{is_australian_region, serve_metrics, RelayConfig};
use clap::Parser;
use std::{net::SocketAddr, sync::Arc};
use tokio::net::UdpSocket;
use tracing::info;

#[derive(Debug, Parser)]
#[command(about = "Australia-pinned BlakTail UDP relay", version)]
struct Config {
    #[arg(long, env = "BLAKTAIL_REGION")]
    region: String,
    #[arg(long, env = "BLAKTAIL_RELAY_BIND", default_value = "0.0.0.0:3478")]
    bind: SocketAddr,
    /// Shared HMAC secret for REGISTER capability tokens; must match the coordinator.
    #[arg(long, env = "BLAKTAIL_RELAY_AUTH_SECRET", hide_env_values = true)]
    auth_secret: Option<String>,
    /// Prometheus metrics endpoint.
    #[arg(
        long,
        env = "BLAKTAIL_RELAY_METRICS_BIND",
        default_value = "127.0.0.1:9702"
    )]
    metrics_bind: SocketAddr,
    #[arg(long, default_value_t = 120)]
    idle_secs: u64,
    #[arg(long, default_value_t = 100)]
    rate_per_sec: u32,
    #[arg(long, default_value_t = 200)]
    rate_burst: u32,
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
    let secret = match config.auth_secret.as_deref().map(str::trim) {
        Some(s) if s.len() >= 32 => s.as_bytes().to_vec(),
        _ => {
            return Err(
                "BLAKTAIL_RELAY_AUTH_SECRET must be at least 32 bytes; the relay rejects unauthenticated registration"
                    .into(),
            )
        }
    };
    let relay_config = RelayConfig {
        auth_secret: secret,
        idle_secs: config.idle_secs,
        rate_per_sec: config.rate_per_sec,
        rate_burst: config.rate_burst,
    };
    let socket = UdpSocket::bind(config.bind).await?;
    info!(region = config.region, bind = %config.bind, metrics = %config.metrics_bind, "starting Australia-pinned relay");
    let metrics = Arc::new(blaktail_relay::Metrics::default());
    let metrics_task = tokio::spawn(serve_metrics(config.metrics_bind, metrics.clone()));
    let serve_task = tokio::spawn(blaktail_relay::serve_with_metrics(
        socket,
        relay_config,
        metrics,
    ));
    tokio::select! {
        result = serve_task => { result?? }
        result = metrics_task => { result?? }
    }
    Ok(())
}
