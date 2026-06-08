# Uniswap V4 Hybrid Volatility Hook 🦄⚡

An advanced Uniswap V4 hook that dynamically adjusts pool swap fees based on real-time price volatility. This project includes extensive fuzzing and stateful invariant testing using the Foundry framework to ensure protocol solvency, state consistency, and gas efficiency.

---

## 📖 Overview

The **Hybrid Volatility Hook** protects liquidity providers (LPs) during periods of high market turbulence by increasing the swap fee when the price moves aggressively. Once the market stabilizes, the fee gradually decays back to the base rate.

This repository serves as a proof-of-concept for dynamic fee mechanisms in decentralized exchanges, with a heavy emphasis on **Smart Contract Security** and **Invariant Testing**.

### Core Logic & Fee Tiers

The hook calculates the absolute tick movement (price impact) between swaps and applies dynamic fees:

| Condition | Fee | Rate |
|---|---|---|
| Tick delta ≤ 200 | `BASE_FEE` = 3000 | 0.30% |
| Tick delta > 200 | `MID_VOLATILE_FEE` = 6000 | 0.60% |
| Tick delta > 500 | `HIGH_VOLATILE_FEE` = 15000 | 1.50% |

**Time Decay:** If no swap occurs within **5 minutes (300 seconds)**, the fee automatically resets to `BASE_FEE`, regardless of prior volatility.

---

## 🏗️ Architecture

```
my-v4-hook/
├── src/
│   ├── HybridVolatilityHook.sol   # Core hook logic — dynamic fee & volatility tracking
│   └── V4LiquiditySystem.sol      # On-chain proxy contract for liquidity management
├── test/                          # Foundry invariant & fuzz tests
│   ├── invariant/
│   │   ├── HookHandler.sol        # Fuzz handler — swap & liquidity actions
│   │   └── VolatilityInvariantTest.sol  # Stateful invariant test suite
│   └── fork/
│       └── RealTokenIntegrationTest.sol # Sepolia fork tests (WETH/USDC)
├── script/                        # Foundry deployment scripts
├── frontend/                      # UI interface
├── lib/                           # Forge dependencies (forge install)
├── proxydeploy.js                 # Deploys V4LiquiditySystem → get proxy address
├── initializePool.js              # Initializes the Uniswap V4 pool
├── addLiquidity.js                # Adds liquidity via proxy contract
├── foundry.toml                   # Foundry configuration
└── .env                           # RPC endpoints & private keys
```

### How the Two Contracts Work Together

```
proxydeploy.js
     │
     ▼
V4LiquiditySystem.sol (deployed) ← proxy address saved to .env
     │
     │  poolManager.unlock(data)
     │       ↓
     │  unlockCallback()
     │       ↓
     │  sync → transfer → settle   (token accounting)
     ▼
IPoolManager.modifyLiquidity()
     │
     ▼
HybridVolatilityHook.sol
  ├── beforeAddLiquidity()   → liquidity tracking
  ├── afterRemoveLiquidity() → delta accounting
  ├── beforeSwap()           → tick capture + fee decay check
  └── afterSwap()            → tickDelta → volatility tier → update fee
```

> **Why V4LiquiditySystem?** Uniswap V4 does not allow direct liquidity additions. All state changes must go through `poolManager.unlock()` with a callback. `V4LiquiditySystem` is the on-chain proxy that implements this `unlockCallback` pattern, enabling `addLiquidity.js` to add liquidity from Node.js scripts.

---

### Hook Lifecycle Callbacks

- **`beforeSwap`** — Captures the current tick before execution and applies the decayed fee if ≥ 300s have elapsed since the last swap.
- **`afterSwap`** — Measures `tickDelta` (post-swap vs. pre-swap tick), computes the new volatility tier, and persists the updated fee state for the next swap.
- **`beforeAddLiquidity` / `afterRemoveLiquidity`** — Tracks liquidity additions and removals using precise delta accounting to ensure system solvency.

---

## 🛡️ Security & Invariant Testing

This project includes a robust suite of stateful invariant tests (`StdInvariant`) to simulate extreme edge cases, boundary ticks, and reentrancy attempts.

### Key Invariants Tested

| Invariant | Description |
|---|---|
| `invariant_tickIsValid` | Pool tick never exceeds `TickMath.MIN_TICK` or `TickMath.MAX_TICK` |
| `invariant_liquidityAccounting` | `Initial + Added - Removed == currentLiquidity`. No leaks. |
| `invariant_zeroMovementNoFeeHike` | Zero-tick-delta trades strictly return the base fee |
| `invariant_resetToBaseFeeAfterLongTime` | Validates the 300s timestamp decay logic |
| `invariant_hookGasEfficiency` | Hook execution stays below the 1,500,000 gas limit |
| `invariant_noReentrancy` | Reentrancy attempts always fail |
| `invariant_ghostLiquidityConservation` | Ghost variable cross-check on liquidity math |
| Int256 Overflow Protection | Boundary blocking and amount clamping prevent `type(int256).min` panics during fuzzing |

---

## 🚀 Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Node.js](https://nodejs.org/) v18+

### Installation

```bash
git clone <your-repo-url>
cd <your-repo-folder>
forge install
npm install
```

### Environment Setup

Copy `.env.example` to `.env` and fill in your values:

```env
SEPOLIA_RPC=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
PRIVATE_KEY=0x...
POOL_MANAGER_ADDRESS=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
LIQUIDITY_SYSTEM_ADDRESS=   # filled after running proxydeploy.js
HOOK_ADDRESS=               # filled after running proxydeploy.js
```

### Running Tests

```bash
# Run all invariant tests
forge test

# Run Sepolia fork integration tests
forge test --match-contract RealTokenIntegrationTest --fork-url $SEPOLIA_RPC -vvvv

# Run with gas reporting
forge test --gas-report
```

### Deployment & Pool Setup

Run these scripts **in order**:

```bash
# Step 1: Deploy HybridVolatilityHook + V4LiquiditySystem (proxy)
node proxydeploy.js
# → Copy the output addresses into your .env file

# Step 2: Initialize the Uniswap V4 pool
node initializePool.js

# Step 3: Add liquidity via the proxy contract
node addLiquidity.js
```

> **Important:** Before running `addLiquidity.js`, approve the `V4LiquiditySystem` proxy address to spend your tokens:
> ```javascript
> await token0.approve(LIQUIDITY_SYSTEM_ADDRESS, ethers.MaxUint256);
> await token1.approve(LIQUIDITY_SYSTEM_ADDRESS, ethers.MaxUint256);
> ```

---

## 🔐 Security Considerations

- All fee transitions are bounded to prevent griefing via artificial volatility.
- The 5-minute decay window mitigates fee manipulation through time-delayed trades.
- Int256 overflow paths are fully guarded and fuzz-tested at boundary values.
- Gas limits are enforced per hook call to prevent DoS via block-stuffing.
- Reentrancy is blocked at the `IPoolManager` level and verified via invariant tests.

---

## 📜 License

This project is licensed under the terms found in [LICENSE](./LICENSE).
