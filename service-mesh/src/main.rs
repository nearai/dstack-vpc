use anyhow::{Context, Result};
use clap::Parser;
use config::{load_config_figment, Config};
use tracing::info;

mod client;
mod config;
mod server;

fn app_version() -> String {
    const CARGO_PKG_VERSION: &str = env!("CARGO_PKG_VERSION");
    const VERSION: &str = git_version::git_version!(
        args = ["--abbrev=20", "--always", "--dirty=-modified"],
        prefix = "git:",
        fallback = "unknown"
    );
    format!("v{CARGO_PKG_VERSION} ({VERSION})")
}

#[derive(Parser)]
#[command(name = "dstack-mesh")]
#[command(about = "dstack service mesh proxy")]
#[command(version)]
struct Args {
    /// Path to the configuration file
    #[arg(short, long)]
    config: Option<String>,
}

#[rocket::main]
async fn main() -> Result<()> {
    // Initialize tracing from environment (RUST_LOG)
    // Use LOG_FORMAT=json or LOG_FORMAT=pretty (default: json)
    let log_format = std::env::var("LOG_FORMAT").unwrap_or_else(|_| "json".to_string());

    let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));

    if log_format == "json" {
        tracing_subscriber::fmt()
            .json()
            .with_env_filter(env_filter)
            .with_current_span(false)
            .with_span_list(false)
            .init();
    } else {
        tracing_subscriber::fmt().with_env_filter(env_filter).init();
    }

    let args = Args::parse();

    // Load configuration
    let figment = load_config_figment(args.config.as_deref());
    let config: Config = figment.extract().context("Failed to load configuration")?;

    info!("Starting dstack mesh proxy {}", app_version());
    info!("Configuration loaded successfully");

    // Start both services - each service creates its own Rocket figment internally
    tokio::select! {
        result = client::run_client_proxy(
            &figment,
            &config
        ) => {
            result.context("Client proxy failed")?;
        }
        result = server::run_auth_service(&figment) => {
            result.context("Auth service failed")?;
        }
    }

    Ok(())
}
