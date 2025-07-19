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

use std::borrow::Cow;

use alloy::primitives::{address, Address};
use clap::Args;
use derive_builder::Builder;

pub use alloy_chains::NamedChain;

/// Configuration for a deployment of the Boundless Market.
// NOTE: See https://github.com/clap-rs/clap/issues/5092#issuecomment-1703980717 about clap usage.
#[non_exhaustive]
#[derive(Clone, Debug, Builder, Args)]
#[group(requires = "boundless_market_address", requires = "set_verifier_address")]
pub struct Deployment {
    /// EIP-155 chain ID of the network.
    #[clap(long, env)]
    #[builder(setter(into, strip_option), default)]
    pub chain_id: Option<u64>,

    /// Address of the [BoundlessMarket] contract.
    ///
    /// [BoundlessMarket]: crate::contracts::IBoundlessMarket
    #[clap(long, env, required = false, long_help = "Address of the BoundlessMarket contract")]
    #[builder(setter(into))]
    pub boundless_market_address: Address,

    /// Address of the [RiscZeroVerifierRouter] contract.
    ///
    /// The verifier router implements [IRiscZeroVerifier]. Each network has a canonical router,
    /// that is deployed by the core team. You can additionally deploy and manage your own verifier
    /// instead. See the [Boundless docs for more details].
    ///
    /// [RiscZeroVerifierRouter]: https://github.com/risc0/risc0-ethereum/blob/main/contracts/src/RiscZeroVerifierRouter.sol
    /// [IRiscZeroVerifier]: https://github.com/risc0/risc0-ethereum/blob/main/contracts/src/IRiscZeroVerifier.sol
    /// [Boundless docs for more details]: https://docs.beboundless.xyz/developers/smart-contracts/verifier-contracts
    #[clap(
        long,
        env = "VERIFIER_ADDRESS",
        long_help = "Address of the RiscZeroVerifierRouter contract"
    )]
    #[builder(setter(strip_option), default)]
    pub verifier_router_address: Option<Address>,

    /// Address of the [RiscZeroSetVerifier] contract.
    ///
    /// [RiscZeroSetVerifier]: https://github.com/risc0/risc0-ethereum/blob/main/contracts/src/RiscZeroSetVerifier.sol
    #[clap(long, env, required = false, long_help = "Address of the RiscZeroSetVerifier contract")]
    #[builder(setter(into))]
    pub set_verifier_address: Address,

    /// Address of the stake token contract. The staking token is an ERC-20.
    #[clap(long, env)]
    #[builder(setter(strip_option), default)]
    pub stake_token_address: Option<Address>,

    /// URL for the offchain [order stream service].
    ///
    /// [order stream service]: crate::order_stream_client
    #[clap(long, env, long_help = "URL for the offchain order stream service")]
    #[builder(setter(into, strip_option), default)]
    pub order_stream_url: Option<Cow<'static, str>>,
}

impl Deployment {
    /// Create a new [DeploymentBuilder].
    pub fn builder() -> DeploymentBuilder {
        Default::default()
    }

    /// Lookup the [Deployment] for a named chain.
    pub const fn from_chain(chain: NamedChain) -> Option<Deployment> {
        match chain {
            NamedChain::Sepolia => Some(SEPOLIA),
            NamedChain::Base => Some(BASE),
            NamedChain::BaseSepolia => Some(BASE_SEPOLIA),
            _ => None,
        }
    }

    /// Lookup the [Deployment] by chain ID.
    pub fn from_chain_id(chain_id: impl Into<u64>) -> Option<Deployment> {
        let chain = NamedChain::try_from(chain_id.into()).ok()?;
        Self::from_chain(chain)
    }
}

// TODO(#654): Ensure consistency with deployment.toml and with docs
/// [Deployment] for the Sepolia testnet.
pub const SEPOLIA: Deployment = Deployment {
    chain_id: Some(NamedChain::Sepolia as u64),
    boundless_market_address: address!("0x13337C76fE2d1750246B68781ecEe164643b98Ec"),
    verifier_router_address: Some(address!("0x925d8331ddc0a1F0d96E68CF073DFE1d92b69187")),
    set_verifier_address: address!("0x7aAB646f23D1392d4522CFaB0b7FB5eaf6821d64"),
    stake_token_address: Some(address!("0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238")),
    order_stream_url: Some(Cow::Borrowed("https://eth-sepolia.beboundless.xyz")),
};

/// [Deployment] for the Base mainnet.
pub const BASE: Deployment = Deployment {
    chain_id: Some(NamedChain::Base as u64),
    boundless_market_address: address!("0x26759dbB201aFbA361Bec78E097Aa3942B0b4AB8"),
    verifier_router_address: Some(address!("0x0b144e07a0826182b6b59788c34b32bfa86fb711")),
    set_verifier_address: address!("0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760"),
    stake_token_address: Some(address!("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")),
    order_stream_url: Some(Cow::Borrowed("https://base-mainnet.beboundless.xyz")),
};

/// [Deployment] for the Base Sepolia.
pub const BASE_SEPOLIA: Deployment = Deployment {
    chain_id: Some(NamedChain::BaseSepolia as u64),
    boundless_market_address: address!("0x6B7ABa661041164b8dB98E30AE1454d2e9D5f14b"),
    verifier_router_address: Some(address!("0x0b144e07a0826182b6b59788c34b32bfa86fb711")),
    set_verifier_address: address!("0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760"),
    stake_token_address: Some(address!("0x036CbD53842c5426634e7929541eC2318f3dCF7e")),
    order_stream_url: Some(Cow::Borrowed("https://base-sepolia.beboundless.xyz")),
};
