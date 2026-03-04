// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {HelloWormholeOnChainQuote} from "../src/HelloWormholeOnChainQuote.sol";
import {TestnetChainConstants} from "wormhole-solidity-sdk/testing/ChainConsts.sol";
import {CHAIN_ID_SEPOLIA, CHAIN_ID_BASE_SEPOLIA} from "wormhole-solidity-sdk/constants/Chains.sol";

contract HelloWormholeOnChainQuoteTest is Test {
    HelloWormholeOnChainQuote public helloWormholeSepolia;
    HelloWormholeOnChainQuote public helloWormholeBaseSepolia;

    // ExecutorQuoterRouter addresses from testnet deployment
    address constant SEPOLIA_EXECUTOR_QUOTER_ROUTER = 0xc0C35D7bfBc4175e0991Ae294f561b433eA4158f;
    address constant BASE_SEPOLIA_EXECUTOR_QUOTER_ROUTER = 0x2507d6899C3D4b93BF46b555d0cB401f44065772;

    // On-chain quoter public key/address
    address constant QUOTER_ADDRESS = 0x5241C9276698439fEf2780DbaB76fEc90B633Fbd;

    uint256 sepoliaFork;
    uint256 baseSepoliaFork;

    function setUp() public {
        // Create forks for Sepolia and Base Sepolia
        sepoliaFork = vm.createFork("https://ethereum-sepolia.publicnode.com");
        baseSepoliaFork = vm.createFork("https://sepolia.base.org");

        // Deploy on Sepolia fork
        vm.selectFork(sepoliaFork);
        address sepoliaCoreBridge = TestnetChainConstants._coreBridge(CHAIN_ID_SEPOLIA);

        helloWormholeSepolia = new HelloWormholeOnChainQuote(sepoliaCoreBridge, SEPOLIA_EXECUTOR_QUOTER_ROUTER);

        // Deploy on Base Sepolia fork
        vm.selectFork(baseSepoliaFork);
        address baseSepoliaCoreBridge = TestnetChainConstants._coreBridge(CHAIN_ID_BASE_SEPOLIA);

        helloWormholeBaseSepolia =
            new HelloWormholeOnChainQuote(baseSepoliaCoreBridge, BASE_SEPOLIA_EXECUTOR_QUOTER_ROUTER);
    }

    function test_DeploymentOnSepolia() public {
        vm.selectFork(sepoliaFork);

        // Verify the contract was deployed correctly
        assertTrue(address(helloWormholeSepolia) != address(0));

        // Verify the deployer has the admin role
        assertTrue(helloWormholeSepolia.hasRole(helloWormholeSepolia.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(helloWormholeSepolia.hasRole(helloWormholeSepolia.PEER_ADMIN_ROLE(), address(this)));
    }

    function test_DeploymentOnBaseSepolia() public {
        vm.selectFork(baseSepoliaFork);

        // Verify the contract was deployed correctly
        assertTrue(address(helloWormholeBaseSepolia) != address(0));

        // Verify the deployer has the admin role
        assertTrue(helloWormholeBaseSepolia.hasRole(helloWormholeBaseSepolia.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(helloWormholeBaseSepolia.hasRole(helloWormholeBaseSepolia.PEER_ADMIN_ROLE(), address(this)));
    }

    function test_SetPeer() public {
        vm.selectFork(sepoliaFork);

        bytes32 peerAddress = bytes32(uint256(uint160(address(helloWormholeBaseSepolia))));

        // Set Base Sepolia as a peer
        helloWormholeSepolia.setPeer(CHAIN_ID_BASE_SEPOLIA, peerAddress);

        // Verify peer was set
        assertEq(helloWormholeSepolia.peers(CHAIN_ID_BASE_SEPOLIA), peerAddress);
    }

    function test_SetPeerRevertsForNonAdmin() public {
        vm.selectFork(sepoliaFork);

        bytes32 peerAddress = bytes32(uint256(uint160(address(helloWormholeBaseSepolia))));
        address nonAdmin = address(0x123);

        // Try to set peer as non-admin
        vm.prank(nonAdmin);
        vm.expectRevert();
        helloWormholeSepolia.setPeer(CHAIN_ID_BASE_SEPOLIA, peerAddress);
    }

    function test_QuoteGreetingRequiresPeer() public {
        vm.selectFork(sepoliaFork);

        // Should revert when no peer is set
        vm.expectRevert("No peer set for target chain");
        helloWormholeSepolia.quoteGreeting(
            CHAIN_ID_BASE_SEPOLIA,
            200000, // gas limit
            QUOTER_ADDRESS
        );
    }

    function test_QuoteGreetingWithPeer() public {
        vm.selectFork(sepoliaFork);

        // Set peer first
        bytes32 peerAddress = bytes32(uint256(uint160(address(helloWormholeBaseSepolia))));
        helloWormholeSepolia.setPeer(CHAIN_ID_BASE_SEPOLIA, peerAddress);

        // Get quote - this will call the actual on-chain quoter
        uint256 quote = helloWormholeSepolia.quoteGreeting(
            CHAIN_ID_BASE_SEPOLIA,
            200000, // gas limit
            QUOTER_ADDRESS
        );

        // Quote should be greater than 0 (includes at least the Wormhole message fee)
        assertGt(quote, 0, "Quote should be non-zero");
    }

    function test_SendGreetingEmitsEvent() public {
        vm.selectFork(sepoliaFork);

        // Set peer first
        bytes32 peerAddress = bytes32(uint256(uint160(address(helloWormholeBaseSepolia))));
        helloWormholeSepolia.setPeer(CHAIN_ID_BASE_SEPOLIA, peerAddress);

        // Get quote
        uint256 totalCost = helloWormholeSepolia.quoteGreeting(CHAIN_ID_BASE_SEPOLIA, 200000, QUOTER_ADDRESS);

        // Fund the test contract
        vm.deal(address(this), totalCost);

        // Expect the GreetingSent event
        vm.expectEmit(false, false, false, true);
        emit HelloWormholeOnChainQuote.GreetingSent("Hello from test!", CHAIN_ID_BASE_SEPOLIA, 0);

        // Send greeting
        helloWormholeSepolia.sendGreeting{value: totalCost}(
            "Hello from test!", CHAIN_ID_BASE_SEPOLIA, 200000, totalCost, QUOTER_ADDRESS
        );
    }

    function test_SendGreetingReturnsSequence() public {
        vm.selectFork(sepoliaFork);

        // Set peer first
        bytes32 peerAddress = bytes32(uint256(uint160(address(helloWormholeBaseSepolia))));
        helloWormholeSepolia.setPeer(CHAIN_ID_BASE_SEPOLIA, peerAddress);

        // Get quote
        uint256 totalCost = helloWormholeSepolia.quoteGreeting(CHAIN_ID_BASE_SEPOLIA, 200000, QUOTER_ADDRESS);

        // Fund the test contract
        vm.deal(address(this), totalCost);

        // Verify the call succeeds without reverting and returns a sequence number
        uint64 sequence = helloWormholeSepolia.sendGreeting{value: totalCost}(
            "Hello!", CHAIN_ID_BASE_SEPOLIA, 200000, totalCost, QUOTER_ADDRESS
        );
        assertTrue(sequence < type(uint64).max);
    }
}
