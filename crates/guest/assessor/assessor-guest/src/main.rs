// Copyright (c) 2025 RISC Zero, Inc.
//
// All rights reserved.

#![no_main]
#![no_std]

extern crate alloc;

use alloc::vec::Vec;
use alloy_primitives::{Address, U256};
use alloy_sol_types::{SolStruct, SolValue};
use boundless_assessor::{process_tree, AssessorInput};
use boundless_market::contracts::{
    AssessorCallback, AssessorCommitment, AssessorJournal, AssessorSelector, RequestId,
    UNSPECIFIED_SELECTOR,
};
use risc0_zkvm::{
    guest::env,
    sha::{Digest, Digestible},
};

risc0_zkvm::guest::entry!(main);

fn main() {
    let bytes = env::read_frame();
    let input = AssessorInput::decode(&bytes).expect("failed to deserialize input");

    // Ensure that the number of fills is within the bounds of the supported max set size.
    // This limitation is imposed by the Selector struct, which uses a u16 to store the index of the
    // fill in the set.
    if input.fills.len() >= u16::MAX.into() {
        panic!("too many fills: {}", input.fills.len());
    }

    // list of ReceiptClaim digests used as leaves in the aggregation set
    let mut leaves: Vec<Digest> = Vec::with_capacity(input.fills.len());
    // sparse list of callbacks to be recorded in the journal
    let mut callbacks: Vec<AssessorCallback> = Vec::<AssessorCallback>::new();
    // list of optional Selectors specified as part of the requests requirements
    let mut selectors = Vec::<AssessorSelector>::new();

    let eip_domain_separator = input.domain.alloy_struct();
    // For each fill we
    // - verify the request's signature
    // - evaluate the request's requirements
    // - verify the integrity of its claim
    // - record the callback if it exists
    // - record the selector if it is present
    // We additionally collect the request and claim digests.
    for (index, fill) in input.fills.iter().enumerate() {
        // Attempt to decode the request ID. If this fails, there may be flags that are not handled
        // by this guest. This check is not strictly needed, but reduces the chance of accidentally
        // failing to enforce a constraint.
        RequestId::try_from(fill.request.id).unwrap();

        // ECDSA signatures are always checked here.
        // Smart contract signatures (via EIP-1271) are checked on-chain either when a request is locked,
        // or when an unlocked request is priced and fulfilled
        let request_digest: [u8; 32] = if fill.request.is_smart_contract_signed() {
            fill.request.eip712_signing_hash(&eip_domain_separator).into()
        } else {
            fill.verify_signature(&eip_domain_separator).expect("signature does not verify")
        };
        fill.evaluate_requirements().expect("requirements not met");
        env::verify_integrity(&fill.receipt_claim()).expect("claim integrity check failed");
        let claim_digest = fill.receipt_claim().digest();
        let commit = AssessorCommitment {
            index: U256::from(index),
            id: fill.request.id,
            requestDigest: request_digest.into(),
            claimDigest: <[u8; 32]>::from(claim_digest).into(),
        }
        .eip712_hash_struct();
        leaves.push(Digest::from_bytes(*commit));
        if fill.request.requirements.callback.addr != Address::ZERO {
            callbacks.push(AssessorCallback {
                index: index.try_into().expect("callback index overflow"),
                addr: fill.request.requirements.callback.addr,
                gasLimit: fill.request.requirements.callback.gasLimit,
            });
        }
        if fill.request.requirements.selector != UNSPECIFIED_SELECTOR {
            selectors.push(AssessorSelector {
                index: index.try_into().expect("selector index overflow"),
                value: fill.request.requirements.selector,
            });
        }
    }

    // compute the merkle root of the commitments
    let root = process_tree(leaves);

    let journal = AssessorJournal {
        callbacks,
        selectors,
        root: <[u8; 32]>::from(root).into(),
        prover: input.prover_address,
    };

    env::commit_slice(&journal.abi_encode());
}
