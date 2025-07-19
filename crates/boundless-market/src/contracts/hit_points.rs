// Copyright 2025 RISC Zero, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! Interface to interact with the `HitPoints` contract used for staking on the market during the Boundless testnet.
//!
//! NOTE: This module will be removed in later phases of the testnet and before mainnet.

use std::time::Duration;

use crate::contracts::{
    token::IERC20,
    IHitPoints::{self, IHitPointsErrors},
};

use super::{IHitPoints::IHitPointsInstance, TXN_CONFIRM_TIMEOUT};
use alloy::{network::Ethereum, primitives::Address, providers::Provider};
use alloy_primitives::U256;
use anyhow::{Context, Result};

const DEFAULT_ALLOWANCE: u128 = 100000000000000000000;
/// HitPointsService provides a high-level interface to the HitPoints contract.
#[derive(Clone)]
pub struct HitPointsService<P> {
    instance: IHitPointsInstance<P, Ethereum>,
    caller: Address,
    tx_timeout: Duration,
}

impl<P: Provider> HitPointsService<P> {
    /// Creates a new HitPointsService.
    pub fn new(address: Address, provider: P, caller: Address) -> Self {
        let instance = IHitPoints::new(address, provider);

        Self { instance, caller, tx_timeout: TXN_CONFIRM_TIMEOUT }
    }

    /// Returns the underlying IHitPointsInstance.
    pub fn instance(&self) -> &IHitPointsInstance<P, Ethereum> {
        &self.instance
    }

    /// Returns the caller address.
    pub fn caller(&self) -> Address {
        self.caller
    }

    /// Sets the timeout for transaction confirmation.
    pub fn with_timeout(self, tx_timeout: Duration) -> Self {
        Self { tx_timeout, ..self }
    }

    /// Grant `MINTER` role to the given account.
    pub async fn grant_minter_role(&self, account: Address) -> Result<()> {
        tracing::debug!("Calling grantMinterRole({:?})", account);
        let call = self.instance().grantMinterRole(account).from(self.caller);
        let pending_tx = call.send().await.map_err(IHitPointsErrors::decode_error)?;
        tracing::debug!("Broadcasting tx {}", pending_tx.tx_hash());
        let tx_hash = pending_tx
            .with_timeout(Some(self.tx_timeout))
            .watch()
            .await
            .context("failed to confirm tx")?;

        tracing::info!("Role `MINTER` granted to {}: {}", account, tx_hash);

        Ok(())
    }

    /// Grant `AUTHORIZED_TRANSFER` role to the given account.
    pub async fn grant_authorized_transfer_role(&self, account: Address) -> Result<()> {
        tracing::debug!("Calling grantAuthorizedTransferRole({:?})", account);
        let call = self.instance().grantAuthorizedTransferRole(account).from(self.caller);
        let pending_tx = call.send().await.map_err(IHitPointsErrors::decode_error)?;
        tracing::debug!("Broadcasting tx {}", pending_tx.tx_hash());
        let tx_hash = pending_tx
            .with_timeout(Some(self.tx_timeout))
            .watch()
            .await
            .context("failed to confirm tx")?;

        tracing::info!("Role `AUTHORIZED_TRANSFER` granted to {}: {}", account, tx_hash);

        Ok(())
    }

    /// Mint HitPoints for an account.
    pub async fn mint(&self, account: Address, value: U256) -> Result<()> {
        tracing::debug!("Calling mint({:?}, {})", account, value);
        let call = self.instance.mint(account, value).from(self.caller);
        let pending_tx = call.send().await.map_err(IHitPointsErrors::decode_error)?;
        tracing::debug!("Broadcasting tx {}", pending_tx.tx_hash());
        let tx_hash = pending_tx
            .with_timeout(Some(self.tx_timeout))
            .watch()
            .await
            .context("failed to confirm tx")?;

        tracing::info!("Minted {} for {}: {}", value, account, tx_hash);

        Ok(())
    }

    /// Returns the balance of an account.
    pub async fn balance_of(&self, account: Address) -> Result<U256> {
        tracing::debug!("Calling balanceOf({:?})", account);
        let contract = IERC20::new(*self.instance.address(), self.instance.provider());
        let call = contract.balanceOf(account).from(self.caller);
        let balance = call.call().await.map_err(IHitPointsErrors::decode_error)?;
        Ok(balance)
    }
}

/// Returns the default allowance.
pub fn default_allowance() -> U256 {
    U256::from(DEFAULT_ALLOWANCE)
}
