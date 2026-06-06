import { ethers } from 'ethers';

// ─────────────────────────────────────────────────────────────────────────────
// 1. Official Uniswap V4 Contract Addresses (Sepolia)
// ─────────────────────────────────────────────────────────────────────────────
export const POOL_MANAGER      = "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543";
export const UNIVERSAL_ROUTER  = "0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b";
export const POSITION_MANAGER  = "0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4";
export const QUOTER            = "0x61b3f2011a92d183c7dbadbda940a7555ccf9227";
export const PERMIT2           = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

// Token Addresses
export const EURC_ADDRESS = "0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4";
export const WETH_ADDRESS = "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14";

// ✅ Lexicographic Sorting: Fixed using BigInt mapping to comply with V4 Core sorting rules
export const [token0, token1] =
  BigInt(ethers.getAddress(EURC_ADDRESS)) < BigInt(ethers.getAddress(WETH_ADDRESS))
    ? [EURC_ADDRESS, WETH_ADDRESS]
    : [WETH_ADDRESS, EURC_ADDRESS];

// Token Decimals Map
const TOKEN_DECIMALS = {
  [EURC_ADDRESS.toLowerCase()]: 6,
  [WETH_ADDRESS.toLowerCase()]: 18,
};

// ─────────────────────────────────────────────────────────────────────────────
// 2. Comprehensive Unified ABIs (Upgraded for V4 PositionManager Specs)
// ─────────────────────────────────────────────────────────────────────────────
export const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
];

export const PERMIT2_ABI = [
  "function approve(address token, address spender, uint160 amount, uint48 expiration) external",
  "function allowance(address owner, address token, address spender) view returns (uint160 amount, uint48 expiration, uint48 nonce)",
];

export const POOL_MANAGER_ABI = [
  "function getSlot0(bytes32 poolId) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
];

export const POSITION_MANAGER_ABI = [
  "function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable",
];

export const QUOTER_ABI = [
  "function quoteExactInput(bytes calldata path, uint256 amountIn) external returns (uint256 amountOut, int24[] memory priceImpacts)"
];

export const UNIVERSAL_ROUTER_ABI = [
  "function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable"
];

export const HOOK_ABI = [
  "function getCurrentVolatility() external view returns (uint256)",
  "function getCurrentFee() external view returns (uint256)",
];

// Pool Settings
export const POOL_CONFIG = {
  fee: 3000,
  tickSpacing: 60,
};

// ─────────────────────────────────────────────────────────────────────────────
// 3. REST API Helpers
// ─────────────────────────────────────────────────────────────────────────────
const API_BASE_URL = "http://localhost:3001/api";

export const hookAPI = {
  async getHookData(poolId = "default") {
    const res = await fetch(`${API_BASE_URL}/hook-data?poolId=${poolId}`);
    if (!res.ok) throw new Error("Failed to fetch hook data");
    return res.json();
  },
  async getStatus() {
    const res = await fetch(`${API_BASE_URL}/hook-data/status`);
    if (!res.ok) throw new Error("Failed to fetch status");
    return res.json();
  },
  async healthCheck() {
    const res = await fetch(`${API_BASE_URL}/health`);
    if (!res.ok) throw new Error("Health check failed");
    return res.json();
  },
};

// ─────────────────────────────────────────────────────────────────────────────
// 4. On-Chain Core Utilities (Tick & Hook State)
// ─────────────────────────────────────────────────────────────────────────────
export const getCurrentTick = async (provider, poolId) => {
  try {
    const poolManager = new ethers.Contract(POOL_MANAGER, POOL_MANAGER_ABI, provider);
    const poolState = await poolManager.getSlot0(poolId);

    if (!poolState || poolState.sqrtPriceX96.toString() === "0") {
      return { success: false, error: "Pool not initialized or lacks liquidity" };
    }

    return {
      success: true,
      tick: Number(poolState.tick),
      sqrtPriceX96: poolState.sqrtPriceX96.toString(),
    };
  } catch (error) {
    console.error("getCurrentTick error:", error);
    return { success: false, error: error.message || "Failed to get slot0 data" };
  }
};

