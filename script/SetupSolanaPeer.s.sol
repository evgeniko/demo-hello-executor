// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {HelloWormhole} from "src/HelloWormhole.sol";

/**
 * @title SetupSolanaPeer
 * @notice Sets up a Solana program as a peer on the EVM HelloWormhole contract
 *
 * For SVM ↔ EVM messaging, peer registration requires TWO separate addresses:
 *
 *   1. peers[Solana]       = PROGRAM ID (bytes32, no padding)
 *      Used by the Executor to route relay requests — must be an executable account.
 *
 *   2. vaaEmitters[Solana] = EMITTER PDA (bytes32, no padding)
 *      Used to verify incoming VAAs from Solana — the PDA that signs Wormhole messages.
 *      Derived as: PDA(["emitter"], programId)
 *
 * To compute these values from a Solana program ID (TypeScript):
 *
 *   const programId = new PublicKey("7eiTqf1b1dNwpzn27qEr4eGSWnuon2fJTbnTuWcFifZG");
 *   const [emitterPda] = PublicKey.findProgramAddressSync([Buffer.from("emitter")], programId);
 *
 *   const programIdBytes32 = '0x' + Buffer.from(programId.toBytes()).toString('hex');
 *   const emitterPdaBytes32 = '0x' + Buffer.from(emitterPda.toBytes()).toString('hex');
 *
 * Usage:
 *   export HELLO_WORMHOLE_SEPOLIA_CROSSVM=0x...
 *   export SOLANA_PROGRAM_ID_BYTES32=0x...  (program ID as bytes32, no padding)
 *   export SOLANA_EMITTER_PDA_BYTES32=0x... (emitter PDA as bytes32, no padding)
 *   forge script script/SetupSolanaPeer.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
 */
contract SetupSolanaPeerScript is Script {
    // Wormhole chain ID for Solana
    uint16 constant CHAIN_ID_SOLANA = 1;

    // Default: program ID of 7eiTqf1b1dNwpzn27qEr4eGSWnuon2fJTbnTuWcFifZG (bytes32, no padding)
    bytes32 constant DEFAULT_SOLANA_PROGRAM_ID = 0x62cf7e5a219d24a831e51b2c2417fa898920b930fd1c6947f3a4fc8feec1020f;

    // Default: emitter PDA of program 7eiTqf1b1dNwpzn27qEr4eGSWnuon2fJTbnTuWcFifZG
    // Derived via: PublicKey.findProgramAddressSync([Buffer.from("emitter")], programId)
    bytes32 constant DEFAULT_SOLANA_EMITTER_PDA = 0x58235d29729e44920df367836a92ab77fcee36b7a27b03304cd699f5eb0efae5;

    function setUp() public {}

    function run() public {
        address localContract = vm.envAddress("HELLO_WORMHOLE_SEPOLIA_CROSSVM");

        // Try to get custom values, fall back to defaults
        bytes32 solanaProgramId;
        try vm.envBytes32("SOLANA_PROGRAM_ID_BYTES32") returns (bytes32 val) {
            solanaProgramId = val;
        } catch {
            solanaProgramId = DEFAULT_SOLANA_PROGRAM_ID;
        }

        bytes32 solanaEmitterPda;
        try vm.envBytes32("SOLANA_EMITTER_PDA_BYTES32") returns (bytes32 val) {
            solanaEmitterPda = val;
        } catch {
            solanaEmitterPda = DEFAULT_SOLANA_EMITTER_PDA;
        }

        console.log("Setting up Solana peer on HelloWormhole:", localContract);
        console.log("  programId:", vm.toString(solanaProgramId));
        console.log("  emitterPDA:", vm.toString(solanaEmitterPda));

        vm.startBroadcast();

        HelloWormhole hello = HelloWormhole(localContract);

        // Register program ID for executor routing (dstAddr in relay requests)
        hello.setPeer(CHAIN_ID_SOLANA, solanaProgramId);

        // Register emitter PDA for incoming VAA verification
        hello.setVaaEmitter(CHAIN_ID_SOLANA, solanaEmitterPda);

        console.log("Done.");

        vm.stopBroadcast();
    }
}
