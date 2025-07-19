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

use std::{
    fmt::Debug,
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};

use alloy::{
    consensus::{BlockHeader, Transaction},
    eips::BlockNumberOrTag,
    network::Ethereum,
    primitives::{utils::format_ether, Address, Bytes, B256, U256},
    providers::{PendingTransactionBuilder, PendingTransactionError, Provider},
    rpc::types::{Log, TransactionReceipt},
    signers::Signer,
};

use alloy_sol_types::{SolCall, SolEvent};
use anyhow::{anyhow, Context, Result};
use risc0_ethereum_contracts::event_query::EventQueryConfig;
use thiserror::Error;

use crate::contracts::token::{IERC20Permit, IHitPoints::IHitPointsErrors, Permit, IERC20};

use super::{
    eip712_domain, AssessorReceipt, EIP712DomainSaltless, Fulfillment,
    IBoundlessMarket::{self, IBoundlessMarketInstance},
    Offer, ProofRequest, RequestError, RequestId, RequestStatus, TxnErr, TXN_CONFIRM_TIMEOUT,
};

/// Fraction of stake the protocol gives to the prover who fills an order that was locked by another prover but expired
/// This is determined by the constant SLASHING_BURN_BPS defined in the BoundlessMarket contract.
/// The value is 4 because the slashing burn is 75% of the stake, and we give the remaining 1/4 of that to the prover.
/// TODO(https://github.com/boundless-xyz/boundless/issues/517): Retrieve this from the contract in the future
const FRACTION_STAKE_REWARD: u64 = 4;

