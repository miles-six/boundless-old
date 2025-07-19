// Copyright (c) 2025 RISC Zero, Inc.
//
// All rights reserved.

pragma solidity ^0.8.20;

import {console} from "forge-std/console.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {
    IRiscZeroVerifier,
    ReceiptClaim,
    Receipt as RiscZeroReceipt,
    ReceiptClaimLib,
    VerificationFailed
} from "risc0/IRiscZeroVerifier.sol";
import {TestReceipt} from "risc0/../test/TestReceipt.sol";
import {RiscZeroMockVerifier} from "risc0/test/RiscZeroMockVerifier.sol";
import {TestUtils} from "./TestUtils.sol";
import {Client} from "./clients/Client.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {UnsafeUpgrades, Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options as UpgradeOptions} from "openzeppelin-foundry-upgrades/Options.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HitPoints} from "../src/HitPoints.sol";

import {BoundlessMarket} from "../src/BoundlessMarket.sol";
import {Callback} from "../src/types/Callback.sol";
import {RequestId, RequestIdLibrary} from "../src/types/RequestId.sol";
import {AssessorJournal} from "../src/types/AssessorJournal.sol";
import {AssessorCallback} from "../src/types/AssessorCallback.sol";
import {BoundlessMarketLib} from "../src/libraries/BoundlessMarketLib.sol";
import {MerkleProofish} from "../src/libraries/MerkleProofish.sol";
import {RequestId} from "../src/types/RequestId.sol";
import {ProofRequest} from "../src/types/ProofRequest.sol";
import {LockRequest} from "../src/types/LockRequest.sol";
import {Account} from "../src/types/Account.sol";
import {RequestLock} from "../src/types/RequestLock.sol";
import {Fulfillment} from "../src/types/Fulfillment.sol";
import {AssessorReceipt} from "../src/types/AssessorReceipt.sol";
import {AssessorJournal} from "../src/types/AssessorJournal.sol";
import {Offer} from "../src/types/Offer.sol";
import {Requirements} from "../src/types/Requirements.sol";
import {Predicate, PredicateType} from "../src/types/Predicate.sol";
import {Input, InputType} from "../src/types/Input.sol";
import {IBoundlessMarket} from "../src/IBoundlessMarket.sol";

import {ProofRequestLibrary} from "../src/types/ProofRequest.sol";
import {RiscZeroSetVerifier} from "risc0/RiscZeroSetVerifier.sol";
import {Fulfillment} from "../src/types/Fulfillment.sol";
import {MockCallback} from "./MockCallback.sol";
import {Selector} from "../src/types/Selector.sol";

import {MockSmartContractWallet} from "./clients/MockSmartContractWallet.sol";
import {SmartContractClient} from "./clients/SmartContractClient.sol";
import {BaseClient} from "./clients/BaseClient.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

Vm constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

bytes32 constant APP_IMAGE_ID = 0x0000000000000000000000000000000000000000000000000000000000000001;
bytes32 constant APP_IMAGE_ID_2 = 0x0000000000000000000000000000000000000000000000000000000000000002;
bytes32 constant SET_BUILDER_IMAGE_ID = 0x0000000000000000000000000000000000000000000000000000000000000002;
bytes32 constant ASSESSOR_IMAGE_ID = 0x0000000000000000000000000000000000000000000000000000000000000003;

bytes constant APP_JOURNAL = bytes("GUEST JOURNAL");
bytes constant APP_JOURNAL_2 = bytes("GUEST JOURNAL 2");

contract BoundlessMarketTest is Test {
    using ReceiptClaimLib for ReceiptClaim;
    using BoundlessMarketLib for Requirements;
    using BoundlessMarketLib for ProofRequest;
    using BoundlessMarketLib for Offer;
    using TestUtils for RiscZeroSetVerifier;
    using TestUtils for Selector[];
    using TestUtils for AssessorCallback[];
    using SafeCast for uint256;
    using SafeCast for int256;

    RiscZeroMockVerifier internal verifier;
    BoundlessMarket internal boundlessMarket;

    address internal boundlessMarketSource;
    address internal proxy;
    RiscZeroSetVerifier internal setVerifier;
    HitPoints internal stakeToken;
    mapping(uint256 => Client) internal clients;
    mapping(uint256 => Client) internal provers;
    mapping(uint256 => SmartContractClient) internal smartContractClients;
    Client internal testProver;
    address internal testProverAddress;
    uint256 initialBalance;
    int256 internal stakeBalanceSnapshot;
    int256 internal stakeTreasuryBalanceSnapshot;

    uint256 constant DEFAULT_BALANCE = 1000 ether;
    uint256 constant EXPECTED_DEFAULT_MAX_GAS_FOR_VERIFY = 50000;
    uint256 constant EXPECTED_SLASH_BURN_BPS = 7500;

    ReceiptClaim internal APP_CLAIM = ReceiptClaimLib.ok(APP_IMAGE_ID, sha256(APP_JOURNAL));

    Vm.Wallet internal OWNER_WALLET = vm.createWallet("OWNER");

    MockCallback internal mockCallback;
    MockCallback internal mockHighGasCallback;

    function setUp() public {
        vm.deal(OWNER_WALLET.addr, DEFAULT_BALANCE);

        vm.startPrank(OWNER_WALLET.addr);

        // Deploy the implementation contracts
        verifier = new RiscZeroMockVerifier(bytes4(0));
        setVerifier = new RiscZeroSetVerifier(verifier, SET_BUILDER_IMAGE_ID, "https://set-builder.dev.null");
        stakeToken = new HitPoints(OWNER_WALLET.addr);

        // Deploy the UUPS proxy with the implementation
        boundlessMarketSource = address(new BoundlessMarket(setVerifier, ASSESSOR_IMAGE_ID, address(stakeToken)));
        proxy = UnsafeUpgrades.deployUUPSProxy(
            boundlessMarketSource,
            abi.encodeCall(BoundlessMarket.initialize, (OWNER_WALLET.addr, "https://assessor.dev.null"))
        );
        boundlessMarket = BoundlessMarket(proxy);

        // Initialize MockCallbacks
        mockCallback = new MockCallback(setVerifier, address(boundlessMarket), APP_IMAGE_ID, 10_000);
        mockHighGasCallback = new MockCallback(setVerifier, address(boundlessMarket), APP_IMAGE_ID, 250_000);

        stakeToken.grantMinterRole(OWNER_WALLET.addr);
        stakeToken.grantAuthorizedTransferRole(proxy);
        vm.stopPrank();

        testProver = getProver(1);
        testProverAddress = testProver.addr();
        for (uint256 i = 0; i < 5; i++) {
            getClient(i);
            getProver(i);
            getSmartContractClient(i);
        }

        initialBalance = address(boundlessMarket).balance;

        stakeBalanceSnapshot = type(int256).max;
        stakeTreasuryBalanceSnapshot = type(int256).max;

        // Verify that OWNER is the actual owner
        assertEq(boundlessMarket.owner(), OWNER_WALLET.addr, "OWNER address is not the contract owner after deployment");
    }

    function expectedSlashBurnAmount(uint256 amount) internal pure returns (uint96) {
        return uint96((uint256(amount) * EXPECTED_SLASH_BURN_BPS) / 10000);
    }

    function expectedSlashTransferAmount(uint256 amount) internal pure returns (uint96) {
        return uint96((uint256(amount) * (10000 - EXPECTED_SLASH_BURN_BPS)) / 10000);
    }

    function expectMarketBalanceUnchanged() internal view {
        uint256 finalBalance = address(boundlessMarket).balance;
        console.log("Initial balance:", initialBalance);
        console.log("Final balance:", finalBalance);
        require(finalBalance == initialBalance, "Market balance changed during the test");
    }

    function snapshotMarketStakeBalance() public {
        stakeBalanceSnapshot = stakeToken.balanceOf(address(boundlessMarket)).toInt256();
    }

    function expectMarketStakeBalanceChange(int256 change) public view {
        require(stakeBalanceSnapshot != type(int256).max, "market stake balance snapshot is not set");
        int256 newBalance = stakeToken.balanceOf(address(boundlessMarket)).toInt256();
        console.log("Market stake balance at block %d: %d", block.number, newBalance.toUint256());
        int256 expectedBalance = stakeBalanceSnapshot + change;
        require(expectedBalance >= 0, "expected market stake balance cannot be less than 0");
        console.log("Market expected stake balance at block %d: %d", block.number, expectedBalance.toUint256());
        require(expectedBalance == newBalance, "market stake balance is not equal to expected value");
    }

    function snapshotMarketStakeTreasuryBalance() public {
        stakeTreasuryBalanceSnapshot = boundlessMarket.balanceOfStake(address(boundlessMarket)).toInt256();
    }

    function expectMarketStakeTreasuryBalanceChange(int256 change) public view {
        require(stakeTreasuryBalanceSnapshot != type(int256).max, "market stake treasury balance snapshot is not set");
        int256 newBalance = boundlessMarket.balanceOfStake(address(boundlessMarket)).toInt256();
        console.log("Market stake treasury balance at block %d: %d", block.number, newBalance.toUint256());
        int256 expectedBalance = stakeTreasuryBalanceSnapshot + change;
        require(expectedBalance >= 0, "expected market treasury stake balance cannot be less than 0");
        console.log("Market expected stake treasury balance at block %d: %d", block.number, expectedBalance.toUint256());
        require(expectedBalance == newBalance, "market stake treasury balance is not equal to expected value");
    }

    function expectRequestFulfilled(RequestId requestId) internal view {
        require(boundlessMarket.requestIsFulfilled(requestId), "Request should be fulfilled");
        require(!boundlessMarket.requestIsSlashed(requestId), "Request should not be slashed");
    }

    function expectRequestFulfilledAndSlashed(RequestId requestId) internal view {
        require(boundlessMarket.requestIsFulfilled(requestId), "Request should be fulfilled");
        require(boundlessMarket.requestIsSlashed(requestId), "Request should be slashed");
    }

    function expectRequestNotFulfilled(RequestId requestId) internal view {
        require(!boundlessMarket.requestIsFulfilled(requestId), "Request should not be fulfilled");
    }

    function expectRequestSlashed(RequestId requestId) internal view {
        require(boundlessMarket.requestIsSlashed(requestId), "Request should be slashed");
    }

    function expectRequestNotSlashed(RequestId requestId) internal view {
        require(!boundlessMarket.requestIsSlashed(requestId), "Request should be slashed");
    }

    // Creates a client account with the given index, gives it some Ether,
    // gives it some Stake Token, and deposits both into the market.
    function getClient(uint256 index) internal returns (Client) {
        if (address(clients[index]) != address(0)) {
            return clients[index];
        }
        Client client = createClientContract(string.concat("CLIENT_", vm.toString(index)));
        fundClient(client);
        clients[index] = client;
        return client;
    }

    // Creates a client account with the given index, gives it some Ether,
    // gives it some Stake Token, and deposits both into the market.
    function getSmartContractClient(uint256 index) internal returns (SmartContractClient) {
        if (address(smartContractClients[index]) != address(0)) {
            return smartContractClients[index];
        }
        SmartContractClient client = createSmartContractClientContract(string.concat("SC_CLIENT_", vm.toString(index)));
        fundSmartContractClient(client);
        smartContractClients[index] = client;
        return client;
    }

    // Creates a prover account with the given index, gives it some Ether,
    // gives it some Stake Token, and deposits both into the market.
    function getProver(uint256 index) internal returns (Client) {
        if (address(provers[index]) != address(0)) {
            return provers[index];
        }
        Client prover = createClientContract(string.concat("PROVER_", vm.toString(index)));
        fundClient(prover);
        provers[index] = prover;
        return prover;
    }

    function fundClient(Client client) internal {
        address clientAddress = client.addr();
        // Deal the client from Ether and deposit it in the market.
        vm.deal(clientAddress, DEFAULT_BALANCE);
        vm.prank(clientAddress);
        boundlessMarket.deposit{value: DEFAULT_BALANCE}();

        // Snapshot their initial ETH balance.
        client.snapshotBalance();

        // Mint some stake tokens.
        vm.prank(OWNER_WALLET.addr);
        stakeToken.mint(clientAddress, DEFAULT_BALANCE);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = client.signPermit(proxy, DEFAULT_BALANCE, deadline);
        vm.prank(clientAddress);
        boundlessMarket.depositStakeWithPermit(DEFAULT_BALANCE, deadline, v, r, s);

        // Snapshot their initial stake balance.
        client.snapshotStakeBalance();
    }

    function fundSmartContractClient(SmartContractClient client) internal {
        address walletAddress = client.addr();
        address signerAddress = client.signerAddr();

        // Deal the SCW some Ether and deposit it in the market.
        vm.deal(walletAddress, DEFAULT_BALANCE);
        vm.prank(signerAddress);
        client.execute(
            address(boundlessMarket),
            abi.encodeWithSelector(IBoundlessMarket.deposit.selector, DEFAULT_BALANCE),
            DEFAULT_BALANCE
        );

        // Snapshot their initial ETH balance.
        client.snapshotBalance();

        // Mint some stake tokens.
        vm.prank(OWNER_WALLET.addr);
        stakeToken.mint(walletAddress, DEFAULT_BALANCE);

        vm.prank(signerAddress);
        client.execute(
            address(stakeToken), abi.encodeWithSelector(IERC20.approve.selector, boundlessMarket, DEFAULT_BALANCE)
        );

        vm.prank(signerAddress);
        client.execute(
            address(boundlessMarket), abi.encodeWithSelector(IBoundlessMarket.depositStake.selector, DEFAULT_BALANCE)
        );

        // check balances
        assertEq(boundlessMarket.balanceOf(walletAddress), DEFAULT_BALANCE);
        assertEq(boundlessMarket.balanceOfStake(walletAddress), DEFAULT_BALANCE);

        // Snapshot their initial stake balance.
        client.snapshotStakeBalance();
    }

    // Create a client, using a trick to set the address equal to the wallet address.
    function createClientContract(string memory identifier) internal returns (Client) {
        Vm.Wallet memory wallet = vm.createWallet(identifier);
        Client client = new Client(wallet);
        client.initialize(identifier, boundlessMarket, stakeToken);
        return client;
    }

    function createSmartContractClientContract(string memory identifier) internal returns (SmartContractClient) {
        Vm.Wallet memory signer = vm.createWallet(string.concat(identifier, "_SIGNER"));
        SmartContractClient client = new SmartContractClient(signer);
        client.initialize(identifier, boundlessMarket, stakeToken);
        return client;
    }

    function submitRoot(bytes32 root) internal {
        boundlessMarket.submitRoot(
            address(setVerifier),
            root,
            verifier.mockProve(
                SET_BUILDER_IMAGE_ID, sha256(abi.encodePacked(SET_BUILDER_IMAGE_ID, uint256(1 << 255), root))
            ).seal
        );
    }

    function createFillAndSubmitRoot(ProofRequest memory request, bytes memory journal, address prover)
        internal
        returns (Fulfillment memory, AssessorReceipt memory)
    {
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes[] memory journals = new bytes[](1);
        journals[0] = journal;
        (Fulfillment[] memory fills, AssessorReceipt memory assessorReceipt) =
            createFillsAndSubmitRoot(requests, journals, prover);
        return (fills[0], assessorReceipt);
    }

    function createFillsAndSubmitRoot(ProofRequest[] memory requests, bytes[] memory journals, address prover)
        internal
        returns (Fulfillment[] memory fills, AssessorReceipt memory assessorReceipt)
    {
        bytes32 root;
        (fills, assessorReceipt, root) = createFills(requests, journals, prover);
        // submit the root to the set verifier
        submitRoot(root);
        return (fills, assessorReceipt);
    }

    function createFills(ProofRequest[] memory requests, bytes[] memory journals, address prover)
        internal
        view
        returns (Fulfillment[] memory fills, AssessorReceipt memory assessorReceipt, bytes32 root)
    {
        // initialize the fullfillments; one for each request;
        // the seal is filled in later, by calling fillInclusionProof
        fills = new Fulfillment[](requests.length);
        Selector[] memory selectors = new Selector[](0);
        AssessorCallback[] memory callbacks = new AssessorCallback[](0);
        for (uint8 i = 0; i < requests.length; i++) {
            Fulfillment memory fill = Fulfillment({
                id: requests[i].id,
                requestDigest: MessageHashUtils.toTypedDataHash(
                    boundlessMarket.eip712DomainSeparator(), requests[i].eip712Digest()
                ),
                imageId: requests[i].requirements.imageId,
                journal: journals[i],
                seal: bytes("")
            });
            fills[i] = fill;
            if (requests[i].requirements.selector != bytes4(0)) {
                selectors = selectors.addSelector(i, requests[i].requirements.selector);
            }
            if (requests[i].requirements.callback.addr != address(0)) {
                callbacks = callbacks.addCallback(
                    AssessorCallback({
                        index: i,
                        gasLimit: requests[i].requirements.callback.gasLimit,
                        addr: requests[i].requirements.callback.addr
                    })
                );
            }
        }

        // compute the assessor claim
        ReceiptClaim memory assessorClaim =
            TestUtils.mockAssessor(fills, ASSESSOR_IMAGE_ID, selectors, callbacks, prover);
        // compute the batchRoot of the batch Merkle Tree (without the assessor)
        (bytes32 batchRoot, bytes32[][] memory tree) = TestUtils.mockSetBuilder(fills);

        bytes32 assessorLeaf = TestUtils.hashLeaf(assessorClaim.digest());
        root = MerkleProofish._hashPair(batchRoot, assessorLeaf);

        // compute all the inclusion proofs for the fullfillments
        TestUtils.fillInclusionProofs(setVerifier, fills, assessorLeaf, tree);
        // compute the assessor fill
        assessorReceipt = AssessorReceipt({
            seal: TestUtils.mockAssessorSeal(setVerifier, batchRoot),
            selectors: selectors,
            callbacks: callbacks,
            prover: prover
        });

        return (fills, assessorReceipt, root);
    }

    function newBatch(uint256 batchSize) internal returns (ProofRequest[] memory requests, bytes[] memory journals) {
        requests = new ProofRequest[](batchSize);
        journals = new bytes[](batchSize);
        for (uint256 j = 0; j < 5; j++) {
            getClient(j);
        }
        for (uint256 i = 0; i < batchSize; i++) {
            Client client = clients[i % 5];
            ProofRequest memory request = client.request(uint32(i / 5));
            bytes memory clientSignature = client.sign(request);
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(request, clientSignature);
            requests[i] = request;
            journals[i] = APP_JOURNAL;
        }
    }

    function newBatchWithSelector(uint256 batchSize, bytes4 selector)
        internal
        returns (ProofRequest[] memory requests, bytes[] memory journals)
    {
        requests = new ProofRequest[](batchSize);
        journals = new bytes[](batchSize);
        for (uint256 j = 0; j < 5; j++) {
            getClient(j);
        }
        for (uint256 i = 0; i < batchSize; i++) {
            Client client = clients[i % 5];
            ProofRequest memory request = client.request(uint32(i / 5));
            request.requirements.selector = selector;
            bytes memory clientSignature = client.sign(request);
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(request, clientSignature);
            requests[i] = request;
            journals[i] = APP_JOURNAL;
        }
    }

    function newBatchWithCallback(uint256 batchSize)
        internal
        returns (ProofRequest[] memory requests, bytes[] memory journals)
    {
        requests = new ProofRequest[](batchSize);
        journals = new bytes[](batchSize);
        for (uint256 j = 0; j < 5; j++) {
            getClient(j);
        }
        for (uint256 i = 0; i < batchSize; i++) {
            Client client = clients[i % 5];
            ProofRequest memory request = client.request(uint32(i / 5));
            request.requirements.callback.addr = address(mockCallback);
            request.requirements.callback.gasLimit = 500_000;
            bytes memory clientSignature = client.sign(request);
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(request, clientSignature);
            requests[i] = request;
            journals[i] = APP_JOURNAL;
        }
    }
}

