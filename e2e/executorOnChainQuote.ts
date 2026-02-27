/**
 * On-chain quote utilities for Wormhole Executor
 *
 * Unlike off-chain quotes which require an API call, on-chain quotes
 * call the ExecutorQuoterRouter contract directly to get pricing.
 */

import { ethers } from 'ethers';

// ExecutorQuoterRouter ABI - only the functions we need
const EXECUTOR_QUOTER_ROUTER_ABI = [
    'function quoteExecution(uint16 dstChain, bytes32 dstAddr, address refundAddr, address quoterAddr, bytes calldata requestBytes, bytes calldata relayInstructions) external view returns (uint256)',
];

// HelloWormholeOnChainQuote ABI - quoteGreeting function
const HELLO_WORMHOLE_OC_ABI = [
    'function quoteGreeting(uint16 targetChain, uint128 gasLimit, address quoterAddress) external view returns (uint256 totalCost)',
    'function sendGreeting(string calldata greeting, uint16 targetChain, uint128 gasLimit, uint256 totalCost, address quoterAddress) external payable returns (uint64 sequence)',
    'function peers(uint16 chainId) external view returns (bytes32)',
    'event GreetingSent(string greeting, uint16 targetChain, uint64 sequence)',
    'event GreetingReceived(string greeting, uint16 senderChain, bytes32 sender)',
];

export interface OnChainQuoteParams {
    targetChain: number;
    gasLimit: bigint;
    quoterAddress: string;
}

export interface OnChainQuoteResult {
    totalCost: bigint;
    quoterAddress: string;
}

/**
 * Get a quote for sending a greeting using the contract's quoteGreeting function
 *
 * This calls the HelloWormholeOnChainQuote contract which internally calls
 * the ExecutorQuoterRouter to get the execution cost.
 */
export async function getOnChainQuote(
    contractAddress: string,
    provider: ethers.Provider,
    params: OnChainQuoteParams,
): Promise<OnChainQuoteResult> {
    console.log('📊 Getting on-chain quote...');
    console.log('  Contract:', contractAddress);
    console.log('  Target chain:', params.targetChain);
    console.log('  Gas limit:', params.gasLimit.toString());
    console.log('  Quoter:', params.quoterAddress);

    const contract = new ethers.Contract(
        contractAddress,
        HELLO_WORMHOLE_OC_ABI,
        provider,
    );

    const totalCost = await contract.quoteGreeting(
        params.targetChain,
        params.gasLimit,
        params.quoterAddress,
    );

    console.log('\n💰 On-chain quote received:');
    console.log(`  Total cost: ${ethers.formatEther(totalCost)} ETH`);

    return {
        totalCost,
        quoterAddress: params.quoterAddress,
    };
}

/**
 * Get HelloWormholeOnChainQuote contract instance
 */
export function getHelloWormholeOnChainQuoteContract(
    address: string,
    signerOrProvider: ethers.Signer | ethers.Provider,
) {
    return new ethers.Contract(
        address,
        HELLO_WORMHOLE_OC_ABI,
        signerOrProvider,
    );
}

export { HELLO_WORMHOLE_OC_ABI };
