// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ExecutorSendReceiveQuoteOnChain, InvalidPeer} from "wormhole-solidity-sdk/Executor/Integration.sol";
import {SequenceReplayProtectionLib} from "wormhole-solidity-sdk/libraries/ReplayProtection.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {CONSISTENCY_LEVEL_INSTANT} from "wormhole-solidity-sdk/constants/ConsistencyLevel.sol";
import {RelayInstructionLib} from "wormhole-solidity-sdk/Executor/RelayInstruction.sol";
import {RequestLib} from "wormhole-solidity-sdk/Executor/Request.sol";
import {toUniversalAddress} from "wormhole-solidity-sdk/Utils.sol";

/**
 * @title HelloWormholeOnChainQuote
 * @notice Cross-chain messaging contract using Wormhole Executor with on-chain quotes
 * @dev Uses ExecutorSendReceiveQuoteOnChain instead of off-chain signed quotes
 *
 * Key differences from HelloWormhole:
 * - Uses `executorQuoterRouter` instead of `executor` address
 * - sendGreeting takes `quoterAddress` instead of `signedQuote`
 * - Provides `quoteGreeting()` for on-chain cost estimation
 */
contract HelloWormholeOnChainQuote is ExecutorSendReceiveQuoteOnChain, AccessControl {
    using SequenceReplayProtectionLib for *;

    bytes32 public constant PEER_ADMIN_ROLE = keccak256("PEER_ADMIN_ROLE");

    // peers[chainId]: executor routing address.
    //   EVM chains  → the deployed contract address (left-padded to bytes32)
    //   Solana      → the PROGRAM ID (32 bytes, no padding; must be executable)
    mapping(uint16 => bytes32) public peers;

    // vaaEmitters[chainId]: Wormhole emitter to verify on *incoming* VAAs.
    //   Leave as bytes32(0) for EVM chains (emitter == peers[chainId]).
    //   Set to the Solana EMITTER PDA for Solana peers (PDA(["emitter"], programId)).
    mapping(uint16 => bytes32) public vaaEmitters;

    constructor(address coreBridge, address executorQuoterRouter)
        ExecutorSendReceiveQuoteOnChain(coreBridge, executorQuoterRouter)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PEER_ADMIN_ROLE, msg.sender);
    }

    event GreetingReceived(string greeting, uint16 senderChain, bytes32 sender);
    event GreetingSent(string greeting, uint16 targetChain, uint64 sequence);

    error NoValueAllowed();

    /// @dev Used by the SDK for executor routing. Must point to an executable account on SVM.
    function _getPeer(uint16 chainId) internal view override returns (bytes32) {
        return peers[chainId];
    }

    /// @dev Override VAA verification to use vaaEmitters when set.
    ///      Falls back to peers[chainId] for EVM chains (emitter == contract address).
    function _checkPeer(uint16 chainId, bytes32 peerAddress) internal view override {
        bytes32 emitter = vaaEmitters[chainId];
        if (emitter == bytes32(0)) emitter = peers[chainId];
        if (emitter != peerAddress) revert InvalidPeer();
    }

    /// @notice Register the executor-routing address for a peer chain.
    ///         EVM: contract address (left-padded). Solana: program ID (32 bytes).
    function setPeer(uint16 chainId, bytes32 peerAddress) external onlyRole(PEER_ADMIN_ROLE) {
        peers[chainId] = peerAddress;
    }

    /// @notice Register the Wormhole emitter for incoming VAA verification.
    ///         Only required when emitter ≠ peers[chainId] (e.g. Solana emitter PDA).
    function setVaaEmitter(uint16 chainId, bytes32 emitterAddress) external onlyRole(PEER_ADMIN_ROLE) {
        vaaEmitters[chainId] = emitterAddress;
    }

    function _replayProtect(
        uint16 emitterChainId,
        bytes32 emitterAddress,
        uint64 sequence,
        bytes calldata /* encodedVaa */
    )
        internal
        override
    {
        SequenceReplayProtectionLib.replayProtect(emitterChainId, emitterAddress, sequence);
    }

    function _executeVaa(
        bytes calldata payload,
        uint32,
        /* timestamp */
        uint16 peerChain,
        bytes32 peerAddress,
        uint64,
        /* sequence */
        uint8 /* consistencyLevel */
    )
        internal
        override
    {
        if (msg.value > 0) {
            revert NoValueAllowed();
        }
        // Decode the payload to extract the greeting message
        string memory greeting = string(payload);

        // Emit an event with the greeting message and sender details
        emit GreetingReceived(greeting, peerChain, peerAddress);
    }

    /**
     * @notice Get a quote for sending a greeting using on-chain quoter
     * @param targetChain The Wormhole chain ID of the destination
     * @param gasLimit Gas limit / compute units for execution on target chain
     * @param msgValue Native token amount for destination (0 for EVM, lamports for Solana)
     * @param quoterAddress The on-chain quoter contract address
     * @return totalCost The total cost including Wormhole message fee and executor fee
     */
    function quoteGreeting(uint16 targetChain, uint128 gasLimit, uint128 msgValue, address quoterAddress)
        external
        view
        returns (uint256 totalCost)
    {
        bytes32 peerAddress = peers[targetChain];
        require(peerAddress != bytes32(0), "No peer set for target chain");

        // Build relay instructions including any msgValue forwarding
        bytes memory relayInstructions = RelayInstructionLib.encodeGas(gasLimit, msgValue);

        // Build request bytes (same format as _publishAndCompose uses)
        bytes memory requestBytes = RequestLib.encodeVaaMultiSigRequest(
            _chainId,
            toUniversalAddress(address(this)),
            0 // sequence placeholder - not needed for quote
        );

        // Get executor quote from on-chain quoter
        uint256 executorFee = _executorQuoterRouter.quoteExecution(
            targetChain,
            peerAddress,
            address(0), // refund address not needed for quote
            quoterAddress,
            requestBytes,
            relayInstructions
        );

        // Total = executor fee + Wormhole message fee
        totalCost = executorFee + _coreBridge.messageFee();
    }

    /**
     * @notice Send a cross-chain greeting using on-chain quote (EVM destinations)
     * @param greeting The message to send
     * @param targetChain The Wormhole chain ID of the destination
     * @param gasLimit Gas limit for execution on target chain
     * @param totalCost Total cost (Wormhole fee + executor fee from quoteGreeting)
     * @param quoterAddress The on-chain quoter contract address
     * @return sequence The Wormhole sequence number
     */
    function sendGreeting(
        string calldata greeting,
        uint16 targetChain,
        uint128 gasLimit,
        uint256 totalCost,
        address quoterAddress
    ) external payable returns (uint64 sequence) {
        return sendGreetingWithMsgValue(greeting, targetChain, gasLimit, 0, totalCost, quoterAddress);
    }

    /**
     * @notice Send a cross-chain greeting with custom msgValue (for SVM destinations)
     * @dev For EVM→Solana, msgValue is in LAMPORTS (e.g. 15_000_000 ≈ 0.015 SOL for rent/fees).
     *      Requires setPeer(solanaChainId, programId) AND setVaaEmitter(solanaChainId, emitterPda).
     * @param greeting The message to send
     * @param targetChain Wormhole chain ID of the destination
     * @param gasLimit Gas / compute units for execution on target chain
     * @param msgValue Native token amount for destination (lamports for Solana, wei for EVM)
     * @param totalCost Total cost (Wormhole fee + executor fee)
     * @param quoterAddress The on-chain quoter contract address
     * @return sequence The Wormhole sequence number
     */
    function sendGreetingWithMsgValue(
        string calldata greeting,
        uint16 targetChain,
        uint128 gasLimit,
        uint128 msgValue,
        uint256 totalCost,
        address quoterAddress
    ) public payable returns (uint64 sequence) {
        sequence = _publishAndRelay(
            bytes(greeting),
            CONSISTENCY_LEVEL_INSTANT,
            totalCost,
            targetChain,
            msg.sender,
            quoterAddress,
            gasLimit,
            msgValue,
            ""
        );
        emit GreetingSent(greeting, targetChain, sequence);
    }
}