contract BoundlessMarketBasicTest is BoundlessMarketTest {
    using ReceiptClaimLib for ReceiptClaim;
    using BoundlessMarketLib for Offer;
    using BoundlessMarketLib for ProofRequest;
    using SafeCast for uint256;

    function _stringEquals(string memory a, string memory b) private pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }

    function testBytecodeSize() public {
        vm.snapshotValue("bytecode size proxy", address(proxy).code.length);
        vm.snapshotValue("bytecode size implementation", boundlessMarketSource.code.length);
    }

    function testDeposit() public {
        vm.deal(testProverAddress, 1 ether);
        // Deposit funds into the market
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.Deposit(testProverAddress, 1 ether);
        vm.prank(testProverAddress);
        boundlessMarket.deposit{value: 1 ether}();
        testProver.expectBalanceChange(1 ether);
    }

    function testDeposits() public {
        address newUser = address(uint160(3));
        vm.deal(newUser, 2 ether);

        // Deposit funds into the market
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.Deposit(newUser, 1 ether);
        vm.prank(newUser);
        boundlessMarket.deposit{value: 1 ether}();
        vm.snapshotGasLastCall("deposit: first ever deposit");

        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.Deposit(newUser, 1 ether);
        vm.prank(newUser);
        boundlessMarket.deposit{value: 1 ether}();
        vm.snapshotGasLastCall("deposit: second deposit");
    }

    function testWithdraw() public {
        // Deposit funds into the market
        vm.deal(testProverAddress, 1 ether);
        vm.prank(testProverAddress);
        boundlessMarket.deposit{value: 1 ether}();

        // Withdraw funds from the market
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.Withdrawal(testProverAddress, 1 ether);
        vm.prank(testProverAddress);
        boundlessMarket.withdraw(1 ether);
        expectMarketBalanceUnchanged();

        // Attempt to withdraw extra funds from the market.
        vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.InsufficientBalance.selector, testProverAddress));
        vm.prank(testProverAddress);
        boundlessMarket.withdraw(DEFAULT_BALANCE + 1);
        expectMarketBalanceUnchanged();
    }

    function testWithdrawFromTreasury() public {
        // Deposit funds into the market
        vm.deal(address(boundlessMarket), 1 ether);
        vm.prank(address(boundlessMarket));
        boundlessMarket.deposit{value: 1 ether}();

        // Attempt to withdraw funds from the treasury from an unauthorized account.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, testProverAddress));
        vm.prank(testProverAddress);
        boundlessMarket.withdrawFromTreasury(1 ether);

        uint256 initialBalance = OWNER_WALLET.addr.balance;
        // Withdraw funds from the treasury
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.Withdrawal(address(boundlessMarket), 1 ether);
        vm.prank(OWNER_WALLET.addr);
        boundlessMarket.withdrawFromTreasury(1 ether);
        assert(boundlessMarket.balanceOf(address(boundlessMarket)) == 0);
        assert(OWNER_WALLET.addr.balance == 1 ether + initialBalance);
    }

    function testWithdrawFromStakeTreasury() public {
        testSlashLockedRequestFullyExpired();

        // Attempt to withdraw funds from the stake treasury from an unauthorized account.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, testProverAddress));
        vm.prank(testProverAddress);
        boundlessMarket.withdrawFromStakeTreasury(0.25 ether);

        // Withdraw funds from the stake treasury
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.StakeWithdrawal(address(boundlessMarket), 0.25 ether);
        vm.prank(OWNER_WALLET.addr);
        boundlessMarket.withdrawFromStakeTreasury(0.25 ether);
        assert(boundlessMarket.balanceOfStake(address(boundlessMarket)) == 0);
        assert(stakeToken.balanceOf(OWNER_WALLET.addr) == 0.25 ether);
    }

    function testWithdrawals() public {
        // Deposit funds into the market
        vm.deal(testProverAddress, 3 ether);
        vm.prank(testProverAddress);
        boundlessMarket.deposit{value: 3 ether}();

        // Withdraw funds from the market
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.Withdrawal(testProverAddress, 1 ether);
        vm.prank(testProverAddress);
        boundlessMarket.withdraw(1 ether);
        vm.snapshotGasLastCall("withdraw: 1 ether");

        uint256 balance = boundlessMarket.balanceOf(testProverAddress);
        vm.prank(testProverAddress);
        boundlessMarket.withdraw(balance);
        vm.snapshotGasLastCall("withdraw: full balance");
        assertEq(boundlessMarket.balanceOf(testProverAddress), 0);

        // Attempt to withdraw extra funds from the market.
        vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.InsufficientBalance.selector, testProverAddress));
        vm.prank(testProverAddress);
        boundlessMarket.withdraw(DEFAULT_BALANCE + 1);
    }

    function testStakeDeposit() public {
        // Mint some tokens
        vm.prank(OWNER_WALLET.addr);
        stakeToken.mint(testProverAddress, 2);

        // Approve the market to spend the testProver's stakeToken
        vm.prank(testProverAddress);
        ERC20(address(stakeToken)).approve(address(boundlessMarket), 2);
        vm.snapshotGasLastCall("ERC20 approve: required for depositStake");

        // Deposit stake into the market
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.StakeDeposit(testProverAddress, 1);
        vm.prank(testProverAddress);
        boundlessMarket.depositStake(1);
        vm.snapshotGasLastCall("depositStake: 1 HP (tops up market account)");
        testProver.expectStakeBalanceChange(1);

        // Deposit stake into the market
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.StakeDeposit(testProverAddress, 1);
        vm.prank(testProverAddress);
        boundlessMarket.depositStake(1);
        vm.snapshotGasLastCall("depositStake: full (drains testProver account)");
        testProver.expectStakeBalanceChange(2);
    }

    function testStakeDepositWithPermit() public {
        // Mint some tokens
        vm.prank(OWNER_WALLET.addr);
        stakeToken.mint(testProverAddress, 2);

        // Approve the market to spend the testProver's stakeToken
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = testProver.signPermit(address(boundlessMarket), 1, deadline);

        // Deposit stake into the market
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.StakeDeposit(testProverAddress, 1);
        vm.prank(testProverAddress);
        boundlessMarket.depositStakeWithPermit(1, deadline, v, r, s);
        vm.snapshotGasLastCall("depositStakeWithPermit: 1 HP (tops up market account)");
        testProver.expectStakeBalanceChange(1);

        // Approve the market to spend the testProver's stakeToken
        (v, r, s) = testProver.signPermit(address(boundlessMarket), 1, deadline);

        // Deposit stake into the market
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.StakeDeposit(testProverAddress, 1);
        vm.prank(testProverAddress);
        boundlessMarket.depositStakeWithPermit(1, deadline, v, r, s);
        vm.snapshotGasLastCall("depositStakeWithPermit: full (drains testProver account)");
        testProver.expectStakeBalanceChange(2);
    }

    function testStakeWithdraw() public {
        // Withdraw stake from the market
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.StakeWithdrawal(testProverAddress, 1);
        vm.prank(testProverAddress);
        boundlessMarket.withdrawStake(1);
        vm.snapshotGasLastCall("withdrawStake: 1 HP balance");
        testProver.expectStakeBalanceChange(-1);
        assertEq(stakeToken.balanceOf(testProverAddress), 1, "TestProver should have 1 hitPoint after withdrawing");

        // Withdraw full stake from the market
        uint256 remainingBalance = boundlessMarket.balanceOfStake(testProverAddress);
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.StakeWithdrawal(testProverAddress, remainingBalance);
        vm.prank(testProverAddress);
        boundlessMarket.withdrawStake(remainingBalance);
        vm.snapshotGasLastCall("withdrawStake: full balance");
        testProver.expectStakeBalanceChange(-int256(DEFAULT_BALANCE));
        assertEq(
            stakeToken.balanceOf(testProverAddress),
            DEFAULT_BALANCE,
            "TestProver should have DEFAULT_BALANCE hitPoint after withdrawing"
        );

        // Attempt to withdraw extra funds from the market.
        vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.InsufficientBalance.selector, testProverAddress));
        vm.prank(testProverAddress);
        boundlessMarket.withdrawStake(1);
    }

    function testSubmitRequest() public {
        Client client = getClient(1);
        ProofRequest memory request = client.request(1);
        bytes memory clientSignature = client.sign(request);

        // Submit the request with no funds
        // Expect the event to be emitted
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.RequestSubmitted(request.id, request, clientSignature);
        boundlessMarket.submitRequest(request, clientSignature);
        vm.snapshotGasLastCall("submitRequest: without ether");

        // Submit the request with funds
        // Expect the event to be emitted
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.Deposit(client.addr(), uint256(request.offer.maxPrice));
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.RequestSubmitted(request.id, request, clientSignature);
        vm.deal(client.addr(), request.offer.maxPrice);
        address clientAddress = client.addr();
        vm.prank(clientAddress);
        boundlessMarket.submitRequest{value: request.offer.maxPrice}(request, clientSignature);
        vm.snapshotGasLastCall("submitRequest: with maxPrice ether");
    }

    function _testLockRequest(bool withSig) private returns (Client, ProofRequest memory) {
        return _testLockRequest(withSig, "");
    }

    function _testLockRequest(bool withSig, string memory snapshot) private returns (Client, ProofRequest memory) {
        Client client = getClient(1);
        ProofRequest memory request = client.request(1);
        bytes memory clientSignature = client.sign(request);
        bytes memory proverSignature = testProver.signLockRequest(LockRequest({request: request}));

        // Expect the event to be emitted
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.RequestLocked(request.id, testProverAddress, request, clientSignature);
        if (withSig) {
            boundlessMarket.lockRequestWithSignature(request, clientSignature, proverSignature);
        } else {
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(request, clientSignature);
        }

        if (!_stringEquals(snapshot, "")) {
            vm.snapshotGasLastCall(snapshot);
        }

        // Ensure the balances are correct
        client.expectBalanceChange(-1 ether);
        testProver.expectStakeBalanceChange(-1 ether);

        // Verify the lock request
        assertTrue(boundlessMarket.requestIsLocked(request.id), "Request should be locked-in");

        expectMarketBalanceUnchanged();

        return (client, request);
    }

    function testLockRequest() public returns (Client, ProofRequest memory) {
        return _testLockRequest(false, "lockinRequest: base case");
    }

    function testLockRequestWithSignature() public returns (Client, ProofRequest memory) {
        return _testLockRequest(true, "lockinRequest: with prover signature");
    }

    function _testLockRequestAlreadyLocked(bool withSig) private {
        (Client client, ProofRequest memory request) = _testLockRequest(withSig);
        bytes memory clientSignature = client.sign(request);
        bytes memory proverSignature = testProver.signLockRequest(LockRequest({request: request}));

        // Attempt to lock the request again
        vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.RequestIsLocked.selector, request.id));
        if (withSig) {
            boundlessMarket.lockRequestWithSignature(request, clientSignature, proverSignature);
        } else {
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(request, clientSignature);
        }

        expectMarketBalanceUnchanged();
    }

    function testLockRequestAlreadyLocked() public {
        return _testLockRequestAlreadyLocked(true);
    }

    function testLockRequestWithSignatureAlreadyLocked() public {
        return _testLockRequestAlreadyLocked(false);
    }

    function _testLockRequestBadClientSignature(bool withSig) private {
        Client clientA = getClient(1);
        Client clientB = getClient(2);
        ProofRequest memory request1 = clientA.request(1);
        ProofRequest memory request2 = clientA.request(2);
        bytes memory proverSignature = testProver.signLockRequest(LockRequest({request: request1}));

        // case: request signed by a different client
        bytes memory badClientSignature = clientB.sign(request1);
        vm.expectRevert(IBoundlessMarket.InvalidSignature.selector);
        if (withSig) {
            boundlessMarket.lockRequestWithSignature(request1, badClientSignature, proverSignature);
        } else {
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(request1, badClientSignature);
        }

        // case: client signed a different request
        badClientSignature = clientA.sign(request2);
        vm.expectRevert(IBoundlessMarket.InvalidSignature.selector);
        if (withSig) {
            boundlessMarket.lockRequestWithSignature(request1, badClientSignature, proverSignature);
        } else {
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(request1, badClientSignature);
        }

        clientA.expectBalanceChange(0 ether);
        clientB.expectBalanceChange(0 ether);
        testProver.expectBalanceChange(0 ether);
        expectMarketBalanceUnchanged();
    }

    function testLockRequestBadClientSignature() public {
        return _testLockRequestBadClientSignature(true);
    }

    function testLockRequestWithSignatureBadClientSignature() public {
        return _testLockRequestBadClientSignature(false);
    }

    function testLockRequestWithSignatureProverSignatureIncorrectRequest() public {
        Client client = getClient(1);
        ProofRequest memory request = client.request(1);
        bytes memory clientSignature = client.sign(request);
        // Prover signs the incorrect request.
        bytes memory badProverSignature = testProver.signLockRequest(LockRequest({request: client.request(2)}));

        // NOTE: Error is "InsufficientBalance" because we will recover _some_ address.
        // It should be random and never correspond to a real account.
        // TODO: This address will need to change anytime we change the ProofRequest struct or
        // the way it is hashed for signatures. Find a good way to avoid this.
        vm.expectRevert(
            abi.encodeWithSelector(
                IBoundlessMarket.InsufficientBalance.selector, address(0x72C929E83beDC7370921131d8BF11B50d656aCE5)
            )
        );
        boundlessMarket.lockRequestWithSignature(request, clientSignature, badProverSignature);

        client.expectBalanceChange(0 ether);
        testProver.expectBalanceChange(0 ether);
        expectMarketBalanceUnchanged();
    }

    function testLockRequestWithSignatureProverSignatureIncorrectDomain() public {
        Client client = getClient(1);
        ProofRequest memory request = client.request(1);
        bytes memory clientSignature = client.sign(request);
        // Prover signs ProofRequest struct rather than LockRequest struct.
        // NOTE: This was how the contract worked in a previous version. This is included as a regression test.
        bytes memory badProverSignature = testProver.sign(request);

        // NOTE: Error is "InsufficientBalance" because we will recover _some_ address.
        // It should be random and never correspond to a real account.
        // TODO: This address will need to change anytime we change the ProofRequest struct or
        // the way it is hashed for signatures. Find a good way to avoid this.
        vm.expectRevert(
            abi.encodeWithSelector(
                IBoundlessMarket.InsufficientBalance.selector, address(0x73F8229890F1F0120B8786926fb44F0656b9416D)
            )
        );
        boundlessMarket.lockRequestWithSignature(request, clientSignature, badProverSignature);

        client.expectBalanceChange(0 ether);
        testProver.expectBalanceChange(0 ether);
        expectMarketBalanceUnchanged();
    }

    function _testLockRequestNotEnoughFunds(bool withSig) private {
        Client client = getClient(1);
        ProofRequest memory request = client.request(1);
        bytes memory clientSignature = client.sign(request);
        bytes memory proverSignature = testProver.signLockRequest(LockRequest({request: request}));

        address clientAddress = client.addr();
        vm.prank(clientAddress);
        boundlessMarket.withdraw(DEFAULT_BALANCE);

        // case: client does not have enough funds to cover for the lock request
        // should revert with "InsufficientBalance(address requester)"
        vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.InsufficientBalance.selector, client.addr()));
        if (withSig) {
            boundlessMarket.lockRequestWithSignature(request, clientSignature, proverSignature);
        } else {
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(request, clientSignature);
        }

        vm.prank(clientAddress);
        boundlessMarket.deposit{value: DEFAULT_BALANCE}();

        vm.prank(testProverAddress);
        boundlessMarket.withdrawStake(DEFAULT_BALANCE);
        // case: prover does not have enough funds to cover for the lock request stake
        // should revert with "InsufficientBalance(address requester)"
        vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.InsufficientBalance.selector, testProverAddress));
        if (withSig) {
            boundlessMarket.lockRequestWithSignature(request, clientSignature, proverSignature);
        } else {
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(request, clientSignature);
        }
    }

    function testLockRequestNotEnoughFunds() public {
        return _testLockRequestNotEnoughFunds(true);
    }

    function testLockRequestWithSignatureNotEnoughFunds() public {
        return _testLockRequestNotEnoughFunds(false);
    }

    function _testLockRequestExpired(bool withSig) private {
        Client client = getClient(1);
        ProofRequest memory request = client.request(1);
        bytes memory clientSignature = client.sign(request);
        bytes memory proverSignature = testProver.signLockRequest(LockRequest({request: request}));

        vm.warp(request.offer.deadline() + 1);

        // Attempt to lock the request after it has expired
        // should revert with "RequestIsExpired({requestId: request.id, deadline: deadline})"
        vm.expectRevert(
            abi.encodeWithSelector(
                IBoundlessMarket.RequestLockIsExpired.selector, request.id, request.offer.lockDeadline()
            )
        );
        if (withSig) {
            boundlessMarket.lockRequestWithSignature(request, clientSignature, proverSignature);
        } else {
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(request, clientSignature);
        }

        expectMarketBalanceUnchanged();
    }

    function testLockRequestExpired() public {
        return _testLockRequestExpired(true);
    }

    function testLockRequestWithSignatureExpired() public {
        return _testLockRequestExpired(false);
    }

    function _testLockRequestLockExpired(bool withSig) private {
        Client client = getClient(1);
        ProofRequest memory request = client.request(1);
        bytes memory clientSignature = client.sign(request);
        bytes memory proverSignature = testProver.signLockRequest(LockRequest({request: request}));

        vm.warp(request.offer.lockDeadline() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBoundlessMarket.RequestLockIsExpired.selector, request.id, request.offer.lockDeadline()
            )
        );
        if (withSig) {
            boundlessMarket.lockRequestWithSignature(request, clientSignature, proverSignature);
        } else {
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(request, clientSignature);
        }

        expectMarketBalanceUnchanged();
    }

    function testLockRequestLockExpired() public {
        return _testLockRequestLockExpired(true);
    }

    function testLockRequestWithSignatureLockExpired() public {
        return _testLockRequestLockExpired(false);
    }

    function _testLockRequestInvalidRequest1(bool withSig) private {
        Offer memory offer = Offer({
            minPrice: 2 ether,
            maxPrice: 1 ether,
            biddingStart: uint64(block.timestamp),
            rampUpPeriod: uint32(0),
            lockTimeout: uint32(1),
            timeout: uint32(1),
            lockStake: 10 ether
        });

        Client client = getClient(1);
        ProofRequest memory request = client.request(1, offer);
        bytes memory clientSignature = client.sign(request);
        bytes memory proverSignature = testProver.signLockRequest(LockRequest({request: request}));

        // Attempt to lock a request with maxPrice smaller than minPrice
        vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.InvalidRequest.selector));
        if (withSig) {
            boundlessMarket.lockRequestWithSignature(request, clientSignature, proverSignature);
        } else {
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(request, clientSignature);
        }

        expectMarketBalanceUnchanged();
    }

    function testLockRequestInvalidRequest1() public {
        return _testLockRequestInvalidRequest1(true);
    }

    function testLockRequestWithSignatureInvalidRequest1() public {
        return _testLockRequestInvalidRequest1(false);
    }

    function _testLockRequestInvalidRequest2(bool withSig) private {
        Offer memory offer = Offer({
            minPrice: 1 ether,
            maxPrice: 1 ether,
            biddingStart: uint64(block.timestamp),
            rampUpPeriod: uint32(2),
            lockTimeout: uint32(1),
            timeout: uint32(1),
            lockStake: 10 ether
        });

        Client client = getClient(1);
        ProofRequest memory request = client.request(1, offer);
        bytes memory clientSignature = client.sign(request);
        bytes memory proverSignature = testProver.signLockRequest(LockRequest({request: request}));

        // Attempt to lock a request with rampUpPeriod greater than timeout
        vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.InvalidRequest.selector));
        if (withSig) {
            boundlessMarket.lockRequestWithSignature(request, clientSignature, proverSignature);
        } else {
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(request, clientSignature);
        }

        expectMarketBalanceUnchanged();
    }

    function testLockRequestInvalidRequest2() public {
        return _testLockRequestInvalidRequest2(true);
    }

    function testLockRequestWithSignatureInvalidRequest2() public {
        return _testLockRequestInvalidRequest2(false);
    }

    enum LockRequestMethod {
        LockRequest,
        LockRequestWithSig,
        None
    }

    function _testFulfillSameBlock(uint32 requestIdx, LockRequestMethod lockinMethod)
        private
        returns (Client, ProofRequest memory)
    {
        return _testFulfillSameBlock(requestIdx, lockinMethod, "");
    }

    // Base for fulfillment tests with different methods for lock, including none. All paths should yield the same result.
    function _testFulfillSameBlock(uint32 requestIdx, LockRequestMethod lockinMethod, string memory snapshot)
        private
        returns (Client, ProofRequest memory)
    {
        Client client = getClient(1);
        ProofRequest memory request = client.request(requestIdx);
        bytes memory clientSignature = client.sign(request);

        client.snapshotBalance();
        testProver.snapshotBalance();

        if (lockinMethod == LockRequestMethod.LockRequest) {
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(request, clientSignature);
        } else if (lockinMethod == LockRequestMethod.LockRequestWithSig) {
            boundlessMarket.lockRequestWithSignature(
                request, clientSignature, testProver.signLockRequest(LockRequest({request: request}))
            );
        }

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);

        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        if (lockinMethod == LockRequestMethod.None) {
            // Annoying boilerplate for creating singleton lists.
            ProofRequest[] memory requests = new ProofRequest[](1);
            requests[0] = request;
            bytes[] memory clientSignatures = new bytes[](1);
            clientSignatures[0] = client.sign(request);

            vm.expectEmit(true, true, true, true);
            emit IBoundlessMarket.RequestFulfilled(request.id, testProverAddress, fill);
            vm.expectEmit(true, true, true, false);
            emit IBoundlessMarket.ProofDelivered(request.id, testProverAddress, fill);
            boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);
            if (!_stringEquals(snapshot, "")) {
                vm.snapshotGasLastCall(snapshot);
            }
        } else {
            vm.expectEmit(true, true, true, true);
            emit IBoundlessMarket.RequestFulfilled(request.id, testProverAddress, fill);
            vm.expectEmit(true, true, true, false);
            emit IBoundlessMarket.ProofDelivered(request.id, testProverAddress, fill);
            boundlessMarket.fulfill(fills, assessorReceipt);
            if (!_stringEquals(snapshot, "")) {
                vm.snapshotGasLastCall(snapshot);
            }
        }

        // Check that the proof was submitted
        expectRequestFulfilled(fill.id);

        client.expectBalanceChange(-1 ether);
        testProver.expectBalanceChange(1 ether);
        expectMarketBalanceUnchanged();

        return (client, request);
    }

    // Base for fulfillmentAndWithdraw tests with different methods for lock, including none. All paths should yield the same result.
    function _testFulfillAndWithdrawSameBlock(uint32 requestIdx, LockRequestMethod lockinMethod, string memory snapshot)
        private
        returns (Client, ProofRequest memory)
    {
        Client client = getClient(1);
        ProofRequest memory request = client.request(requestIdx);
        bytes memory clientSignature = client.sign(request);

        client.snapshotBalance();
        testProver.snapshotBalance();

        if (lockinMethod == LockRequestMethod.LockRequest) {
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(request, clientSignature);
        } else if (lockinMethod == LockRequestMethod.LockRequestWithSig) {
            boundlessMarket.lockRequestWithSignature(
                request, clientSignature, testProver.signLockRequest(LockRequest({request: request}))
            );
        }

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        uint256 initialBalance = boundlessMarket.balanceOf(testProverAddress) + testProverAddress.balance;

        if (lockinMethod == LockRequestMethod.None) {
            // Annoying boilerplate for creating singleton lists.
            ProofRequest[] memory requests = new ProofRequest[](1);
            requests[0] = request;
            bytes[] memory clientSignatures = new bytes[](1);
            clientSignatures[0] = client.sign(request);

            vm.expectEmit(true, true, true, true);
            emit IBoundlessMarket.RequestFulfilled(request.id, testProverAddress, fill);
            vm.expectEmit(true, true, true, false);
            emit IBoundlessMarket.ProofDelivered(request.id, testProverAddress, fill);
            boundlessMarket.priceAndFulfillAndWithdraw(requests, clientSignatures, fills, assessorReceipt);
            if (!_stringEquals(snapshot, "")) {
                vm.snapshotGasLastCall(snapshot);
            }
        } else {
            vm.expectEmit(true, true, true, true);
            emit IBoundlessMarket.RequestFulfilled(request.id, testProverAddress, fill);
            vm.expectEmit(true, true, true, false);
            emit IBoundlessMarket.ProofDelivered(request.id, testProverAddress, fill);
            boundlessMarket.fulfillAndWithdraw(fills, assessorReceipt);
            if (!_stringEquals(snapshot, "")) {
                vm.snapshotGasLastCall(snapshot);
            }
        }

        // Check that the proof was submitted
        expectRequestFulfilled(fill.id);

        client.expectBalanceChange(-1 ether);
        assert(boundlessMarket.balanceOf(testProverAddress) == 0);
        assert(testProverAddress.balance == initialBalance + 1 ether);

        return (client, request);
    }

    // Base for submitRoot and fulfillment tests with different methods for lock, including none. All paths should yield the same result.
    function _testSubmitRootAndFulfillSameBlock(
        uint32 requestIdx,
        LockRequestMethod lockinMethod,
        string memory snapshot
    ) private returns (Client, ProofRequest memory) {
        Client client = getClient(1);
        ProofRequest memory request = client.request(requestIdx);
        bytes memory clientSignature = client.sign(request);

        client.snapshotBalance();
        testProver.snapshotBalance();

        if (lockinMethod == LockRequestMethod.LockRequest) {
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(request, clientSignature);
        } else if (lockinMethod == LockRequestMethod.LockRequestWithSig) {
            boundlessMarket.lockRequestWithSignature(
                request, clientSignature, testProver.signLockRequest(LockRequest({request: request}))
            );
        }

        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes[] memory journals = new bytes[](1);
        journals[0] = APP_JOURNAL;

        (Fulfillment[] memory fills, AssessorReceipt memory assessorReceipt, bytes32 root) =
            createFills(requests, journals, testProverAddress);

        bytes memory seal = verifier.mockProve(
            SET_BUILDER_IMAGE_ID, sha256(abi.encodePacked(SET_BUILDER_IMAGE_ID, uint256(1 << 255), root))
        ).seal;

        if (lockinMethod == LockRequestMethod.None) {
            // Annoying boilerplate for creating singleton lists.
            bytes[] memory clientSignatures = new bytes[](1);
            clientSignatures[0] = client.sign(request);

            vm.expectEmit(true, true, true, true);
            emit IBoundlessMarket.RequestFulfilled(request.id, testProverAddress, fills[0]);
            vm.expectEmit(true, true, true, false);
            emit IBoundlessMarket.ProofDelivered(request.id, testProverAddress, fills[0]);
            boundlessMarket.submitRootAndPriceAndFulfill(
                address(setVerifier), root, seal, requests, clientSignatures, fills, assessorReceipt
            );
            if (!_stringEquals(snapshot, "")) {
                vm.snapshotGasLastCall(snapshot);
            }
        } else {
            vm.expectEmit(true, true, true, true);
            emit IBoundlessMarket.RequestFulfilled(request.id, testProverAddress, fills[0]);
            vm.expectEmit(true, true, true, false);
            emit IBoundlessMarket.ProofDelivered(request.id, testProverAddress, fills[0]);
            boundlessMarket.submitRootAndPriceAndFulfill(
                address(setVerifier), root, seal, new ProofRequest[](0), new bytes[](0), fills, assessorReceipt
            );
            if (!_stringEquals(snapshot, "")) {
                vm.snapshotGasLastCall(snapshot);
            }
        }

        // Check that the proof was submitted
        expectRequestFulfilled(fills[0].id);

        client.expectBalanceChange(-1 ether);
        testProver.expectBalanceChange(1 ether);
        expectMarketBalanceUnchanged();

        return (client, request);
    }

    // Base for submitRootAndFulfillAndWithdraw tests with different methods for lock, including none. All paths should yield the same result.
    function _testSubmitRootAndFulfillAndWithdrawSameBlock(
        uint32 requestIdx,
        LockRequestMethod lockinMethod,
        string memory snapshot
    ) private returns (Client, ProofRequest memory) {
        Client client = getClient(1);
        ProofRequest memory request = client.request(requestIdx);
        bytes memory clientSignature = client.sign(request);

        client.snapshotBalance();
        testProver.snapshotBalance();

        if (lockinMethod == LockRequestMethod.LockRequest) {
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(request, clientSignature);
        } else if (lockinMethod == LockRequestMethod.LockRequestWithSig) {
            boundlessMarket.lockRequestWithSignature(
                request, clientSignature, testProver.signLockRequest(LockRequest({request: request}))
            );
        }

        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes[] memory journals = new bytes[](1);
        journals[0] = APP_JOURNAL;

        (Fulfillment[] memory fills, AssessorReceipt memory assessorReceipt, bytes32 root) =
            createFills(requests, journals, testProverAddress);

        bytes memory seal = verifier.mockProve(
            SET_BUILDER_IMAGE_ID, sha256(abi.encodePacked(SET_BUILDER_IMAGE_ID, uint256(1 << 255), root))
        ).seal;

        uint256 initialBalance = boundlessMarket.balanceOf(testProverAddress) + testProverAddress.balance;

        if (lockinMethod == LockRequestMethod.None) {
            // Annoying boilerplate for creating singleton lists.
            bytes[] memory clientSignatures = new bytes[](1);
            clientSignatures[0] = client.sign(request);

            vm.expectEmit(true, true, true, true);
            emit IBoundlessMarket.RequestFulfilled(request.id, testProverAddress, fills[0]);
            vm.expectEmit(true, true, true, false);
            emit IBoundlessMarket.ProofDelivered(request.id, testProverAddress, fills[0]);
            boundlessMarket.submitRootAndPriceAndFulfillAndWithdraw(
                address(setVerifier), root, seal, requests, clientSignatures, fills, assessorReceipt
            );
            if (!_stringEquals(snapshot, "")) {
                vm.snapshotGasLastCall(snapshot);
            }
        } else {
            vm.expectEmit(true, true, true, true);
            emit IBoundlessMarket.RequestFulfilled(request.id, testProverAddress, fills[0]);
            vm.expectEmit(true, true, true, false);
            emit IBoundlessMarket.ProofDelivered(request.id, testProverAddress, fills[0]);
            boundlessMarket.submitRootAndPriceAndFulfillAndWithdraw(
                address(setVerifier), root, seal, new ProofRequest[](0), new bytes[](0), fills, assessorReceipt
            );
            if (!_stringEquals(snapshot, "")) {
                vm.snapshotGasLastCall(snapshot);
            }
        }

        // Check that the proof was submitted
        expectRequestFulfilled(fills[0].id);

        client.expectBalanceChange(-1 ether);
        assert(boundlessMarket.balanceOf(testProverAddress) == 0);
        assert(testProverAddress.balance == initialBalance + 1 ether);

        return (client, request);
    }

    function testFulfillLockedRequest() public {
        _testFulfillSameBlock(1, LockRequestMethod.LockRequest, "fulfill: a locked request");
    }

    function testFulfillAndWithdrawLockedRequest() public {
        _testFulfillAndWithdrawSameBlock(1, LockRequestMethod.LockRequest, "fulfillAndWithdraw: a locked request");
    }

    function testFulfillLockedRequestWithSig() public {
        _testFulfillSameBlock(
            1, LockRequestMethod.LockRequestWithSig, "fulfill: a locked request (locked via prover signature)"
        );
    }

    function testSubmitRootAndFulfillLockedRequest() public {
        _testSubmitRootAndFulfillSameBlock(1, LockRequestMethod.LockRequest, "submitRootAndFulfill: a locked request");
    }

    function testSubmitRootAndFulfillAndWithdrawLockedRequest() public {
        _testSubmitRootAndFulfillAndWithdrawSameBlock(
            1, LockRequestMethod.LockRequest, "submitRootAndFulfillAndWithdraw: a locked request"
        );
    }

    function testSubmitRootAndFulfillLockedRequestWithSig() public {
        _testSubmitRootAndFulfillSameBlock(
            1,
            LockRequestMethod.LockRequestWithSig,
            "submitRootAndFulfill: a locked request (locked via prover signature)"
        );
    }

    // Check that a single client can create many requests, with the full range of indices, and
    // complete the flow each time.
    function testFulfillLockedRequestRangeOfRequestIdx() public {
        for (uint32 idx = 0; idx < 512; idx++) {
            _testFulfillSameBlock(idx, LockRequestMethod.LockRequest);
        }
        _testFulfillSameBlock(0xdeadbeef, LockRequestMethod.LockRequest);
        _testFulfillSameBlock(0xffffffff, LockRequestMethod.LockRequest);
    }

    function testFulfillLargeJournal() external {
        // Generate a 10kB buffer full of non-zero bytes.
        // 10kB = 320 bytes32 values (10240/32)
        bytes32[] memory buffer32 = new bytes32[](320);
        for (uint256 i = 0; i < buffer32.length; i++) {
            buffer32[i] = bytes32(uint256(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF));
        }
        bytes memory bigJournal = abi.encodePacked(buffer32);

        Client client = getClient(1);
        ProofRequest memory request = client.request(1);
        request.requirements.predicate =
            Predicate({predicateType: PredicateType.DigestMatch, data: abi.encode(sha256(bigJournal))});
        bytes memory clientSignature = client.sign(request);

        client.snapshotBalance();
        testProver.snapshotBalance();

        vm.prank(testProverAddress);
        boundlessMarket.lockRequest(request, clientSignature);

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, bigJournal, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.RequestFulfilled(request.id, testProverAddress, fill);
        vm.expectEmit(true, true, true, false);
        emit IBoundlessMarket.ProofDelivered(request.id, testProverAddress, fill);
        boundlessMarket.fulfill(fills, assessorReceipt);
        vm.snapshotGasLastCall("fulfill: a locked request with 10kB journal");

        // Check that the proof was submitted
        expectRequestFulfilled(fill.id);

        client.expectBalanceChange(-1 ether);
        testProver.expectBalanceChange(1 ether);
        expectMarketBalanceUnchanged();
    }

    // While a request is locked, another prover can fulfill it but will not receive a payment.
    function testFulfillLockedRequestByOtherProverNotRequirePayment()
        public
        returns (Client, Client, ProofRequest memory)
    {
        Client client = getClient(1);
        ProofRequest memory request = client.request(3);

        boundlessMarket.lockRequestWithSignature(
            request, client.sign(request), testProver.signLockRequest(LockRequest({request: request}))
        );

        Client otherProver = getProver(2);
        address otherProverAddress = otherProver.addr();
        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, otherProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.PaymentRequirementsFailed(
            abi.encodeWithSelector(IBoundlessMarket.RequestIsLocked.selector, request.id)
        );
        boundlessMarket.fulfill(fills, assessorReceipt);
        vm.snapshotGasLastCall("fulfill: another prover fulfills without payment");

        expectRequestFulfilled(fill.id);

        // Provers stake is still on the line.
        testProver.expectStakeBalanceChange(-int256(uint256(request.offer.lockStake)));

        // No payment should have been made, as the other prover filled while the request is still locked.
        otherProver.expectBalanceChange(0);
        otherProver.expectStakeBalanceChange(0);

        expectMarketBalanceUnchanged();

        return (client, otherProver, request);
    }

    // If a request was fulfilled and payment was already sent, we don't allow it to be fulfilled again.
    function testFulfillLockedRequestAlreadyFulfilledAndPaid() public {
        _testFulfillAlreadyFulfilled(1, LockRequestMethod.LockRequest);
        _testFulfillAlreadyFulfilled(2, LockRequestMethod.LockRequestWithSig);
    }

    // This is the only case where fulfill can be called twice successfully.
    // In some cases, a request can be fulfilled without payment being sent. This test starts with
    // one of those cases and checks that the prover can submit fulfillment again to get payment.
    function testFulfillLockedRequestAlreadyFulfilledByOtherProver() public {
        (, Client otherProver, ProofRequest memory request) = testFulfillLockedRequestByOtherProverNotRequirePayment();
        testProver.snapshotBalance();
        testProver.snapshotStakeBalance();
        otherProver.snapshotBalance();
        otherProver.snapshotStakeBalance();

        expectRequestFulfilled(request.id);

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;
        boundlessMarket.fulfill(fills, assessorReceipt);
        vm.snapshotGasLastCall(
            "fulfill: fulfilled by the locked prover for payment (request already fulfilled by another prover)"
        );

        expectRequestFulfilled(request.id);

        // Prover should now have received back their stake plus payment for the request.
        testProver.expectBalanceChange(1 ether);
        testProver.expectStakeBalanceChange(1 ether);

        // No payment should have been made to the other prover that filled while the request was locked.
        otherProver.expectBalanceChange(0);
        otherProver.expectStakeBalanceChange(0);

        expectMarketBalanceUnchanged();
    }

    function testFulfillLockedRequestProverAddressNotMatchAssessorReceipt() public {
        Client client = getClient(1);

        ProofRequest memory request = client.request(3);

        boundlessMarket.lockRequestWithSignature(
            request, client.sign(request), testProver.signLockRequest(LockRequest({request: request}))
        );
        // address(3) is just a standin for some other address.
        address mockOtherProverAddr = address(uint160(3));
        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        assessorReceipt.prover = mockOtherProverAddr;
        vm.expectRevert(VerificationFailed.selector);
        boundlessMarket.fulfill(fills, assessorReceipt);

        // Prover should have their original balance less the stake amount.
        testProver.expectStakeBalanceChange(-int256(uint256(request.offer.lockStake)));
        expectMarketBalanceUnchanged();
    }

    // Tests trying to fulfill a request that was locked and has now expired.
    function testFulfillLockedRequestFullyExpired() public returns (Client, ProofRequest memory) {
        Client client = getClient(1);
        ProofRequest memory request = client.request(1);
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes memory clientSignature = client.sign(request);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignature;
        client.snapshotBalance();
        testProver.snapshotBalance();

        vm.prank(testProverAddress);
        boundlessMarket.lockRequest(request, clientSignature);
        // At this point the client should have only been charged the 1 ETH at lock time.
        client.expectBalanceChange(-1 ether);

        // Advance the chain ahead to simulate the request timeout.
        vm.warp(request.offer.deadline() + 1);

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        // Try the priceAndFulfill path.
        bytes[] memory paymentErrors =
            boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);
        assert(
            keccak256(paymentErrors[0])
                == keccak256(abi.encodeWithSelector(IBoundlessMarket.RequestIsExpired.selector, request.id))
        );
        expectRequestNotFulfilled(fill.id);

        // Client is out 1 eth until slash is called.
        client.expectBalanceChange(-1 ether);
        testProver.expectBalanceChange(0 ether);
        testProver.expectStakeBalanceChange(-1 ether);
        expectMarketBalanceUnchanged();

        // Try the fulfill path as well. Should be the same results.
        paymentErrors = boundlessMarket.fulfill(fills, assessorReceipt);
        assert(
            keccak256(paymentErrors[0])
                == keccak256(abi.encodeWithSelector(IBoundlessMarket.RequestIsExpired.selector, request.id))
        );
        expectRequestNotFulfilled(fill.id);

        // Client is out 1 eth until slash is called.
        client.expectBalanceChange(-1 ether);
        testProver.expectBalanceChange(0 ether);
        testProver.expectStakeBalanceChange(-1 ether);
        expectMarketBalanceUnchanged();

        return (client, request);
    }

    function testFulfillLockedRequestMultipleRequestsSameIndex() public {
        _testFulfillRepeatIndex(LockRequestMethod.LockRequest);
    }

    function testFulfillLockedRequestMultipleRequestsSameIndexWithSig() public {
        _testFulfillRepeatIndex(LockRequestMethod.LockRequestWithSig);
    }

    // Scenario when a prover locks a request, fails to deliver it within the lock expiry,
    // then another prover fulfills a request after the lock has expired,
    // but before the request as a whole has expired.
    function testFulfillWasLockedRequestByOtherProver() public returns (ProofRequest memory, Client, Client, Client) {
        // Create a request with a lock timeout of 50 blocks, and overall timeout of 100.
        Client client = getClient(1);
        ProofRequest memory request = client.request(
            1,
            Offer({
                minPrice: 1 ether,
                maxPrice: 2 ether,
                biddingStart: uint64(block.timestamp),
                rampUpPeriod: uint32(50),
                lockTimeout: uint32(50),
                timeout: uint32(100),
                lockStake: 1 ether
            })
        );
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes memory clientSignature = client.sign(request);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignature;

        Client locker = getProver(1);
        Client otherProver = getProver(2);

        client.snapshotBalance();
        locker.snapshotBalance();
        otherProver.snapshotBalance();

        address lockerAddress = locker.addr();
        vm.prank(lockerAddress);
        boundlessMarket.lockRequest(request, clientSignature);
        // At this point the client should have only been charged the 1 ETH at lock time.
        client.expectBalanceChange(-1 ether);

        // Advance the chain ahead to simulate the lock timeout.
        vm.warp(request.offer.lockDeadline() + 1);

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, otherProver.addr());
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.RequestFulfilled(request.id, otherProver.addr(), fill);
        vm.expectEmit(true, true, true, false);
        emit IBoundlessMarket.ProofDelivered(request.id, otherProver.addr(), fill);

        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);

        // Check that the proof was submitted
        expectRequestFulfilled(fill.id);

        // Client's fee should be returned on fulfill.
        client.expectBalanceChange(0 ether);
        locker.expectBalanceChange(0 ether);
        locker.expectStakeBalanceChange(-1 ether);
        otherProver.expectBalanceChange(0 ether);
        otherProver.expectStakeBalanceChange(0 ether);
        expectMarketBalanceUnchanged();

        return (request, client, locker, otherProver);
    }

    function testFulfillWasLockedClientWithdrawsBalance() public {
        Client client = getClient(1);
        ProofRequest memory request = client.request(
            1,
            Offer({
                minPrice: 1 ether,
                maxPrice: 2 ether,
                biddingStart: uint64(block.timestamp),
                rampUpPeriod: uint32(50),
                lockTimeout: uint32(50),
                timeout: uint32(100),
                lockStake: 1 ether
            })
        );
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes memory clientSignature = client.sign(request);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignature;

        address clientAddress = client.addr();
        vm.prank(testProverAddress);
        boundlessMarket.lockRequest(request, clientSignature);

        uint256 balance = boundlessMarket.balanceOf(clientAddress);
        vm.prank(clientAddress);
        boundlessMarket.withdraw(balance);

        client.snapshotBalance();

        // Advance the chain ahead to simulate the lock timeout.
        vm.warp(request.offer.lockDeadline() + 1);

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        // Fulfill should complete successfully.
        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);
        expectRequestFulfilled(fill.id);

        // Client should get back 1 eth upon fulfill.
        client.expectBalanceChange(1 ether);
        testProver.expectBalanceChange(0 ether);
        testProver.expectStakeBalanceChange(-1 ether);
    }

    // Scenario when a prover locks a request, fails to deliver it within the lock expiry,
    // but does deliver it before the request expires. Here they should lose their stake,
    // but receive payment for the request.
    function testFulfillWasLockedRequestByOriginalLocker() public returns (ProofRequest memory, Client) {
        // Create a request with a lock timeout of 50 blocks, and overall timeout of 100.
        Client client = getClient(1);
        ProofRequest memory request = client.request(
            1,
            Offer({
                minPrice: 1 ether,
                maxPrice: 2 ether,
                biddingStart: uint64(block.timestamp),
                rampUpPeriod: uint32(50),
                lockTimeout: uint32(50),
                timeout: uint32(100),
                lockStake: 1 ether
            })
        );
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes memory clientSignature = client.sign(request);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignature;

        Client locker = getProver(1);

        client.snapshotBalance();
        locker.snapshotBalance();

        address lockerAddress = locker.addr();
        vm.prank(lockerAddress);
        boundlessMarket.lockRequest(request, clientSignature);

        // Advance the chain ahead to simulate the lock timeout.
        vm.warp(request.offer.lockDeadline() + 1);

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, locker.addr());
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.RequestFulfilled(request.id, lockerAddress, fill);
        vm.expectEmit(true, true, true, false);
        emit IBoundlessMarket.ProofDelivered(request.id, lockerAddress, fill);

        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);

        // Check that the proof was submitted
        expectRequestFulfilled(fill.id);

        client.expectBalanceChange(0 ether);
        locker.expectBalanceChange(0 ether);
        locker.expectStakeBalanceChange(-1 ether);
        expectMarketBalanceUnchanged();
        return (request, locker);
    }

    // One request is locked, fully expires.
    // A second request with the same id is then fulfilled.
    // Slash should award stake to the fulfiller of the second request.
    function testFulfillWasLockedRequestRepeatIndexStakeRollover() public {
        Client client = getClient(1);

        Offer memory offerA = Offer({
            minPrice: 1 ether,
            maxPrice: 2 ether,
            biddingStart: uint64(block.timestamp),
            rampUpPeriod: uint32(10),
            lockTimeout: uint32(100),
            timeout: uint32(100),
            lockStake: 1 ether
        });
        Offer memory offerB = Offer({
            minPrice: 1 ether,
            maxPrice: 2 ether,
            biddingStart: uint64(block.timestamp) + uint64(offerA.timeout) + 1,
            rampUpPeriod: uint32(10),
            lockTimeout: uint32(100),
            timeout: 100,
            lockStake: 1 ether
        });

        ProofRequest memory requestA = client.request(1, offerA);
        ProofRequest memory requestB = client.request(1, offerB);
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = requestB;
        bytes memory clientSignatureA = client.sign(requestA);
        bytes memory clientSignatureB = client.sign(requestB);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignatureB;
        Client locker = getProver(1);
        Client fulfiller = getProver(2);

        client.snapshotBalance();
        locker.snapshotBalance();
        fulfiller.snapshotBalance();

        // Lock-in request A.
        address lockerAddress = locker.addr();
        vm.prank(lockerAddress);
        boundlessMarket.lockRequest(requestA, clientSignatureA);

        vm.warp(uint64(block.timestamp) + uint64(offerA.timeout) + 1);
        // Attempt to fill request B.
        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(requestB, APP_JOURNAL, fulfiller.addr());
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);

        // Check that the request ID is marked as fulfilled.
        expectRequestFulfilled(fill.id);

        boundlessMarket.slash(fill.id);

        client.expectBalanceChange(-1 ether);
        locker.expectBalanceChange(0 ether);
        locker.expectStakeBalanceChange(-1 ether);
        fulfiller.expectBalanceChange(1 ether);
        fulfiller.expectStakeBalanceChange(uint256(expectedSlashTransferAmount(offerA.lockStake)).toInt256());
        expectMarketBalanceUnchanged();
    }

    // One request is locked, the lock expires, but the request is not yet expired.
    // A second request with the same id is then fulfilled.
    // Slash should award stake to the fulfiller of the second request.
    function testFulfillWasLockedRequestRepeatIndexStakeRolloverFirstRequestNotExpired() public {
        Client client = getClient(1);

        Offer memory offerA = Offer({
            minPrice: 1 ether,
            maxPrice: 2 ether,
            biddingStart: uint64(block.timestamp),
            rampUpPeriod: uint32(10),
            lockTimeout: uint32(50),
            timeout: uint32(100),
            lockStake: 1 ether
        });
        Offer memory offerB = Offer({
            minPrice: 2 ether,
            maxPrice: 2 ether,
            biddingStart: uint64(block.timestamp),
            rampUpPeriod: uint32(0),
            lockTimeout: offerA.timeout + 101,
            timeout: offerA.timeout + 101,
            lockStake: 1 ether
        });

        ProofRequest memory requestA = client.request(1, offerA);
        ProofRequest memory requestB = client.request(1, offerB);
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = requestB;
        bytes memory clientSignatureA = client.sign(requestA);
        bytes memory clientSignatureB = client.sign(requestB);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignatureB;
        Client locker = getProver(1);
        Client fulfiller = getProver(2);

        client.snapshotBalance();
        locker.snapshotBalance();
        fulfiller.snapshotBalance();

        // Lock-in request A.
        address lockerAddress = locker.addr();
        vm.prank(lockerAddress);
        boundlessMarket.lockRequest(requestA, clientSignatureA);

        vm.warp(offerA.lockDeadline() + 1);
        // Attempt to fill request B.
        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(requestB, APP_JOURNAL, fulfiller.addr());
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);

        // Check that the request ID is marked as fulfilled.
        expectRequestFulfilled(fill.id);

        // Slash should revert as the original locked request has not yet fully expired.
        vm.expectRevert(
            abi.encodeWithSelector(
                IBoundlessMarket.RequestIsNotExpired.selector, fill.id, uint64(block.timestamp) + uint64(offerA.timeout)
            )
        );
        boundlessMarket.slash(fill.id);

        // Advance to where the original locked request has fully expired.
        vm.warp(uint64(block.timestamp) + uint64(offerA.timeout) + 1);

        vm.prank(lockerAddress);
        boundlessMarket.slash(fill.id);

        client.expectBalanceChange(-2 ether);
        locker.expectBalanceChange(0 ether);
        locker.expectStakeBalanceChange(-1 ether);
        fulfiller.expectBalanceChange(2 ether);
        fulfiller.expectStakeBalanceChange(uint256(expectedSlashTransferAmount(offerA.lockStake)).toInt256());
        expectMarketBalanceUnchanged();
    }

    // One request is locked and the client is charged 2 ether. The request expires unfulfilled.
    // A second request with the same id is then fulfilled for a cost of just 1 ether.
    // The client should be refunded the difference.
    function testFulfillWasLockedRequestRepeatIndexSecondRequestCheaper() public {
        Client client = getClient(1);

        // Create two distinct requests with the same ID. It should be the case that only one can be
        // filled, and if one is locked, the other cannot be filled.
        Offer memory offerA = Offer({
            minPrice: 2 ether,
            maxPrice: 3 ether,
            biddingStart: uint64(block.timestamp),
            rampUpPeriod: uint32(10),
            lockTimeout: uint32(50),
            timeout: uint32(100),
            lockStake: 1 ether
        });
        Offer memory offerB = Offer({
            minPrice: 1 ether,
            maxPrice: 1 ether,
            biddingStart: uint64(block.timestamp),
            rampUpPeriod: uint32(0),
            lockTimeout: uint32(100),
            timeout: uint32(block.timestamp) + offerA.timeout + 101,
            lockStake: 1 ether
        });

        ProofRequest memory requestA = client.request(1, offerA);
        ProofRequest memory requestB = client.request(1, offerB);
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = requestB;
        bytes memory clientSignatureA = client.sign(requestA);
        bytes memory clientSignatureB = client.sign(requestB);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignatureB;
        Client locker = getProver(1);
        Client fulfiller = getProver(2);

        client.snapshotBalance();
        locker.snapshotBalance();
        fulfiller.snapshotBalance();

        // Lock-in request A.
        address lockerAddress = locker.addr();
        vm.prank(lockerAddress);
        boundlessMarket.lockRequest(requestA, clientSignatureA);

        client.expectBalanceChange(-2 ether);

        vm.warp(offerA.lockDeadline() + 1);

        // Attempt to fill request B, which costs just 1 ether at the time of fulfillment.
        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(requestB, APP_JOURNAL, fulfiller.addr());
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;
        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);

        // Client should be refunded 1 ether, meaning their net balance change is -1
        client.expectBalanceChange(-1 ether);

        // Check that the request ID is marked as fulfilled.
        expectRequestFulfilled(fill.id);

        client.expectBalanceChange(-1 ether);
        locker.expectBalanceChange(0 ether);
        locker.expectStakeBalanceChange(-1 ether);
        fulfiller.expectBalanceChange(1 ether);
        fulfiller.expectStakeBalanceChange(0 ether);
        expectMarketBalanceUnchanged();
    }

    // One request is locked, expires, and is slashed.
    // A second request with the same id is then fulfilled.
    function testFulfillWasLockedRequestRepeatIndexStakeRolloverSlashedBeforeFulfill() public {
        Client client = getClient(1);

        // Create two distinct requests with the same ID. It should be the case that only one can be
        // filled, and if one is locked, the other cannot be filled.
        Offer memory offerA = Offer({
            minPrice: 1 ether,
            maxPrice: 2 ether,
            biddingStart: uint64(block.timestamp),
            rampUpPeriod: uint32(10),
            lockTimeout: uint32(100),
            timeout: uint32(100),
            lockStake: 1 ether
        });
        Offer memory offerB = Offer({
            minPrice: 3 ether,
            maxPrice: 3 ether,
            biddingStart: uint64(block.timestamp) + uint64(offerA.timeout) + 1,
            rampUpPeriod: uint32(10),
            lockTimeout: uint32(100),
            timeout: 100,
            lockStake: 1 ether
        });

        ProofRequest memory requestA = client.request(1, offerA);
        ProofRequest memory requestB = client.request(1, offerB);
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = requestB;
        bytes memory clientSignatureA = client.sign(requestA);
        bytes memory clientSignatureB = client.sign(requestB);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignatureB;
        Client locker = getProver(1);
        Client fulfiller = getProver(2);

        client.snapshotBalance();
        locker.snapshotBalance();
        fulfiller.snapshotBalance();

        // Lock-in request A.
        address lockerAddress = locker.addr();
        vm.prank(lockerAddress);
        boundlessMarket.lockRequest(requestA, clientSignatureA);

        vm.warp(uint64(block.timestamp) + uint64(offerA.timeout) + 1);

        // Slash the request first.
        vm.prank(lockerAddress);
        boundlessMarket.slash(requestA.id);

        // Attempt to fill request B.
        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(requestB, APP_JOURNAL, fulfiller.addr());
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        address fulfillerAddress = fulfiller.addr();
        vm.prank(fulfillerAddress);
        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);

        // Check that the request ID is marked as fulfilled.
        expectRequestFulfilledAndSlashed(fill.id);

        client.expectBalanceChange(-3 ether);
        locker.expectBalanceChange(0 ether);
        locker.expectStakeBalanceChange(-1 ether);
        fulfiller.expectBalanceChange(3 ether);
        fulfiller.expectStakeBalanceChange(0 ether);
    }

    // Scenario when a prover locks a request, fails to deliver it within the lock expiry,
    // but does deliver it before the request expires. Here they should lose most of their stake
    // (not all), and receive no payment from the client.
    function testFulfillWasLockedRequestDoubleFulfill() public {
        // Create a request with a lock timeout of 50 blocks, and overall timeout of 100.
        Client client = getClient(1);
        ProofRequest memory request = client.request(
            1,
            Offer({
                minPrice: 1 ether,
                maxPrice: 2 ether,
                biddingStart: uint64(block.timestamp),
                rampUpPeriod: uint32(50),
                lockTimeout: uint32(50),
                timeout: uint32(100),
                lockStake: 1 ether
            })
        );
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes memory clientSignature = client.sign(request);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignature;

        Client locker = getProver(1);
        address lockerAddress = locker.addr();

        client.snapshotBalance();
        locker.snapshotBalance();

        vm.prank(lockerAddress);
        boundlessMarket.lockRequest(request, clientSignature);

        // Advance the chain ahead to simulate the lock timeout.
        vm.warp(request.offer.lockDeadline() + 1);

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, lockerAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.RequestFulfilled(request.id, testProverAddress, fill);
        vm.expectEmit(true, true, true, false);
        emit IBoundlessMarket.ProofDelivered(request.id, testProverAddress, fill);

        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);

        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.PaymentRequirementsFailed(
            abi.encodeWithSelector(IBoundlessMarket.RequestIsFulfilled.selector, request.id)
        );
        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);
        vm.snapshotGasLastCall("priceAndFulfill: fulfill already fulfilled was locked request");

        // Check that the proof was submitted
        expectRequestFulfilled(fill.id);

        // Check balances after the fulfillment but before slash.
        client.expectBalanceChange(0 ether);
        locker.expectBalanceChange(0 ether);
        locker.expectStakeBalanceChange(-1 ether);

        vm.warp(request.offer.deadline() + 1);
        boundlessMarket.slash(request.id);

        // Check balances after the slash.
        client.expectBalanceChange(0 ether);
        locker.expectBalanceChange(0 ether);
        locker.expectStakeBalanceChange(-int256(uint256(expectedSlashBurnAmount(request.offer.lockStake))));
    }

    // Scenario when a prover locks a request, fails to deliver it within the lock expiry,
    // another prover fulfills the request, and then the locker tries to fulfill the request
    // before the request as a whole has expired. A proof should still be delivered and no revert
    // should occur, since we support multiple proofs being delivered for a single request. No
    // balance changes should occur.
    function testFulfillWasLockedRequestLockerFulfillAfterAnotherProverFulfill() public {
        (ProofRequest memory request, Client client, Client locker,) = testFulfillWasLockedRequestByOtherProver();

        locker.snapshotBalance();
        locker.snapshotStakeBalance();

        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes memory clientSignature = client.sign(request);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignature;

        // The locker should have no balance change.
        // Now the locker tries to fulfill the request.
        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, locker.addr());
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        // But its already been fulfilled by the other prover.
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.PaymentRequirementsFailed(
            abi.encodeWithSelector(IBoundlessMarket.RequestIsFulfilled.selector, request.id)
        );

        // The proof should still be delivered.
        vm.expectEmit(true, true, true, false);
        emit IBoundlessMarket.ProofDelivered(request.id, locker.addr(), fill);

        // The fulfillment should not revert, as we support multiple proofs being delivered for a single request.
        bytes[] memory paymentErrors =
            boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);
        assert(
            keccak256(paymentErrors[0])
                == keccak256(abi.encodeWithSelector(IBoundlessMarket.RequestIsFulfilled.selector, request.id))
        );

        // The locker should have no balance change.
        locker.expectBalanceChange(0 ether);
        locker.expectStakeBalanceChange(0 ether);
        expectMarketBalanceUnchanged();
    }

    // Scenario when a prover locks a request, fails to deliver it within the lock expiry,
    // another prover fulfills the request, and then the locker tries to fulfill the request
    // _after_ the request has fully expired.
    //
    // In this case the request has fully expired, so the proof should NOT be delivered,
    // however we should not revert (as this allows partial fulfillment of other requests in the batch).
    function testFulfillWasLockedRequestLockerFulfillAfterAnotherProverFulfillAndRequestExpired() public {
        (ProofRequest memory request, Client client, Client locker,) = testFulfillWasLockedRequestByOtherProver();

        locker.snapshotBalance();
        locker.snapshotStakeBalance();

        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes memory clientSignature = client.sign(request);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignature;

        // Advance the chain ahead to simulate the request expiration.
        vm.warp(request.offer.deadline() + 1);

        // The locker should have no balance change.
        // Now the locker tries to fulfill the request.
        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, locker.addr());
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        // In this case the request has fully expired, so the proof should NOT be delivered,
        // however we should not revert (as this allows partial fulfillment of other requests in the batch)
        vm.expectEmit(true, true, true, false);
        emit IBoundlessMarket.PaymentRequirementsFailed(
            abi.encodeWithSelector(IBoundlessMarket.RequestIsExpired.selector, request.id)
        );

        // The fulfillment should not revert, as we support multiple proofs being delivered for a single request.
        bytes[] memory paymentErrors =
            boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);
        assert(
            keccak256(paymentErrors[0])
                == keccak256(abi.encodeWithSelector(IBoundlessMarket.RequestIsExpired.selector, request.id))
        );

        // The locker should have no balance change.
        locker.expectBalanceChange(0 ether);
        locker.expectStakeBalanceChange(0 ether);
        expectMarketBalanceUnchanged();
    }

    // A request is locked with a valid smart contract signature (signature is checked onchain at lock time)
    // and then a prover tries to fulfill it specifying an invalid smart contract signature. The signature could
    // be invalid for a number of reasons, including the smart contract wallet rotating their signers so the old signature
    // is no longer valid.
    // Since there is possibility of funds being pulled in the multiple request same id case, we ensure we check
    // the SC signature again.
    function testFulfillWasLockedRequestByInvalidSmartContractSignature() public {
        SmartContractClient client = getSmartContractClient(1);
        // Request ID indicates smart contract signature, but the signature is invalid.
        ProofRequest memory request = client.request(
            1,
            Offer({
                minPrice: 1 ether,
                maxPrice: 2 ether,
                biddingStart: uint64(block.timestamp),
                rampUpPeriod: uint32(50),
                lockTimeout: uint32(50),
                timeout: uint32(100),
                lockStake: 1 ether
            })
        );
        bytes memory validClientSignature = client.sign(request);
        bytes memory invalidClientSignature = bytes("invalid");

        boundlessMarket.lockRequestWithSignature(
            request, validClientSignature, testProver.signLockRequest(LockRequest({request: request}))
        );
        vm.warp(request.offer.lockDeadline() + 1);

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        // Fulfill should succeed even though the lock has expired when the request matches what was locked.
        boundlessMarket.fulfill(fills, assessorReceipt);

        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = invalidClientSignature;
        // Fulfill should revert during the signature check during pricing, since the signature is invalid.
        // NOTE: This should revert, even though we know the request was signed previously because
        // of signature validation during the lock operation, because the signature in this call is
        // invalid. As a principle, all data in a message must be validated, even if the data given
        // is superfluous.
        vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.InvalidSignature.selector));
        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);

        clientSignatures[0] = validClientSignature;
        // Fulfill should succeed if the signature is valid.
        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);
        expectRequestFulfilled(fill.id);

        client.expectBalanceChange(0 ether);
        testProver.expectBalanceChange(0 ether);
        expectMarketBalanceUnchanged();
    }

    function testFulfillNeverLocked() public {
        _testFulfillSameBlock(1, LockRequestMethod.None, "priceAndFulfill: a single request that was not locked");
    }

    /// Fulfill without locking should still work even if the prover does not have stake.
    function testFulfillNeverLockedProverNoStake() public {
        vm.prank(testProverAddress);
        boundlessMarket.withdrawStake(DEFAULT_BALANCE);

        _testFulfillSameBlock(
            1,
            LockRequestMethod.None,
            "priceAndFulfill: a single request that was not locked fulfilled by prover not in allow-list"
        );
    }

    function testSubmitRootAndFulfillNeverLocked() public {
        _testSubmitRootAndFulfillSameBlock(
            1, LockRequestMethod.None, "submitRootAndPriceAndFulfill: a single request that was not locked"
        );
    }

    /// SubmitRootAndFulfill without locking should still work even if the prover does not have stake.
    function testSubmitRootAndFulfillNeverLockedProverNoStake() public {
        vm.prank(testProverAddress);
        boundlessMarket.withdrawStake(DEFAULT_BALANCE);

        _testSubmitRootAndFulfillSameBlock(
            1,
            LockRequestMethod.None,
            "submitRootAndPriceAndFulfill: a single request that was not locked fulfilled by prover not in allow-list"
        );
    }

    function testFulfillNeverLockedNotPriced() public {
        Client client = getClient(1);
        ProofRequest memory request = client.request(1);
        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        // Attempt to fulfill a request without locking or pricing it.
        vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.RequestIsNotLockedOrPriced.selector, request.id));
        boundlessMarket.fulfill(fills, assessorReceipt);

        expectMarketBalanceUnchanged();
    }

    // Should revert as you can not fulfill a request twice, except for in the case covered by:
    // `testFulfillLockedRequestAlreadyFulfilledByOtherProver`
    function testFulfillNeverLockedAlreadyFulfilledAndPaid() public {
        _testFulfillAlreadyFulfilled(3, LockRequestMethod.None);
    }

    function testFulfillNeverLockedFullyExpired() public returns (Client, ProofRequest memory) {
        Client client = getClient(1);
        ProofRequest memory request = client.request(1);
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes memory clientSignature = client.sign(request);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignature;

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        vm.warp(request.offer.deadline() + 1);

        bytes[] memory paymentErrors =
            boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);
        assert(
            keccak256(paymentErrors[0])
                == keccak256(abi.encodeWithSelector(IBoundlessMarket.RequestIsExpired.selector, request.id))
        );
        expectRequestNotFulfilled(fill.id);

        vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.RequestIsNotLockedOrPriced.selector, request.id));
        boundlessMarket.fulfill(fills, assessorReceipt);

        expectRequestNotFulfilled(fill.id);
        client.expectBalanceChange(0 ether);
        testProver.expectBalanceChange(0 ether);
        testProver.expectStakeBalanceChange(0 ether);
        expectMarketBalanceUnchanged();

        return (client, request);
    }

    function testFulfillNeverLockedClientWithdrawsBalance() public {
        Client client = getClient(1);
        ProofRequest memory request = client.request(1);
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes memory clientSignature = client.sign(request);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignature;

        address clientAddress = client.addr();

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        uint256 balance = boundlessMarket.balanceOf(clientAddress);
        vm.prank(clientAddress);
        boundlessMarket.withdraw(balance);

        // expect emit of payment requirement failed
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.PaymentRequirementsFailed(
            abi.encodeWithSelector(IBoundlessMarket.InsufficientBalance.selector, clientAddress)
        );
        vm.prank(clientAddress);
        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);
        expectRequestFulfilled(fill.id);
    }

    function testFulfillNeverLockedRequestMultipleRequestsSameIndex() public {
        _testFulfillRepeatIndex(LockRequestMethod.None);
    }

    // Fulfill a batch of locked requests
    function testFulfillLockedRequests() public {
        // Provide a batch definition as an array of clients and how many requests each submits.
        uint256[5] memory batch = [uint256(1), 2, 1, 3, 1];
        uint256 batchSize = 0;
        for (uint256 i = 0; i < batch.length; i++) {
            batchSize += batch[i];
        }
        ProofRequest[] memory requests = new ProofRequest[](batchSize);
        bytes[] memory journals = new bytes[](batchSize);
        uint256 expectedRevenue = 0;
        uint256 idx = 0;
        for (uint256 i = 0; i < batch.length; i++) {
            Client client = getClient(i);

            for (uint256 j = 0; j < batch[i]; j++) {
                ProofRequest memory request = client.request(uint32(j));

                // TODO: This is a fragile part of this test. It should be improved.
                uint256 desiredPrice = uint256(1.5 ether);
                vm.warp(request.offer.timeAtPrice(desiredPrice));
                expectedRevenue += desiredPrice;

                boundlessMarket.lockRequestWithSignature(
                    request, client.sign(request), testProver.signLockRequest(LockRequest({request: request}))
                );

                requests[idx] = request;
                journals[idx] = APP_JOURNAL;
                idx++;
            }
        }

        (Fulfillment[] memory fills, AssessorReceipt memory assessorReceipt) =
            createFillsAndSubmitRoot(requests, journals, testProverAddress);

        for (uint256 i = 0; i < fills.length; i++) {
            vm.expectEmit(true, true, true, true);
            emit IBoundlessMarket.RequestFulfilled(fills[i].id, testProverAddress, fills[i]);
            vm.expectEmit(true, true, true, false);
            emit IBoundlessMarket.ProofDelivered(fills[i].id, testProverAddress, fills[i]);
        }
        boundlessMarket.fulfill(fills, assessorReceipt);
        vm.snapshotGasLastCall(string.concat("fulfill: a batch of ", vm.toString(batchSize)));

        for (uint256 i = 0; i < fills.length; i++) {
            // Check that the proof was submitted
            expectRequestFulfilled(fills[i].id);
        }

        testProver.expectBalanceChange(int256(uint256(expectedRevenue)));
        expectMarketBalanceUnchanged();
    }

    // Testing that reordering request IDs in a batch will cause the fulfill to revert.
    function testFulfillShuffleIds() public {
        uint256[5] memory batch = [uint256(1), 2, 1, 3, 1];
        uint256 batchSize = 0;
        for (uint256 i = 0; i < batch.length; i++) {
            batchSize += batch[i];
        }
        ProofRequest[] memory requests = new ProofRequest[](batchSize);
        bytes[] memory journals = new bytes[](batchSize);
        bytes[] memory signatures = new bytes[](batchSize);
        uint256 idx = 0;
        for (uint256 i = 0; i < batch.length; i++) {
            Client client = getClient(i);

            for (uint256 j = 0; j < batch[i]; j++) {
                ProofRequest memory request = client.request(uint32(j));

                requests[idx] = request;
                journals[idx] = APP_JOURNAL;
                signatures[idx] = client.sign(request);
                idx++;
            }
        }

        (Fulfillment[] memory fills, AssessorReceipt memory assessorReceipt) =
            createFillsAndSubmitRoot(requests, journals, testProverAddress);

        // Swap first two IDs
        RequestId id0 = fills[0].id;
        fills[0].id = fills[1].id;
        fills[1].id = id0;

        vm.warp(requests[0].offer.timeAtPrice(uint256(1.5 ether)));
        vm.expectRevert(VerificationFailed.selector);
        boundlessMarket.priceAndFulfill(requests, signatures, fills, assessorReceipt);

        expectMarketBalanceUnchanged();
    }

    // Testing that reordering fulfillments in a batch will cause the fulfill to revert.
    function testFulfillShuffleFills() public {
        uint256 batchSize = 2;
        ProofRequest[] memory requests = new ProofRequest[](batchSize);
        bytes[] memory journals = new bytes[](batchSize);

        // First request
        Client client = getClient(0);
        ProofRequest memory request = client.request(uint32(0));
        boundlessMarket.lockRequestWithSignature(
            request, client.sign(request), testProver.signLockRequest(LockRequest({request: request}))
        );
        requests[0] = request;
        journals[0] = APP_JOURNAL;

        // Second request
        client = getClient(1);
        request = client.request(uint32(1));
        request.requirements = Requirements({
            imageId: bytes32(APP_IMAGE_ID_2),
            predicate: Predicate({predicateType: PredicateType.DigestMatch, data: abi.encode(sha256(APP_JOURNAL_2))}),
            selector: bytes4(0),
            callback: Callback({addr: address(0), gasLimit: 0})
        });
        boundlessMarket.lockRequestWithSignature(
            request, client.sign(request), testProver.signLockRequest(LockRequest({request: request}))
        );
        requests[1] = request;
        journals[1] = APP_JOURNAL_2;

        (Fulfillment[] memory fills, AssessorReceipt memory assessorReceipt) =
            createFillsAndSubmitRoot(requests, journals, testProverAddress);

        bytes32 imageId0 = fills[0].imageId;
        bytes memory journal0 = fills[0].journal;

        fills[0].imageId = fills[1].imageId;
        fills[1].imageId = imageId0;

        fills[0].journal = fills[1].journal;
        fills[1].journal = journal0;

        vm.expectRevert(VerificationFailed.selector);
        boundlessMarket.fulfill(fills, assessorReceipt);

        expectMarketBalanceUnchanged();
    }

    // Test that a smart contract signature can be used to price a request.
    // The smart contract signature must be validated when a request is priced. This
    // ensures that the smart contract signature is checked in the never locked path,
    // since the signature is not checked at lock time (nor in the assessor).
    function testPriceRequestSmartContractSignature() external {
        SmartContractClient client = getSmartContractClient(1);
        ProofRequest memory request = client.request(3);
        bytes memory clientSignature = client.sign(request);

        // Expect isValidSignature to be called on the smart contract wallet
        bytes32 requestHash =
            MessageHashUtils.toTypedDataHash(boundlessMarket.eip712DomainSeparator(), request.eip712Digest());
        vm.expectCall(
            client.addr(), abi.encodeWithSelector(IERC1271.isValidSignature.selector, requestHash, clientSignature)
        );
        boundlessMarket.priceRequest(request, clientSignature);
    }

    function testPriceRequestSmartContractSignatureExceedsGasLimit() external {
        SmartContractClient client = getSmartContractClient(1);
        client.smartWallet().setGasCost(boundlessMarket.ERC1271_MAX_GAS_FOR_CHECK() + 1);
        ProofRequest memory request = client.request(3);
        bytes memory clientSignature = client.sign(request);

        // Expect isValidSignature to be called on the smart contract wallet
        bytes32 requestHash =
            MessageHashUtils.toTypedDataHash(boundlessMarket.eip712DomainSeparator(), request.eip712Digest());
        vm.expectCall(
            client.addr(), abi.encodeWithSelector(IERC1271.isValidSignature.selector, requestHash, clientSignature)
        );
        vm.expectRevert(bytes("")); // revert due to out of gas results in empty error
        boundlessMarket.priceRequest(request, clientSignature);
    }

    // Test that a smart contract signature can be used to price and fulfill a request.
    // The smart contract signature must be validated when a request is priced. This
    // ensures that the smart contract signature is validated during the never locked path,
    // since the signature is not checked at lock time (nor in the assessor).
    function testPriceAndFulfillSmartContractSignature() external {
        SmartContractClient client = getSmartContractClient(1);
        ProofRequest memory request = client.request(3);
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;

        bytes memory clientSignature = client.sign(request);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignature;
        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.RequestFulfilled(request.id, testProverAddress, fill);
        vm.expectEmit(true, true, true, false);
        emit IBoundlessMarket.ProofDelivered(request.id, testProverAddress, fill);
        // Expect isValidSignature to be called on the smart contract wallet
        bytes32 requestHash =
            MessageHashUtils.toTypedDataHash(boundlessMarket.eip712DomainSeparator(), request.eip712Digest());
        vm.expectCall(
            client.addr(), abi.encodeWithSelector(IERC1271.isValidSignature.selector, requestHash, clientSignature)
        );

        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);
        vm.snapshotGasLastCall("priceAndFulfill: a single request (smart contract signature)");

        expectRequestFulfilled(fill.id);

        client.expectBalanceChange(-1 ether);
        testProver.expectBalanceChange(1 ether);
        expectMarketBalanceUnchanged();
    }

    // Fulfill a batch of locked requests and withdraw
    function testFulfillAndWithdrawLockedRequests() public {
        // Provide a batch definition as an array of clients and how many requests each submits.
        uint256[5] memory batch = [uint256(1), 2, 1, 3, 1];
        uint256 batchSize = 0;
        for (uint256 i = 0; i < batch.length; i++) {
            batchSize += batch[i];
        }

        ProofRequest[] memory requests = new ProofRequest[](batchSize);
        bytes[] memory journals = new bytes[](batchSize);
        uint256 expectedRevenue = 0;
        uint256 idx = 0;
        for (uint256 i = 0; i < batch.length; i++) {
            Client client = getClient(i);

            for (uint256 j = 0; j < batch[i]; j++) {
                ProofRequest memory request = client.request(uint32(j));

                // TODO: This is a fragile part of this test. It should be improved.
                uint256 desiredPrice = uint256(1.5 ether);
                vm.warp(request.offer.timeAtPrice(desiredPrice));
                expectedRevenue += desiredPrice;

                boundlessMarket.lockRequestWithSignature(
                    request, client.sign(request), testProver.signLockRequest(LockRequest({request: request}))
                );

                requests[idx] = request;
                journals[idx] = APP_JOURNAL;
                idx++;
            }
        }

        (Fulfillment[] memory fills, AssessorReceipt memory assessorReceipt) =
            createFillsAndSubmitRoot(requests, journals, testProverAddress);

        uint256 initialBalance = testProverAddress.balance + boundlessMarket.balanceOf(testProverAddress);

        for (uint256 i = 0; i < fills.length; i++) {
            vm.expectEmit(true, true, true, true);
            emit IBoundlessMarket.RequestFulfilled(fills[i].id, testProverAddress, fills[i]);
            vm.expectEmit(true, true, true, false);
            emit IBoundlessMarket.ProofDelivered(fills[i].id, testProverAddress, fills[i]);
        }
        boundlessMarket.fulfillAndWithdraw(fills, assessorReceipt);
        vm.snapshotGasLastCall(string.concat("fulfillAndWithdraw: a batch of ", vm.toString(batchSize)));

        for (uint256 i = 0; i < fills.length; i++) {
            // Check that the proof was submitted
            expectRequestFulfilled(fills[i].id);
        }

        assert(boundlessMarket.balanceOf(testProverAddress) == 0);
        assert(testProverAddress.balance == initialBalance + uint256(expectedRevenue));
    }

    function testPriceAndFulfillLockedRequest() external {
        Client client = getClient(1);
        ProofRequest memory request = client.request(3);

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);

        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = client.sign(request);

        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.RequestFulfilled(request.id, testProverAddress, fill);
        vm.expectEmit(true, true, true, false);
        emit IBoundlessMarket.ProofDelivered(request.id, testProverAddress, fill);
        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);
        vm.snapshotGasLastCall("priceAndFulfill: a single request");

        expectRequestFulfilled(fill.id);

        client.expectBalanceChange(-1 ether);
        testProver.expectBalanceChange(1 ether);
        expectMarketBalanceUnchanged();
    }

    function testSubmitRootAndPriceAndFulfillLockedRequest() external {
        Client client = getClient(1);
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = client.request(3);
        bytes[] memory journals = new bytes[](1);
        journals[0] = APP_JOURNAL;

        (Fulfillment[] memory fills, AssessorReceipt memory assessorReceipt, bytes32 root) =
            createFills(requests, journals, testProverAddress);

        bytes memory seal = verifier.mockProve(
            SET_BUILDER_IMAGE_ID, sha256(abi.encodePacked(SET_BUILDER_IMAGE_ID, uint256(1 << 255), root))
        ).seal;

        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = client.sign(requests[0]);

        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.RequestFulfilled(requests[0].id, testProverAddress, fills[0]);
        vm.expectEmit(true, true, true, false);
        emit IBoundlessMarket.ProofDelivered(requests[0].id, testProverAddress, fills[0]);
        boundlessMarket.submitRootAndPriceAndFulfill(
            address(setVerifier), root, seal, requests, clientSignatures, fills, assessorReceipt
        );
        vm.snapshotGasLastCall("submitRootAndPriceAndFulfill: a single request");

        expectRequestFulfilled(fills[0].id);

        client.expectBalanceChange(-1 ether);
        testProver.expectBalanceChange(1 ether);
        expectMarketBalanceUnchanged();
    }

    function _testFulfillAlreadyFulfilled(uint32 idx, LockRequestMethod lockinMethod) private {
        (, ProofRequest memory request) = _testFulfillSameBlock(idx, lockinMethod);

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = getClient(1).sign(request);

        // TODO(#704): Workaround in test for edge case described in #704
        vm.warp(request.offer.lockDeadline() + 1);

        // Attempt to fulfill a request already fulfilled
        // should return "RequestIsFulfilled({requestId: request.id})"
        bytes[] memory paymentError =
            boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);
        assert(
            keccak256(paymentError[0])
                == keccak256(abi.encodeWithSelector(IBoundlessMarket.RequestIsFulfilled.selector, request.id))
        );

        expectMarketBalanceUnchanged();
    }

    function testPriceAndFulfillWithSelector() external {
        Client client = getClient(1);
        ProofRequest memory request = client.request(3);
        request.requirements.selector = setVerifier.SELECTOR();

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);

        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = client.sign(request);

        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.RequestFulfilled(request.id, testProverAddress, fill);
        vm.expectEmit(true, true, true, false);
        emit IBoundlessMarket.ProofDelivered(request.id, testProverAddress, fill);
        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);
        vm.snapshotGasLastCall("priceAndFulfill: a single request (with selector)");

        expectRequestFulfilled(fill.id);

        client.expectBalanceChange(-1 ether);
        testProver.expectBalanceChange(1 ether);
        expectMarketBalanceUnchanged();
    }

    function testFulfillRequestWrongSelector() public {
        Client client = getClient(1);
        ProofRequest memory request = client.request(1);
        request.requirements.selector = setVerifier.SELECTOR();
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes memory clientSignature = client.sign(request);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignature;

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        // Attempt to fulfill a request with wrong selector.
        assessorReceipt.selectors[0] = Selector({index: 0, value: bytes4(0xdeadbeef)});
        vm.expectRevert(
            abi.encodeWithSelector(
                IBoundlessMarket.SelectorMismatch.selector, bytes4(0xdeadbeef), setVerifier.SELECTOR()
            )
        );
        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);

        expectMarketBalanceUnchanged();
    }

    function testFulfillApplicationVerificationGasLimit() public {
        Client client = getClient(1);
        ProofRequest memory request = client.request(3);
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        bytes memory clientSignature = client.sign(request);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignature;

        bytes32 claimDigest = ReceiptClaimLib.ok(fill.imageId, sha256(fill.journal)).digest();

        // If no selector is specified, we expect the call to verifyIntegrity to use the default
        // gas limit when verifying the application.
        vm.expectCall(
            address(setVerifier),
            0,
            uint64(EXPECTED_DEFAULT_MAX_GAS_FOR_VERIFY),
            abi.encodeWithSelector(IRiscZeroVerifier.verifyIntegrity.selector, RiscZeroReceipt(fill.seal, claimDigest))
        );
        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);

        expectRequestFulfilled(fill.id);

        client.expectBalanceChange(-1 ether);
        testProver.expectBalanceChange(1 ether);
        expectMarketBalanceUnchanged();
    }

    function testFulfillVerificationGasLimitForSelector() public {
        Client client = getClient(1);
        ProofRequest memory request = client.request(3);
        request.requirements.selector = setVerifier.SELECTOR();
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        bytes memory clientSignature = client.sign(request);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignature;

        bytes32 claimDigest = ReceiptClaimLib.ok(fill.imageId, sha256(fill.journal)).digest();

        // If a selector is specified, we expect the call to verifyIntegrity to not use the default
        // gas limit, so the minimum gas it should have should exceed it.
        vm.expectCallMinGas(
            address(setVerifier),
            0,
            uint64(EXPECTED_DEFAULT_MAX_GAS_FOR_VERIFY + 1),
            abi.encodeWithSelector(IRiscZeroVerifier.verifyIntegrity.selector, RiscZeroReceipt(fill.seal, claimDigest))
        );
        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);

        expectRequestFulfilled(fill.id);

        client.expectBalanceChange(-1 ether);
        testProver.expectBalanceChange(1 ether);
        expectMarketBalanceUnchanged();
    }

    function _testFulfillRepeatIndex(LockRequestMethod lockinMethod) private {
        Client client = getClient(1);

        // Create two distinct requests with the same ID. It should be the case that only one can be
        // filled, and if one is locked, the other cannot be filled.
        Offer memory offerA = client.defaultOffer();
        Offer memory offerB = client.defaultOffer();
        offerB.maxPrice = 3 ether;
        ProofRequest memory requestA = client.request(1, offerA);
        ProofRequest memory requestB = client.request(1, offerB);
        bytes memory clientSignatureA = client.sign(requestA);

        // Lock-in request A.
        if (lockinMethod == LockRequestMethod.LockRequest) {
            vm.prank(testProverAddress);
            boundlessMarket.lockRequest(requestA, clientSignatureA);
        } else if (lockinMethod == LockRequestMethod.LockRequestWithSig) {
            boundlessMarket.lockRequestWithSignature(
                requestA, clientSignatureA, testProver.signLockRequest(LockRequest({request: requestA}))
            );
        }

        client.snapshotBalance();
        testProver.snapshotBalance();

        // Attempt to fill request B.
        (Fulfillment memory fillB, AssessorReceipt memory assessorReceiptB) =
            createFillAndSubmitRoot(requestB, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fillsB = new Fulfillment[](1);
        fillsB[0] = fillB;

        if (lockinMethod == LockRequestMethod.None) {
            // Annoying boilerplate for creating singleton lists.
            // Here we price/lock with request A and try to fill with request B.
            ProofRequest[] memory requestsA = new ProofRequest[](1);
            requestsA[0] = requestA;
            bytes[] memory clientSignatures = new bytes[](1);
            clientSignatures[0] = clientSignatureA;

            vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.RequestIsNotLockedOrPriced.selector, requestA.id));
            boundlessMarket.priceAndFulfill(requestsA, clientSignatures, fillsB, assessorReceiptB);

            expectRequestNotFulfilled(fillB.id);
        } else {
            // Attempting to fulfill request B should revert, since it has never been seen onchain.
            vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.RequestIsNotLockedOrPriced.selector, requestA.id));
            boundlessMarket.fulfill(fillsB, assessorReceiptB);
            expectRequestNotFulfilled(fillB.id);

            // Attempting to price and fulfill with request B should return a
            // payment error since request A is still locked.
            ProofRequest[] memory requestsB = new ProofRequest[](1);
            requestsB[0] = requestB;
            bytes[] memory clientSignatures = new bytes[](1);
            clientSignatures[0] = client.sign(requestB);

            bytes[] memory paymentErrors =
                boundlessMarket.priceAndFulfill(requestsB, clientSignatures, fillsB, assessorReceiptB);
            assert(
                keccak256(paymentErrors[0])
                    == keccak256(abi.encodeWithSelector(IBoundlessMarket.RequestIsLocked.selector, requestB.id))
            );
            expectRequestFulfilled(fillB.id);
        }

        // No balance changes should have occurred after lockin.
        client.expectBalanceChange(0 ether);
        testProver.expectBalanceChange(0 ether);
        expectMarketBalanceUnchanged();
    }

    function testSubmitRootAndFulfill() public {
        (ProofRequest[] memory requests, bytes[] memory journals) = newBatch(2);
        (Fulfillment[] memory fills, AssessorReceipt memory assessorReceipt, bytes32 root) =
            createFills(requests, journals, testProverAddress);

        bytes memory seal = verifier.mockProve(
            SET_BUILDER_IMAGE_ID, sha256(abi.encodePacked(SET_BUILDER_IMAGE_ID, uint256(1 << 255), root))
        ).seal;
        boundlessMarket.submitRootAndFulfill(address(setVerifier), root, seal, fills, assessorReceipt);
        vm.snapshotGasLastCall("submitRootAndFulfill: a batch of 2 requests");

        for (uint256 j = 0; j < fills.length; j++) {
            expectRequestFulfilled(fills[j].id);
        }
    }

    function testSlashLockedRequestFullyExpired() public returns (Client, ProofRequest memory) {
        (Client client, ProofRequest memory request) = testFulfillLockedRequestFullyExpired();
        // Provers stake balance is subtracted at lock time, not when slash is called
        testProver.expectStakeBalanceChange(-uint256(request.offer.lockStake).toInt256());

        snapshotMarketStakeBalance();
        snapshotMarketStakeTreasuryBalance();

        // Slash the request
        // Burning = sending tokens to address 0xdEaD, expect a transfer event to be emitted to address 0xdEaD
        vm.expectEmit(true, true, true, false);
        emit IERC20.Transfer(address(proxy), address(0xdEaD), request.offer.lockStake);
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.ProverSlashed(
            request.id,
            expectedSlashBurnAmount(request.offer.lockStake),
            expectedSlashTransferAmount(request.offer.lockStake),
            address(boundlessMarket)
        );

        boundlessMarket.slash(request.id);
        vm.snapshotGasLastCall("slash: base case");

        expectMarketStakeBalanceChange(-int256(int96(expectedSlashBurnAmount(request.offer.lockStake))));
        expectMarketStakeTreasuryBalanceChange(int256(int96(expectedSlashTransferAmount(request.offer.lockStake))));

        client.expectBalanceChange(0 ether);
        testProver.expectStakeBalanceChange(-uint256(request.offer.lockStake).toInt256());

        // Check that the request is slashed and is not fulfilled
        expectRequestSlashed(request.id);

        return (client, request);
    }

    // Prover locks a request, the request expires, then they fulfill a request with the same ID.
    // Prover should be slashable, but still able to fulfill the other request and receive payment for it.
    function testSlashLockedRequestMultipleRequestsSameIndex() public {
        Client client = getClient(1);

        // Create two distinct requests with the same ID.
        Offer memory offerA = Offer({
            minPrice: 1 ether,
            maxPrice: 2 ether,
            biddingStart: uint64(block.timestamp),
            rampUpPeriod: uint32(10),
            lockTimeout: uint32(100),
            timeout: uint32(100),
            lockStake: 1 ether
        });
        Offer memory offerB = Offer({
            minPrice: 3 ether,
            maxPrice: 3 ether,
            biddingStart: uint64(block.timestamp) + uint64(offerA.timeout) + 1,
            rampUpPeriod: uint32(10),
            lockTimeout: uint32(100),
            timeout: 100,
            lockStake: 1 ether
        });
        ProofRequest memory requestA = client.request(1, offerA);
        ProofRequest memory requestB = client.request(1, offerB);
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = requestB;
        bytes memory clientSignatureA = client.sign(requestA);
        bytes memory clientSignatureB = client.sign(requestB);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignatureB;

        client.snapshotBalance();
        testProver.snapshotBalance();

        vm.prank(testProverAddress);
        boundlessMarket.lockRequest(requestA, clientSignatureA);

        vm.warp(requestA.offer.deadline() + 1);

        // Attempt to fill request B.
        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(requestB, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;
        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);

        boundlessMarket.slash(requestA.id);

        expectRequestFulfilledAndSlashed(fill.id);

        client.expectBalanceChange(-3 ether);
        testProver.expectBalanceChange(3 ether);
        // They lose their original stake, but gain a portion of the slashed stake.
        testProver.expectStakeBalanceChange(
            -1 ether + int256(uint256(expectedSlashTransferAmount(requestA.offer.lockStake)))
        );
        expectMarketBalanceUnchanged();
    }

    // Handles case where a third-party that was not locked fulfills the request, and the locked prover does not.
    // Once the locked prover is slashed, we expect the request to be both "fulfilled" and "slashed".
    // We expect a portion of slashed funds to go to the market treasury.
    function testSlashLockedRequestFulfilledByOtherProverDuringLock() public {
        Client client = getClient(1);
        ProofRequest memory request = client.request(1);

        // Lock to "testProver" but "prover2" fulfills the request
        boundlessMarket.lockRequestWithSignature(
            request, client.sign(request), testProver.signLockRequest(LockRequest({request: request}))
        );

        Client testProver2 = getClient(2);
        (address testProver2Address,,,) = testProver2.wallet();
        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProver2Address);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        boundlessMarket.fulfill(fills, assessorReceipt);
        expectRequestFulfilled(fill.id);

        vm.warp(request.offer.deadline() + 1);

        // Slash the original prover that locked and didnt deliver
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.ProverSlashed(
            request.id,
            expectedSlashBurnAmount(request.offer.lockStake),
            expectedSlashTransferAmount(request.offer.lockStake),
            address(boundlessMarket)
        );
        boundlessMarket.slash(request.id);

        client.expectBalanceChange(0 ether);
        testProver.expectStakeBalanceChange(-uint256(request.offer.lockStake).toInt256());
        testProver2.expectStakeBalanceChange(0 ether);

        // We expect the request is both slashed and fulfilled
        require(boundlessMarket.requestIsSlashed(request.id), "Request should be slashed");
        require(boundlessMarket.requestIsFulfilled(request.id), "Request should be fulfilled");
    }

    function testSlashInvalidRequestID() public {
        // Attempt to slash an invalid request ID
        // should revert with "RequestIsNotLocked({requestId: request.id})"
        vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.RequestIsNotLocked.selector, 0xa));
        boundlessMarket.slash(RequestId.wrap(0xa));

        expectMarketBalanceUnchanged();
    }

    function testSlashLockedRequestNotExpired() public {
        (, ProofRequest memory request) = testLockRequest();

        // Attempt to slash a request not expired
        // should revert with "RequestIsNotExpired({requestId: request.id,  deadline: deadline})"
        vm.expectRevert(
            abi.encodeWithSelector(IBoundlessMarket.RequestIsNotExpired.selector, request.id, request.offer.deadline())
        );
        boundlessMarket.slash(request.id);

        expectMarketBalanceUnchanged();
    }

    // Even if the lock has expired, you can not slash until the request is fully expired, as we need to know if the
    // request was eventually fulfilled or not to decide who to send stake to.
    function testSlashWasLockedRequestNotFullyExpired() public {
        Client client = getClient(1);
        ProofRequest memory request = client.request(
            1,
            Offer({
                minPrice: 1 ether,
                maxPrice: 2 ether,
                biddingStart: uint64(block.timestamp),
                rampUpPeriod: uint32(50),
                lockTimeout: uint32(50),
                timeout: uint32(100),
                lockStake: 1 ether
            })
        );
        bytes memory clientSignature = client.sign(request);

        Client locker = getProver(1);
        client.snapshotBalance();
        locker.snapshotBalance();

        address lockerAddress = locker.addr();
        vm.prank(lockerAddress);
        boundlessMarket.lockRequest(request, clientSignature);
        // At this point the client should have only been charged the 1 ETH at lock time.
        client.expectBalanceChange(-1 ether);

        // Advance the chain ahead to simulate the lock timeout.
        vm.warp(request.offer.lockDeadline() + 1);

        // Attempt to slash a request not expired
        // should revert with "RequestIsNotExpired({requestId: request.id,  deadline: deadline})"
        vm.expectRevert(
            abi.encodeWithSelector(IBoundlessMarket.RequestIsNotExpired.selector, request.id, request.offer.deadline())
        );
        boundlessMarket.slash(request.id);

        expectMarketBalanceUnchanged();
    }

    function _testSlashFulfilledSameBlock(uint32 idx, LockRequestMethod lockinMethod) private {
        (, ProofRequest memory request) = _testFulfillSameBlock(idx, lockinMethod);

        if (lockinMethod == LockRequestMethod.None) {
            vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.RequestIsNotLocked.selector, request.id));
        } else {
            vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.RequestIsFulfilled.selector, request.id));
        }

        boundlessMarket.slash(request.id);

        expectMarketBalanceUnchanged();
    }

    function testSlashLockedRequestFulfilledByLocker() public {
        _testSlashFulfilledSameBlock(1, LockRequestMethod.LockRequest);
        _testSlashFulfilledSameBlock(2, LockRequestMethod.LockRequestWithSig);
    }

    function testSlashNeverLockedRequestFulfilled() public {
        _testSlashFulfilledSameBlock(3, LockRequestMethod.None);
    }

    // Test slashing in the scenario where a request is fulfilled by another prover after the lock expires.
    // but before the request as a whole has expired.
    function testSlashWasLockedRequestFulfilledByOtherProver()
        public
        returns (ProofRequest memory, Client, Client, Client)
    {
        snapshotMarketStakeTreasuryBalance();
        (ProofRequest memory request, Client client, Client locker, Client otherProver) =
            testFulfillWasLockedRequestByOtherProver();
        vm.warp(request.offer.deadline() + 1);
        otherProver.snapshotStakeBalance();

        // We expect the prover that ultimately fulfilled the request to receive stake.
        // Burning = sending tokens to address 0xdEaD, expect a transfer event to be emitted to address 0xdEaD
        vm.expectEmit(true, true, true, false);
        emit IERC20.Transfer(address(proxy), address(0xdEaD), request.offer.lockStake);
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.ProverSlashed(
            request.id,
            expectedSlashBurnAmount(request.offer.lockStake),
            expectedSlashTransferAmount(request.offer.lockStake),
            otherProver.addr()
        );

        boundlessMarket.slash(request.id);
        vm.snapshotGasLastCall("slash: fulfilled request after lock deadline");

        // Prover should have their original balance less the stake amount.
        testProver.expectStakeBalanceChange(-uint256(request.offer.lockStake).toInt256());
        // Other prover should receive a portion of the stake
        otherProver.expectStakeBalanceChange(uint256(expectedSlashTransferAmount(request.offer.lockStake)).toInt256());

        expectMarketStakeTreasuryBalanceChange(0);
        expectMarketBalanceUnchanged();

        return (request, client, locker, otherProver);
    }

    // In this case the lock expires, the request is fulfilled by another prover, the request is slashed,
    // and then finally the locker tries to fulfill the request.
    //
    // In this case the request has fully expired, so the proof should NOT be delivered,
    // however we should not revert (as this allows partial fulfillment of other requests in the batch).
    function testSlashWasLockedRequestFulfilledByOtherProverFulfillAfterRequestExpired() public {
        (ProofRequest memory request, Client client, Client locker,) = testSlashWasLockedRequestFulfilledByOtherProver();
        vm.warp(request.offer.deadline() + 1);

        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;
        bytes memory clientSignature = client.sign(request);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignature;

        // Advance the chain ahead to simulate the request expiration.
        vm.warp(request.offer.deadline() + 1);

        // The locker should have no balance change.
        // Now the locker tries to fulfill the request.
        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, locker.addr());
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        // In this case the request has fully expired, so the proof should NOT be delivered,
        // however we should not revert (as this allows partial fulfillment of other requests in the batch)
        vm.expectEmit(true, true, true, false);
        emit IBoundlessMarket.PaymentRequirementsFailed(
            abi.encodeWithSelector(IBoundlessMarket.RequestIsExpired.selector, request.id)
        );

        // The fulfillment should not revert, as we support multiple proofs being delivered for a single request.
        bytes[] memory paymentErrors =
            boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);
        assert(
            keccak256(paymentErrors[0])
                == keccak256(abi.encodeWithSelector(IBoundlessMarket.RequestIsExpired.selector, request.id))
        );
    }

    // Test slashing in the scenario where a request is fulfilled by the locker after the lock expires.
    // but before the request as a whole has expired.
    function testSlashWasLockedRequestFulfilledByLocker() public {
        snapshotMarketStakeTreasuryBalance();
        (ProofRequest memory request, Client prover) = testFulfillWasLockedRequestByOriginalLocker();
        vm.warp(request.offer.deadline() + 1);

        // We expect the prover that ultimately fulfilled the request to receive stake.
        // Burning = sending tokens to address 0xdEaD, expect a transfer event to be emitted to address 0xdEaD
        vm.expectEmit(true, true, true, false);
        emit IERC20.Transfer(address(proxy), address(0xdEaD), request.offer.lockStake);
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.ProverSlashed(
            request.id,
            expectedSlashBurnAmount(request.offer.lockStake),
            expectedSlashTransferAmount(request.offer.lockStake),
            prover.addr()
        );

        boundlessMarket.slash(request.id);

        // Prover should have their original balance less the stake amount plus the stake for eventually filling.
        prover.expectStakeBalanceChange(
            -uint256(request.offer.lockStake).toInt256()
                + uint256(expectedSlashTransferAmount(request.offer.lockStake)).toInt256()
        );

        expectMarketStakeTreasuryBalanceChange(0);
        expectMarketBalanceUnchanged();
    }

    function testSlashSlash() public {
        (, ProofRequest memory request) = testSlashLockedRequestFullyExpired();
        expectRequestSlashed(request.id);

        vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.RequestIsSlashed.selector, request.id));
        boundlessMarket.slash(request.id);
    }

    function testLockRequestSmartContractSignature() public {
        SmartContractClient client = getSmartContractClient(1);
        ProofRequest memory request = client.request(1);
        bytes memory clientSig = client.sign(request);

        // Expect isValidSignature to be called on the smart contract wallet
        bytes32 requestHash =
            MessageHashUtils.toTypedDataHash(boundlessMarket.eip712DomainSeparator(), request.eip712Digest());
        vm.expectCall(client.addr(), abi.encodeWithSelector(IERC1271.isValidSignature.selector, requestHash, clientSig));

        // Call lockRequest with the smart contract signature
        vm.prank(testProverAddress);
        boundlessMarket.lockRequest(request, clientSig);

        // Verify the lock request
        assertTrue(boundlessMarket.requestIsLocked(request.id), "Request should be locked");
    }

    // Test that the smart contract client receives the proof request when isValidSignature is called,
    // if the client signature provided is empty. This enables custom smart contract clients that want to authorize
    // payments based on how a proof request is structured.
    function testLockRequestSmartContractClientValidatesPassthroughEmptySignature() public {
        SmartContractClient client = getSmartContractClient(1);
        ProofRequest memory request = client.request(1);
        bytes memory clientSig = bytes("");
        client.setExpectedSignature(clientSig);

        // Expect isValidSignature to be called on the smart contract wallet with the proof request as the signature.
        bytes32 requestHash =
            MessageHashUtils.toTypedDataHash(boundlessMarket.eip712DomainSeparator(), request.eip712Digest());
        vm.expectCall(client.addr(), abi.encodeWithSelector(IERC1271.isValidSignature.selector, requestHash, clientSig));

        // Call lockRequest with the smart contract signature
        vm.prank(testProverAddress);
        boundlessMarket.lockRequest(request, clientSig);

        // Verify the lock request
        assertTrue(boundlessMarket.requestIsLocked(request.id), "Request should be locked");
    }

    function testLockRequestSmartContractSignatureInvalid() public {
        SmartContractClient client = getSmartContractClient(1);
        ProofRequest memory request = client.request(1);
        bytes memory clientSig = bytes("invalid_signature");

        // Expect isValidSignature to be called on the smart contract wallet
        bytes32 requestHash =
            MessageHashUtils.toTypedDataHash(boundlessMarket.eip712DomainSeparator(), request.eip712Digest());
        vm.expectCall(client.addr(), abi.encodeWithSelector(IERC1271.isValidSignature.selector, requestHash, clientSig));

        // Call lockRequest with the smart contract signature
        vm.prank(testProverAddress);
        vm.expectRevert(IBoundlessMarket.InvalidSignature.selector);
        boundlessMarket.lockRequest(request, clientSig);
    }

    function testLockRequestSmartContractSignatureExceedsGasLimit() public {
        SmartContractClient client = getSmartContractClient(1);
        client.smartWallet().setGasCost(boundlessMarket.ERC1271_MAX_GAS_FOR_CHECK() + 1);
        ProofRequest memory request = client.request(1);
        bytes memory clientSig = client.sign(request);

        // Expect isValidSignature to be called on the smart contract wallet
        bytes32 requestHash =
            MessageHashUtils.toTypedDataHash(boundlessMarket.eip712DomainSeparator(), request.eip712Digest());
        vm.expectCall(client.addr(), abi.encodeWithSelector(IERC1271.isValidSignature.selector, requestHash, clientSig));

        // Call lockRequest with the smart contract signature
        vm.prank(testProverAddress);
        vm.expectRevert(bytes("")); // revert due to out of gas results in empty error
        boundlessMarket.lockRequest(request, clientSig);
    }

    function testLockRequestWithSignatureClientSmartContractSignatureInvalid() public {
        SmartContractClient client = getSmartContractClient(1);
        Client prover = getClient(2);

        ProofRequest memory request = client.request(1);
        bytes memory clientSig = bytes("invalid_signature");
        bytes memory proverSig = prover.signLockRequest(LockRequest({request: request}));

        address proverAddress = prover.addr();
        vm.prank(proverAddress);
        vm.expectRevert(IBoundlessMarket.InvalidSignature.selector);
        boundlessMarket.lockRequestWithSignature(request, clientSig, proverSig);
    }

    function testFulfillLockedRequestWithCallback() public {
        Client client = getClient(1);

        // Create request with low gas callback
        ProofRequest memory request = client.request(1);
        request.requirements.callback = Callback({addr: address(mockCallback), gasLimit: 500_000});

        bytes memory clientSignature = client.sign(request);
        client.snapshotBalance();
        testProver.snapshotBalance();

        // Lock and fulfill the request
        vm.prank(testProverAddress);
        boundlessMarket.lockRequest(request, clientSignature);

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.RequestFulfilled(request.id, testProverAddress, fill);
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.ProofDelivered(request.id, testProverAddress, fill);
        vm.expectEmit(true, true, true, false);
        emit MockCallback.MockCallbackCalled(request.requirements.imageId, APP_JOURNAL, fill.seal);
        boundlessMarket.fulfill(fills, assessorReceipt);

        // Verify callback was called exactly once
        assertEq(mockCallback.getCallCount(), 1, "Callback should be called exactly once");

        // Verify request state and balances
        expectRequestFulfilled(fill.id);
        client.expectBalanceChange(-1 ether);
        testProver.expectBalanceChange(1 ether);
        expectMarketBalanceUnchanged();
    }

    function testFulfillLockedRequestWithCallbackExceedGasLimit() public {
        Client client = getClient(1);

        // Create request with high gas callback that will exceed limit
        ProofRequest memory request = client.request(1);
        request.requirements.callback = Callback({addr: address(mockHighGasCallback), gasLimit: 10_000});

        bytes memory clientSignature = client.sign(request);
        client.snapshotBalance();
        testProver.snapshotBalance();

        // Lock and fulfill the request
        vm.prank(testProverAddress);
        boundlessMarket.lockRequest(request, clientSignature);

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.RequestFulfilled(request.id, testProverAddress, fill);
        vm.expectEmit(true, true, true, false);
        emit IBoundlessMarket.ProofDelivered(request.id, testProverAddress, fill);
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.CallbackFailed(request.id, address(mockHighGasCallback), "");
        boundlessMarket.fulfill(fills, assessorReceipt);

        // Verify callback was attempted
        assertEq(mockHighGasCallback.getCallCount(), 0, "Callback not succeed");

        // Verify request state and balances
        expectRequestFulfilled(fill.id);
        client.expectBalanceChange(-1 ether);
        testProver.expectBalanceChange(1 ether);
        expectMarketBalanceUnchanged();
    }

    function testFulfillLockedRequestWithCallbackByOtherProver() public {
        Client client = getClient(1);

        // Create request with low gas callback
        ProofRequest memory request = client.request(1);
        request.requirements.callback = Callback({addr: address(mockCallback), gasLimit: 100_000});

        bytes memory clientSignature = client.sign(request);

        // Lock request with testProver
        boundlessMarket.lockRequestWithSignature(
            request, clientSignature, testProver.signLockRequest(LockRequest({request: request}))
        );

        // Have otherProver fulfill without requiring payment
        Client otherProver = getProver(2);
        address otherProverAddress = otherProver.addr();
        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, otherProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.RequestFulfilled(request.id, otherProverAddress, fill);
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.PaymentRequirementsFailed(
            abi.encodeWithSelector(IBoundlessMarket.RequestIsLocked.selector, request.id)
        );
        vm.expectEmit(true, true, true, false);
        emit IBoundlessMarket.ProofDelivered(request.id, otherProverAddress, fill);
        vm.expectEmit(true, true, true, true);
        emit MockCallback.MockCallbackCalled(request.requirements.imageId, APP_JOURNAL, fill.seal);

        vm.prank(otherProverAddress);
        boundlessMarket.fulfill(fills, assessorReceipt);

        // Verify callback was called exactly once
        assertEq(mockCallback.getCallCount(), 1, "Callback should be called exactly once");

        // Verify request state and balances
        expectRequestFulfilled(fill.id);
        testProver.expectStakeBalanceChange(-int256(uint256(request.offer.lockStake)));
        otherProver.expectBalanceChange(0);
        otherProver.expectStakeBalanceChange(0);
        expectMarketBalanceUnchanged();
    }

    function testFulfillLockedRequestWithCallbackAlreadyFulfilledByOtherProver() public {
        Client client = getClient(1);

        ProofRequest memory request = client.request(1);
        request.requirements.callback = Callback({addr: address(mockCallback), gasLimit: 100_000});

        bytes memory clientSignature = client.sign(request);

        // Lock request with testProver
        boundlessMarket.lockRequestWithSignature(
            request, clientSignature, testProver.signLockRequest(LockRequest({request: request}))
        );

        // Have otherProver fulfill without requiring payment
        Client otherProver = getProver(2);
        address otherProverAddress = address(otherProver);
        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, otherProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.RequestFulfilled(request.id, otherProverAddress, fill);
        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.PaymentRequirementsFailed(
            abi.encodeWithSelector(IBoundlessMarket.RequestIsLocked.selector, request.id)
        );
        vm.expectEmit(true, true, true, false);
        emit IBoundlessMarket.ProofDelivered(request.id, otherProverAddress, fill);
        vm.expectEmit(true, true, true, true);
        emit MockCallback.MockCallbackCalled(request.requirements.imageId, APP_JOURNAL, fill.seal);
        boundlessMarket.fulfill(fills, assessorReceipt);

        // Verify callback was called exactly once
        assertEq(mockCallback.getCallCount(), 1, "Callback should be called exactly once");

        // Now have original locker fulfill to get payment
        (fill, assessorReceipt) = createFillAndSubmitRoot(request, APP_JOURNAL, testProverAddress);
        fills[0] = fill;
        boundlessMarket.fulfill(fills, assessorReceipt);

        // Verify callback is called again
        assertEq(mockCallback.getCallCount(), 2, "Callback should be called twice");

        expectRequestFulfilled(fill.id);
        testProver.expectBalanceChange(1 ether);
        testProver.expectStakeBalanceChange(0 ether);
        otherProver.expectBalanceChange(0);
        otherProver.expectStakeBalanceChange(0);
        expectMarketBalanceUnchanged();
    }

    function testFulfillWasLockedRequestWithCallbackByOtherProver() public {
        Client client = getClient(1);

        // Create request with lock timeout of 50 blocks, overall timeout of 100
        ProofRequest memory request = client.request(
            1,
            Offer({
                minPrice: 1 ether,
                maxPrice: 2 ether,
                biddingStart: uint64(block.timestamp),
                rampUpPeriod: uint32(50),
                lockTimeout: uint32(50),
                timeout: uint32(100),
                lockStake: 1 ether
            })
        );
        request.requirements.callback = Callback({addr: address(mockCallback), gasLimit: 100_000});
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = request;

        bytes memory clientSignature = client.sign(request);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignature;

        Client locker = getProver(1);
        Client otherProver = getProver(2);

        client.snapshotBalance();
        locker.snapshotBalance();
        otherProver.snapshotBalance();

        address lockerAddress = locker.addr();
        vm.prank(lockerAddress);
        boundlessMarket.lockRequest(request, clientSignature);
        client.expectBalanceChange(-1 ether);

        // Advance chain ahead to simulate lock timeout
        vm.warp(request.offer.lockDeadline() + 1);

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(request, APP_JOURNAL, otherProver.addr());
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.RequestFulfilled(request.id, otherProver.addr(), fill);
        vm.expectEmit(true, true, true, false);
        emit IBoundlessMarket.ProofDelivered(request.id, otherProver.addr(), fill);
        vm.expectEmit(true, true, true, true);
        emit MockCallback.MockCallbackCalled(request.requirements.imageId, APP_JOURNAL, fill.seal);
        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);

        // Verify callback was called exactly once
        assertEq(mockCallback.getCallCount(), 1, "Callback should be called exactly once");

        // Check request state and balances
        expectRequestFulfilled(fill.id);
        client.expectBalanceChange(0 ether);
        locker.expectBalanceChange(0 ether);
        locker.expectStakeBalanceChange(-1 ether);
        otherProver.expectBalanceChange(0 ether);
        expectMarketBalanceUnchanged();
    }

    function testFulfillWasLockedRequestWithCallbackMultipleRequestsSameIndex() public {
        Client client = getClient(1);

        // Create first request with callback A
        Offer memory offerA = Offer({
            minPrice: 1 ether,
            maxPrice: 2 ether,
            biddingStart: uint64(block.timestamp),
            rampUpPeriod: uint32(10),
            lockTimeout: uint32(100),
            timeout: uint32(100),
            lockStake: 1 ether
        });
        ProofRequest memory requestA = client.request(1, offerA);
        requestA.requirements.callback = Callback({addr: address(mockCallback), gasLimit: 10_000});
        bytes memory clientSignatureA = client.sign(requestA);

        // Create second request with same ID but different callback
        Offer memory offerB = Offer({
            minPrice: 1 ether,
            maxPrice: 3 ether,
            biddingStart: offerA.biddingStart,
            rampUpPeriod: offerA.rampUpPeriod,
            lockTimeout: offerA.lockTimeout + 100,
            timeout: offerA.timeout + 100,
            lockStake: offerA.lockStake
        });
        ProofRequest memory requestB = client.request(1, offerB);
        requestB.requirements.callback = Callback({addr: address(mockHighGasCallback), gasLimit: 300_000});
        ProofRequest[] memory requests = new ProofRequest[](1);
        requests[0] = requestB;
        bytes memory clientSignatureB = client.sign(requestB);
        bytes[] memory clientSignatures = new bytes[](1);
        clientSignatures[0] = clientSignatureB;

        client.snapshotBalance();
        testProver.snapshotBalance();

        // Lock request A
        vm.prank(testProverAddress);
        boundlessMarket.lockRequest(requestA, clientSignatureA);

        // Advance chain ahead to simulate request A lock timeout
        vm.warp(requestA.offer.lockDeadline() + 1);

        (Fulfillment memory fill, AssessorReceipt memory assessorReceipt) =
            createFillAndSubmitRoot(requestB, APP_JOURNAL, testProverAddress);
        Fulfillment[] memory fills = new Fulfillment[](1);
        fills[0] = fill;

        // Since the request being fulfilled is distinct from the one that was locked, the
        // transaction should revert if the request is not priced before fulfillment.
        vm.expectRevert(abi.encodeWithSelector(IBoundlessMarket.RequestIsNotLockedOrPriced.selector, requestB.id));
        boundlessMarket.fulfill(fills, assessorReceipt);

        vm.expectEmit(true, true, true, true);
        emit IBoundlessMarket.RequestFulfilled(requestB.id, testProverAddress, fill);
        vm.expectEmit(true, true, true, false);
        emit IBoundlessMarket.ProofDelivered(requestB.id, testProverAddress, fill);
        vm.expectEmit(true, true, true, true);
        emit MockCallback.MockCallbackCalled(requestB.requirements.imageId, APP_JOURNAL, fill.seal);
        boundlessMarket.priceAndFulfill(requests, clientSignatures, fills, assessorReceipt);

        // Verify only the second request's callback was called
        assertEq(mockCallback.getCallCount(), 0, "First request's callback should not be called");
        assertEq(mockHighGasCallback.getCallCount(), 1, "Second request's callback should be called once");

        // Verify request state and balances
        expectRequestFulfilled(fill.id);
        client.expectBalanceChange(-3 ether);
        testProver.expectBalanceChange(3 ether);
        testProver.expectStakeBalanceChange(-1 ether); // Lost stake from lock
        expectMarketBalanceUnchanged();
    }
}

