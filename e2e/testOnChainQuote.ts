#!/usr/bin/env tsx
/**
 * End-to-end test for HelloWormholeOnChainQuote cross-chain messaging
 *
 * This script demonstrates the on-chain quote Executor integration:
 * 1. Gets a quote from the on-chain quoter contract (no API call needed)
 * 2. Sends a greeting from Sepolia to Base Sepolia using the Executor
 * 3. Tracks VAA signing via Wormhole Scan API
 * 4. Monitors Executor status for automatic relay
 * 5. Verifies the greeting was received on the target chain
 */

import { ethers } from 'ethers';
import {
    configOnChainQuote,
    validateConfigOnChainQuote,
} from './configOnChainQuote.js';
import { getProviderAndWallet, formatGreeting, pollForVAA } from './utils.js';
import { pollForExecutorStatus } from './executor.js';
import { sendGreetingOnChainQuote } from './messagingOnChainQuote.js';

async function main() {
    console.log('🚀 HelloWormholeOnChainQuote E2E Test\n');
    console.log(
        'This test uses ON-CHAIN QUOTES instead of API-based signed quotes.\n',
    );

    // Validate configuration
    try {
        validateConfigOnChainQuote();
    } catch (error: any) {
        console.error('❌', error.message);
        process.exit(1);
    }

    // Format greeting message
    const greeting = formatGreeting('Hello from Sepolia (On-Chain Quote)!');

    // Get current block number on target chain (for event filtering)
    const { provider: baseProvider } = await getProviderAndWallet(
        configOnChainQuote.baseSepolia,
    );
    const currentBlock = await baseProvider.getBlockNumber();

    // Send greeting from Sepolia to Base Sepolia using on-chain quote
    const { receipt, sequence } = await sendGreetingOnChainQuote(
        configOnChainQuote.sepolia,
        configOnChainQuote.baseSepolia,
        greeting,
        configOnChainQuote.quoter.address,
    );

    if (!receipt || receipt.status !== 1) {
        console.error('❌ Failed to send greeting');
        process.exit(1);
    }

    if (sequence === undefined) {
        console.error(
            '❌ Failed to get sequence number from GreetingSent event',
        );
        process.exit(1);
    }

    // Use Wormhole Scan API to track VAA signing
    console.log('\n⏳ Tracking VAA status via Wormhole Scan...');
    const vaaData = await pollForVAA(
        configOnChainQuote.sepolia.wormholeChainId,
        configOnChainQuote.sepolia.helloWormholeAddress,
        Number(sequence),
        'Testnet',
        120000, // 2 minute timeout
    );

    if (!vaaData) {
        console.error('❌ VAA was not signed within timeout period');
        console.log(
            'The transaction may still be processing. Check Wormhole Scan manually:',
        );
        console.log(`https://testnet.wormholescan.io/#/tx/${receipt.hash}`);
        process.exit(1);
    }

    console.log(
        '\n✅ VAA confirmed! Wormhole Guardians have signed the message.',
    );

    // Poll for Executor to process the VAA and check status
    const executorStatus = await pollForExecutorStatus(
        'Sepolia',
        receipt.hash,
        'Testnet',
        60000,
    );

    console.log('\n📊 Executor Status:');
    console.log(JSON.stringify(executorStatus, null, 2));

    // Check if it's an array of relay transactions (success case)
    if (Array.isArray(executorStatus)) {
        const relayTx = executorStatus[0];
        if (relayTx && relayTx.status === 'underpaid') {
            console.log('\n❌ Transaction FAILED: Underpaid!');
            console.log(
                '   The Executor determined the transaction did not send enough value.',
            );
            console.log('\n💰 Payment Details:');
            console.log(
                `   Amount Paid: ${
                    relayTx.requestForExecution?.amtPaid || 'unknown'
                } wei`,
            );
            console.log(
                `   Estimated Cost: ${relayTx.estimatedCost || 'unknown'} wei`,
            );
            if (relayTx.requestForExecution?.amtPaid && relayTx.estimatedCost) {
                const shortfall =
                    BigInt(relayTx.estimatedCost) -
                    BigInt(relayTx.requestForExecution.amtPaid);
                console.log(
                    `   Shortfall: ${shortfall} wei (${ethers.formatEther(
                        shortfall,
                    )} ETH)`,
                );
            }
            console.log('\n💡 Debug with Executor Explorer:');
            console.log(
                `   https://wormholelabs-xyz.github.io/executor-explorer/#/tx/${receipt.hash}?endpoint=https%3A%2F%2Fexecutor-testnet.labsapis.com&env=Testnet`,
            );
            process.exit(1);
        } else if (relayTx && relayTx.status === 'error') {
            console.log('\n❌ Transaction FAILED with error!');
            console.log(
                `   Error: ${
                    relayTx.error || relayTx.failedReason || 'unknown'
                }`,
            );
            console.log('\n💡 Debug with Executor Explorer:');
            console.log(
                `   https://wormholelabs-xyz.github.io/executor-explorer/#/tx/${receipt.hash}?endpoint=https%3A%2F%2Fexecutor-testnet.labsapis.com&env=Testnet`,
            );
            process.exit(1);
        } else if (relayTx && relayTx.status === 'submitted' && relayTx.txs?.length) {
            // "submitted" + txs[] = relay TX included on destination chain (success state)
            console.log('\n✅ Executor successfully relayed the transaction!');
            console.log(`   Destination TX: ${relayTx.txs[0].txHash}`);
            console.log(`   Block: ${relayTx.txs[0].blockNumber}`);
        }
    } else if (executorStatus.error || executorStatus.status === 'timeout') {
        console.log('\n⚠️  Executor issue detected!');
        console.log(
            `   Status: ${executorStatus.error || executorStatus.status}`,
        );
        console.log('\n💡 Debug with Executor Explorer:');
        console.log(
            `   https://wormholelabs-xyz.github.io/executor-explorer/#/tx/${receipt.hash}?endpoint=https%3A%2F%2Fexecutor-testnet.labsapis.com&env=Testnet`,
        );
        process.exit(1);
    }

    // Final summary
    console.log(`\n${'='.repeat(60)}`);
    console.log('🎉 On-Chain Quote E2E Test Complete!');
    console.log(`${'='.repeat(60)}`);
    console.log('\n📋 Summary:');
    console.log(`  Source: Sepolia`);
    console.log(`  Destination: Base Sepolia`);
    console.log(`  TX Hash: ${receipt.hash}`);
    console.log(`  Sequence: ${sequence}`);
    console.log(`  Quoter: ${configOnChainQuote.quoter.address}`);
    console.log(`\n🔗 View on Wormhole Scan:`);
    console.log(`  https://testnet.wormholescan.io/#/tx/${receipt.hash}`);
}

main().catch((error) => {
    console.error('Fatal error:', error);
    process.exit(1);
});
