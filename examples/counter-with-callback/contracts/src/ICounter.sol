// Copyright (c) 2025 RISC Zero, Inc.
//
// All rights reserved.

pragma solidity ^0.8.13;

import {IBoundlessMarketCallback} from "boundless-market/IBoundlessMarketCallback.sol";

// @notice ICounter is a simple interface that inherits from IBoundlessMarketCallback
// to handle proofs delivered by the Boundless Market.
interface ICounter is IBoundlessMarketCallback {
    // @notice Emitted when the counter is incremented.
    event CounterCallbackCalled(bytes32 imageId, bytes journal, bytes seal);

    // @notice AlreadyVerified is an error that is thrown when a proof has already been verified.
    error AlreadyVerified();

    // @notice Retrieves the current count.
    // @return The current count.
    function count() external view returns (uint256);
}
