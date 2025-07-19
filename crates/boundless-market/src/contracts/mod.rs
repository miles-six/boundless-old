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

#[cfg(not(target_os = "zkvm"))]
use std::str::FromStr;
use std::{borrow::Cow, ops::Not};

#[cfg(not(target_os = "zkvm"))]
use alloy::{
    contract::Error as ContractErr,
    primitives::{Signature, SignatureError},
    signers::Signer,
    sol_types::{Error as DecoderErr, SolInterface, SolStruct},
    transports::TransportError,
};
use alloy_primitives::{
    aliases::{U160, U32, U96},
    Address, Bytes, FixedBytes, B256, U256,
};
use alloy_sol_types::{eip712_domain, Eip712Domain};
use serde::{Deserialize, Serialize};
#[cfg(not(target_os = "zkvm"))]
use std::time::Duration;
#[cfg(not(target_os = "zkvm"))]
use thiserror::Error;
#[cfg(not(target_os = "zkvm"))]
use token::{
    IHitPoints::{self, IHitPointsErrors},
    IERC20::IERC20Errors,
};
use url::Url;

use risc0_zkvm::sha::Digest;

#[cfg(not(target_os = "zkvm"))]
pub use risc0_ethereum_contracts::{encode_seal, selector::Selector, IRiscZeroSetVerifier};

#[cfg(not(target_os = "zkvm"))]
use crate::{input::GuestEnvBuilder, util::now_timestamp};

#[cfg(not(target_os = "zkvm"))]
const TXN_CONFIRM_TIMEOUT: Duration = Duration::from_secs(45);

// boundless_market_generated.rs contains the Boundless contract types
// with alloy derive statements added.
// See the build.rs script in this crate for more details.
include!(concat!(env!("OUT_DIR"), "/boundless_market_generated.rs"));
pub use boundless_market_contract::{
    AssessorCallback, AssessorCommitment, AssessorJournal, AssessorJournalCallback,
    AssessorReceipt, Callback, Fulfillment, FulfillmentContext, IBoundlessMarket,
    Input as RequestInput, InputType as RequestInputType, LockRequest, Offer, Predicate,
    PredicateType, ProofRequest, RequestLock, Requirements, Selector as AssessorSelector,
};

#[allow(missing_docs)]
#[cfg(not(target_os = "zkvm"))]
pub mod token {
    use alloy::{
        primitives::{Signature, B256},
        signers::Signer,
        sol_types::SolStruct,
    };
    use anyhow::Result;
    use serde::Serialize;

    alloy::sol!(
        #![sol(rpc, all_derives)]
        "src/contracts/artifacts/IHitPoints.sol"
    );

    alloy::sol! {
        #[derive(Debug, Serialize)]
        struct Permit {
            address owner;
            address spender;
            uint256 value;
            uint256 nonce;
            uint256 deadline;
        }
    }

    alloy::sol! {
        #[derive(Debug)]
        #[sol(rpc)]
        interface IERC20 {
            error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
            error ERC20InvalidSender(address sender);
            error ERC20InvalidReceiver(address receiver);
            error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
            error ERC20InvalidApprover(address approver);
            error ERC20InvalidSpender(address spender);
            function approve(address spender, uint256 value) external returns (bool);
            function balanceOf(address account) external view returns (uint256);
            function symbol() external view returns (string memory);
            function decimals() external view returns (uint8);
        }
    }

    alloy::sol! {
        #[sol(rpc)]
        interface IERC20Permit {
            function nonces(address owner) external view returns (uint256);
            function DOMAIN_SEPARATOR() external view returns (bytes32);
        }
    }

    impl Permit {
        /// Signs the [Permit] with the given signer and EIP-712 domain separator.
        ///
        /// The content to be signed is the hash of the magic bytes 0x1901
        /// concatenated with the domain separator and the `hashStruct` result:
        /// `keccak256("\x19\x01" ‖ domainSeparator ‖ hashStruct(permit))`
        pub async fn sign(
            &self,
            signer: &impl Signer,
            domain_separator: B256,
        ) -> Result<Signature> {
            let struct_hash = self.eip712_hash_struct();
            let prefix: &[u8] = &[0x19, 0x01];
            let signing_bytes = prefix
                .iter()
                .chain(domain_separator.as_slice())
                .chain(struct_hash.as_slice())
                .cloned()
                .collect::<Vec<u8>>();
            let signing_hash = alloy::primitives::keccak256(signing_bytes);

            Ok(signer.sign_hash(&signing_hash).await?)
        }
    }
}