contract BoundlessMarketBench is BoundlessMarketTest {
    using BoundlessMarketLib for Offer;

    function benchFulfill(uint256 batchSize, string memory snapshot) public {
        (ProofRequest[] memory requests, bytes[] memory journals) = newBatch(batchSize);
        (Fulfillment[] memory fills, AssessorReceipt memory assessorReceipt) =
            createFillsAndSubmitRoot(requests, journals, testProverAddress);

        boundlessMarket.fulfill(fills, assessorReceipt);
        vm.snapshotGasLastCall(string.concat("fulfill: batch of ", snapshot));

        for (uint256 j = 0; j < fills.length; j++) {
            expectRequestFulfilled(fills[j].id);
        }
    }

    function benchFulfillWithSelector(uint256 batchSize, string memory snapshot) public {
        (ProofRequest[] memory requests, bytes[] memory journals) =
            newBatchWithSelector(batchSize, setVerifier.SELECTOR());
        (Fulfillment[] memory fills, AssessorReceipt memory assessorReceipt) =
            createFillsAndSubmitRoot(requests, journals, testProverAddress);

        boundlessMarket.fulfill(fills, assessorReceipt);
        vm.snapshotGasLastCall(string.concat("fulfill (with selector): batch of ", snapshot));

        for (uint256 j = 0; j < fills.length; j++) {
            expectRequestFulfilled(fills[j].id);
        }
    }

    function benchFulfillWithCallback(uint256 batchSize, string memory snapshot) public {
        (ProofRequest[] memory requests, bytes[] memory journals) = newBatchWithCallback(batchSize);
        (Fulfillment[] memory fills, AssessorReceipt memory assessorReceipt) =
            createFillsAndSubmitRoot(requests, journals, testProverAddress);

        boundlessMarket.fulfill(fills, assessorReceipt);
        vm.snapshotGasLastCall(string.concat("fulfill (with callback): batch of ", snapshot));

        for (uint256 j = 0; j < fills.length; j++) {
            expectRequestFulfilled(fills[j].id);
        }
    }

    function testBenchFulfill001() public {
        benchFulfill(1, "001");
    }

    function testBenchFulfill002() public {
        benchFulfill(2, "002");
    }

    function testBenchFulfill004() public {
        benchFulfill(4, "004");
    }

    function testBenchFulfill008() public {
        benchFulfill(8, "008");
    }

    function testBenchFulfill016() public {
        benchFulfill(16, "016");
    }

    function testBenchFulfill032() public {
        benchFulfill(32, "032");
    }

    function testBenchFulfill064() public {
        benchFulfill(64, "064");
    }

    function testBenchFulfill128() public {
        benchFulfill(128, "128");
    }

    function testBenchFulfillWithSelector001() public {
        benchFulfillWithSelector(1, "001");
    }

    function testBenchFulfillWithSelector002() public {
        benchFulfillWithSelector(2, "002");
    }

    function testBenchFulfillWithSelector004() public {
        benchFulfillWithSelector(4, "004");
    }

    function testBenchFulfillWithSelector008() public {
        benchFulfillWithSelector(8, "008");
    }

    function testBenchFulfillWithSelector016() public {
        benchFulfillWithSelector(16, "016");
    }

    function testBenchFulfillWithSelector032() public {
        benchFulfillWithSelector(32, "032");
    }

    function testBenchFulfillWithCallback001() public {
        benchFulfillWithCallback(1, "001");
    }

    function testBenchFulfillWithCallback002() public {
        benchFulfillWithCallback(2, "002");
    }

    function testBenchFulfillWithCallback004() public {
        benchFulfillWithCallback(4, "004");
    }

    function testBenchFulfillWithCallback008() public {
        benchFulfillWithCallback(8, "008");
    }

    function testBenchFulfillWithCallback016() public {
        benchFulfillWithCallback(16, "016");
    }

    function testBenchFulfillWithCallback032() public {
        benchFulfillWithCallback(32, "032");
    }
}