export const getHookDataOnChain = async (provider, hookAddress) => {
  try {
    const hookContract = new ethers.Contract(hookAddress, HOOK_ABI, provider);
    const volatility = await hookContract.getCurrentVolatility().catch(() => null);
    const fee = await hookContract.getCurrentFee().catch(() => null);

    return {
      success: true,
      volatility: volatility ? ethers.formatUnits(volatility, 6) : null,
      fee: fee ? ethers.formatUnits(fee, 4) : null,
    };
  } catch (error) {
    console.error("On-chain hook read error:", error);
    return { success: false, error: error.message };
  }
};

// ─────────────────────────────────────────────────────────────────────────────
// 5. Shared Permit2 Compliance Handler (Exported to eliminate UI dead zones)
// ─────────────────────────────────────────────────────────────────────────────
export const ensurePermit2Compliance = async (signer, tokenAddress, spender, requiredAmount) => {
  const provider = signer.provider;
  const code = await provider.getCode(tokenAddress);
  if (code === "0x" || code === "0x00") {
    throw new Error(`Token contract missing at ${tokenAddress}. Verify network node (Sepolia).`);
  }

  const userAddress = await signer.getAddress();
  const tokenContract = new ethers.Contract(tokenAddress, ERC20_ABI, signer);

  // Step A: Approve Permit2 to pull assets from ERC20 contract
  const currentERC20Allowance = await tokenContract.allowance(userAddress, PERMIT2);
  if (currentERC20Allowance < requiredAmount) {
    console.log(`🔑 Approving Token level to Permit2 Ledger for ${tokenAddress.slice(0, 8)}…`);
    const tx = await tokenContract.approve(PERMIT2, ethers.MaxUint256);
    await tx.wait();
  }

  // Step B: Configure target routing permissions within Permit2 architecture
  const permit2Contract = new ethers.Contract(PERMIT2, PERMIT2_ABI, signer);
  const [allowedAmount] = await permit2Contract.allowance(userAddress, tokenAddress, spender);

  if (allowedAmount < requiredAmount) {
    console.log(`🔑 Granting App/Router clearance inside Permit2 container for ${spender.slice(0, 8)}…`);
    const tokenMaxBits = tokenAddress.toLowerCase() === EURC_ADDRESS.toLowerCase() ? 10n**14n : 10n**25n;
    const tx = await permit2Contract.approve(tokenAddress, spender, tokenMaxBits, 2000000000);
    await tx.wait();
  }
};

// ─────────────────────────────────────────────────────────────────────────────
// 6. Advanced Liquidity Management via PositionManager (Upgraded for V4 Specs)
// ─────────────────────────────────────────────────────────────────────────────
export const addLiquidity = async (signer, hookAddress, tickLower, tickUpper, liquidityDelta) => {
  try {
    if (!signer) throw new Error("Signer is required");
    if (!liquidityDelta || BigInt(liquidityDelta) <= 0n) throw new Error("Liquidity must be non-zero");

    const finalTickLower = Math.min(Number(tickLower), Number(tickUpper));
    const finalTickUpper = Math.max(Number(tickLower), Number(tickUpper));

    const t0Address = ethers.getAddress(token0);
    const t1Address = ethers.getAddress(token1);

    const reqAmount0 = BigInt(liquidityDelta);
    const reqAmount1 = BigInt(liquidityDelta) * (10n ** 12n);

    // Run compliance checks before firing calldata loops
    await ensurePermit2Compliance(signer, t0Address, POSITION_MANAGER, reqAmount0);
    await ensurePermit2Compliance(signer, t1Address, POSITION_MANAGER, reqAmount1);

    const targetHook = hookAddress && hookAddress !== '0xYourHookContractAddress' 
      ? ethers.getAddress(hookAddress) 
      : ethers.ZeroAddress;

    const poolKey = {
      currency0: t0Address,
      currency1: t1Address,
      fee: POOL_CONFIG.fee,
      tickSpacing: POOL_CONFIG.tickSpacing,
      hooks: targetHook,
    };

    const abiCoder = ethers.AbiCoder.defaultAbiCoder();
    
    // ✅ FIX: Match the V4 action payload logic -> MINT_POSITION(0x00) then SETTLE_PAIR(0x11)
    const actions = ethers.concat([
      ethers.getBytes("0x00"), 
      ethers.getBytes("0x11"), 
    ]);

    const UINT128_MAX = (2n ** 128n) - 1n;

    // ✅ FIX: Encoded with uint128 constraints and trailing empty hookData bytes context
    const mintParams = abiCoder.encode(
      [
        "(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)",
        "int24",
        "int24",
        "uint256",   // liquidityDelta
        "uint128",   // amount0Max
        "uint128",   // amount1Max
        "address",   // recipient
        "bytes",     // hookData
      ],
      [poolKey, finalTickLower, finalTickUpper, BigInt(liquidityDelta), UINT128_MAX, UINT128_MAX, await signer.getAddress(), "0x"]
    );

    const settleParams = abiCoder.encode(
      ["address", "address"],
      [poolKey.currency0, poolKey.currency1]
    );

    const unlockData = abiCoder.encode(
      ["bytes", "bytes[]"],
      [actions, [mintParams, settleParams]]
    );

    const posManagerContract = new ethers.Contract(POSITION_MANAGER, POSITION_MANAGER_ABI, signer);
    const deadline = Math.floor(Date.now() / 1000) + 1200;

    console.log("🚀 Calling PositionManager modifyLiquidities (Mint)...");
    const tx = await posManagerContract.modifyLiquidities(unlockData, deadline, { gasLimit: 1200000n });
    const receipt = await tx.wait();

    return { success: true, hash: tx.hash, receipt };
  } catch (error) {
    console.error("addLiquidity error:", error);
    return { success: false, error: error.reason || error.message || "Failed to mint position" };
  }
};

