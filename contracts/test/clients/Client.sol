// Copyright (c) 2025 RISC Zero, Inc.
//
// All rights reserved.
pragma solidity ^0.8.13;

import {IBoundlessMarket} from "../../src/IBoundlessMarket.sol";
import {HitPoints} from "../../src/HitPoints.sol";
import {BaseClient} from "./BaseClient.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {TestUtils} from "../TestUtils.sol";
import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {ProofRequest} from "../../src/types/ProofRequest.sol";
import {RequestIdLibrary} from "../../src/types/RequestId.sol";
import {Input, InputType} from "../../src/types/Input.sol";
import {Offer} from "../../src/types/Offer.sol";
import {LockRequest} from "../../src/types/LockRequest.sol";

Vm constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

/// @dev Client is a wrapper around an EOA with logic for signing proof requests and submitting them to the market.
/// It also inherits functions for tracking balances and stake from BaseClient.
contract Client is BaseClient {
    Vm.Wallet public wallet;

    constructor(Vm.Wallet memory _wallet) BaseClient() {
        wallet = _wallet;
    }

    function addr() public view override returns (address) {
        return wallet.addr;
    }

    function sign(ProofRequest calldata req) public override returns (bytes memory) {
        bytes32 structDigest =
            MessageHashUtils.toTypedDataHash(boundlessMarket.eip712DomainSeparator(), req.eip712Digest());
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(wallet, structDigest);
        return abi.encodePacked(r, s, v);
    }

    function signLockRequest(LockRequest calldata req) public override returns (bytes memory) {
        bytes32 structDigest =
            MessageHashUtils.toTypedDataHash(boundlessMarket.eip712DomainSeparator(), req.eip712Digest());
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(wallet, structDigest);
        return abi.encodePacked(r, s, v);
    }

    function request(uint32 idx) public view override returns (ProofRequest memory) {
        return ProofRequest({
            id: RequestIdLibrary.from(addr(), idx),
            requirements: defaultRequirements(),
            imageUrl: "https://image.dev.null",
            input: Input({inputType: InputType.Url, data: bytes("https://input.dev.null")}),
            offer: defaultOffer()
        });
    }

    function request(uint32 idx, Offer memory offer) public view override returns (ProofRequest memory) {
        return ProofRequest({
            id: RequestIdLibrary.from(addr(), idx),
            requirements: defaultRequirements(),
            imageUrl: "https://image.dev.null",
            input: Input({inputType: InputType.Url, data: bytes("https://input.dev.null")}),
            offer: offer
        });
    }

    function signPermit(address spender, uint256 value, uint256 deadline)
        public
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return VM.sign(
            wallet,
            MessageHashUtils.toTypedDataHash(
                stakeToken.DOMAIN_SEPARATOR(),
                TestUtils.getPermitHash(
                    wallet.addr, spender, value, ERC20Permit(address(stakeToken)).nonces(wallet.addr), deadline
                )
            )
        );
    }
}
