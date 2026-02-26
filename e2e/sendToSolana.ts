#!/usr/bin/env tsx
/**
 * Send greeting from Sepolia to Solana via Executor
 */

import { ethers } from 'ethers';
import * as dotenv from 'dotenv';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { Connection, PublicKey } from '@solana/web3.js';
import { createRelayInstructions } from './relay.js';
import { parseSignedQuote, calculateEstimatedCost } from './executor.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
dotenv.config({ path: join(__dirname, '.env') });

// Configuration
const SEPOLIA_RPC = process.env.SEPOLIA_RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com';
const HELLO_WORMHOLE = process.env.HELLO_WORMHOLE_SEPOLIA_CROSSVM || '0x15cEeB2C089D19E754463e1697d69Ad11A6e8841';
const PRIVATE_KEY = process.env.PRIVATE_KEY_SEPOLIA!;

// Solana delivery verification
const SOLANA_RPC = process.env.SOLANA_DEVNET_RPC || 'https://api.devnet.solana.com';
// HelloExecutor Solana program ID — receives the message
const SOLANA_PROGRAM_ID = process.env.HELLO_EXECUTOR_SOLANA_PROGRAM_ID || '7eiTqf1b1dNwpzn27qEr4eGSWnuon2fJTbnTuWcFifZG';

// Chain IDs
const CHAIN_ID_SOLANA = 1;
const CHAIN_ID_SEPOLIA = 10002;

// Executor API
const EXECUTOR_API = 'https://executor-testnet.labsapis.com/v0';

// Solana-specific: msgValue in LAMPORTS for rent, priority fees, etc.
// Based on NTT demo: 10_000_000 + 1_500_000 = 11,500,000 lamports (~0.0115 SOL)
const SOLANA_MSG_VALUE_LAMPORTS = 15_000_000n; // 0.015 SOL - a bit more for safety

// HelloWormhole ABI (just the functions we need)
const ABI = [
    'function sendGreeting(string greeting, uint16 targetChain, uint128 gasLimit, uint256 totalCost, bytes signedQuote) external payable returns (uint64)',
    'function sendGreetingWithMsgValue(string greeting, uint16 targetChain, uint128 gasLimit, uint128 msgValue, uint256 totalCost, bytes signedQuote) external payable returns (uint64)',
    'event GreetingSent(string greeting, uint16 targetChain, uint64 sequence)',
];

interface QuoteResponse {
    signedQuote: string;
    estimatedCost?: string;
}

interface QuoteWithCost extends QuoteResponse {
    estimatedCost: string;
    parsedQuote: ReturnType<typeof parseSignedQuote>;
}

interface ExecutorStatusItem {
    status: string;
    txs?: Array<{ txHash?: string }>;
    failureCause?: string;
}

async function getExecutorQuote(
    srcChain: number,
    dstChain: number,
    gasLimit: number = 500000,
    msgValueLamports: bigint = 0n
): Promise<QuoteWithCost> {
    // Create relay instructions with gasLimit and msgValue
    // For Solana destinations, msgValue should be in LAMPORTS
    const relayInstructions = createRelayInstructions(BigInt(gasLimit), msgValueLamports);
    
    console.log(`\n📋 Relay Instructions:`);
    console.log(`   gasLimit: ${gasLimit} (compute units)`);
    console.log(`   msgValue: ${msgValueLamports} lamports (${Number(msgValueLamports) / 1e9} SOL)`);
    console.log(`   encoded:  ${relayInstructions}`);
    
    const response = await fetch(`${EXECUTOR_API}/quote`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ 
            srcChain, 
            dstChain, 
            gasLimit,
            relayInstructions,  // Include relay instructions for proper quote
        }),
    });

    if (!response.ok) {
        throw new Error(`Failed to get quote: ${await response.text()}`);
    }

    const data = (await response.json()) as QuoteResponse;
    
    // Parse quote for debugging/logging
    const parsed = parseSignedQuote(data.signedQuote);
    
    // Use the API's estimatedCost if available - it includes msgValue properly
    // Only fall back to our calculation if API doesn't provide it
    const apiEstimatedCost = data.estimatedCost ? BigInt(data.estimatedCost) : null;
    const calculatedCost = calculateEstimatedCost(parsed, BigInt(gasLimit));
    
    console.log(`   API estimatedCost: ${apiEstimatedCost ? apiEstimatedCost.toString() : 'not provided'}`);
    console.log(`   Our calculation: ${calculatedCost.toString()}`);
    
    return {
        ...data,
        estimatedCost: (apiEstimatedCost || calculatedCost).toString(),
        parsedQuote: parsed,
    };
}

