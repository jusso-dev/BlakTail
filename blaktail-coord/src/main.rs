use axum_server::tls_rustls::RustlsConfig;
use blaktail_coord::Store;
use clap::Parser;
use std::{net::SocketAddr, path::PathBuf};
use tracing::info;

#[derive(Debug, Parser)]
#[command(about = "Self-hosted BlakTail coordination server")]
struct Config {
    #[arg(long, env = "BLAKTAIL_REGION")]
    region: String,
    #[arg(long, env = "BLAKTAIL_BIND", default_value = "0.0.0.0:8443")]
    bind: SocketAddr,
    #[arg(
        long,
        env = "BLAKTAIL_DATABASE",
        default_value = "blaktail-coord.sqlite3"
    )]
    database: PathBuf,
    #[arg(long, env = "BLAKTAIL_TLS_CERT")]
    tls_cert: PathBuf,
    #[arg(long, env = "BLAKTAIL_TLS_KEY")]
    tls_key: PathBuf,
    #[arg(long, env = "BLAKTAIL_AUTH_HMAC_SECRET", hide_env_values = true)]
    auth_hmac_secret: String,
    /// Dedicated HMAC secret shared only with relay processes.
    #[arg(long, env = "BLAKTAIL_RELAY_AUTH_SECRET", hide_env_values = true)]
    relay_auth_secret: Option<String>,
    /// Comma-separated relay endpoints (host:port UDP) advertised to nodes.
    #[arg(long, env = "BLAKTAIL_RELAYS", default_value = "")]
    relays: String,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();
    let config = Config::parse();
    let region = config.region.trim();
    if region.is_empty() {
        return Err("region must not be empty; choose the Australian hosting region".into());
    }
    if config.auth_hmac_secret.len() < 32 {
        return Err("BLAKTAIL_AUTH_HMAC_SECRET must be at least 32 bytes".into());
    }
    let store = Store::open(&config.database)?;
    let tls = RustlsConfig::from_pem_file(&config.tls_cert, &config.tls_key).await?;
    let relays: Vec<String> = config
        .relays
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect();
    let relay_auth_secret = config.relay_auth_secret.unwrap_or_default();
    if !relays.is_empty() && relay_auth_secret.len() < 32 {
        return Err(
            "BLAKTAIL_RELAY_AUTH_SECRET must be at least 32 bytes when relays are configured"
                .into(),
        );
    }
    info!(region, bind = %config.bind, relays = relays.len(), "starting BlakTail coordination server");
    axum_server::bind_rustls(config.bind, tls)
        .serve(
            blaktail_coord::app_with_relays(
                store,
                region.to_owned(),
                config.auth_hmac_secret.into_bytes(),
                relay_auth_secret.into_bytes(),
                relays,
            )
            .into_make_service(),
        )
        .await?;
    Ok(())
}
