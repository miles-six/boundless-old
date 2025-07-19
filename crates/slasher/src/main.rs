// Copyright (c) 2025 RISC Zero, Inc.
//
// All rights reserved.

use std::{path::PathBuf, time::Duration};

use alloy::{
    primitives::{utils::parse_ether, Address, U256},
    signers::local::PrivateKeySigner,
};
use anyhow::{bail, Result};
use boundless_slasher::{SlashService, SlashServiceConfig};
use clap::{Args, Parser};
use url::Url;

/// Arguments of the order generator.
#[derive(Parser, Debug)]
#[clap(author, version, about, long_about = None)]
struct MainArgs {
    /// URL of the Ethereum RPC endpoint.
    #[clap(short, long, env)]
    rpc_url: Url,
    /// Private key used to sign and submit slash requests.
    #[clap(short, long, env)]
    private_key: PrivateKeySigner,
    /// Address of the BoundlessMarket contract.
    #[clap(short, long, env)]
    boundless_market_address: Address,
    /// DB connection string.
    #[clap(long, default_value = "sqlite::memory:")]
    db: String,
    /// Starting block number.
    #[clap(long)]
    start_block: Option<u64>,
    /// Interval in seconds between checking for expired requests.
    #[clap(long, default_value = "5")]
    interval: u64,
    /// Number of retries before quitting after an error.
    #[clap(long, default_value = "10")]
    retries: u32,
    /// Balance threshold at which to log a warning.
    #[clap(long, value_parser = parse_ether, default_value = "1")]
    warn_balance_below: Option<U256>,
    /// Balance threshold at which to log an error.
    #[clap(long, value_parser = parse_ether, default_value = "0.1")]
    error_balance_below: Option<U256>,
    /// Comma-separated list of addresses to skip when processing locked events.
    #[clap(long, value_delimiter = ',', value_parser = parse_address)]
    skip_addresses: Vec<Address>,
    /// Transaction timeout in seconds.
    #[clap(long, default_value = "120")]
    tx_timeout: u64,
}

fn parse_address(s: &str) -> Result<Address, String> {
    s.trim().parse::<Address>().map_err(|e| format!("Failed to parse address {}: {}", s, e))
}

#[derive(Args, Clone, Debug)]
#[group(required = false, multiple = false)]
struct OrderInput {
    /// Input for the guest, given as a hex-encoded string.
    #[clap(long, value_parser = |s: &str| hex::decode(s))]
    input: Option<Vec<u8>>,
    /// Input for the guest, given as a path to a file.
    #[clap(long)]
    input_file: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .json()
        .init();

    let args = MainArgs::parse();

    let slash_service = SlashService::new(
        args.rpc_url.clone(),
        &args.private_key,
        args.boundless_market_address,
        &args.db,
        SlashServiceConfig {
            interval: Duration::from_secs(args.interval),
            retries: args.retries,
            balance_warn_threshold: args.warn_balance_below,
            balance_error_threshold: args.error_balance_below,
            skip_addresses: args.skip_addresses,
            tx_timeout: Duration::from_secs(args.tx_timeout),
        },
    )
    .await?;

    if let Err(err) = slash_service.run(args.start_block).await {
        bail!("FATAL: Error running the slasher: {err}");
    }

    Ok(())
}