/// Status of a proof request
#[derive(Default, Debug, PartialEq)]
pub enum RequestStatus {
    /// The request has expired.
    Expired,
    /// The request is locked in and waiting for fulfillment.
    Locked,
    /// The request has been fulfilled.
    Fulfilled,
    /// The request has an unknown status.
    ///
    /// This is used to represent the status of a request
    /// with no evidence in the state. The request may be
    /// open for bidding or it may not exist.
    #[default]
    Unknown,
}

#[derive(Deserialize, Serialize, Clone, Debug, PartialEq)]
/// EIP-712 domain separator without the salt field.
pub struct EIP712DomainSaltless {
    /// The name of the domain.
    pub name: Cow<'static, str>,
    /// The protocol version.
    pub version: Cow<'static, str>,
    /// The chain ID.
    pub chain_id: u64,
    /// The address of the verifying contract.
    pub verifying_contract: Address,
}

impl EIP712DomainSaltless {
    /// Returns the EIP-712 domain with the salt field set to zero.
    pub fn alloy_struct(&self) -> Eip712Domain {
        eip712_domain! {
            name: self.name.clone(),
            version: self.version.clone(),
            chain_id: self.chain_id,
            verifying_contract: self.verifying_contract,
        }
    }
}

/// Structured represent of a request ID.
///
/// This struct can be packed and unpacked from a U256 value.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[non_exhaustive]
pub struct RequestId {
    /// Address of the wallet or contract authorizing the request.
    pub addr: Address,
    /// Index of the request, assigned by the requester.
    ///
    /// Each index can correspond to a single fulfilled request. If multiple requests have the same
    /// address and index, only one can ever be fulfilled. This is similar to how transaction
    /// nonces work on Ethereum.
    pub index: u32,
    /// A flag set to true when the signature over the request is provided by a smart contract,
    /// using ERC-1271. When set to false, the request is signed using ECDSA.
    pub smart_contract_signed: bool,
}

impl RequestId {
    /// Create a [RequestId] with the given [Address] and index. Sets flags to default values.
    pub fn new(addr: Address, index: u32) -> Self {
        Self { addr, index, smart_contract_signed: false }
    }

    /// Create a packed [RequestId] with the given [Address] and index. Sets flags to default values.
    pub fn u256(addr: Address, index: u32) -> U256 {
        Self::new(addr, index).into()
    }

    /// Set the smart contract signed flag to true. This indicates that the signature associated
    /// with the request should be validated using ERC-1271's isValidSignature function.
    pub fn set_smart_contract_signed_flag(self) -> Self {
        Self { addr: self.addr, index: self.index, smart_contract_signed: true }
    }

    /// Unpack a [RequestId] from a [U256] ignoring bits that do not correspond to known fields.
    ///
    /// Note that this is a lossy conversion in that converting the resulting [RequestId] back into
    /// a [U256] is not guaranteed to give the original value. If flags are added in future
    /// versions of the Boundless Market, this function will ignore them.
    pub fn from_lossy(value: U256) -> Self {
        let mut addr_u256 = value >> U256::from(32);
        addr_u256 &= (U256::from(1) << U256::from(160)) - U256::from(1); // mask out the flags
        let addr = Address::from(addr_u256.to::<U160>());
        Self {
            addr,
            index: (value & U32::MAX.to::<U256>()).to::<u32>(),
            smart_contract_signed: (value & (U256::from(1) << 192)) != U256::ZERO,
        }
    }
}

impl TryFrom<U256> for RequestId {
    type Error = RequestError;

    fn try_from(value: U256) -> Result<Self, Self::Error> {
        // Check if any bits above the smart contract signed flag are set.
        // An error here could indicate that this logic has not been updated to support new flags
        if value >> 193 != U256::ZERO {
            return Err(RequestError::MalformedRequestId);
        }
        Ok(RequestId::from_lossy(value))
    }
}

