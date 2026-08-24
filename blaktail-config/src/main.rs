use blaktail_config::{
    reload_plan_for_service, support_preview, write_support_bundle, LoadedConfig, Service,
    ENVIRONMENT_OVERRIDES, SCHEMA_VERSION,
};
use clap::{Parser, Subcommand};
use std::{ffi::OsString, io::Write as _, path::PathBuf, process};

#[derive(Debug, Parser)]
#[command(
    name = "blaktail-config",
    about = "Validate and inspect BlakTail operator configuration without opening listeners",
    version
)]
struct Cli {
    #[arg(long, global = true, env = "BLAKTAIL_CONFIG")]
    config: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Validate configuration offline without listeners, migrations, or network calls.
    CheckConfig {
        #[arg(long, default_value = "all")]
        service: ServiceArg,
    },
    /// Print final defaults/file/environment precedence with every secret redacted.
    DumpConfig {
        #[arg(long, default_value = "all")]
        service: ServiceArg,
        /// Required safety acknowledgement; non-redacted output is not supported.
        #[arg(long)]
        redacted: bool,
    },
    /// Compare a candidate file and classify atomic-safe versus restart-required changes.
    ReloadCheck {
        #[arg(long)]
        candidate: PathBuf,
        #[arg(long, default_value = "all")]
        service: ServiceArg,
    },
    /// Preview or export a redacted JSON support bundle.
    SupportBundle {
        #[arg(long, default_value = "all")]
        service: ServiceArg,
        #[arg(long)]
        log_file: Option<PathBuf>,
        #[arg(long)]
        output: Option<PathBuf>,
        /// Digest printed by a prior preview of the same inputs.
        #[arg(long)]
        confirm: Option<String>,
    },
    /// Print schema and environment-override reference as JSON.
    Schema,
    /// Internal container adapter: validate console config, then exec its command.
    #[command(hide = true)]
    RunConsole {
        #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
        command: Vec<OsString>,
    },
}

#[derive(Clone, Copy, Debug)]
struct ServiceArg(Service);

impl std::str::FromStr for ServiceArg {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        value.parse().map(Self)
    }
}

fn main() {
    if let Err(error) = run(Cli::parse()) {
        eprintln!("blaktail-config: {error}");
        process::exit(1);
    }
}

fn run(cli: Cli) -> Result<(), Box<dyn std::error::Error>> {
    match cli.command {
        Command::Schema => {
            let schema: serde_json::Value =
                serde_json::from_str(include_str!("../../config/schema-v1.json"))?;
            println!(
                "{}",
                serde_json::to_string_pretty(&serde_json::json!({
                    "schema_version": SCHEMA_VERSION,
                    "schema": schema,
                    "precedence": ["defaults", "file", "environment"],
                    "environment_overrides": ENVIRONMENT_OVERRIDES.iter().map(|(name, field, secret)| {
                        serde_json::json!({"name": name, "field": field, "secret": secret})
                    }).collect::<Vec<_>>(),
                }))?
            );
        }
        Command::CheckConfig { service } => {
            let loaded = LoadedConfig::load(cli.config.as_deref(), service.0)?;
            loaded.validate(service.0)?;
            for warning in &loaded.warnings {
                eprintln!("warning: {warning}");
            }
            println!(
                "configuration valid: schema {}, service {}",
                SCHEMA_VERSION, service.0
            );
        }
        Command::DumpConfig { service, redacted } => {
            if !redacted {
                return Err("--redacted is required; BlakTail never dumps secret values".into());
            }
            let loaded = LoadedConfig::load(cli.config.as_deref(), service.0)?;
            loaded.validate(service.0)?;
            println!("{}", loaded.redacted_dump(service.0)?);
        }
        Command::ReloadCheck { candidate, service } => {
            let current = LoadedConfig::load(cli.config.as_deref(), service.0)?;
            current.validate(service.0)?;
            let candidate = LoadedConfig::load(Some(&candidate), service.0)?;
            candidate.validate(service.0)?;
            println!(
                "{}",
                serde_json::to_string_pretty(&reload_plan_for_service(
                    &current.config,
                    &candidate.config,
                    service.0,
                ))?
            );
        }
        Command::SupportBundle {
            service,
            log_file,
            output,
            confirm,
        } => {
            let loaded = LoadedConfig::load(cli.config.as_deref(), service.0)?;
            let (preview, bytes) = support_preview(&loaded, service.0, log_file.as_deref())?;
            match (output, confirm) {
                (None, None) => println!("{}", serde_json::to_string_pretty(&preview)?),
                (Some(output), Some(confirm)) => {
                    write_support_bundle(&output, &confirm, &preview, &bytes)?;
                    println!("support bundle written: {}", output.display());
                }
                _ => {
                    return Err(
                        "preview first with no --output/--confirm; export requires both --output and --confirm <preview digest>"
                            .into(),
                    )
                }
            }
        }
        Command::RunConsole { command } => {
            let loaded = LoadedConfig::load(cli.config.as_deref(), Service::Console)?;
            loaded.validate(Service::Console)?;
            for warning in &loaded.warnings {
                eprintln!("warning: {warning}");
            }
            println!(
                "configuration valid: schema {}, service console",
                SCHEMA_VERSION
            );
            std::io::stdout().flush()?;
            exec_console(loaded, command)?;
        }
    }
    Ok(())
}

fn exec_console(
    loaded: LoadedConfig,
    command: Vec<OsString>,
) -> Result<(), Box<dyn std::error::Error>> {
    let config = &loaded.config.console;
    let database_url = loaded.secret(
        config
            .database_url
            .as_ref()
            .expect("validated console database URL"),
        "console.database_url",
    )?;
    let auth_secret = loaded.secret(
        config
            .auth_secret
            .as_ref()
            .expect("validated console auth secret"),
        "console.auth_secret",
    )?;
    let coordinator_auth_secret = loaded.secret(
        config
            .coordinator_auth_secret
            .as_ref()
            .expect("validated console coordinator auth secret"),
        "console.coordinator_auth_secret",
    )?;
    let mut child = process::Command::new(&command[0]);
    child
        .args(&command[1..])
        .env("BLAKTAIL_REGION", &config.region)
        .env("PORT", config.port.to_string())
        .env("DATABASE_URL", database_url.as_str("console.database_url")?)
        .env("BETTER_AUTH_URL", &config.base_url)
        .env(
            "BETTER_AUTH_TRUSTED_ORIGINS",
            config.trusted_origins.join(","),
        )
        .env("COORD_BASE_URL", &config.coordinator_url)
        .env(
            "BETTER_AUTH_SECRET",
            auth_secret.as_str("console.auth_secret")?,
        )
        .env(
            "BLAKTAIL_AUTH_HMAC_SECRET",
            coordinator_auth_secret.as_str("console.coordinator_auth_secret")?,
        )
        .env_remove("DATABASE_URL_FILE")
        .env_remove("BETTER_AUTH_SECRET_FILE")
        .env_remove("BLAKTAIL_AUTH_HMAC_SECRET_FILE");
    if let Some(path) = &config.coordinator_ca_file {
        child.env("NODE_EXTRA_CA_CERTS", path);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt as _;
        Err(child.exec().into())
    }
    #[cfg(not(unix))]
    {
        let status = child.status()?;
        if status.success() {
            Ok(())
        } else {
            Err(format!("console command exited with {status}").into())
        }
    }
}
