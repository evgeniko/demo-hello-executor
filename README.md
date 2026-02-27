# Hello Wormhole Executor Demo

Cross-chain messaging with Wormhole Executor, demonstrating both **off-chain** and **on-chain** quote methods.

This repo covers two use cases:
- **EVM ↔ EVM** — both off-chain and on-chain quotes, Sepolia ↔ Base Sepolia
- **EVM ↔ Solana** — off-chain quotes only (see [Cross-VM section](#cross-vm-evm--solana))

> **License:** Code provided "AS IS", without warranties. Audit before mainnet deployment.

## Contracts

| Contract                    | Quote Method    | Base Class                         | Constructor Param      |
| --------------------------- | --------------- | ---------------------------------- | ---------------------- |
| `HelloWormhole`             | Off-chain (API) | `ExecutorSendReceiveQuoteOffChain` | `executor`             |
| `HelloWormholeOnChainQuote` | On-chain        | `ExecutorSendReceiveQuoteOnChain`  | `executorQuoterRouter` |

**Off-chain quotes** require fetching a `signedQuote` from the Executor API before sending:

```solidity
function sendGreeting(..., bytes calldata signedQuote) external payable;
```

**On-chain quotes** use a quoter contract directly—no API call needed:

```solidity
function quoteGreeting(uint16 targetChain, uint128 gasLimit, address quoterAddress) external view returns (uint256);
function sendGreeting(..., address quoterAddress) external payable;
```

> **Note:** On-chain quotes currently support EVM destination chains only.
> For EVM → Solana, use `HelloWormhole` (off-chain signed quotes) instead.
> Solana support will be added once the on-chain quoter supports SVM pricing.

## Deployed Contracts (Testnet)

| Chain        | HelloWormhole (Off-chain)                    | HelloWormholeOnChainQuote                    |
| ------------ | -------------------------------------------- | -------------------------------------------- |
| Sepolia      | `0x8f6E15d9A4d0abCe4814c7d86D5B741A91bDCC04` | `0x86B9182095dca2bdFDFeC7614Af6EC5fAfa910a6` |
| Base Sepolia | `0xdF781F7473a1A7C20C1e5fC5f427Fa712dafB698` | `0x8Be172f2575fe38560bcF0587Ae4269Cb4CC3D18` |

**On-chain Quoter:** `0x5241C9276698439fEf2780DbaB76fEc90B633Fbd`

## Installation

```bash
forge install   # Solidity dependencies
npm install     # TypeScript/E2E dependencies
```

---

## EVM ↔ EVM

### Building an Executor Integration

#### 1. Choose Your Base Contract

```solidity
// Off-chain quotes (requires API call for signedQuote)
import {ExecutorSendReceiveQuoteOffChain} from "wormhole-solidity-sdk/Executor/Integration.sol";

// On-chain quotes (query quoter contract directly)
import {ExecutorSendReceiveQuoteOnChain} from "wormhole-solidity-sdk/Executor/Integration.sol";

// Both methods supported
import {ExecutorSendReceiveQuoteBoth} from "wormhole-solidity-sdk/Executor/Integration.sol";
```

Also available: `ExecutorSendQuote*` (send-only) and `ExecutorReceive` (receive-only) variants.

#### 2. Implement Constructor

```solidity
// Off-chain: pass executor address
constructor(address coreBridge, address executor)
    ExecutorSendReceiveQuoteOffChain(coreBridge, executor) {}

// On-chain: pass executorQuoterRouter address
constructor(address coreBridge, address executorQuoterRouter)
    ExecutorSendReceiveQuoteOnChain(coreBridge, executorQuoterRouter) {}
```

#### 3. Implement Required Functions

```solidity
// Peer management
function _getPeer(uint16 chainId) internal view override returns (bytes32) {
    return peers[chainId];
}

// Replay protection (sequence-based for finalized VAAs)
function _replayProtect(uint16 emitterChainId, bytes32 emitterAddress, uint64 sequence, bytes calldata)
    internal override {
    SequenceReplayProtectionLib.replayProtect(emitterChainId, emitterAddress, sequence);
}

// Handle incoming messages
function _executeVaa(bytes calldata payload, uint32, uint16 peerChain, bytes32 peerAddress, uint64, uint8)
    internal override {
    string memory greeting = string(payload);
    emit GreetingReceived(greeting, peerChain, peerAddress);
}
```

#### 4. Send Messages

```solidity
// Off-chain quote version
sequence = _publishAndRelay(payload, consistencyLevel, totalCost, targetChain, refundAddr,
    signedQuote, gasLimit, msgVal, extraInstructions);

// On-chain quote version
sequence = _publishAndRelay(payload, consistencyLevel, totalCost, targetChain, refundAddr,
    quoterAddress, gasLimit, msgVal, extraInstructions);
```

### Deployment

```bash
# Deploy
forge script script/HelloWormholeOnChainQuote.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
forge script script/HelloWormholeOnChainQuote.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --verify

# Set peers (after updating .env with deployed addresses)
forge script script/SetupPeersOnChainQuote.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
forge script script/SetupPeersOnChainQuote.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
```

### E2E Testing

```bash
cd e2e
cp .env.example .env  # Fill in private keys and contract addresses
npx tsx test.ts              # Off-chain quote (Sepolia → Base Sepolia)
npx tsx testOnChainQuote.ts  # On-chain quote  (Sepolia → Base Sepolia)
```

---

## Cross-VM: EVM ↔ Solana

Uses `HelloWormhole` (off-chain quotes) — on-chain quotes do not yet support Solana destinations.

See the [Solana demo repo](https://github.com/evgeniko/demo-hello-executor-solana) for the Solana-side implementation.

### Peer Registration

For EVM ↔ Solana, peer registration on the EVM side requires **two separate addresses** because the Executor uses `peers[chainId]` as a routing address (must be an executable program), while incoming VAAs carry the **emitter PDA** as their source:

```solidity
// 1. Program ID → executor routing (must be an executable account on Solana)
hello.setPeer(CHAIN_ID_SOLANA, solanaProgramIdBytes32);

// 2. Emitter PDA → VAA verification (PDA(["emitter"], programId))
hello.setVaaEmitter(CHAIN_ID_SOLANA, solanaEmitterPdaBytes32);
```

Run `script/SetupSolanaPeer.s.sol` to register both in one step. For EVM↔EVM, only `setPeer()` is needed.

Derive both Solana addresses from your program ID:
```typescript
const programId = new PublicKey("7eiTqf1b1dNwpzn27qEr4eGSWnuon2fJTbnTuWcFifZG");
const [emitterPda] = PublicKey.findProgramAddressSync([Buffer.from("emitter")], programId);

const programIdBytes32  = '0x' + Buffer.from(programId.toBytes()).toString('hex');
const emitterPdaBytes32 = '0x' + Buffer.from(emitterPda.toBytes()).toString('hex');
```

### Sending to Solana

Use `sendGreetingWithMsgValue` with `msgValue` in **lamports** to cover rent and fees on Solana:

```solidity
// msgValue covers rent + fees on Solana (~0.015 SOL = 15_000_000 lamports)
sequence = sendGreetingWithMsgValue(
    greeting,
    1,              // Wormhole chain ID for Solana
    500000,         // compute units (not gas)
    15_000_000,     // msgValue in lamports
    totalCost,
    signedQuote
);
```

> **Message size limit:** The Solana receiver enforces a **512-byte** max on greeting messages
> (`GREETING_MAX_LENGTH` in `receive_greeting.rs`). Messages longer than 512 bytes will be
> accepted on Sepolia but fail on Solana with `InvalidMessage`.

### Deployment

```bash
# Deploy HelloWormhole (cross-VM variant)
forge script script/HelloWormhole.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify

# Register Solana as a peer (both program ID and emitter PDA)
forge script script/SetupSolanaPeer.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
```

### E2E Testing

```bash
cd e2e
cp .env.example .env  # Fill in HELLO_WORMHOLE_SEPOLIA_CROSSVM and Solana peer addresses
npx tsx sendToSolana.ts      # EVM → Solana
# For Solana → EVM, run sendToSepolia.ts from the Solana demo repo
```

---

## Testing

```bash
forge test -vvv                                                  # All tests
forge test --match-contract HelloWormholeOnChainQuoteTest -vvv   # On-chain quote tests only
```

## Key Concepts

| Concept                 | Description                                                                  |
| ----------------------- | ---------------------------------------------------------------------------- |
| **Chain IDs**           | Wormhole uses its own IDs: `CHAIN_ID_SEPOLIA`, `CHAIN_ID_BASE_SEPOLIA`, etc. |
| **Universal Addresses** | Cross-chain addresses as `bytes32` via `toUniversalAddress()`                |
| **Consistency Levels**  | `1`=Instant, `200`=Finalized, `201`=Safe                                     |

## Resources

- [Wormhole Docs](https://wormhole.com/docs)
- [Solidity SDK](https://github.com/wormhole-foundation/wormhole-solidity-sdk)
- [Executor Documentation](https://wormhole.com/docs/protocol/infrastructure/relayer/#executor)
- [Solana demo repo](https://github.com/evgeniko/demo-hello-executor-solana)
