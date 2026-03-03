// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {HelloWormhole} from "../src/HelloWormhole.sol";
import {TestnetChainConstants} from "wormhole-solidity-sdk/testing/ChainConsts.sol";
import {CHAIN_ID_SEPOLIA, CHAIN_ID_BASE_SEPOLIA, CHAIN_ID_SOLANA} from "wormhole-solidity-sdk/constants/Chains.sol";

// Exposes _executeVaa for unit-testing the payload decoding logic.
contract HelloWormholeHarness is HelloWormhole {
    constructor(address coreBridge, address executor) HelloWormhole(coreBridge, executor) {}

    function executeVaa(bytes calldata payload, uint16 peerChain, bytes32 peerAddress) external {
        _executeVaa(payload, 0, peerChain, peerAddress, 0, 0);
    }
}

contract HelloWormholeTest is Test {
    HelloWormhole public helloWormholeSepolia;
    HelloWormhole public helloWormholeBaseSepolia;
    HelloWormholeHarness public harness;

    uint256 sepoliaFork;
    uint256 baseSepoliaFork;

    function setUp() public {
        // Create forks for Sepolia and Base Sepolia
        sepoliaFork = vm.createFork("https://ethereum-sepolia.publicnode.com");
        baseSepoliaFork = vm.createFork("https://sepolia.base.org");

        // Deploy on Sepolia fork
        vm.selectFork(sepoliaFork);
        address sepoliaCoreBridge = TestnetChainConstants._coreBridge(CHAIN_ID_SEPOLIA);
        address sepoliaExecutor = address(0x2); // No executor constant available, keeping mock

        helloWormholeSepolia = new HelloWormhole(sepoliaCoreBridge, sepoliaExecutor);
        harness = new HelloWormholeHarness(sepoliaCoreBridge, sepoliaExecutor);

        // Deploy on Base Sepolia fork
        vm.selectFork(baseSepoliaFork);
        address baseSepoliaCoreBridge = TestnetChainConstants._coreBridge(CHAIN_ID_BASE_SEPOLIA);
        address baseSepoliaExecutor = address(0x2); // No executor constant available, keeping mock

        helloWormholeBaseSepolia = new HelloWormhole(baseSepoliaCoreBridge, baseSepoliaExecutor);
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

    function test_SetSolanaPeer() public {
        vm.selectFork(sepoliaFork);

        // For SVM peers, TWO addresses must be registered:
        //   peers[chainId]       = program ID (executor routing, must be executable)
        //   vaaEmitters[chainId] = emitter PDA (incoming VAA verification)
        uint16 CHAIN_ID_SOLANA = 1;
        // Program ID: 7eiTqf1b1dNwpzn27qEr4eGSWnuon2fJTbnTuWcFifZG
        bytes32 solanaProgramId = bytes32(0x62cf7e5a219d24a831e51b2c2417fa898920b930fd1c6947f3a4fc8feec1020f);
        // Emitter PDA: PDA(["emitter"], programId) = 6w49u8Z4D3uqwMrxHF6XXKGUVAuKhkVu6WFarMgamscY
        bytes32 solanaEmitterPda = bytes32(0x58235d29729e44920df367836a92ab77fcee36b7a27b03304cd699f5eb0efae5);

        helloWormholeSepolia.setPeer(CHAIN_ID_SOLANA, solanaProgramId);
        helloWormholeSepolia.setVaaEmitter(CHAIN_ID_SOLANA, solanaEmitterPda);

        assertEq(helloWormholeSepolia.peers(CHAIN_ID_SOLANA), solanaProgramId);
        assertEq(helloWormholeSepolia.vaaEmitters(CHAIN_ID_SOLANA), solanaEmitterPda);
    }

    function test_SendGreetingRevertsWhenPayloadExceedsSolanaLimit() public {
        vm.selectFork(sepoliaFork);

        bytes32 solanaProgramId = bytes32(0x62cf7e5a219d24a831e51b2c2417fa898920b930fd1c6947f3a4fc8feec1020f);
        helloWormholeSepolia.setPeer(CHAIN_ID_SOLANA, solanaProgramId);

        // 513-byte string — one byte over the 512-byte Solana cap
        string memory tooBig = string(new bytes(513));

        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(HelloWormhole.PayloadTooLargeForSolana.selector, 513, 512));
        helloWormholeSepolia.sendGreetingWithMsgValue{value: 0.01 ether}(
            tooBig, CHAIN_ID_SOLANA, 500_000, 15_000_000, 0.01 ether, ""
        );
    }

    function test_ExecuteVaaSolanaPayloadStripsHeader() public {
        vm.selectFork(sepoliaFork);

        // Simulate a Solana Hello payload: 0x01 | u16_BE(len) | utf8 message
        string memory message = "GM from Berlin from Chain Solana";
        bytes memory msgBytes = bytes(message);
        bytes memory payload = abi.encodePacked(uint8(0x01), uint16(msgBytes.length), msgBytes);

        bytes32 emitterPda = bytes32(0x58235d29729e44920df367836a92ab77fcee36b7a27b03304cd699f5eb0efae5);

        vm.expectEmit(true, true, true, true);
        emit HelloWormhole.GreetingReceived(message, CHAIN_ID_SOLANA, emitterPda);
        harness.executeVaa(payload, CHAIN_ID_SOLANA, emitterPda);
    }

    function test_ExecuteVaaSolanaPayloadRevertsOnBadHeader() public {
        vm.selectFork(sepoliaFork);

        // Payload missing the 0x01 type tag (e.g. Alive message with tag 0x00)
        bytes memory payload = abi.encodePacked(uint8(0x00), bytes32(0));
        bytes32 emitterPda = bytes32(0x58235d29729e44920df367836a92ab77fcee36b7a27b03304cd699f5eb0efae5);

        vm.expectRevert(bytes("HelloWormhole: expected Solana Hello payload"));
        harness.executeVaa(payload, CHAIN_ID_SOLANA, emitterPda);
    }

    function test_SendGreetingWithMsgValueRevertsWithMockExecutor() public {
        vm.selectFork(sepoliaFork);

        // Register a Solana peer (program ID for executor routing)
        uint16 CHAIN_ID_SOLANA = 1;
        bytes32 solanaPeer = bytes32(0x62cf7e5a219d24a831e51b2c2417fa898920b930fd1c6947f3a4fc8feec1020f);
        helloWormholeSepolia.setPeer(CHAIN_ID_SOLANA, solanaPeer);

        // This call reverts at the executor layer because tests use a mock executor.
        // The test validates callable surface for SVM-specific msgValue path.
        uint128 gasLimit = 500000;
        uint128 msgValue = 15_000_000; // lamports

        // Verify the function exists and is callable (will revert due to mock executor,
        // but confirms ABI compatibility)
        vm.deal(address(this), 1 ether);
        vm.expectRevert(); // Expected: mock executor can't process
        helloWormholeSepolia.sendGreetingWithMsgValue{value: 0.01 ether}(
            "Hello Solana!",
            CHAIN_ID_SOLANA,
            gasLimit,
            msgValue,
            0.01 ether,
            "" // empty signed quote - will fail but proves function exists
        );
    }
}