impl From<RequestId> for U256 {
    fn from(value: RequestId) -> Self {
        #[allow(clippy::unnecessary_fallible_conversions)] // U160::from does not compile
        let addr = U160::try_from(value.addr).unwrap();
        let smart_contract_signed_flag =
            if value.smart_contract_signed { U256::from(1) } else { U256::ZERO };
        (smart_contract_signed_flag << 192) | (U256::from(addr) << 32) | U256::from(value.index)
    }
}

#[non_exhaustive]
#[derive(thiserror::Error, Debug)]
/// Errors that can occur when creating a proof request.
pub enum RequestError {
    /// The request ID is malformed.
    #[error("malformed request ID")]
    MalformedRequestId,

    /// The client address is all zeroes.
    #[error("request ID has client address of all zeroes")]
    ClientAddrIsZero,

    /// The signature is invalid.
    #[cfg(not(target_os = "zkvm"))]
    #[error("signature error: {0}")]
    SignatureError(#[from] alloy::signers::Error),

    /// The image URL is empty.
    #[error("image URL must not be empty")]
    EmptyImageUrl,

    /// The image URL is malformed.
    #[error("malformed image URL: {0}")]
    MalformedImageUrl(#[from] url::ParseError),

    /// The image ID is zero.
    #[error("image ID must not be ZERO")]
    ImageIdIsZero,

    /// The offer timeout is zero.
    #[error("offer timeout must be greater than 0")]
    OfferTimeoutIsZero,

    /// The offer lock timeout is zero.
    #[error("offer lock timeout must be greater than 0")]
    OfferLockTimeoutIsZero,

    /// The offer ramp up period is longer than the lock timeout
    #[error("offer ramp up period must be less than or equal to the lock timeout")]
    OfferRampUpGreaterThanLockTimeout,

    /// The offer lock timeout is greater than the timeout
    #[error("offer lock timeout must be less than or equal to the timeout")]
    OfferLockTimeoutGreaterThanTimeout,

    /// Difference between timeout and lockTimeout much be less than 2^24
    ///
    /// This is a requirement of the BoundlessMarket smart to optimize use of storage.
    #[error("difference between timeout and lockTimeout much be less than 2^24")]
    OfferTimeoutRangeTooLarge,

    /// The offer max price is zero.
    #[error("offer maxPrice must be greater than 0")]
    OfferMaxPriceIsZero,

    /// The offer max price is less than the min price.
    #[error("offer maxPrice must be greater than or equal to minPrice")]
    OfferMaxPriceIsLessThanMin,

    /// The offer bidding start is zero.
    #[error("offer biddingStart must be greater than 0")]
    OfferBiddingStartIsZero,

    /// The requirements are missing from the request.
    #[error("missing requirements")]
    MissingRequirements,

    /// The image URL is missing from the request.
    #[error("missing image URL")]
    MissingImageUrl,

    /// The input is missing from the request.
    #[error("missing input")]
    MissingInput,

    /// The offer is missing from the request.
    #[error("missing offer")]
    MissingOffer,

    /// The request ID is missing from the request.
    #[error("missing request ID")]
    MissingRequestId,

    /// Request digest mismatch.
    #[error("request digest mismatch")]
    DigestMismatch,
}

#[cfg(not(target_os = "zkvm"))]
impl From<SignatureError> for RequestError {
    fn from(err: alloy::primitives::SignatureError) -> Self {
        RequestError::SignatureError(err.into())
    }
}

impl ProofRequest {
    /// Creates a new proof request with the given parameters.
    ///
    /// The request ID is generated by combining the address and given idx.
    pub fn new(
        request_id: RequestId,
        requirements: impl Into<Requirements>,
        image_url: impl Into<String>,
        input: impl Into<RequestInput>,
        offer: impl Into<Offer>,
    ) -> Self {
        Self {
            id: request_id.into(),
            requirements: requirements.into(),
            imageUrl: image_url.into(),
            input: input.into(),
            offer: offer.into(),
        }
    }

    /// Returns the client address from the request ID.
    pub fn client_address(&self) -> Address {
        RequestId::from_lossy(self.id).addr
    }

    /// Returns the time, in seconds since the UNIX epoch, at which the request expires.
    pub fn expires_at(&self) -> u64 {
        self.offer.biddingStart + self.offer.timeout as u64
    }

    /// Returns true if the expiration time has passed, according to the system clock.
    ///
    /// NOTE: If the system clock has significant has drifted relative to the chain's clock, this
    /// may not give the correct result.
    #[cfg(not(target_os = "zkvm"))]
    pub fn is_expired(&self) -> bool {
        self.expires_at() < now_timestamp()
    }

    /// Returns the time, in seconds since the UNIX epoch, at which the request lock expires.
    pub fn lock_expires_at(&self) -> u64 {
        self.offer.biddingStart + self.offer.lockTimeout as u64
    }

    /// Returns true if the lock expiration time has passed, according to the system clock.
    ///
    /// NOTE: If the system clock has significant has drifted relative to the chain's clock, this
    /// may not give the correct result.
    #[cfg(not(target_os = "zkvm"))]
    pub fn is_lock_expired(&self) -> bool {
        self.lock_expires_at() < now_timestamp()
    }

    /// Return true if the request ID indicates that it is authorized by a smart contract, rather
    /// than an EOA (i.e. an ECDSA key).
    pub fn is_smart_contract_signed(&self) -> bool {
        RequestId::from_lossy(self.id).smart_contract_signed
    }

    /// Check that the request is valid and internally consistent.
    ///
    /// If any field are empty, or if two fields conflict (e.g. the max price is less than the min
    /// price) this function will return an error.
    ///
    /// NOTE: This does not check whether the request has expired. You can use
    /// [ProofRequest::is_lock_expired] to do so.
    pub fn validate(&self) -> Result<(), RequestError> {
        if RequestId::from_lossy(self.id).addr == Address::ZERO {
            return Err(RequestError::ClientAddrIsZero);
        }
        if self.imageUrl.is_empty() {
            return Err(RequestError::EmptyImageUrl);
        }
        Url::parse(&self.imageUrl).map(|_| ())?;

        if self.requirements.imageId == B256::default() {
            return Err(RequestError::ImageIdIsZero);
        }
        if self.offer.timeout == 0 {
            return Err(RequestError::OfferTimeoutIsZero);
        }
        if self.offer.lockTimeout == 0 {
            return Err(RequestError::OfferLockTimeoutIsZero);
        }
        if self.offer.rampUpPeriod > self.offer.lockTimeout {
            return Err(RequestError::OfferRampUpGreaterThanLockTimeout);
        }
        if self.offer.lockTimeout > self.offer.timeout {
            return Err(RequestError::OfferLockTimeoutGreaterThanTimeout);
        }
        if self.offer.timeout - self.offer.lockTimeout >= 1 << 24 {
            return Err(RequestError::OfferTimeoutRangeTooLarge);
        }
        if self.offer.maxPrice == U256::ZERO {
            return Err(RequestError::OfferMaxPriceIsZero);
        }
        if self.offer.maxPrice < self.offer.minPrice {
            return Err(RequestError::OfferMaxPriceIsLessThanMin);
        }
        if self.offer.biddingStart == 0 {
            return Err(RequestError::OfferBiddingStartIsZero);
        }

        Ok(())
    }
}

#[cfg(not(target_os = "zkvm"))]
impl ProofRequest {
    /// Signs the request with the given signer and EIP-712 domain derived from the given
    /// contract address and chain ID.
    pub async fn sign_request(
        &self,
        signer: &impl Signer,
        contract_addr: Address,
        chain_id: u64,
    ) -> Result<Signature, RequestError> {
        let domain = eip712_domain(contract_addr, chain_id);
        let hash = self.eip712_signing_hash(&domain.alloy_struct());
        Ok(signer.sign_hash(&hash).await?)
    }

    /// Returns the EIP-712 signing hash for the request.
    pub fn signing_hash(
        &self,
        contract_addr: Address,
        chain_id: u64,
    ) -> Result<FixedBytes<32>, RequestError> {
        let domain = eip712_domain(contract_addr, chain_id);
        let hash = self.eip712_signing_hash(&domain.alloy_struct());
        Ok(hash)
    }

    /// Verifies the request signature with the given signer and EIP-712 domain derived from
    /// the given contract address and chain ID.
    pub fn verify_signature(
        &self,
        signature: &Bytes,
        contract_addr: Address,
        chain_id: u64,
    ) -> Result<(), RequestError> {
        let sig = Signature::try_from(signature.as_ref())?;
        let domain = eip712_domain(contract_addr, chain_id);
        let hash = self.eip712_signing_hash(&domain.alloy_struct());
        let addr = sig.recover_address_from_prehash(&hash)?;
        if addr == self.client_address() {
            Ok(())
        } else {
            Err(SignatureError::FromBytes("Address mismatch").into())
        }
    }
}

impl Requirements {
    /// Creates a new requirements with the given image ID and predicate.
    pub fn new(image_id: impl Into<Digest>, predicate: Predicate) -> Self {
        Self {
            imageId: <[u8; 32]>::from(image_id.into()).into(),
            predicate,
            callback: Callback::default(),
            selector: UNSPECIFIED_SELECTOR,
        }
    }

    /// Sets the image ID.
    pub fn with_image_id(self, image_id: impl Into<Digest>) -> Self {
        Self { imageId: <[u8; 32]>::from(image_id.into()).into(), ..self }
    }

    /// Sets the predicate.
    pub fn with_predicate(self, predicate: Predicate) -> Self {
        Self { predicate, ..self }
    }

    /// Sets the callback.
    pub fn with_callback(self, callback: Callback) -> Self {
        Self { callback, ..self }
    }

    /// Sets the selector.
    pub fn with_selector(self, selector: FixedBytes<4>) -> Self {
        Self { selector, ..self }
    }

    /// Set the selector for a groth16 proof.
    ///
    /// This will set the selector to the appropriate value based on the current environment.
    /// In dev mode, the selector will be set to `FakeReceipt`, otherwise it will be set
    /// to `Groth16V2_1`.
    #[cfg(not(target_os = "zkvm"))]
    pub fn with_groth16_proof(self) -> Self {
        match risc0_zkvm::is_dev_mode() {
            true => Self { selector: FixedBytes::from(Selector::FakeReceipt as u32), ..self },
            false => Self { selector: FixedBytes::from(Selector::Groth16V2_1 as u32), ..self },
        }
    }
}

impl Predicate {
    /// Returns a predicate to match the journal digest. This ensures that the request's
    /// fulfillment will contain a journal with the same digest.
    pub fn digest_match(digest: impl Into<Digest>) -> Self {
        Self {
            predicateType: PredicateType::DigestMatch,
            data: digest.into().as_bytes().to_vec().into(),
        }
    }

    /// Returns a predicate to match the journal prefix. This ensures that the request's
    /// fulfillment will contain a journal with the same prefix.
    pub fn prefix_match(prefix: impl Into<Bytes>) -> Self {
        Self { predicateType: PredicateType::PrefixMatch, data: prefix.into() }
    }
}

impl Callback {
    /// Constant representing a none callback (i.e. no call will be made).
    pub const NONE: Self = Self { addr: Address::ZERO, gasLimit: U96::ZERO };

    /// Sets the address of the callback.
    pub fn with_addr(self, addr: impl Into<Address>) -> Self {
        Self { addr: addr.into(), ..self }
    }

    /// Sets the gas limit of the callback.
    pub fn with_gas_limit(self, gas_limit: u64) -> Self {
        Self { gasLimit: U96::from(gas_limit), ..self }
    }

    /// Returns true if this is a none callback (i.e. no call will be made).
    ///
    /// NOTE: A callback is considered none if the address is zero, regardless of the gas limit.
    pub fn is_none(&self) -> bool {
        self.addr == Address::ZERO
    }

    /// Convert to an option representation, mapping a none callback to `None`.
    pub fn into_option(self) -> Option<Self> {
        self.is_none().not().then_some(self)
    }

    /// Convert to an option representation, mapping a none callback to `None`.
    pub fn as_option(&self) -> Option<&Self> {
        self.is_none().not().then_some(self)
    }

    /// Convert from an option representation, mapping `None` to [Self::NONE].
    pub fn from_option(opt: Option<Self>) -> Self {
        opt.unwrap_or(Self::NONE)
    }
}

impl RequestInput {
    /// Create a new [GuestEnvBuilder] for use in constructing and encoding the guest zkVM environment.
    #[cfg(not(target_os = "zkvm"))]
    pub fn builder() -> GuestEnvBuilder {
        GuestEnvBuilder::new()
    }

    /// Sets the input type to inline and the data to the given bytes.
    ///
    /// See [GuestEnvBuilder] for more details on how to write input data.
    ///
    /// # Example
    ///
    /// ```
    /// use boundless_market::contracts::RequestInput;
    ///
    /// let input_vec = RequestInput::builder().write(&[0x41, 0x41, 0x41, 0x41])?.build_vec()?;
    /// let input = RequestInput::inline(input_vec);
    /// # anyhow::Ok(())
    /// ```
    pub fn inline(data: impl Into<Bytes>) -> Self {
        Self { inputType: RequestInputType::Inline, data: data.into() }
    }

    /// Sets the input type to URL and the data to the given URL.
    pub fn url(url: impl Into<String>) -> Self {
        Self { inputType: RequestInputType::Url, data: url.into().as_bytes().to_vec().into() }
    }
}

impl From<Url> for RequestInput {
    /// Create a URL input from the given URL.
    fn from(value: Url) -> Self {
        Self::url(value)
    }
}

impl Offer {
    /// Sets the offer minimum price.
    pub fn with_min_price(self, min_price: U256) -> Self {
        Self { minPrice: min_price, ..self }
    }

    /// Sets the offer maximum price.
    pub fn with_max_price(self, max_price: U256) -> Self {
        Self { maxPrice: max_price, ..self }
    }

    /// Sets the offer lock-in stake.
    pub fn with_lock_stake(self, lock_stake: U256) -> Self {
        Self { lockStake: lock_stake, ..self }
    }

    /// Sets the offer bidding start time, in seconds since the UNIX epoch.
    pub fn with_bidding_start(self, bidding_start: u64) -> Self {
        Self { biddingStart: bidding_start, ..self }
    }

    /// Sets the offer timeout as seconds from the bidding start before expiring.
    pub fn with_timeout(self, timeout: u32) -> Self {
        Self { timeout, ..self }
    }

    /// Sets the offer lock-in timeout as seconds from the bidding start before expiring.
    pub fn with_lock_timeout(self, lock_timeout: u32) -> Self {
        Self { lockTimeout: lock_timeout, ..self }
    }

    /// Sets the duration (in seconds) during which the auction price increases linearly
    /// from the minimum to the maximum price. After this period, the price remains at maximum.
    pub fn with_ramp_up_period(self, ramp_up_period: u32) -> Self {
        Self { rampUpPeriod: ramp_up_period, ..self }
    }

    /// Sets the offer minimum price based on the desired price per million cycles.
    pub fn with_min_price_per_mcycle(self, mcycle_price: U256, mcycle: u64) -> Self {
        let min_price = mcycle_price * U256::from(mcycle);
        Self { minPrice: min_price, ..self }
    }

    /// Sets the offer maximum price based on the desired price per million cycles.
    pub fn with_max_price_per_mcycle(self, mcycle_price: U256, mcycle: u64) -> Self {
        let max_price = mcycle_price * U256::from(mcycle);
        Self { maxPrice: max_price, ..self }
    }

    /// Sets the offer lock-in stake based on the desired price per million cycles.
    pub fn with_lock_stake_per_mcycle(self, mcycle_price: U256, mcycle: u64) -> Self {
        let lock_stake = mcycle_price * U256::from(mcycle);
        Self { lockStake: lock_stake, ..self }
    }
}

use sha2::{Digest as _, Sha256};
#[cfg(not(target_os = "zkvm"))]
use IBoundlessMarket::IBoundlessMarketErrors;
#[cfg(not(target_os = "zkvm"))]
use IRiscZeroSetVerifier::IRiscZeroSetVerifierErrors;

impl Predicate {
    /// Evaluates the predicate against the given journal.
    #[inline]
    pub fn eval(&self, journal: impl AsRef<[u8]>) -> bool {
        match self.predicateType {
            PredicateType::DigestMatch => self.data.as_ref() == Sha256::digest(journal).as_slice(),
            PredicateType::PrefixMatch => journal.as_ref().starts_with(&self.data),
            PredicateType::__Invalid => panic!("invalid PredicateType"),
        }
    }
}

#[cfg(not(target_os = "zkvm"))]
/// The Boundless market module.
pub mod boundless_market;
#[cfg(not(target_os = "zkvm"))]
/// The Hit Points module.
pub mod hit_points;

#[cfg(not(target_os = "zkvm"))]
#[derive(Error, Debug)]
/// Errors that can occur when interacting with the contracts.
pub enum TxnErr {
    /// Error from the SetVerifier contract.
    #[error("SetVerifier error: {0:?}")]
    SetVerifierErr(IRiscZeroSetVerifierErrors),

    /// Error from the BoundlessMarket contract.
    #[error("BoundlessMarket Err: {0:?}")]
    BoundlessMarketErr(IBoundlessMarket::IBoundlessMarketErrors),

    /// Error from the HitPoints contract.
    #[error("HitPoints Err: {0:?}")]
    HitPointsErr(IHitPoints::IHitPointsErrors),

    /// Error from the ERC20 contract.
    #[error("IERC20 Err: {0:?}")]
    ERC20Err(token::IERC20::IERC20Errors),

    /// Missing data while decoding the error response from the contract.
    #[error("decoding err, missing data, code: {0} msg: {1}")]
    MissingData(i64, String),

    /// Error decoding the error response from the contract.
    #[error("decoding err: bytes decoding")]
    BytesDecode,

    /// Error from the contract.
    #[error("contract error: {0}")]
    ContractErr(ContractErr),

    /// ABI decoder error.
    #[error("abi decoder error: {0} - {1}")]
    DecodeErr(DecoderErr, Bytes),
}

// TODO: Deduplicate the code from the following two conversion methods.
#[cfg(not(target_os = "zkvm"))]
impl From<ContractErr> for TxnErr {
    fn from(err: ContractErr) -> Self {
        match &err {
            ContractErr::TransportError(TransportError::ErrorResp(ts_err)) => {
                let Some(data) = &ts_err.data else {
                    return TxnErr::MissingData(ts_err.code, ts_err.message.to_string());
                };

                let data = data.get().trim_matches('"');

                let Ok(data) = Bytes::from_str(data) else {
                    return Self::BytesDecode;
                };

                // Trial deocde the error with each possible contract ABI.
                if let Ok(decoded_error) = IBoundlessMarketErrors::abi_decode(&data) {
                    Self::BoundlessMarketErr(decoded_error)
                } else if let Ok(decoded_error) = IHitPointsErrors::abi_decode(&data) {
                    Self::HitPointsErr(decoded_error)
                } else if let Ok(decoded_error) = IRiscZeroSetVerifierErrors::abi_decode(&data) {
                    Self::SetVerifierErr(decoded_error)
                } else if let Ok(decoded_error) = IERC20Errors::abi_decode(&data) {
                    Self::ERC20Err(decoded_error)
                } else {
                    Self::ContractErr(err)
                }
            }
            _ => Self::ContractErr(err),
        }
    }
}

#[cfg(not(target_os = "zkvm"))]
fn decode_contract_err<T: SolInterface>(err: ContractErr) -> Result<T, TxnErr> {
    match err {
        ContractErr::TransportError(TransportError::ErrorResp(ts_err)) => {
            let Some(data) = ts_err.data else {
                return Err(TxnErr::MissingData(ts_err.code, ts_err.message.to_string()));
            };

            let data = data.get().trim_matches('"');

            let Ok(data) = Bytes::from_str(data) else {
                return Err(TxnErr::BytesDecode);
            };

            let decoded_error = match T::abi_decode(&data) {
                Ok(res) => res,
                Err(err) => {
                    return Err(TxnErr::DecodeErr(err, data));
                }
            };

            Ok(decoded_error)
        }
        _ => Err(TxnErr::ContractErr(err)),
    }
}

#[cfg(not(target_os = "zkvm"))]
impl IHitPointsErrors {
    pub(crate) fn decode_error(err: ContractErr) -> TxnErr {
        match decode_contract_err(err) {
            Ok(res) => TxnErr::HitPointsErr(res),
            Err(decode_err) => decode_err,
        }
    }
}

#[cfg(not(target_os = "zkvm"))]
/// The EIP-712 domain separator for the Boundless Market contract.
pub fn eip712_domain(addr: Address, chain_id: u64) -> EIP712DomainSaltless {
    EIP712DomainSaltless {
        name: "IBoundlessMarket".into(),
        version: "1".into(),
        chain_id,
        verifying_contract: addr,
    }
}

/// Constant to specify when no selector is specified.
pub const UNSPECIFIED_SELECTOR: FixedBytes<4> = FixedBytes::<4>([0; 4]);

#[cfg(feature = "test-utils")]
#[allow(missing_docs)]
pub mod bytecode;

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::signers::local::PrivateKeySigner;

    async fn create_order(
        signer: &impl Signer,
        signer_addr: Address,
        order_id: u32,
        contract_addr: Address,
        chain_id: u64,
    ) -> (ProofRequest, [u8; 65]) {
        let request_id = RequestId::u256(signer_addr, order_id);

        let req = ProofRequest {
            id: request_id,
            requirements: Requirements::new(
                Digest::ZERO,
                Predicate { predicateType: PredicateType::PrefixMatch, data: Default::default() },
            ),
            imageUrl: "https://dev.null".to_string(),
            input: RequestInput::builder().build_inline().unwrap(),
            offer: Offer {
                minPrice: U256::from(0),
                maxPrice: U256::from(1),
                biddingStart: 0,
                timeout: 1000,
                rampUpPeriod: 1,
                lockTimeout: 1000,
                lockStake: U256::from(0),
            },
        };

        let client_sig = req.sign_request(signer, contract_addr, chain_id).await.unwrap();

        (req, client_sig.as_bytes())
    }

    #[tokio::test]
    async fn validate_sig() {
        let signer: PrivateKeySigner =
            "6f142508b4eea641e33cb2a0161221105086a84584c74245ca463a49effea30b".parse().unwrap();
        let order_id: u32 = 1;
        let contract_addr = Address::ZERO;
        let chain_id = 1;
        let signer_addr = signer.address();

        let (req, client_sig) =
            create_order(&signer, signer_addr, order_id, contract_addr, chain_id).await;

        req.verify_signature(&Bytes::from(client_sig), contract_addr, chain_id).unwrap();
    }

    #[tokio::test]
    #[should_panic(expected = "SignatureError")]
    async fn invalid_sig() {
        let signer: PrivateKeySigner =
            "6f142508b4eea641e33cb2a0161221105086a84584c74245ca463a49effea30b".parse().unwrap();
        let order_id: u32 = 1;
        let contract_addr = Address::ZERO;
        let chain_id = 1;
        let signer_addr = signer.address();

        let (req, mut client_sig) =
            create_order(&signer, signer_addr, order_id, contract_addr, chain_id).await;

        client_sig[0] = 1;
        req.verify_signature(&Bytes::from(client_sig), contract_addr, chain_id).unwrap();
    }

    #[tokio::test]
    async fn test_request_id() {
        // Test case 1: Regular signature
        let raw_id1 =
            U256::from_str("3130239009558586413752262552917257075388277690201777635428").unwrap();
        let request_id1 = RequestId::from_lossy(raw_id1);

        let client1 = request_id1.addr;
        let idx1 = request_id1.index;
        let is_smart_contract1 = request_id1.smart_contract_signed;

        assert_eq!(
            client1,
            Address::from_str("0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496").unwrap()
        );
        assert_eq!(idx1, 100);
        assert!(!is_smart_contract1);

        // Test case 2: Smart contract signature
        let raw_id2 =
            U256::from_str("9407340744945267177588051976124923491490633134665812148266").unwrap();
        let request_id2 = RequestId::from_lossy(raw_id2);

        let client2 = request_id2.addr;
        let idx2 = request_id2.index;
        let is_smart_contract2 = request_id2.smart_contract_signed;

        assert_eq!(
            client2,
            Address::from_str("0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496").unwrap()
        );
        assert_eq!(idx2, 42);
        assert!(is_smart_contract2);

        // Test conversion back to U256
        let request_id1_u256: U256 = request_id1.into();
        let request_id2_u256: U256 = request_id2.into();
        assert_eq!(request_id1_u256, raw_id1);
        assert_eq!(request_id2_u256, raw_id2);
    }
}
