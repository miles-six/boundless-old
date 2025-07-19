// Copyright (c) 2025 RISC Zero, Inc.
//
// All rights reserved.

use std::{
    str::FromStr,
    time::{Duration, SystemTime},
};

use crate::counter::{ICounter, ICounter::ICounterInstance};
use alloy::{primitives::Address, signers::local::PrivateKeySigner, sol_types::SolCall};
use anyhow::{Context, Result};
use boundless_market::{
    request_builder::RequirementParams, Client, Deployment, StorageProviderConfig,
};
use clap::Parser;
use guest_util::ECHO_ELF;
use tracing_subscriber::{filter::LevelFilter, prelude::*, EnvFilter};
use url::Url;

/// Timeout for the transaction to be confirmed.
pub const TX_TIMEOUT: Duration = Duration::from_secs(30);

mod counter {
    alloy::sol!(
        #![sol(rpc, all_derives)]
        "../contracts/src/ICounter.sol"
    );
}

/// Arguments for the counter app CLI.
#[derive(Parser, Debug)]
#[clap(author, version, about, long_about = None)]
struct Args {
    /// URL of the Ethereum RPC endpoint.
    #[clap(short, long, env)]
    rpc_url: Url,
    /// Private key used to interact with the Counter contract and the Boundless Market.
    #[clap(long, env)]
    private_key: PrivateKeySigner,
    /// Address of the Counter contract.
    #[clap(short, long, env)]
    counter_address: Address,
    /// Configuration for the StorageProvider to use for uploading programs and inputs.
    #[clap(flatten, next_help_heading = "Storage Provider")]
    storage_config: StorageProviderConfig,
    #[clap(flatten, next_help_heading = "Boundless Market Deployment")]
    deployment: Option<Deployment>,
}

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging.
    tracing_subscriber::registry()
        .with(tracing_subscriber::fmt::layer())
        .with(
            EnvFilter::builder()
                .with_default_directive(LevelFilter::from_str("info")?.into())
                .from_env_lossy(),
        )
        .init();

    let args = Args::parse();

    // NOTE: Using a separate `run` function to facilitate testing below.
    run(args).await
}

/// Main logic which creates the Boundless client, executes the proofs and submits the tx.
async fn run(args: Args) -> Result<()> {
    // Create a Boundless client from the provided parameters.
    let client = Client::builder()
        .with_rpc_url(args.rpc_url)
        .with_deployment(args.deployment)
        .with_storage_provider_config(&args.storage_config)?
        .with_private_key(args.private_key)
        .build()
        .await
        .context("failed to build boundless client")?;

    // We use a timestamp as input to the ECHO guest code as the Counter contract
    // accepts only unique proofs. Using the same input twice would result in the same proof.
    let echo_message = format!("{:?}", SystemTime::now());

    // Create a request with a callback to the counter contract
    let request = client
        .new_request()
        .with_program(ECHO_ELF)
        .with_stdin(echo_message.as_bytes())
        // Add the callback to the counter contract by configuring the requirements
        .with_requirements(
            RequirementParams::builder()
                .callback_address(args.counter_address)
                .callback_gas_limit(100_000),
        );

    // Submit the request to the blockchain
    let (request_id, expires_at) = client.submit_onchain(request).await?;

    // Wait for the request to be fulfilled. The market will return the journal and seal.
    tracing::info!("Waiting for request {:x} to be fulfilled", request_id);
    let (_journal, _seal) = client
        .wait_for_request_fulfillment(
            request_id,
            Duration::from_secs(5), // check every 5 seconds
            expires_at,
        )
        .await?;
    tracing::info!("Request {:x} fulfilled", request_id);

    // We interact with the Counter contract by calling the getCount function to check that the callback
    // was executed correctly.
    let counter = ICounterInstance::new(args.counter_address, client.provider().clone());
    let count = counter
        .count()
        .call()
        .await
        .with_context(|| format!("failed to call {}", ICounter::countCall::SIGNATURE))?;
    tracing::info!("Counter value for address: {:?} is {:?}", client.caller(), count);

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::{
        network::EthereumWallet,
        node_bindings::{Anvil, AnvilInstance},
        providers::{Provider, ProviderBuilder, WalletProvider},
    };
    use boundless_market::contracts::hit_points::default_allowance;
    use boundless_market::storage::StorageProviderType;
    use boundless_market_test_utils::{create_test_ctx, TestCtx, ECHO_ID};
    use broker::test_utils::BrokerBuilder;
    use risc0_zkvm::Digest;
    use test_log::test;
    use tokio::task::JoinSet;

    alloy::sol!(
        #![sol(rpc)]
        Counter,
        "../contracts/out/Counter.sol/Counter.json"
    );

    async fn deploy_counter<P: Provider + 'static + Clone + WalletProvider>(
        anvil: &AnvilInstance,
        test_ctx: &TestCtx<P>,
    ) -> Result<Address> {
        let deployer_signer: PrivateKeySigner = anvil.keys()[0].clone().into();
        let deployer_provider = ProviderBuilder::new()
            .wallet(EthereumWallet::from(deployer_signer))
            .connect(&anvil.endpoint())
            .await
            .unwrap();
        let counter = Counter::deploy(
            &deployer_provider,
            test_ctx
                .deployment
                .verifier_router_address
                .ok_or_else(|| anyhow::anyhow!("deployment is missing verifier_router_address"))?,
            test_ctx.deployment.boundless_market_address,
            <[u8; 32]>::from(Digest::from(ECHO_ID)).into(),
        )
        .await?;

        Ok(*counter.address())
    }

    #[test(tokio::test)]
    async fn test_main() -> Result<()> {
        // Setup anvil and deploy contracts.
        let anvil = Anvil::new().spawn();
        let ctx = create_test_ctx(&anvil).await.unwrap();
        ctx.prover_market
            .deposit_stake_with_permit(default_allowance(), &ctx.prover_signer)
            .await
            .unwrap();
        let counter_address = deploy_counter(&anvil, &ctx).await.unwrap();

        // A JoinSet automatically aborts all its tasks when dropped
        let mut tasks = JoinSet::new();

        // Start a broker.
        let (broker, _config) =
            BrokerBuilder::new_test(&ctx, anvil.endpoint_url()).await.build().await?;
        tasks.spawn(async move { broker.start_service().await });

        const TIMEOUT_SECS: u64 = 600; // 10 minutes

        let run_task = run(Args {
            counter_address,
            rpc_url: anvil.endpoint_url(),
            private_key: ctx.customer_signer,
            storage_config: StorageProviderConfig::builder()
                .storage_provider(StorageProviderType::Mock)
                .build()
                .unwrap(),
            deployment: Some(ctx.deployment),
        });

        // Run with properly handled cancellation.
        tokio::select! {
            run_result = run_task => run_result?,

            broker_task_result = tasks.join_next() => {
                panic!("Broker exited unexpectedly: {:?}", broker_task_result.unwrap());
            },

            _ = tokio::time::sleep(Duration::from_secs(TIMEOUT_SECS)) => {
                panic!("The run function did not complete within {} seconds", TIMEOUT_SECS)
            }
        }

        Ok(())
    }
}