export const removeLiquidity = async (signer, hookAddress, tickLower, tickUpper, liquidityDelta) => {
  try {
    if (!signer) throw new Error("Signer is required");
    if (!liquidityDelta || BigInt(liquidityDelta) <= 0n) throw new Error("Liquidity delta required");

    const finalTickLower = Math.min(Number(tickLower), Number(tickUpper));
    const finalTickUpper = Math.max(Number(tickLower), Number(tickUpper));

    const targetHook = hookAddress && hookAddress !== '0xYourHookContractAddress' 
      ? ethers.getAddress(hookAddress) 
      : ethers.ZeroAddress;

    const poolKey = {
      currency0: ethers.getAddress(token0),
      currency1: ethers.getAddress(token1),
      fee: POOL_CONFIG.fee,
      tickSpacing: POOL_CONFIG.tickSpacing,
      hooks: targetHook,
    };

    const abiCoder = ethers.AbiCoder.defaultAbiCoder();
    
    // ✅ FIX: Match correct decrease actions -> DECREASE_LIQUIDITY(0x02) then TAKE_PAIR(0x10) or similar
    // For standard burns, 0x02 followed by settling matches V4 configuration protocols
    const actions = ethers.concat([
      ethers.getBytes("0x02"), 
      ethers.getBytes("0x12"), // CLOSE/TAKE ACTION FOR ASSET WITHDRAWALS
    ]);

    const burnParams = abiCoder.encode(
      [
        "(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)",
        "int24",
        "int24",
        "uint256",   // liquidityDelta
        "uint128",   // amount0Min
        "uint128",   // amount1Min
        "bytes",     // hookData
      ],
      [poolKey, finalTickLower, finalTickUpper, BigInt(liquidityDelta), 0n, 0n, "0x"]
    );

    const takeParams = abiCoder.encode(
      ["address", "address", "address"],
      [poolKey.currency0, poolKey.currency1, await signer.getAddress()]
    );

    const unlockData = abiCoder.encode(
      ["bytes", "bytes[]"],
      [actions, [burnParams, takeParams]]
    );

    const posManagerContract = new ethers.Contract(POSITION_MANAGER, POSITION_MANAGER_ABI, signer);
    const deadline = Math.floor(Date.now() / 1000) + 1200;

    console.log("📉 Calling PositionManager modifyLiquidities (Burn)...");
    const tx = await posManagerContract.modifyLiquidities(unlockData, deadline, { gasLimit: 1200000n });
    const receipt = await tx.wait();

    return { success: true, hash: tx.hash, receipt };
  } catch (error) {
    console.error("removeLiquidity error:", error);
    return { success: false, error: error.reason || error.message || "Failed to withdraw liquidity" };
  }
};