contract BoundlessMarketUpgradeTest is BoundlessMarketTest {
    using BoundlessMarketLib for Offer;

    function testUnsafeUpgrade() public {
        vm.startPrank(OWNER_WALLET.addr);
        proxy = UnsafeUpgrades.deployUUPSProxy(
            address(new BoundlessMarket(setVerifier, ASSESSOR_IMAGE_ID, address(0))),
            abi.encodeCall(BoundlessMarket.initialize, (OWNER_WALLET.addr, "https://assessor.dev.null"))
        );
        boundlessMarket = BoundlessMarket(proxy);
        address implAddressV1 = UnsafeUpgrades.getImplementationAddress(proxy);

        // Should emit an `Upgraded` event
        vm.expectEmit(false, true, true, true);
        emit IERC1967.Upgraded(address(0));
        UnsafeUpgrades.upgradeProxy(
            proxy, address(new BoundlessMarket(setVerifier, ASSESSOR_IMAGE_ID, address(0))), "", OWNER_WALLET.addr
        );
        vm.stopPrank();
        address implAddressV2 = UnsafeUpgrades.getImplementationAddress(proxy);

        assertFalse(implAddressV2 == implAddressV1);

        (bytes32 imageID, string memory imageUrl) = boundlessMarket.imageInfo();
        assertEq(imageID, ASSESSOR_IMAGE_ID, "Image ID should be the same after upgrade");
        assertEq(imageUrl, "https://assessor.dev.null", "Image URL should be the same after upgrade");
    }

    function testTransferOwnership() public {
        address newOwner = vm.createWallet("NEW_OWNER").addr;
        vm.prank(OWNER_WALLET.addr);
        boundlessMarket.transferOwnership(newOwner);

        vm.prank(newOwner);
        boundlessMarket.acceptOwnership();

        assertEq(boundlessMarket.owner(), newOwner, "Owner should be changed");
    }
}
