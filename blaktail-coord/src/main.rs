use axum_server::tls_rustls::RustlsConfig;
use blaktail_coord::{app, Store};
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
    #[arg(long, env = "BLAKTAIL_AUTH_HMAC_SECRET")]
    auth_hmac_secret: String,
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
    info!(region, bind = %config.bind, "starting BlakTail coordination server");
    axum_server::bind_rustls(config.bind, tls)
        .serve(
            app(
                store,
                region.to_owned(),
                config.auth_hmac_secret.into_bytes(),
            )
            .into_make_service(),
        )
        .await?;
    Ok(())
}
