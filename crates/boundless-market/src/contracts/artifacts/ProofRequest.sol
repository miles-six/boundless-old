// Copyright (c) 2025 RISC Zero, Inc.
//
// All rights reserved.
pragma solidity ^0.8.20;

import {RequestId} from "./RequestId.sol";
import {Account} from "./Account.sol";
import {Callback, CallbackLibrary} from "./Callback.sol";
import {Offer, OfferLibrary} from "./Offer.sol";
import {Predicate, PredicateLibrary} from "./Predicate.sol";
import {Input, InputType, InputLibrary} from "./Input.sol";
import {Requirements, RequirementsLibrary} from "./Requirements.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IBoundlessMarket} from "../IBoundlessMarket.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

using ProofRequestLibrary for ProofRequest global;

/// @title Proof Request Struct and Library
/// @notice Represents a proof request with its associated data and functions.
struct ProofRequest {
    /// @notice Unique ID for this request, constructed from the client address and a 32-bit index.
    RequestId id;
    /// @notice Requirements of the delivered proof.
    /// @dev Specifies the program that must be run, constrains the value of the journal, and specifies a callback required to be called when the proof is delivered.
    Requirements requirements;
    /// @notice A public URI where the program (i.e. image) can be downloaded.
    /// @dev This URI will be accessed by provers that are evaluating whether to bid on the request.
    string imageUrl;
    /// @notice Input to be provided to the zkVM guest execution.
    Input input;
    /// @notice Offer specifying how much the client is willing to pay to have this request fulfilled.
    Offer offer;
}

library ProofRequestLibrary {
    /// @dev Id is uint256 as for user defined types, the eip712 type hash uses the underlying type.
    string constant PROOF_REQUEST_TYPE =
        "ProofRequest(uint256 id,Requirements requirements,string imageUrl,Input input,Offer offer)";

    bytes32 constant PROOF_REQUEST_TYPEHASH = keccak256(
        abi.encodePacked(
            PROOF_REQUEST_TYPE,
            CallbackLibrary.CALLBACK_TYPE,
            InputLibrary.INPUT_TYPE,
            OfferLibrary.OFFER_TYPE,
            PredicateLibrary.PREDICATE_TYPE,
            RequirementsLibrary.REQUIREMENTS_TYPE
        )
    );

    /// @notice Computes the EIP-712 digest for the given proof request.
    /// @param request The proof request to compute the digest for.
    /// @return The EIP-712 digest of the proof request.
    function eip712Digest(ProofRequest memory request) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PROOF_REQUEST_TYPEHASH,
                request.id,
                request.requirements.eip712Digest(),
                keccak256(bytes(request.imageUrl)),
                request.input.eip712Digest(),
                request.offer.eip712Digest()
            )
        );
    }

    /// @notice Validates the proof request with the intention for it to be priced.
    /// Does not check if the request is already locked or fulfilled, but does check
    /// if it has expired.
    /// @param request The proof request to validate.
    /// @return lockDeadline The deadline for when a lock expires for the request.
    /// @return deadline The deadline for the request as a whole.
    function validate(ProofRequest calldata request) internal pure returns (uint64 lockDeadline, uint64 deadline) {
        return request.offer.validate();
    }
}