// ─────────────────────────────────────────────────────────────────────────────
// 7. Swap Operations (Quoting & Routing via Universal Router)
// ─────────────────────────────────────────────────────────────────────────────
export const getSwapQuote = async (provider, amount, direction, hookAddress) => {
  try {
    const zeroForOne = direction === "eurcToWeth";
    const sourceToken = zeroForOne ? EURC_ADDRESS : WETH_ADDRESS;
    const destToken = zeroForOne ? WETH_ADDRESS : EURC_ADDRESS;
    
    const inputDecimals = TOKEN_DECIMALS[sourceToken.toLowerCase()];
    const outputDecimals = TOKEN_DECIMALS[destToken.toLowerCase()];
    const amountIn = ethers.parseUnits(amount, inputDecimals);

    const targetHook = hookAddress && hookAddress !== '0xYourHookContractAddress' 
      ? ethers.getAddress(hookAddress) 
      : ethers.ZeroAddress;

    const abiCoder = ethers.AbiCoder.defaultAbiCoder();
    const path = abiCoder.encode(
      ["address[]", "uint24[]", "int24[]", "address[]"],
      [[sourceToken, destToken], [POOL_CONFIG.fee], [POOL_CONFIG.tickSpacing], [targetHook]]
    );

    const quoterContract = new ethers.Contract(QUOTER, QUOTER_ABI, provider);
    const [amountOut] = await quoterContract.quoteExactInput.staticCall(path, amountIn);
    
    return {
      success: true,
      quote: ethers.formatUnits(amountOut, outputDecimals)
    };
  } catch (error) {
    console.error("Quote execution failed:", error);
    return { success: false, error: error.message || "Quote context calculation rejected" };
  }
};

export const executeSwap = async (signer, amount, direction, hookAddress) => {
  try {
    if (!signer) throw new Error("Signer asset contextualization missing");

    const zeroForOne = direction === "eurcToWeth";
    const sourceToken = ethers.getAddress(zeroForOne ? EURC_ADDRESS : WETH_ADDRESS);
    const destToken = ethers.getAddress(zeroForOne ? WETH_ADDRESS : EURC_ADDRESS);

    const inputDecimals = TOKEN_DECIMALS[sourceToken.toLowerCase()];
    const amountIn = ethers.parseUnits(amount, inputDecimals);

    await ensurePermit2Compliance(signer, sourceToken, UNIVERSAL_ROUTER, amountIn);

    const targetHook = hookAddress && hookAddress !== '0xYourHookContractAddress' 
      ? ethers.getAddress(hookAddress) 
      : ethers.ZeroAddress;

    const routerContract = new ethers.Contract(UNIVERSAL_ROUTER, UNIVERSAL_ROUTER_ABI, signer);
    const commands = ethers.getBytes("0x10"); 
    
    const abiCoder = ethers.AbiCoder.defaultAbiCoder();
    const routerActionInputs = abiCoder.encode(
      ["address", "uint256", "uint256", "address", "address", "uint24", "int24", "address"],
      [
        await signer.getAddress(), 
        amountIn,                  
        0n,                        
        sourceToken,
        destToken,
        POOL_CONFIG.fee,
        POOL_CONFIG.tickSpacing,
        targetHook
      ]
    );

    const inputs = [routerActionInputs];
    const deadline = Math.floor(Date.now() / 1000) + 1200;

    console.log("🔄 Relaying execution commands to Universal Router...");
    const tx = await routerContract.execute(commands, inputs, deadline, { gasLimit: 650000n });
    const receipt = await tx.wait();

    return { success: true, hash: tx.hash, receipt };
  } catch (error) {
    console.error("executeSwap runtime error:", error);
    return { success: false, error: error.message || "Swap transaction reverted" };
  }
};

// ─────────────────────────────────────────────────────────────────────────────
// 8. Unified Export Model (Fixes Destructured and Default Module Imports)
// ─────────────────────────────────────────────────────────────────────────────
const exportPayload = {
  ...hookAPI,
  POSITION_MANAGER,
  ensurePermit2Compliance,
  getCurrentTick,
  getHookDataOnChain,
  addLiquidity,
  removeLiquidity,
  getSwapQuote,
  executeSwap,
};

export default exportPayload;