async function checkStatus(txHash: string): Promise<ExecutorStatusItem | null> {
    const response = await fetch(`${EXECUTOR_API}/status/tx`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ chainId: CHAIN_ID_SEPOLIA, txHash }),
    });

    if (!response.ok) return null;
    const data = (await response.json()) as ExecutorStatusItem[];
    return data[0] || null;
}

/**
 * Poll the Solana received PDA to confirm on-chain delivery.
 *
 * The `received` PDA is created by the HelloExecutor program when it processes
 * the VAA. Its existence proves that:
 *  1. The Executor posted the VAA to Wormhole Core Bridge on Solana
 *  2. HelloExecutor's receive_greeting instruction executed successfully
 *  3. Replay protection is now in place for this (chain, sequence) pair
 *
 * Seeds: ["received", emitter_chain_le_u16, sequence_le_u64]
 */
async function pollSolanaDelivery(
    emitterChain: number,  // Wormhole chain ID of the sender (10002 for Sepolia)
    sequence: bigint,      // VAA sequence from the GreetingSent event
    timeoutMs = 120_000,
): Promise<{ delivered: boolean; pdaAddress: string }> {
    const connection = new Connection(SOLANA_RPC, 'confirmed');
    const programId = new PublicKey(SOLANA_PROGRAM_ID);

    const chainBuffer = Buffer.alloc(2);
    chainBuffer.writeUInt16LE(emitterChain);
    const seqBuffer = Buffer.alloc(8);
    seqBuffer.writeBigUInt64LE(sequence);

    const [receivedPda] = PublicKey.findProgramAddressSync(
        [Buffer.from('received'), chainBuffer, seqBuffer],
        programId,
    );
    const pdaAddress = receivedPda.toBase58();

    console.log(`\n🔍 Polling Solana received PDA: ${pdaAddress}`);
    console.log(`   (chain=${emitterChain}, seq=${sequence})`);

    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        process.stdout.write('.');
        const info = await connection.getAccountInfo(receivedPda).catch(() => null);
        if (info) {
            console.log('\n✅ Delivered on Solana! received PDA exists.');
            return { delivered: true, pdaAddress };
        }
        await new Promise(r => setTimeout(r, 5000));
    }

    console.log('\n⚠️  Timed out waiting for Solana delivery — PDA not yet created.');
    console.log(`   Check manually: solana account ${pdaAddress} --url devnet`);
    return { delivered: false, pdaAddress };
}

