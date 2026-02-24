// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {HelloWormhole} from "src/HelloWormhole.sol";

/**
 * @title SetupSolanaPeer
 * @notice Sets up a Solana program as a peer on the EVM HelloWormhole contract
 *
 * IMPORTANT: Register the Solana program's **emitter PDA**, NOT the program ID!
 * The emitter PDA is derived on-chain as: PDA(["emitter"], programId)
 *
 * To derive the emitter PDA from a Solana program ID:
 *   // TypeScript (using @solana/web3.js)
 *   const [emitterPda] = PublicKey.findProgramAddressSync(
 *       [Buffer.from("emitter")],
 *       new PublicKey("5qAHNEvdL7gAj49q4jm1718h6tCGX5q8KBurM9iiQ4Rp")
 *   );
 *   // Then convert to bytes32: Buffer.from(emitterPda.toBytes()).toString('hex')
 *
 * Usage:
 *   export HELLO_WORMHOLE_SEPOLIA_CROSSVM=0x...
 *   export SOLANA_PROGRAM_ID_BYTES32=0x... (emitter PDA as bytes32, NOT the program ID)
 *   forge script script/SetupSolanaPeer.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
 */
contract SetupSolanaPeerScript is Script {
    // Wormhole chain ID for Solana
    uint16 constant CHAIN_ID_SOLANA = 1;

    // Default: emitter PDA of program 5qAHNEvdL7gAj49q4jm1718h6tCGX5q8KBurM9iiQ4Rp
    // Derived via PDA(["emitter"], programId) — this is what Wormhole sees as the sender
    bytes32 constant DEFAULT_SOLANA_EMITTER_PDA = 0x47c51f36dcb45b5bbdba739f0fa993b142f908f06095def3775428b46361b9d3;

    function setUp() public {}

    function run() public {
        address localContract = vm.envAddress("HELLO_WORMHOLE_SEPOLIA_CROSSVM");

        // Try to get custom emitter PDA, fall back to default
        bytes32 solanaEmitterPda;
        try vm.envBytes32("SOLANA_PROGRAM_ID_BYTES32") returns (bytes32 val) {
            solanaEmitterPda = val;
        } catch {
            solanaEmitterPda = DEFAULT_SOLANA_EMITTER_PDA;
        }

        console.log("Setting up Solana peer on Sepolia HelloWormhole");
        console.log("Local contract:", localContract);
        console.log("Solana emitter PDA (bytes32):", vm.toString(solanaEmitterPda));
        console.log("Wormhole chain ID:", CHAIN_ID_SOLANA);

        vm.startBroadcast();

        HelloWormhole hello = HelloWormhole(localContract);
        hello.setPeer(CHAIN_ID_SOLANA, solanaEmitterPda);

        console.log("Solana peer set successfully!");

        vm.stopBroadcast();
    }
}