/// Boundless market errors.
#[derive(Error, Debug)]
pub enum MarketError {
    /// Transaction error.
    #[error("Transaction error: {0}")]
    TxnError(#[from] TxnErr),

    /// Transaction confirmation error.
    #[error("Transaction confirmation error: {0:?}")]
    TxnConfirmationError(anyhow::Error),

    /// Request not fulfilled.
    #[error("Request is not fulfilled 0x{0:x}")]
    RequestNotFulfilled(U256),

    /// Request has expired.
    #[error("Request has expired 0x{0:x}")]
    RequestHasExpired(U256),

    /// Request malformed.
    #[error("Request error {0}")]
    RequestError(#[from] RequestError),

    /// Request address does not match with signer.
    #[error("Request address does not match with signer {0} - {0}")]
    AddressMismatch(Address, Address),

    /// Proof not found.
    #[error("Proof not found for request in events logs 0x{0:x}")]
    ProofNotFound(U256),

    /// Request not found.
    #[error("Request not found in event logs 0x{0:x}")]
    RequestNotFound(U256),

    /// Request already locked.
    #[error("Request already locked: 0x{0:x}")]
    RequestAlreadyLocked(U256),

    /// Lock request reverted, possibly outbid.
    #[error("Lock request reverted, possibly outbid: txn_hash: {0}")]
    LockRevert(B256),

    /// General market error.
    #[error("Other error: {0:?}")]
    Error(#[from] anyhow::Error),

    /// Timeout reached.
    #[error("Timeout: 0x{0:x}")]
    TimeoutReached(U256),
}

impl From<alloy::contract::Error> for MarketError {
    fn from(err: alloy::contract::Error) -> Self {
        tracing::debug!("raw alloy contract error: {:?}", err);
        MarketError::Error(TxnErr::from(err).into())
    }
}

/// Proof market service.
pub struct BoundlessMarketService<P> {
    instance: IBoundlessMarketInstance<P, Ethereum>,
    // Chain ID with caching to ensure we fetch it at most once.
    chain_id: AtomicU64,
    caller: Address,
    timeout: Duration,
    event_query_config: EventQueryConfig,
    balance_alert_config: StakeBalanceAlertConfig,
    receipt_query_config: ReceiptQueryConfig,
}

#[derive(Clone, Debug)]
struct ReceiptQueryConfig {
    /// Interval at which the transaction receipts are polled.
    retry_interval: Duration,
    /// Number of retries for querying receipt of lock transactions.
    retry_count: usize,
}

impl Default for ReceiptQueryConfig {
    fn default() -> Self {
        Self { retry_count: 10, retry_interval: Duration::from_millis(500) }
    }
}

#[derive(Clone, Debug, Default)]
struct StakeBalanceAlertConfig {
    /// Threshold at which to log a warning
    warn_threshold: Option<U256>,
    /// Threshold at which to log an error
    error_threshold: Option<U256>,
}

impl<P: Clone> Clone for BoundlessMarketService<P> {
    fn clone(&self) -> Self {
        Self {
            instance: self.instance.clone(),
            chain_id: self.chain_id.load(Ordering::Relaxed).into(),
            caller: self.caller,
            timeout: self.timeout,
            event_query_config: self.event_query_config.clone(),
            balance_alert_config: self.balance_alert_config.clone(),
            receipt_query_config: self.receipt_query_config.clone(),
        }
    }
}

fn extract_tx_log<E: SolEvent + Debug + Clone>(
    receipt: &TransactionReceipt,
) -> Result<Log<E>, anyhow::Error> {
    let logs = receipt
        .inner
        .logs()
        .iter()
        .filter_map(|log| {
            if log.topic0().map(|topic| E::SIGNATURE_HASH == *topic).unwrap_or(false) {
                Some(
                    log.log_decode::<E>()
                        .with_context(|| format!("failed to decode event {}", E::SIGNATURE)),
                )
            } else {
                tracing::debug!(
                    "skipping log on receipt; does not match {}: {log:?}",
                    E::SIGNATURE
                );
                None
            }
        })
        .collect::<Result<Vec<_>>>()?;

    match &logs[..] {
        [log] => Ok(log.clone()),
        [] => Err(anyhow!(
            "transaction 0x{:x} did not emit event {}",
            receipt.transaction_hash,
            E::SIGNATURE
        )),
        _ => Err(anyhow!(
            "transaction emitted more than one event with signature {}, {:#?}",
            E::SIGNATURE,
            logs
        )),
    }
}

impl<P: Provider> BoundlessMarketService<P> {
    /// Creates a new Boundless market service.
    pub fn new(address: impl Into<Address>, provider: P, caller: impl Into<Address>) -> Self {
        let instance = IBoundlessMarket::new(address.into(), provider);

        Self {
            instance,
            chain_id: AtomicU64::new(0),
            caller: caller.into(),
            timeout: TXN_CONFIRM_TIMEOUT,
            event_query_config: EventQueryConfig::default(),
            balance_alert_config: StakeBalanceAlertConfig::default(),
            receipt_query_config: ReceiptQueryConfig::default(),
        }
    }

    /// Sets the transaction timeout.
    pub fn with_timeout(self, timeout: Duration) -> Self {
        Self { timeout, ..self }
    }

    /// Sets the event query configuration.
    pub fn with_event_query_config(self, config: EventQueryConfig) -> Self {
        Self { event_query_config: config, ..self }
    }

    /// Set stake balance thresholds to warn or error alert on
    pub fn with_stake_balance_alert(
        self,
        warn_threshold: &Option<U256>,
        error_threshold: &Option<U256>,
    ) -> Self {
        Self {
            balance_alert_config: StakeBalanceAlertConfig {
                warn_threshold: *warn_threshold,
                error_threshold: *error_threshold,
            },
            ..self
        }
    }

    /// Retry count for confirmed transactions receipts.
    pub fn with_receipt_retry_count(mut self, count: usize) -> Self {
        self.receipt_query_config.retry_count = count;
        self
    }

    /// Retry polling interval for confirmed transactions receipts.
    pub fn with_receipt_retry_interval(mut self, interval: Duration) -> Self {
        self.receipt_query_config.retry_interval = interval;
        self
    }

    /// Returns the market contract instance.
    pub fn instance(&self) -> &IBoundlessMarketInstance<P, Ethereum> {
        &self.instance
    }

    /// Returns the caller address.
    pub fn caller(&self) -> Address {
        self.caller
    }

    /// Get the EIP-712 domain associated with the market contract.
    ///
    /// If not cached, this function will fetch the chain ID with an RPC call.
    pub async fn eip712_domain(&self) -> Result<EIP712DomainSaltless, MarketError> {
        Ok(eip712_domain(*self.instance.address(), self.get_chain_id().await?))
    }

    /// Deposit Ether into the market to pay for proof and/or lockin stake.
    pub async fn deposit(&self, value: U256) -> Result<(), MarketError> {
        tracing::trace!("Calling deposit() value: {value}");
        let call = self.instance.deposit().value(value);
        let pending_tx = call.send().await?;
        tracing::debug!("Broadcasting deposit tx {}", pending_tx.tx_hash());
        let tx_hash = pending_tx
            .with_timeout(Some(self.timeout))
            .watch()
            .await
            .context("failed to confirm tx")?;
        tracing::debug!("Submitted deposit {}", tx_hash);

        Ok(())
    }

    /// Withdraw Ether from the market.
    pub async fn withdraw(&self, amount: U256) -> Result<(), MarketError> {
        tracing::trace!("Calling withdraw({amount})");
        let call = self.instance.withdraw(amount);
        let pending_tx = call.send().await?;
        tracing::debug!("Broadcasting withdraw tx {}", pending_tx.tx_hash());
        let tx_hash = pending_tx
            .with_timeout(Some(self.timeout))
            .watch()
            .await
            .context("failed to confirm tx")?;
        tracing::debug!("Submitted withdraw {}", tx_hash);

        Ok(())
    }

    /// Returns the balance, in Wei, of the given account.
    pub async fn balance_of(&self, account: impl Into<Address>) -> Result<U256, MarketError> {
        let account = account.into();
        tracing::trace!("Calling balanceOf({account})");
        let balance = self.instance.balanceOf(account).call().await?;

        Ok(balance)
    }

    /// Submit a request such that it is publicly available for provers to evaluate and bid
    /// on. Includes the specified value, which will be deposited to the account of msg.sender.
    pub async fn submit_request_with_value(
        &self,
        request: &ProofRequest,
        signer: &impl Signer,
        value: impl Into<U256>,
    ) -> Result<U256, MarketError> {
        tracing::trace!("Calling submitRequest({:x?})", request);
        tracing::debug!("Sending request ID {:x}", request.id);
        let client_address = request.client_address();
        if client_address != signer.address() {
            return Err(MarketError::AddressMismatch(client_address, signer.address()));
        };
        let chain_id = self.get_chain_id().await.context("failed to get chain ID")?;
        let client_sig = request
            .sign_request(signer, *self.instance.address(), chain_id)
            .await
            .context("failed to sign request")?;
        let call = self
            .instance
            .submitRequest(request.clone(), client_sig.as_bytes().into())
            .from(self.caller)
            .value(value.into());
        let pending_tx = call.send().await?;
        tracing::debug!(
            "Broadcasting tx {:x} with request ID {:x}",
            pending_tx.tx_hash(),
            request.id
        );

        let receipt = self.get_receipt_with_retry(pending_tx).await?;

        // Look for the logs for submitting the transaction.
        let log = extract_tx_log::<IBoundlessMarket::RequestSubmitted>(&receipt)?;
        Ok(U256::from(log.inner.data.requestId))
    }

    /// Submit a request such that it is publicly available for provers to evaluate and bid
    /// on, with a signature specified as Bytes.
    pub async fn submit_request_with_signature(
        &self,
        request: &ProofRequest,
        signature: impl Into<Bytes>,
    ) -> Result<U256, MarketError> {
        tracing::trace!("Calling submitRequest({:x?})", request);
        tracing::debug!("Sending request ID {:x}", request.id);
        let call = self.instance.submitRequest(request.clone(), signature.into()).from(self.caller);
        let pending_tx = call.send().await?;
        tracing::debug!(
            "Broadcasting tx {:x} with request ID {:x}",
            pending_tx.tx_hash(),
            request.id
        );

        let receipt = self.get_receipt_with_retry(pending_tx).await?;

        // Look for the logs for submitting the transaction.
        let log = extract_tx_log::<IBoundlessMarket::RequestSubmitted>(&receipt)?;
        Ok(U256::from(log.inner.data.requestId))
    }

    /// Submit a request such that it is publicly available for provers to evaluate and bid
    /// on. Deposits funds to the client account if there are not enough to cover the max price on
    /// the offer.
    pub async fn submit_request(
        &self,
        request: &ProofRequest,
        signer: &impl Signer,
    ) -> Result<U256, MarketError> {
        let balance = self
            .balance_of(signer.address())
            .await
            .context("failed to get whether the client balance can cover the offer max price")?;
        let max_price = U256::from(request.offer.maxPrice);
        let value = if balance > max_price { U256::ZERO } else { U256::from(max_price) - balance };
        if value > U256::ZERO {
            tracing::debug!("Sending {} ETH with request {:x}", format_ether(value), request.id);
        }
        self.submit_request_with_value(request, signer, value).await
    }

    /// Lock the request to the prover, giving them exclusive rights to be paid to
    /// fulfill this request, and also making them subject to slashing penalties if they fail to
    /// deliver. At this point, the price for fulfillment is also set, based on the reverse Dutch
    /// auction parameters and the block number at which this transaction is processed.
    ///
    /// This method should be called from the address of the prover.
    pub async fn lock_request(
        &self,
        request: &ProofRequest,
        client_sig: impl Into<Bytes>,
        priority_gas: Option<u64>,
    ) -> Result<u64, MarketError> {
        tracing::trace!("Calling requestIsLocked({:x})", request.id);
        let is_locked_in: bool =
            self.instance.requestIsLocked(request.id).call().await.context("call failed")?;
        if is_locked_in {
            return Err(MarketError::RequestAlreadyLocked(request.id));
        }

        let client_sig_bytes = client_sig.into();
        tracing::trace!("Calling lockRequest({:x?}, {:x?})", request, client_sig_bytes);

        let mut call =
            self.instance.lockRequest(request.clone(), client_sig_bytes).from(self.caller);

        if let Some(gas) = priority_gas {
            let priority_fee = self
                .instance
                .provider()
                .estimate_eip1559_fees()
                .await
                .context("Failed to get priority gas fee")?;

            call = call
                .max_fee_per_gas(priority_fee.max_fee_per_gas + gas as u128)
                .max_priority_fee_per_gas(priority_fee.max_priority_fee_per_gas + gas as u128);
        }

        tracing::trace!("Sending tx {}", format!("{:?}", call));
        let pending_tx = call.send().await?;

        let tx_hash = *pending_tx.tx_hash();
        tracing::trace!("Broadcasting lock request tx {}", tx_hash);

        let receipt = self.get_receipt_with_retry(pending_tx).await?;

        if !receipt.status() {
            // TODO: Get + print revertReason
            return Err(MarketError::LockRevert(receipt.transaction_hash));
        }

        tracing::info!(
            "Locked request {:x}, transaction hash: {}",
            request.id,
            receipt.transaction_hash
        );

        self.check_stake_balance().await?;

        Ok(receipt.block_number.context("TXN Receipt missing block number")?)
    }

    /// Lock the request to the prover, giving them exclusive rights to be paid to
    /// fulfill this request, and also making them subject to slashing penalties if they fail to
    /// deliver. At this point, the price for fulfillment is also set, based on the reverse Dutch
    /// auction parameters and the block at which this transaction is processed.
    ///
    /// This method uses the provided signature to authenticate the prover. Note that the prover
    /// signature must be over the LockRequest struct, not the ProofRequest struct.
    pub async fn lock_request_with_signature(
        &self,
        request: &ProofRequest,
        client_sig: impl Into<Bytes>,
        prover_sig: impl Into<Bytes>,
        _priority_gas: Option<u128>,
    ) -> Result<u64, MarketError> {
        tracing::trace!("Calling requestIsLocked({:x})", request.id);
        let is_locked_in: bool =
            self.instance.requestIsLocked(request.id).call().await.context("call failed")?;
        if is_locked_in {
            return Err(MarketError::RequestAlreadyLocked(request.id));
        }

        let client_sig_bytes = client_sig.into();
        let prover_sig_bytes = prover_sig.into();
        tracing::trace!(
            "Calling lockRequestWithSignature({:x?}, {:x?}, {:x?})",
            request,
            client_sig_bytes,
            prover_sig_bytes
        );

        let call = self
            .instance
            .lockRequestWithSignature(request.clone(), client_sig_bytes.clone(), prover_sig_bytes)
            .from(self.caller);
        let pending_tx = call.send().await.context("Failed to lock")?;
        tracing::trace!("Broadcasting lock request with signature tx {}", pending_tx.tx_hash());

        let receipt = self.get_receipt_with_retry(pending_tx).await?;
        if !receipt.status() {
            // TODO: Get + print revertReason
            return Err(MarketError::LockRevert(receipt.transaction_hash));
        }

        tracing::info!(
            "Locked request {:x}, transaction hash: {}",
            request.id,
            receipt.transaction_hash
        );

        Ok(receipt.block_number.context("TXN Receipt missing block number")?)
    }

    async fn get_receipt_with_retry(
        &self,
        pending_tx: PendingTransactionBuilder<Ethereum>,
    ) -> Result<TransactionReceipt, MarketError> {
        let tx_hash = *pending_tx.tx_hash();

        // Get the nonce of the transaction for debugging purposes.
        // It is possible that the transaction is not found immediately after broadcast, so we don't error if it's not found.
        let tx_result = self.instance.provider().get_transaction_by_hash(tx_hash).await;
        if let Ok(Some(tx)) = tx_result {
            let nonce = tx.nonce();
            tracing::debug!("Tx {} broadcasted with nonce {}", tx_hash, nonce);
        } else {
            tracing::debug!(
                "Tx {} not found immediately after broadcast. Can't get nonce.",
                tx_hash
            );
        }

        match pending_tx.with_timeout(Some(self.timeout)).get_receipt().await {
            Ok(receipt) => Ok(receipt),
            Err(PendingTransactionError::TransportError(err)) if err.is_null_resp() => {
                tracing::debug!("failed to query receipt of confirmed transaction, retrying");
                // There is a race condition with some providers where a transaction will be
                // confirmed through the RPC, but querying the receipt returns null when requested
                // immediately after.
                for _ in 0..self.receipt_query_config.retry_count {
                    if let Ok(Some(receipt)) =
                        self.instance.provider().get_transaction_receipt(tx_hash).await
                    {
                        return Ok(receipt);
                    }

                    tokio::time::sleep(self.receipt_query_config.retry_interval).await;
                }

                Err(anyhow!(
                    "Transaction {:?} confirmed, but receipt was not found after {} retries.",
                    tx_hash,
                    self.receipt_query_config.retry_count
                )
                .into())
            }
            Err(e) => Err(MarketError::TxnConfirmationError(anyhow!(
                "failed to confirm tx {:?} within timeout {:?}: {}",
                tx_hash,
                self.timeout,
                e
            ))),
        }
    }

    /// When a prover fails to fulfill a request by the deadline, this function can be used to burn
    /// the associated prover stake.
    pub async fn slash(
        &self,
        request_id: U256,
    ) -> Result<IBoundlessMarket::ProverSlashed, MarketError> {
        tracing::trace!("Calling slash({:x?})", request_id);
        let call = self.instance.slash(request_id).from(self.caller);
        let pending_tx = call.send().await?;
        tracing::debug!("Broadcasting tx {}", pending_tx.tx_hash());

        let receipt = self.get_receipt_with_retry(pending_tx).await?;

        let log = extract_tx_log::<IBoundlessMarket::ProverSlashed>(&receipt)?;
        Ok(log.inner.data)
    }

    /// Submits a `FulfillmentTx`.
    pub async fn fulfill(&self, tx: FulfillmentTx) -> Result<(), MarketError> {
        let FulfillmentTx { root, unlocked_requests, fulfillments, assessor_receipt, withdraw } =
            tx;
        let price = !unlocked_requests.is_empty();

        match root {
            None => match (price, withdraw) {
                (false, false) => self._fulfill(fulfillments, assessor_receipt).await,
                (false, true) => self.fulfill_and_withdraw(fulfillments, assessor_receipt).await,
                (true, false) => {
                    self.price_and_fulfill(unlocked_requests, fulfillments, assessor_receipt, None)
                        .await
                }
                (true, true) => {
                    self.price_and_fulfill_and_withdraw(
                        unlocked_requests,
                        fulfillments,
                        assessor_receipt,
                        None,
                    )
                    .await
                }
            },
            Some(root) => match (price, withdraw) {
                (false, false) => {
                    self.submit_root_and_fulfill(root, fulfillments, assessor_receipt).await
                }
                (false, true) => {
                    self.submit_root_and_fulfill_and_withdraw(root, fulfillments, assessor_receipt)
                        .await
                }
                (true, false) => {
                    self.submit_root_and_price_fulfill(
                        root,
                        unlocked_requests,
                        fulfillments,
                        assessor_receipt,
                    )
                    .await
                }
                (true, true) => {
                    self.submit_root_and_price_fulfill_and_withdraw(
                        root,
                        unlocked_requests,
                        fulfillments,
                        assessor_receipt,
                    )
                    .await
                }
            },
        }
    }

    /// Fulfill a batch of requests by delivering the proof for each application.
    ///
    /// See [BoundlessMarketService::fulfill] for more details.
    async fn _fulfill(
        &self,
        fulfillments: Vec<Fulfillment>,
        assessor_fill: AssessorReceipt,
    ) -> Result<(), MarketError> {
        let fill_ids = fulfillments.iter().map(|fill| fill.id).collect::<Vec<_>>();
        tracing::trace!("Calling fulfill({fulfillments:?}, {assessor_fill:?})");
        let call = self.instance.fulfill(fulfillments, assessor_fill).from(self.caller);
        tracing::trace!("Calldata: {:x}", call.calldata());
        let pending_tx = call.send().await?;
        tracing::debug!("Broadcasting tx {}", pending_tx.tx_hash());

        let receipt = self.get_receipt_with_retry(pending_tx).await?;

        tracing::info!("Submitted proof for batch {:?}: {}", fill_ids, receipt.transaction_hash);

        Ok(())
    }

    /// Fulfill a batch of requests by delivering the proof for each application and withdraw from the prover balance.
    ///
    /// See [BoundlessMarketService::fulfill] for more details.
    async fn fulfill_and_withdraw(
        &self,
        fulfillments: Vec<Fulfillment>,
        assessor_fill: AssessorReceipt,
    ) -> Result<(), MarketError> {
        let fill_ids = fulfillments.iter().map(|fill| fill.id).collect::<Vec<_>>();
        tracing::trace!("Calling fulfillAndWithdraw({fulfillments:?}, {assessor_fill:?})");
        let call = self.instance.fulfillAndWithdraw(fulfillments, assessor_fill).from(self.caller);
        tracing::trace!("Calldata: {:x}", call.calldata());
        let pending_tx = call.send().await?;
        tracing::debug!("Broadcasting tx {}", pending_tx.tx_hash());

        let receipt = self.get_receipt_with_retry(pending_tx).await?;

        tracing::info!("Submitted proof for batch {:?}: {}", fill_ids, receipt.transaction_hash);

        Ok(())
    }

    /// Combined function to submit a new merkle root to the set-verifier and call `fulfill`.
    /// Useful to reduce the transaction count for fulfillments
    async fn submit_root_and_fulfill(
        &self,
        root: Root,
        fulfillments: Vec<Fulfillment>,
        assessor_fill: AssessorReceipt,
    ) -> Result<(), MarketError> {
        tracing::trace!(
            "Calling submitRootAndFulfill({:?}, {:x}, {fulfillments:?}, {assessor_fill:?})",
            root.root,
            root.seal
        );
        let call = self
            .instance
            .submitRootAndFulfill(
                root.verifier_address,
                root.root,
                root.seal,
                fulfillments,
                assessor_fill,
            )
            .from(self.caller);
        tracing::trace!("Calldata: {}", call.calldata());
        let pending_tx = call.send().await?;
        tracing::debug!("Broadcasting tx {}", pending_tx.tx_hash());
        let tx_receipt = self.get_receipt_with_retry(pending_tx).await?;

        tracing::info!("Submitted merkle root and proof for batch {}", tx_receipt.transaction_hash);

        Ok(())
    }

    /// Combined function to submit a new merkle root to the set-verifier and call `fulfillAndWithdraw`.
    /// Useful to reduce the transaction count for fulfillments
    async fn submit_root_and_fulfill_and_withdraw(
        &self,
        root: Root,
        fulfillments: Vec<Fulfillment>,
        assessor_fill: AssessorReceipt,
    ) -> Result<(), MarketError> {
        tracing::trace!("Calling submitRootAndFulfillAndWithdraw({:?}, {:x}, {fulfillments:?}, {assessor_fill:?})", root.root, root.seal);
        let call = self
            .instance
            .submitRootAndFulfillAndWithdraw(
                root.verifier_address,
                root.root,
                root.seal,
                fulfillments,
                assessor_fill,
            )
            .from(self.caller);
        tracing::trace!("Calldata: {}", call.calldata());
        let pending_tx = call.send().await?;
        tracing::debug!("Broadcasting tx {}", pending_tx.tx_hash());
        let tx_receipt = self.get_receipt_with_retry(pending_tx).await?;

        tracing::info!("Submitted merkle root and proof for batch {}", tx_receipt.transaction_hash);

        Ok(())
    }

    /// A combined call to `IBoundlessMarket.priceRequest` and `IBoundlessMarket.fulfill`.
    /// The caller should provide the signed request and signature for each unlocked request they
    /// want to fulfill. Payment for unlocked requests will go to the provided `prover` address.
    async fn price_and_fulfill(
        &self,
        unlocked_requests: Vec<UnlockedRequest>,
        fulfillments: Vec<Fulfillment>,
        assessor_fill: AssessorReceipt,
        priority_gas: Option<u64>,
    ) -> Result<(), MarketError> {
        tracing::trace!("Calling priceAndFulfill({fulfillments:?}, {assessor_fill:?})");

        let (requests, client_sigs): (Vec<_>, Vec<_>) =
            unlocked_requests.into_iter().map(|ur| (ur.request, ur.client_sig)).unzip();
        let mut call = self
            .instance
            .priceAndFulfill(requests, client_sigs, fulfillments, assessor_fill)
            .from(self.caller);
        tracing::trace!("Calldata: {}", call.calldata());

        if let Some(gas) = priority_gas {
            let priority_fee = self
                .instance
                .provider()
                .estimate_eip1559_fees()
                .await
                .context("Failed to get priority gas fee")?;

            call = call
                .max_fee_per_gas(priority_fee.max_fee_per_gas + gas as u128)
                .max_priority_fee_per_gas(priority_fee.max_priority_fee_per_gas + gas as u128);
        }

        let pending_tx = call.send().await?;
        tracing::debug!("Broadcasting tx {}", pending_tx.tx_hash());

        let tx_receipt = self.get_receipt_with_retry(pending_tx).await?;

        tracing::info!("Fulfilled proof for batch {}", tx_receipt.transaction_hash);

        Ok(())
    }

    /// A combined call to `IBoundlessMarket.priceRequest` and `IBoundlessMarket.fulfillAndWithdraw`.
    /// The caller should provide the signed request and signature for each unlocked request they
    /// want to fulfill. Payment for unlocked requests will go to the provided `prover` address.
    async fn price_and_fulfill_and_withdraw(
        &self,
        unlocked_requests: Vec<UnlockedRequest>,
        fulfillments: Vec<Fulfillment>,
        assessor_fill: AssessorReceipt,
        priority_gas: Option<u64>,
    ) -> Result<(), MarketError> {
        tracing::trace!("Calling priceAndFulfillAndWithdraw({fulfillments:?}, {assessor_fill:?})");

        let (requests, client_sigs): (Vec<_>, Vec<_>) =
            unlocked_requests.into_iter().map(|ur| (ur.request, ur.client_sig)).unzip();
        let mut call = self
            .instance
            .priceAndFulfillAndWithdraw(requests, client_sigs, fulfillments, assessor_fill)
            .from(self.caller);
        tracing::trace!("Calldata: {}", call.calldata());

        if let Some(gas) = priority_gas {
            let priority_fee = self
                .instance
                .provider()
                .estimate_eip1559_fees()
                .await
                .context("Failed to get priority gas fee")?;

            call = call
                .max_fee_per_gas(priority_fee.max_fee_per_gas + gas as u128)
                .max_priority_fee_per_gas(priority_fee.max_priority_fee_per_gas + gas as u128);
        }

        let pending_tx = call.send().await?;
        tracing::debug!("Broadcasting tx {}", pending_tx.tx_hash());

        let tx_receipt = self.get_receipt_with_retry(pending_tx).await?;

        tracing::info!("Fulfilled proof for batch {}", tx_receipt.transaction_hash);

        Ok(())
    }

    /// Combined function to submit a new merkle root to the set-verifier and call `priceAndfulfill`.
    /// Useful to reduce the transaction count for fulfillments
    async fn submit_root_and_price_fulfill(
        &self,
        root: Root,
        unlocked_requests: Vec<UnlockedRequest>,
        fulfillments: Vec<Fulfillment>,
        assessor_fill: AssessorReceipt,
    ) -> Result<(), MarketError> {
        let (requests, client_sigs): (Vec<_>, Vec<_>) =
            unlocked_requests.into_iter().map(|ur| (ur.request, ur.client_sig)).unzip();
        tracing::trace!("Calling submitRootAndPriceAndFulfill({:?}, {:x}, {:?}, {:?}, {fulfillments:?}, {assessor_fill:?})", root.root, root.seal, requests, client_sigs);
        let call = self
            .instance
            .submitRootAndPriceAndFulfill(
                root.verifier_address,
                root.root,
                root.seal,
                requests,
                client_sigs,
                fulfillments,
                assessor_fill,
            )
            .from(self.caller);
        tracing::trace!("Calldata: {}", call.calldata());
        let pending_tx = call.send().await?;
        tracing::debug!("Broadcasting tx {}", pending_tx.tx_hash());
        let tx_receipt = pending_tx
            .with_timeout(Some(self.timeout))
            .get_receipt()
            .await
            .context("failed to confirm tx")?;

        tracing::info!("Submitted merkle root and proof for batch {}", tx_receipt.transaction_hash);

        Ok(())
    }

    /// Combined function to submit a new merkle root to the set-verifier and call `priceAndFulfillAndWithdraw`.
    /// Useful to reduce the transaction count for fulfillments
    async fn submit_root_and_price_fulfill_and_withdraw(
        &self,
        root: Root,
        unlocked_requests: Vec<UnlockedRequest>,
        fulfillments: Vec<Fulfillment>,
        assessor_fill: AssessorReceipt,
    ) -> Result<(), MarketError> {
        let (requests, client_sigs): (Vec<_>, Vec<_>) =
            unlocked_requests.into_iter().map(|ur| (ur.request, ur.client_sig)).unzip();
        tracing::trace!("Calling submitRootAndPriceAndFulfillAndWithdraw({:?}, {:x}, {:?}, {:?}, {fulfillments:?}, {assessor_fill:?})", root.root, root.seal, requests, client_sigs);
        let call = self
            .instance
            .submitRootAndPriceAndFulfillAndWithdraw(
                root.verifier_address,
                root.root,
                root.seal,
                requests,
                client_sigs,
                fulfillments,
                assessor_fill,
            )
            .from(self.caller);
        tracing::trace!("Calldata: {}", call.calldata());
        let pending_tx = call.send().await?;
        tracing::debug!("Broadcasting tx {}", pending_tx.tx_hash());
        let tx_receipt = pending_tx
            .with_timeout(Some(self.timeout))
            .get_receipt()
            .await
            .context("failed to confirm tx")?;

        tracing::info!("Submitted merkle root and proof for batch {}", tx_receipt.transaction_hash);

        Ok(())
    }

    /// Checks if a request is locked in.
    pub async fn is_locked(&self, request_id: U256) -> Result<bool, MarketError> {
        tracing::trace!("Calling requestIsLocked({:x})", request_id);
        let res = self.instance.requestIsLocked(request_id).call().await?;

        Ok(res)
    }

    /// Checks if a request is fulfilled.
    pub async fn is_fulfilled(&self, request_id: U256) -> Result<bool, MarketError> {
        tracing::trace!("Calling requestIsFulfilled({:x})", request_id);
        let res = self.instance.requestIsFulfilled(request_id).call().await?;

        Ok(res)
    }

    /// Checks if a request is slashed.
    pub async fn is_slashed(&self, request_id: U256) -> Result<bool, MarketError> {
        tracing::trace!("Calling requestIsSlashed({:x})", request_id);
        let res = self.instance.requestIsSlashed(request_id).call().await?;

        Ok(res)
    }

    /// Returns the [RequestStatus] of a request.
    ///
    /// The `expires_at` parameter is the time at which the request expires.
    pub async fn get_status(
        &self,
        request_id: U256,
        expires_at: Option<u64>,
    ) -> Result<RequestStatus, MarketError> {
        let timestamp = self.get_latest_block_timestamp().await?;

        if self.is_fulfilled(request_id).await.context("Failed to check fulfillment status")? {
            return Ok(RequestStatus::Fulfilled);
        }

        if let Some(expires_at) = expires_at {
            if timestamp > expires_at {
                return Ok(RequestStatus::Expired);
            }
        }

        if self.is_locked(request_id).await.context("Failed to check locked status")? {
            let deadline = self.instance.requestDeadline(request_id).call().await?;
            if timestamp > deadline && deadline > 0 {
                return Ok(RequestStatus::Expired);
            };
            return Ok(RequestStatus::Locked);
        }

        Ok(RequestStatus::Unknown)
    }

    async fn get_latest_block_number(&self) -> Result<u64, MarketError> {
        Ok(self
            .instance
            .provider()
            .get_block_number()
            .await
            .context("Failed to get latest block number")?)
    }

    async fn get_latest_block_timestamp(&self) -> Result<u64, MarketError> {
        let block = self
            .instance
            .provider()
            .get_block_by_number(BlockNumberOrTag::Latest)
            .await
            .context("failed to get block")?
            .context("failed to get block")?;
        Ok(block.header.timestamp())
    }

    /// Query the ProofDelivered event based on request ID and block options.
    /// For each iteration, we query a range of blocks.
    /// If the event is not found, we move the range down and repeat until we find the event.
    /// If the event is not found after the configured max iterations, we return an error.
    /// The default range is set to 1000 blocks for each iteration, and the default maximum number of
    /// iterations is 100. This means that the search will cover a maximum of 100,000 blocks.
    /// Optionally, you can specify a lower and upper bound to limit the search range.
    async fn query_fulfilled_event(
        &self,
        request_id: U256,
        lower_bound: Option<u64>,
        upper_bound: Option<u64>,
    ) -> Result<(Bytes, Bytes), MarketError> {
        let mut upper_block = upper_bound.unwrap_or(self.get_latest_block_number().await?);
        let start_block = lower_bound.unwrap_or(upper_block.saturating_sub(
            self.event_query_config.block_range * self.event_query_config.max_iterations,
        ));

        // Loop to progressively search through blocks
        for _ in 0..self.event_query_config.max_iterations {
            // If the current end block is less than or equal to the starting block, stop searching
            if upper_block <= start_block {
                break;
            }

            // Calculate the block range to query: from [lower_block] to [upper_block]
            let lower_block = upper_block.saturating_sub(self.event_query_config.block_range);

            // Set up the event filter for the specified block range
            let mut event_filter = self.instance.ProofDelivered_filter();
            event_filter.filter = event_filter
                .filter
                .topic1(request_id)
                .from_block(lower_block)
                .to_block(upper_block);

            // Query the logs for the event
            let logs = event_filter.query().await?;

            if let Some((event, _)) = logs.first() {
                return Ok((event.fulfillment.journal.clone(), event.fulfillment.seal.clone()));
            }

            // Move the upper_block down for the next iteration
            upper_block = lower_block.saturating_sub(1);
        }

        // Return error if no logs are found after all iterations
        Err(MarketError::ProofNotFound(request_id))
    }

    /// Query the RequestSubmitted event based on request ID and block options.
    ///
    /// For each iteration, we query a range of blocks.
    /// If the event is not found, we move the range down and repeat until we find the event.
    /// If the event is not found after the configured max iterations, we return an error.
    /// The default range is set to 1000 blocks for each iteration, and the default maximum number of
    /// iterations is 100. This means that the search will cover a maximum of 100,000 blocks.
    /// Optionally, you can specify a lower and upper bound to limit the search range.
    async fn query_request_submitted_event(
        &self,
        request_id: U256,
        lower_bound: Option<u64>,
        upper_bound: Option<u64>,
    ) -> Result<(ProofRequest, Bytes), MarketError> {
        let mut upper_block = upper_bound.unwrap_or(self.get_latest_block_number().await?);
        let start_block = lower_bound.unwrap_or(upper_block.saturating_sub(
            self.event_query_config.block_range * self.event_query_config.max_iterations,
        ));

        // Loop to progressively search through blocks
        for _ in 0..self.event_query_config.max_iterations {
            // If the current end block is less than or equal to the starting block, stop searching
            if upper_block <= start_block {
                break;
            }

            // Calculate the block range to query: from [lower_block] to [upper_block]
            let lower_block = upper_block.saturating_sub(self.event_query_config.block_range);

            // Set up the event filter for the specified block range
            let mut event_filter = self.instance.RequestSubmitted_filter();
            event_filter.filter = event_filter
                .filter
                .topic1(request_id)
                .from_block(lower_block)
                .to_block(upper_block);

            // Query the logs for the event
            let logs = event_filter.query().await?;

            if let Some((event, _)) = logs.first() {
                return Ok((event.request.clone(), event.clientSignature.clone()));
            }

            // Move the upper_block down for the next iteration
            upper_block = lower_block.saturating_sub(1);
        }

        // Return error if no logs are found after all iterations
        Err(MarketError::RequestNotFound(request_id))
    }

    /// Returns journal and seal if the request is fulfilled.
    pub async fn get_request_fulfillment(
        &self,
        request_id: U256,
    ) -> Result<(Bytes, Bytes), MarketError> {
        match self.get_status(request_id, None).await? {
            RequestStatus::Expired => Err(MarketError::RequestHasExpired(request_id)),
            RequestStatus::Fulfilled => self.query_fulfilled_event(request_id, None, None).await,
            _ => Err(MarketError::RequestNotFulfilled(request_id)),
        }
    }

    /// Returns proof request and signature for a request submitted onchain.
    pub async fn get_submitted_request(
        &self,
        request_id: U256,
        tx_hash: Option<B256>,
    ) -> Result<(ProofRequest, Bytes), MarketError> {
        if let Some(tx_hash) = tx_hash {
            let tx_data = self
                .instance
                .provider()
                .get_transaction_by_hash(tx_hash)
                .await
                .context("Failed to get transaction")?
                .context("Transaction not found")?;
            let inputs = tx_data.input();
            let calldata = IBoundlessMarket::submitRequestCall::abi_decode(inputs)
                .context("Failed to decode input")?;
            return Ok((calldata.request, calldata.clientSignature));
        }
        self.query_request_submitted_event(request_id, None, None).await
    }

    /// Returns journal and seal if the request is fulfilled.
    ///
    /// This method will poll the status of the request until it is Fulfilled or Expired.
    /// Polling is done at intervals of `retry_interval` until the request is Fulfilled, Expired or
    /// the optional timeout is reached.
    pub async fn wait_for_request_fulfillment(
        &self,
        request_id: U256,
        retry_interval: Duration,
        expires_at: u64,
    ) -> Result<(Bytes, Bytes), MarketError> {
        loop {
            let status = self.get_status(request_id, Some(expires_at)).await?;
            match status {
                RequestStatus::Expired => return Err(MarketError::RequestHasExpired(request_id)),
                RequestStatus::Fulfilled => {
                    return self.query_fulfilled_event(request_id, None, None).await;
                }
                _ => {
                    tracing::info!(
                        "Request {:x} status: {:?}. Retrying in {:?}",
                        request_id,
                        status,
                        retry_interval
                    );
                    tokio::time::sleep(retry_interval).await;
                    continue;
                }
            }
        }
    }

    /// Generates a request index based on the EOA nonce.
    ///
    /// It does not guarantee that the index is not in use by the time the caller uses it.
    pub async fn index_from_nonce(&self) -> Result<u32, MarketError> {
        let nonce = self
            .instance
            .provider()
            .get_transaction_count(self.caller)
            .await
            .context(format!("Failed to get EOA nonce for {:?}", self.caller))?;
        let id: u32 = nonce.try_into().context("Failed to convert nonce to u32")?;
        let request_id = RequestId::u256(self.caller, id);
        match self.get_status(request_id, None).await? {
            RequestStatus::Unknown => Ok(id),
            _ => Err(MarketError::Error(anyhow!("index already in use"))),
        }
    }

    /// Generates a new request ID based on the EOA nonce.
    ///
    /// It does not guarantee that the ID is not in use by the time the caller uses it.
    pub async fn request_id_from_nonce(&self) -> Result<U256, MarketError> {
        let index = self.index_from_nonce().await?;
        Ok(RequestId::u256(self.caller, index))
    }

    /// Randomly generates a request index.
    ///
    /// It retries up to 10 times to generate a unique index, after which it returns an error.
    /// It does not guarantee that the index is not in use by the time the caller uses it.
    pub async fn index_from_rand(&self) -> Result<u32, MarketError> {
        let attempts = 10usize;
        for _ in 0..attempts {
            let id: u32 = rand::random();
            let request_id = RequestId::u256(self.caller, id);
            match self.get_status(request_id, None).await? {
                RequestStatus::Unknown => return Ok(id),
                _ => continue,
            }
        }
        Err(MarketError::Error(anyhow!(
            "failed to generate a unique index after {attempts} attempts"
        )))
    }

    /// Randomly generates a new request ID.
    ///
    /// It does not guarantee that the ID is not in use by the time the caller uses it.
    pub async fn request_id_from_rand(&self) -> Result<U256, MarketError> {
        let index = self.index_from_rand().await?;
        Ok(RequestId::u256(self.caller, index))
    }

    /// Returns the image ID and URL of the assessor guest.
    pub async fn image_info(&self) -> Result<(B256, String)> {
        tracing::trace!("Calling imageInfo()");
        let (image_id, image_url) =
            self.instance.imageInfo().call().await.context("call failed")?.into();

        Ok((image_id, image_url))
    }

    /// Get the chain ID.
    ///
    /// This function implements caching to save the chain ID after the first successful fetch.
    pub async fn get_chain_id(&self) -> Result<u64, MarketError> {
        let mut id = self.chain_id.load(Ordering::Relaxed);
        if id != 0 {
            return Ok(id);
        }
        id = self.instance.provider().get_chain_id().await.context("failed to get chain ID")?;
        self.chain_id.store(id, Ordering::Relaxed);
        Ok(id)
    }

    /// Approve a spender to spend `value` amount of HitPoints on behalf of the caller.
    pub async fn approve_deposit_stake(&self, value: U256) -> Result<()> {
        let spender = *self.instance.address();
        tracing::trace!("Calling approve({:?}, {})", spender, value);
        let token_address = self
            .instance
            .STAKE_TOKEN_CONTRACT()
            .call()
            .await
            .context("STAKE_TOKEN_CONTRACT call failed")?
            .0;
        let contract = IERC20::new(token_address.into(), self.instance.provider());
        let call = contract.approve(spender, value).from(self.caller);
        let pending_tx = call.send().await.map_err(IHitPointsErrors::decode_error)?;
        tracing::debug!("Broadcasting tx {}", pending_tx.tx_hash());
        let tx_hash = pending_tx
            .with_timeout(Some(self.timeout))
            .watch()
            .await
            .context("failed to confirm tx")?;

        tracing::info!("Approved {} to spend {}: {}", spender, value, tx_hash);

        Ok(())
    }

    /// Deposit stake into the market to pay for lockin stake.
    ///
    /// Before calling this method, the account owner must first approve
    /// the Boundless market contract as an allowed spender by calling `approve_deposit_stake`.    
    pub async fn deposit_stake(&self, value: U256) -> Result<(), MarketError> {
        tracing::trace!("Calling depositStake({})", value);
        let call = self.instance.depositStake(value);
        let pending_tx = call.send().await?;
        tracing::debug!("Broadcasting stake deposit tx {}", pending_tx.tx_hash());
        let tx_hash = pending_tx
            .with_timeout(Some(self.timeout))
            .watch()
            .await
            .context("failed to confirm tx")?;
        tracing::debug!("Submitted stake deposit {}", tx_hash);
        Ok(())
    }

    /// Permit and deposit stake into the market to pay for lockin stake.
    ///
    /// This method will send a single transaction.
    pub async fn deposit_stake_with_permit(
        &self,
        value: U256,
        signer: &impl Signer,
    ) -> Result<(), MarketError> {
        let token_address = self
            .instance
            .STAKE_TOKEN_CONTRACT()
            .call()
            .await
            .context("STAKE_TOKEN_CONTRACT call failed")?
            .0;
        let contract = IERC20Permit::new(token_address.into(), self.instance.provider());
        let call = contract.nonces(self.caller());
        let nonce = call.call().await.map_err(IHitPointsErrors::decode_error)?;
        let block = self
            .instance
            .provider()
            .get_block_by_number(BlockNumberOrTag::Latest)
            .await
            .context("failed to get block")?
            .context("failed to get block")?;
        let deadline = U256::from(block.header.timestamp() + 1000);
        let permit = Permit {
            owner: self.caller(),
            spender: *self.instance().address(),
            value,
            nonce,
            deadline,
        };
        tracing::debug!("Permit: {:?}", permit);
        let domain_separator = contract.DOMAIN_SEPARATOR().call().await?;
        let sig = permit.sign(signer, domain_separator).await?.as_bytes();
        let r = B256::from_slice(&sig[..32]);
        let s = B256::from_slice(&sig[32..64]);
        let v: u8 = sig[64];
        tracing::trace!("Calling depositStakeWithPermit({})", value);
        let call = self.instance.depositStakeWithPermit(value, deadline, v, r, s);
        let pending_tx = call.send().await?;
        tracing::debug!("Broadcasting stake deposit tx {}", pending_tx.tx_hash());
        let tx_hash = pending_tx
            .with_timeout(Some(self.timeout))
            .watch()
            .await
            .context("failed to confirm tx")?;
        tracing::debug!("Submitted stake deposit {}", tx_hash);
        Ok(())
    }

    /// Withdraw stake from the market.
    pub async fn withdraw_stake(&self, value: U256) -> Result<(), MarketError> {
        tracing::trace!("Calling withdrawStake({})", value);
        let call = self.instance.withdrawStake(value);
        let pending_tx = call.send().await?;
        tracing::debug!("Broadcasting stake withdraw tx {}", pending_tx.tx_hash());
        let tx_hash = pending_tx
            .with_timeout(Some(self.timeout))
            .watch()
            .await
            .context("failed to confirm tx")?;
        tracing::debug!("Submitted stake withdraw {}", tx_hash);
        self.check_stake_balance().await?;
        Ok(())
    }

    /// Returns the deposited balance, in HP, of the given account.
    pub async fn balance_of_stake(&self, account: impl Into<Address>) -> Result<U256, MarketError> {
        let account = account.into();
        tracing::trace!("Calling balanceOfStake({})", account);
        let balance = self.instance.balanceOfStake(account).call().await.context("call failed")?;
        Ok(balance)
    }

    /// Check the current stake balance against the alert config
    /// and log a warning or error or below the thresholds.
    async fn check_stake_balance(&self) -> Result<(), MarketError> {
        let stake_balance = self.balance_of_stake(self.caller()).await?;
        if stake_balance < self.balance_alert_config.error_threshold.unwrap_or(U256::ZERO) {
            tracing::error!(
                "[B-BAL-STK] stake balance {} for {} < error threshold",
                stake_balance,
                self.caller(),
            );
        } else if stake_balance < self.balance_alert_config.warn_threshold.unwrap_or(U256::ZERO) {
            tracing::warn!(
                "[B-BAL-STK] stake balance {} for {} < warning threshold",
                stake_balance,
                self.caller(),
            );
        } else {
            tracing::trace!("stake balance for {} is: {}", self.caller(), stake_balance);
        }
        Ok(())
    }

    /// Returns the stake token address used by the market.
    pub async fn stake_token_address(&self) -> Result<Address, MarketError> {
        tracing::trace!("Calling STAKE_TOKEN_CONTRACT()");
        let address = self
            .instance
            .STAKE_TOKEN_CONTRACT()
            .call()
            .await
            .context("STAKE_TOKEN_CONTRACT call failed")?
            .0;
        Ok(address.into())
    }

    /// Returns the stake token's symbol.
    pub async fn stake_token_symbol(&self) -> Result<String, MarketError> {
        let address = self.stake_token_address().await?;
        let contract = IERC20::new(address, self.instance.provider());
        let symbol = contract.symbol().call().await.context("Failed to get token symbol")?;
        Ok(symbol)
    }

    /// Returns the stake token's decimals.
    pub async fn stake_token_decimals(&self) -> Result<u8, MarketError> {
        let address = self.stake_token_address().await?;
        let contract = IERC20::new(address, self.instance.provider());
        let decimals = contract.decimals().call().await.context("Failed to get token decimals")?;
        Ok(decimals)
    }
}

impl Offer {
    /// Calculates the time, in seconds since the UNIX epoch, at which the price will be at the given price.
    pub fn time_at_price(&self, price: U256) -> Result<u64, MarketError> {
        let max_price = U256::from(self.maxPrice);
        let min_price = U256::from(self.minPrice);

        if price > U256::from(max_price) {
            return Err(MarketError::Error(anyhow::anyhow!("Price cannot exceed max price")));
        }

        if price <= min_price {
            return Ok(0);
        }

        let rise = max_price - min_price;
        let run = U256::from(self.rampUpPeriod);
        let delta = ((price - min_price) * run).div_ceil(rise);
        let delta: u64 = delta.try_into().context("Failed to convert block delta to u64")?;

        Ok(self.biddingStart + delta)
    }

    /// Calculates the price at the given time, in seconds since the UNIX epoch.
    pub fn price_at(&self, timestamp: u64) -> Result<U256, MarketError> {
        let max_price = U256::from(self.maxPrice);
        let min_price = U256::from(self.minPrice);

        if timestamp < self.biddingStart {
            return Ok(self.minPrice);
        }

        if timestamp > self.lock_deadline() {
            return Ok(U256::ZERO);
        }

        if timestamp < self.biddingStart + self.rampUpPeriod as u64 {
            let rise = max_price - min_price;
            let run = U256::from(self.rampUpPeriod);
            let delta = U256::from(timestamp) - U256::from(self.biddingStart);

            Ok(min_price + (delta * rise) / run)
        } else {
            Ok(max_price)
        }
    }

    /// UNIX timestamp after which the request is considered completely expired.
    pub fn deadline(&self) -> u64 {
        self.biddingStart + (self.timeout as u64)
    }

    /// UNIX timestamp after which any lock on the request expires, and the client fee is zero.
    ///
    /// Once locked, if a valid proof is not submitted before this deadline, the prover can be
    /// "slashed", which refunds the price to the requester and takes the prover stake.
    /// Additionally, the fee paid by the client is zero for proofs delivered after this time. Note
    /// that after this time, and before `timeout` a proof can still be delivered to fulfill the
    /// request.
    pub fn lock_deadline(&self) -> u64 {
        self.biddingStart + (self.lockTimeout as u64)
    }

    /// Returns the amount of stake that the protocol awards to the prover who fills an order that
    /// was locked by another prover but not fulfilled by lock expiry.
    pub fn stake_reward_if_locked_and_not_fulfilled(&self) -> U256 {
        self.lockStake / U256::from(FRACTION_STAKE_REWARD)
    }
}

#[derive(Debug, Clone)]
/// Represents the parameters for submitting a Merkle Root.
pub struct Root {
    /// The address of the set verifier contract.
    pub verifier_address: Address,
    /// The Merkle root of the proof.
    pub root: B256,
    /// The seal of the proof.
    pub seal: Bytes,
}

#[derive(Debug, Clone)]
/// Represents the parameters for pricing an unlocked request.
pub struct UnlockedRequest {
    /// The unlocked request to be priced.
    pub request: ProofRequest,
    /// The client signature for the request.
    pub client_sig: Bytes,
}

impl UnlockedRequest {
    /// Creates a new instance of the `UnlockedRequest` struct.
    pub fn new(request: ProofRequest, client_sig: impl Into<Bytes>) -> Self {
        Self { request, client_sig: client_sig.into() }
    }
}

#[derive(Clone)]
#[non_exhaustive]
/// Struct for creating a fulfillment transaction request.
///
/// The `root` can be `None` if the caller does not want to submit a new Merkle root as part of the transaction.
/// The `unlocked_requests` field is used to price the requests.
/// The `withdraw` field indicates whether the prover should withdraw their balance after fulfilling the requests.
pub struct FulfillmentTx {
    /// The parameters for submitting a Merkle Root
    pub root: Option<Root>,
    /// The list of unlocked requests.
    pub unlocked_requests: Vec<UnlockedRequest>,
    /// The fulfillments to be submitted
    pub fulfillments: Vec<Fulfillment>,
    /// The assessor receipt
    pub assessor_receipt: AssessorReceipt,
    /// Whether to withdraw the fee
    pub withdraw: bool,
}

impl FulfillmentTx {
    /// Creates a new instance of the `Fulfill` struct.
    pub fn new(fulfillments: Vec<Fulfillment>, assessor_receipt: AssessorReceipt) -> Self {
        Self {
            root: None,
            unlocked_requests: Vec::new(),
            fulfillments,
            assessor_receipt,
            withdraw: false,
        }
    }

    /// Sets the parameters for submitting a Merkle Root.
    pub fn with_submit_root(
        self,
        verifier_address: impl Into<Address>,
        root: B256,
        seal: impl Into<Bytes>,
    ) -> Self {
        Self {
            root: Some(Root { verifier_address: verifier_address.into(), root, seal: seal.into() }),
            ..self
        }
    }

    /// Adds an unlocked request to be priced to the transaction.
    pub fn with_unlocked_request(self, unlocked_request: UnlockedRequest) -> Self {
        let mut requests = self.unlocked_requests;
        requests.push(unlocked_request);
        Self { unlocked_requests: requests, ..self }
    }

    /// Adds a list of unlocked requests to be priced to the transaction.
    pub fn with_unlocked_requests(self, unlocked_requests: Vec<UnlockedRequest>) -> Self {
        let mut requests = self.unlocked_requests;
        requests.extend(unlocked_requests);
        Self { unlocked_requests: requests, ..self }
    }

    /// Sets whether to withdraw the fee.
    pub fn with_withdraw(self, withdraw: bool) -> Self {
        Self { withdraw, ..self }
    }
}

#[cfg(test)]
mod tests {
    use crate::contracts::Offer;
    use alloy::primitives::{utils::parse_ether, U256};
    fn ether(value: &str) -> U256 {
        parse_ether(value).unwrap()
    }

    fn test_offer(bidding_start: u64) -> Offer {
        Offer {
            minPrice: ether("1"),
            maxPrice: ether("2"),
            biddingStart: bidding_start,
            rampUpPeriod: 100,
            timeout: 500,
            lockTimeout: 500,
            lockStake: ether("1"),
        }
    }

    #[test]
    fn test_price_at() {
        let offer = &test_offer(100);

        // Before bidding start, price is min price.
        assert_eq!(offer.price_at(90).unwrap(), ether("1"));

        assert_eq!(offer.price_at(100).unwrap(), ether("1"));

        assert_eq!(offer.price_at(101).unwrap(), ether("1.01"));
        assert_eq!(offer.price_at(125).unwrap(), ether("1.25"));
        assert_eq!(offer.price_at(150).unwrap(), ether("1.5"));
        assert_eq!(offer.price_at(175).unwrap(), ether("1.75"));
        assert_eq!(offer.price_at(199).unwrap(), ether("1.99"));

        assert_eq!(offer.price_at(200).unwrap(), ether("2"));
        assert_eq!(offer.price_at(500).unwrap(), ether("2"));
    }

    #[test]
    fn test_time_at_price() {
        let offer = &test_offer(100);

        assert_eq!(offer.time_at_price(ether("1")).unwrap(), 0);

        assert_eq!(offer.time_at_price(ether("1.01")).unwrap(), 101);
        assert_eq!(offer.time_at_price(ether("1.001")).unwrap(), 101);

        assert_eq!(offer.time_at_price(ether("1.25")).unwrap(), 125);
        assert_eq!(offer.time_at_price(ether("1.5")).unwrap(), 150);
        assert_eq!(offer.time_at_price(ether("1.75")).unwrap(), 175);
        assert_eq!(offer.time_at_price(ether("1.99")).unwrap(), 199);
        assert_eq!(offer.time_at_price(ether("2")).unwrap(), 200);

        // Price cannot exceed maxPrice
        assert!(offer.time_at_price(ether("3")).is_err());
    }
}
