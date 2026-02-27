// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ExecutorSendReceiveQuoteOnChain} from "wormhole-solidity-sdk/Executor/Integration.sol";
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
 *
 * ## EVM-only
 * On-chain quotes are currently supported for EVM destination chains only.
 * For EVM → Solana, use HelloWormhole (off-chain signed quotes) instead.
 * SVM support will be added in a future update once the on-chain quoter
 * supports Solana pricing.
 */
contract HelloWormholeOnChainQuote is ExecutorSendReceiveQuoteOnChain, AccessControl {
    using SequenceReplayProtectionLib for *;

    bytes32 public constant PEER_ADMIN_ROLE = keccak256("PEER_ADMIN_ROLE");

    // peers[chainId]: the deployed HelloWormholeOnChainQuote contract address on that chain
    //   (left-padded to bytes32). EVM chains only — see contract NatSpec.
    mapping(uint16 => bytes32) public peers;

    constructor(address coreBridge, address executorQuoterRouter)
        ExecutorSendReceiveQuoteOnChain(coreBridge, executorQuoterRouter)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PEER_ADMIN_ROLE, msg.sender);
    }

    event GreetingReceived(string greeting, uint16 senderChain, bytes32 sender);
    event GreetingSent(string greeting, uint16 targetChain, uint64 sequence);

    error NoValueAllowed();

    function _getPeer(uint16 chainId) internal view override returns (bytes32) {
        return peers[chainId];
    }

    /// @notice Register the peer contract address for a destination EVM chain.
    function setPeer(uint16 chainId, bytes32 peerAddress) external onlyRole(PEER_ADMIN_ROLE) {
        peers[chainId] = peerAddress;
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
        string memory greeting = string(payload);
        emit GreetingReceived(greeting, peerChain, peerAddress);
    }

    /**
     * @notice Get a quote for sending a greeting using on-chain quoter
     * @dev EVM destinations only. SVM destination support via on-chain quoter
     *      is not yet verified — use HelloWormhole for EVM→Solana.
     * @param targetChain The Wormhole chain ID of the destination
     * @param gasLimit Gas limit for execution on target chain
     * @param quoterAddress The on-chain quoter contract address
     * @return totalCost The total cost including Wormhole message fee and executor fee
     */
    function quoteGreeting(uint16 targetChain, uint128 gasLimit, address quoterAddress)
        external
        view
        returns (uint256 totalCost)
    {
        bytes32 peerAddress = peers[targetChain];
        require(peerAddress != bytes32(0), "No peer set for target chain");

        bytes memory relayInstructions = RelayInstructionLib.encodeGas(gasLimit, 0);

        bytes memory requestBytes = RequestLib.encodeVaaMultiSigRequest(
            _chainId,
            toUniversalAddress(address(this)),
            0 // sequence placeholder - not needed for quote
        );

        uint256 executorFee = _executorQuoterRouter.quoteExecution(
            targetChain, peerAddress, address(0), quoterAddress, requestBytes, relayInstructions
        );

        totalCost = executorFee + _coreBridge.messageFee();
    }

    /**
     * @notice Send a cross-chain greeting using on-chain quote
     * @dev EVM destinations only. SVM destination support via on-chain quoter
     *      is not yet verified — use HelloWormhole for EVM→Solana.
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
        sequence = _publishAndRelay(
            bytes(greeting),
            CONSISTENCY_LEVEL_INSTANT,
            totalCost,
            targetChain,
            msg.sender,
            quoterAddress,
            gasLimit,
            0,
            ""
        );
        emit GreetingSent(greeting, targetChain, sequence);
    }
}