async function main() {
    const greeting = process.argv[2] || 'Hello Solana from Sepolia! 🌉';
    
    console.log('🚀 Sending Greeting: Sepolia → Solana\n');
    console.log(`Message: "${greeting}"`);

    // Setup provider and wallet
    const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC);
    const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
    console.log(`\nWallet: ${wallet.address}`);

    const balance = await provider.getBalance(wallet.address);
    console.log(`Balance: ${ethers.formatEther(balance)} ETH`);

    // Get quote with Solana-specific msgValue in lamports
    console.log('\n📊 Getting Executor quote...');
    const gasLimit = 500000; // For Solana, this is compute units
    // Pass msgValue in LAMPORTS - this tells the Executor how much SOL to use for rent/fees
    const quote = await getExecutorQuote(CHAIN_ID_SEPOLIA, CHAIN_ID_SOLANA, gasLimit, SOLANA_MSG_VALUE_LAMPORTS);
    console.log(`   Signed Quote: ${quote.signedQuote.slice(0, 60)}...`);

    // Use the API's estimated cost directly - it properly includes msgValue
    // Add 10% buffer to be safe
    const apiCost = BigInt(quote.estimatedCost);
    const estimatedCost = apiCost * 110n / 100n;  // 10% buffer
    
    console.log(`   Parsed Quote Params:`);
    console.log(`     baseFee: ${quote.parsedQuote.baseFee}`);
    console.log(`     dstGasPrice: ${quote.parsedQuote.dstGasPrice}`);
    console.log(`     srcPrice: ${quote.parsedQuote.srcPrice}`);
    console.log(`     dstPrice: ${quote.parsedQuote.dstPrice}`);
    console.log(`   API Estimated Cost: ${ethers.formatEther(apiCost)} ETH`);
    console.log(`   With 10% buffer: ${ethers.formatEther(estimatedCost)} ETH (${estimatedCost} wei)`);

    // Create contract instance
    const contract = new ethers.Contract(HELLO_WORMHOLE, ABI, wallet);

    // Send greeting with msgValue for Solana (in lamports)
    console.log('\n📤 Sending transaction with msgValue for Solana...');
    console.log(`   msgValue: ${SOLANA_MSG_VALUE_LAMPORTS} lamports (${Number(SOLANA_MSG_VALUE_LAMPORTS) / 1e9} SOL)`);
    const tx = await contract.sendGreetingWithMsgValue(
        greeting,
        CHAIN_ID_SOLANA,
        gasLimit,
        SOLANA_MSG_VALUE_LAMPORTS,  // msgValue in lamports for Solana
        estimatedCost,
        quote.signedQuote,
        { value: estimatedCost }
    );

    console.log(`TX Hash: ${tx.hash}`);
    console.log(`Explorer: https://sepolia.etherscan.io/tx/${tx.hash}`);

    // Wait for confirmation
    console.log('\n⏳ Waiting for confirmation...');
    const receipt = await tx.wait();
    console.log(`✅ Confirmed in block ${receipt.blockNumber}`);

    // Parse GreetingSent event — capture sequence for Solana PDA verification
    let vaaSequence: bigint | undefined;
    const iface = new ethers.Interface(ABI);
    for (const log of receipt.logs) {
        try {
            const parsed = iface.parseLog({ topics: log.topics as string[], data: log.data });
            if (parsed?.name === 'GreetingSent') {
                vaaSequence = BigInt(parsed.args[2]);
                console.log(`\n📨 GreetingSent event:`);
                console.log(`   Message: ${parsed.args[0]}`);
                console.log(`   Target Chain: ${parsed.args[1]}`);
                console.log(`   Sequence: ${vaaSequence}`);
            }
        } catch {}
    }

    // Poll executor status.
    // The Executor API terminal states are:
    //   "submitted" + txs[] → relay TX included on destination chain (success)
    //   "error"             → relay failed (execution reverted, etc.)
    //   "underpaid"         → insufficient payment
    // Non-terminal: "pending", "processing".
    // Note: the Executor never emits "completed"; "submitted" is the delivered state.
    console.log('\n⏳ Waiting for Executor relay...');
    let executorDelivered = false;
    for (let i = 0; i < 24; i++) { // 2 minutes max
        await new Promise(r => setTimeout(r, 5000));
        process.stdout.write('.');

        const status = await checkStatus(tx.hash);
        if (status) {
            if (status.status === 'submitted' && status.txs?.length) {
                console.log('\n\n🎉 Executor delivered! Solana TX:');
                console.log(`   ${status.txs[0].txHash}`);
                console.log(`   https://explorer.solana.com/tx/${status.txs[0].txHash}?cluster=devnet`);
                executorDelivered = true;
                break;
            } else if (status.status === 'error' || status.status === 'aborted') {
                console.log(`\n\n❌ Relay failed: ${status.failureCause || status.status}`);
                break;
            } else if (status.status === 'underpaid') {
                console.log('\n\n❌ Relay underpaid. Increase SOLANA_MSG_VALUE_LAMPORTS or retry with a fresh quote.');
                break;
            } else {
                process.stdout.write(`(${status.status})`);
            }
        }
    }

    // Independently verify on-chain delivery by checking the Solana received PDA.
    // This is the ground truth: PDA existence proves receive_greeting ran successfully.
    if (vaaSequence !== undefined) {
        const result = await pollSolanaDelivery(CHAIN_ID_SEPOLIA, vaaSequence);
        if (result.delivered) {
            console.log(`   received PDA: ${result.pdaAddress}`);
            console.log(`   Explorer: https://explorer.solana.com/account/${result.pdaAddress}?cluster=devnet`);
        }
    } else {
        console.log('\n⚠️  Could not parse GreetingSent event — skipping Solana delivery check');
    }

    console.log('\n' + '─'.repeat(60));
    console.log('Links:');
    console.log(`  Sepolia TX:  https://sepolia.etherscan.io/tx/${tx.hash}`);
    console.log(`  Wormholescan: https://wormholescan.io/#/tx/${tx.hash}?network=Testnet`);
}

main().catch(console.error);
