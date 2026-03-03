// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ExecutorSendReceiveQuoteOffChain, InvalidPeer} from "wormhole-solidity-sdk/Executor/Integration.sol";
import {SequenceReplayProtectionLib} from "wormhole-solidity-sdk/libraries/ReplayProtection.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {CONSISTENCY_LEVEL_INSTANT} from "wormhole-solidity-sdk/constants/ConsistencyLevel.sol";
import {CHAIN_ID_SOLANA} from "wormhole-solidity-sdk/constants/Chains.sol";

contract HelloWormhole is ExecutorSendReceiveQuoteOffChain, AccessControl {
    using SequenceReplayProtectionLib for *;

    bytes32 public constant PEER_ADMIN_ROLE = keccak256("PEER_ADMIN_ROLE");

    // peers[chainId]: the address the Executor uses to route messages to the peer.
    //   - EVM chains:   the deployed HelloWormhole contract address (left-padded to bytes32)
    //   - Solana:       the PROGRAM ID (left-aligned, no padding) — must be executable so
    //                   the Executor can call it as the VAA resolver
    mapping(uint16 => bytes32) public peers;

    // vaaEmitters[chainId]: the Wormhole emitter address to verify on *incoming* VAAs.
    //   Only needs to be set when the emitter differs from peers[chainId].
    //   - EVM chains:   leave as bytes32(0) — emitter == peers[chainId] (same contract)
    //   - Solana:       set to the EMITTER PDA (the PDA that signs Wormhole messages),
    //                   because the emitter PDA ≠ program ID
    mapping(uint16 => bytes32) public vaaEmitters;

    constructor(address coreBridge, address executor) ExecutorSendReceiveQuoteOffChain(coreBridge, executor) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PEER_ADMIN_ROLE, msg.sender);
    }

    event GreetingReceived(string greeting, uint16 senderChain, bytes32 sender);
    event GreetingSent(string greeting, uint16 targetChain, uint64 sequence);

    error NoValueAllowed();
    error PayloadTooLargeForSolana(uint256 length, uint256 maxLength);

    // Solana's receive_greeting enforces a 512-byte cap on the message payload.
    // Enforce it here so callers don't pay a relay fee for a delivery that will fail.
    uint256 private constant SOLANA_MAX_PAYLOAD_BYTES = 512;

    function _getPeer(uint16 chainId) internal view override returns (bytes32) {
        return peers[chainId];
    }

    function _checkPeer(uint16 chainId, bytes32 peerAddress) internal view override {
        bytes32 emitter = vaaEmitters[chainId];
        if (emitter == bytes32(0)) emitter = peers[chainId];
        if (emitter != peerAddress) revert InvalidPeer();
    }

    function setPeer(uint16 chainId, bytes32 peerAddress) external onlyRole(PEER_ADMIN_ROLE) {
        peers[chainId] = peerAddress;
    }

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

        // Decode the payload to extract the greeting message.
        // Solana payloads use a tagged format: 0x01 | u16_BE(len) | utf8 message.
        // EVM payloads are raw UTF-8 bytes. Strip the header only for Solana senders.
        string memory greeting;
        if (peerChain == CHAIN_ID_SOLANA) {
            require(payload.length >= 3 && payload[0] == 0x01, "HelloWormhole: expected Solana Hello payload");
            uint16 len = (uint16(uint8(payload[1])) << 8) | uint16(uint8(payload[2]));
            require(payload.length == 3 + uint256(len), "HelloWormhole: payload length mismatch");
            greeting = string(payload[3:]);
        } else {
            greeting = string(payload);
        }

        // Emit an event with the greeting message and sender details
        emit GreetingReceived(greeting, peerChain, peerAddress);
    }

    // msgValue: lamports for Solana destinations, 0 for EVM
    function sendGreetingWithMsgValue(
        string calldata greeting,
        uint16 targetChain,
        uint128 gasLimit,
        uint128 msgValue,
        uint256 totalCost,
        bytes calldata signedQuote
    ) public payable returns (uint64 sequence) {
        // Encode the greeting as bytes
        bytes memory payload = bytes(greeting);

        // Solana enforces a 512-byte cap on incoming messages; fail early so the
        // relay fee is not spent on a delivery that will be rejected on Solana.
        if (targetChain == CHAIN_ID_SOLANA && payload.length > SOLANA_MAX_PAYLOAD_BYTES) {
            revert PayloadTooLargeForSolana(payload.length, SOLANA_MAX_PAYLOAD_BYTES);
        }

        // Publish and relay the message to the target chain
        sequence = _publishAndRelay(
            payload,
            CONSISTENCY_LEVEL_INSTANT, // choose safe or finalized based on your needs
            totalCost,
            targetChain,
            msg.sender, // refund address
            signedQuote,
            gasLimit,
            msgValue, // pass through for SVM destinations (in lamports)
            "" // no extra relay instructions
        );

        emit GreetingSent(greeting, targetChain, sequence);
    }

    function sendGreeting(
        string calldata greeting,
        uint16 targetChain,
        uint128 gasLimit,
        uint256 totalCost,
        bytes calldata signedQuote
    ) external payable returns (uint64 sequence) {
        // Encode the greeting as bytes
        bytes memory payload = bytes(greeting);

        // Solana enforces a 512-byte cap on incoming messages; fail early so the
        // relay fee is not spent on a delivery that will be rejected on Solana.
        if (targetChain == CHAIN_ID_SOLANA && payload.length > SOLANA_MAX_PAYLOAD_BYTES) {
            revert PayloadTooLargeForSolana(payload.length, SOLANA_MAX_PAYLOAD_BYTES);
        }

        // Publish and relay the message to the target chain
        sequence = _publishAndRelay(
            payload,
            CONSISTENCY_LEVEL_INSTANT, // choose safe or finalized based on your needs
            totalCost,
            targetChain,
            msg.sender, // refund address
            signedQuote,
            gasLimit,
            0, // no msg.value forwarding
            "" // no extra relay instructions
        );

        emit GreetingSent(greeting, targetChain, sequence);
    }
}
