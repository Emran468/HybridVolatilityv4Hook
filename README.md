# AegisHook — HybridVolatilityv4Hook

> **AegisHook** is a production-grade Uniswap v4 Hook providing real-time dynamic fee adjustment and on-chain MEV/sandwich attack protection — deployed and verified on Unichain Sepolia.
>
> *Aegis: the impenetrable shield of Zeus — protecting liquidity providers from volatility and MEV attackers.*

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.26-blue)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)](https://getfoundry.sh/)
[![Tests](https://img.shields.io/badge/Tests-111%20passed-brightgreen)](https://github.com/Emran468/my-v4-hook)
[![Network](https://img.shields.io/badge/Network-Unichain%20Sepolia-purple)](https://unichain-sepolia.blockscout.com)

---

## Deployed Addresses (Unichain Sepolia — Chain ID 1301)

| Contract | Address |
|----------|---------|
| **HybridVolatilityHook** | [`0xA8B74ADfA5558F27A7c9983D14a302aBE13575c0`](https://unichain-sepolia.blockscout.com/address/0xA8B74ADfA5558F27A7c9983D14a302aBE13575c0) |
| PoolManager | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| SwapRouter | `0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4` |

---

## Test Results

### Local Tests

```
Ran 12 tests  — SandwichSecurityTest      ✅ 12 passed
Ran 46 tests  — VolatilityHookTest (unit) ✅ 46 passed
Ran  5 tests  — VolatilityHookTest (fuzz) ✅  5 passed
Ran 24 tests  — VolatilityInvariantTest   ✅ 24 passed
Ran  7 tests  — SimulateHistoryTest       ✅  7 passed
Ran  7 tests  — EasyPosmTest + liquidity  ✅  7 passed
─────────────────────────────────────────────────────
Total: 101 tests passed, 0 failed
```

### Fork Tests (Unichain Sepolia — Live Network)

```
forge test --match-contract RealTokenIntegrationTest --fork-url unichain_sepolia

[PASS] test_realToken_basicSwap_oneForZero          (gas: 233,918)
[PASS] test_realToken_reverseSwap_zeroForOne        (gas: 256,146)
[PASS] test_realToken_rapidSwaps_feeShouldEscalate  (gas: 291,669)
[PASS] test_realToken_feeDecay_afterBlockWindow     (gas: 296,183)
[PASS] test_realToken_balanceConservation           (gas: 251,986)
[PASS] test_realToken_hookStateUpdate_afterSwap     (gas: 248,090)
[PASS] test_realToken_addRemoveLiquidity            (gas: passed  )
[PASS] test_realToken_multiplePositions             (gas: 579,520)
[PASS] test_realToken_feeStaysHigh_consecutiveSwaps (gas: 397,832)
[PASS] test_realToken_mevPenalty_sameBlock          (gas: 373,663)
─────────────────────────────────────────────────────
Total: 10 fork tests passed, 0 failed
```

**Grand Total: 111 tests passed, 0 failed across local + live fork.**

---

## Overview

AegisHook (contract: `HybridVolatilityHook`) solves two critical problems for liquidity providers on Uniswap v4:

**Problem 1 — Static Fees:** Traditional AMMs charge fixed fees (0.05%, 0.3%, 1%) regardless of market conditions. During high volatility, LPs absorb impermanent loss without adequate fee compensation.

**Problem 2 — MEV & Sandwich Attacks:** Malicious bots systematically front-run and back-run swaps within a single block, extracting value from LPs and ordinary traders. This costs DeFi users hundreds of millions of dollars annually.

AegisHook addresses both problems in a single composable contract with no external dependencies beyond the Uniswap v4 core.

---

## Fee Tiers

| Market Condition | Fee | Basis Points |
|-----------------|-----|-------------|
| Calm / Stable | `BASE_FEE` | **0.30%** (3000) |
| Moderate volatility | `MID_VOLATILE_FEE` | **0.60%** (6000) |
| High volatility | `HIGH_VOLATILE_FEE` | **1.50%** (15000) |
| MEV / Sandwich detected | `MEV_PENALTY_FEE` | **10.00%** (100000) |

Fees automatically decay back to `BASE_FEE` after a chain-specific block decay window, preventing permanent fee elevation.

---

## How It Works

### Dynamic Fee (afterSwap)

```
Swap executes
    │
    ├── Read pre-swap tick (stored in EIP-1153 transient storage by beforeSwap)
    ├── Read post-swap tick from PoolManager
    ├── Compute tickDelta = |postTick - preTick|
    │
    ├── tickDelta > 500 (HIGH threshold) → HIGH_VOLATILE_FEE (1.5%)
    ├── tickDelta > 200 (MID  threshold) → MID_VOLATILE_FEE  (0.6%)
    └── else                             → BASE_FEE           (0.3%)
```

### Sandwich Detection (afterSwap)

```
Per-block SandwichTracker:
    ├── Track firstMove direction for each block
    ├── If currentMove reverses firstMove  → isReversal = true
    ├── If isReversal
    │   AND blockVolume > mevVolumeThreshold    (default: 1 ether)
    │       → isSandwich = true
    │       → apply MEV_PENALTY_FEE (10%)
    │       → set sandwichFlag for this block
    └── All subsequent swaps in this block also receive MEV_PENALTY_FEE
```

### Block Decay

```
On any swap:
    blockDelta = currentBlock - lastBlock
    if blockDelta >= blockDecayWindow → fee resets to BASE_FEE
```

---

## Architecture

```
HybridVolatilityHook (AegisHook)
│
├── beforeSwap()
│     ├── Composability guard (EIP-1153 dirty flag check)
│     ├── Store pre-swap tick in transient storage
│     ├── sandwichFlag set this block? → return MEV_PENALTY_FEE
│     └── Return stored fee (or BASE_FEE if decay window passed)
│
├── afterSwap()
│     ├── Read pre-swap tick from transient storage
│     ├── Compute tick delta, accumulate block volume
│     ├── Update SandwichTracker (firstMove, lastMove, swapCount)
│     ├── Detect sandwich: reversal + volume threshold check
│     ├── Compute and persist new fee to poolStates
│     └── Emit FeeUpdated, HistoryUpdated, SandwichDetected (if applicable)
│
├── afterAddLiquidity() / afterRemoveLiquidity()
│     └── Track LP positions in storedPositions mapping
│
├── afterInitialize()
│     ├── Seed PackedPoolState (lastTick, fee, lastBlock, lastTimestamp)
│     └── Pre-compute deterministic transient storage slot keys
│
└── beforeInitialize()
      └── Return selector (hook address flags enforced by Uniswap v4)
```

---

## Hook Permissions

```solidity
Hooks.Permissions({
    beforeInitialize:                true,
    afterInitialize:                 true,
    beforeAddLiquidity:              false,
    afterAddLiquidity:               true,
    beforeRemoveLiquidity:           false,
    afterRemoveLiquidity:            true,
    beforeSwap:                      true,
    afterSwap:                       true,
    beforeDonate:                    false,
    afterDonate:                     false,
    beforeSwapReturnDelta:           false,
    afterSwapReturnDelta:            false,
    afterAddLiquidityReturnDelta:    false,
    afterRemoveLiquidityReturnDelta: false
})
```

---

## Multi-Chain Support

| Network | Chain ID | Block Decay Window |
|---------|----------|--------------------|
| Unichain Mainnet | 130 | 300 blocks |
| Ethereum Mainnet | 1 | 25 blocks |
| Base Mainnet | 8453 | 150 blocks |
| Optimism Mainnet | 10 | 150 blocks |
| Arbitrum One | 42161 | 1000 blocks |
| Sepolia Testnet | 11155111 | 25 blocks |
| **Unichain Sepolia** | **1301** | **300 blocks** |
| Base Sepolia | 84532 | 150 blocks |

The constructor validates the correct PoolManager address against the `ChainRegistry` at deploy time. Deployment on an unsupported chain reverts. Local Anvil (chain ID 31337) skips this check for testing.

---

## Gas Profile

| Test | Gas Used |
|------|----------|
| Basic swap with hook | 233,918 |
| MEV penalty swap | 373,663 |
| Multiple positions swap | 579,520 |
| Max hook gas (invariant tested) | < 1,500,000 |

Optimized via `via_ir = true`, `optimizer_runs = 1,000,000`, and single-slot `uint256` packing of the entire `SandwichTracker`.

---

## Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh/) installed

### Clone & Build

```bash
git clone https://github.com/Emran468/my-v4-hook
cd my-v4-hook
forge install
forge build
```

### Run Tests

```bash
# All local tests
forge test -vvvv

# Individual suites
forge test --match-contract SandwichSecurityTest -vvvv
forge test --match-contract VolatilityHookTest -vvvv
forge test --match-contract VolatilityInvariantTest -vvvv
forge test --match-contract SimulateHistoryTest -vvvv

# Fork integration tests (requires RPC)
forge test --match-contract RealTokenIntegrationTest \
           --fork-url $UNICHAIN_SEPOLIA_RPC -vvvv
```

### Deploy

```bash
forge script script/DeployUnichainSepolia.s.sol \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --broadcast \
  --private-key $PRIVATE_KEY
```

---

## Configuration

```solidity
// Owner-only — can be called at any time
hook.setTickThresholds(
    uint256 high,             // tick delta for HIGH_VOLATILE_FEE       (default: 500)
    uint256 mid,              // tick delta for MID_VOLATILE_FEE        (default: 200)
    uint256 volumeThreshold,  // min block volume for sandwich penalty   (default: 1 ether)
    uint256 sandwichThreshold // min tick delta for sandwich penalty     (default: 80)
);
// Constraint: high > mid, otherwise reverts
```

---

## Events

```solidity
event FeeUpdated(PoolId indexed poolId, uint24 newFee);
event SandwichDetected(PoolId indexed poolId, int24 firstMove, int24 lastMove, uint256 blockVolume, uint24 feeApplied);
event LiquidityUpdated(address indexed sender, PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint128 newLiquidity, bool isAdding);
event HistoryUpdated(PoolId indexed poolId, int24 newTick, uint256 blockNumber, uint256 timestamp);
event DeployedOnChain(uint256 indexed chainId, string chainName, uint64 blockDecayWindow);
```

---

## Security Properties

- `onlyPoolManager` on all hook callbacks — only the Uniswap v4 PoolManager can invoke them
- EIP-1153 transient storage dirty flag prevents composability violations within a single unlock
- `nonReentrant` guard on all liquidity callbacks
- Sandwich state resets every block — flags never persist across blocks
- `onlyOwner` guards all admin functions; ownership is transferable to a multisig

---

## Test Suite Summary

| Suite | Tests | Type |
|-------|-------|------|
| `VolatilityHookTest` | 51 | Unit + Fuzz |
| `SandwichSecurityTest` | 12 | Security |
| `VolatilityInvariantTest` | 24 | Invariant (256 runs × 6400 calls each) |
| `SimulateHistoryTest` | 7 | Simulation |
| `RealTokenIntegrationTest` | 10 | Fork — Live Unichain Sepolia |
| **Total** | **111** | |

---

## Roadmap

- [ ] Mainnet deployment — Unichain, Base, Optimism
- [ ] Independent security audit
- [ ] Developer integration guide with consumer hook examples
- [ ] Governance mechanism for threshold updates
- [ ] Full-match Sourcify verification on mainnet

---

## License

MIT — see [LICENSE](./LICENSE)

---

## Author

**Md Emran** — Independent blockchain developer, Bangladesh
GitHub: [@Emran468](https://github.com/Emran468)
Contract: [`0xA8B74ADfA5558F27A7c9983D14a302aBE13575c0`](https://unichain-sepolia.blockscout.com/address/0xA8B74ADfA5558F27A7c9983D14a302aBE13575c0)
