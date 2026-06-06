const express = require("express");
const cors = require("cors");
const { ethers } = require("ethers");

const app = express();
app.use(cors());

// ─────────────────────────────────────────────────────────────────────────────
// ✅ Official Uniswap V4 Sepolia Testnet Config
// ─────────────────────────────────────────────────────────────────────────────
const SEPOLIA_CONFIG = {
  // আপনার ডিপ্লয় করা হুক অ্যাড্রেসটি এখানে বসাবেন
  HOOK_ADDRESS: ethers.getAddress("0x88Bb6571DB4f0eb66831E1De0804D033686ab0c0".toLowerCase()),
  
  // Official Uniswap V4 Sepolia Core Addresses
  POOL_MANAGER_ADDRESS: ethers.getAddress("0xE03A1074c86CFeDd5C142C4F04F1a1536e203543".toLowerCase()),
  EURC_ADDRESS: ethers.getAddress("0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4".toLowerCase()), 
  WETH_ADDRESS: ethers.getAddress("0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14".toLowerCase()),
  
  FEE: 3000,
  TICK_SPACING: 60,
  RPC_URL: "https://ethereum-sepolia-rpc.publicnode.com",
  POOL_ID: "" // অন-চেইন ইভেন্ট লগ থেকে অটোমেটিক জেনারেট/লোড হবে
};

const provider = new ethers.JsonRpcProvider(SEPOLIA_CONFIG.RPC_URL);

// ─────────────────────────────────────────────────────────────────────────────
// ✅ Comprehensive ABIs aligned with V4 Official Releases
// ─────────────────────────────────────────────────────────────────────────────
const poolManagerABI = [
  // Official V4 slot0 call signature is 'getSlot0'
  "function getSlot0(bytes32 poolId) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
  // Official V4 Core Core Initialize Event layout
  "event Initialize(bytes32 indexed poolId, address indexed token0, address indexed token1, uint24 fee, int24 tickSpacing, address hooks)"
];

const hookABI = [
  "function getCurrentVolatility() external view returns (uint256)",
  "function getCurrentFee() external view returns (uint256)"
];

const poolManagerContract = new ethers.Contract(SEPOLIA_CONFIG.POOL_MANAGER_ADDRESS, poolManagerABI, provider);
const hookContract = new ethers.Contract(SEPOLIA_CONFIG.HOOK_ADDRESS, hookABI, provider);

// Data runtime cache storage
let historicalData = [];
let lastKnownTick = 0;
let totalSwaps = 0;
let lastUpdateTime = Date.now();

// ─────────────────────────────────────────────────────────────────────────────
// 🌟 Auto Fetch Pool ID via On-Chain Logs (Official V4 Update)
// ─────────────────────────────────────────────────────────────────────────────
async function autoFetchPoolId() {
  try {
    console.log("⏳ Syncing network logs to lookup active Uniswap V4 Pool ID...");
    
    // Lexicographical sorting rule mandatory requirement for V4 Core Pools
    const [t0, t1] = SEPOLIA_CONFIG.EURC_ADDRESS.toLowerCase() < SEPOLIA_CONFIG.WETH_ADDRESS.toLowerCase()
      ? [SEPOLIA_CONFIG.EURC_ADDRESS, SEPOLIA_CONFIG.WETH_ADDRESS]
      : [SEPOLIA_CONFIG.WETH_ADDRESS, SEPOLIA_CONFIG.EURC_ADDRESS];

    // Create event indexing filter template
    const filter = poolManagerContract.filters.Initialize(null, t0, t1);
    const currentBlock = await provider.getBlockNumber();
    
    // Safety check block parameters window bounds
    const logs = await poolManagerContract.queryFilter(filter, currentBlock - 30000, currentBlock);

    if (logs.length > 0) {
      SEPOLIA_CONFIG.POOL_ID = logs[logs.length - 1].args.poolId;
      console.log(`🎯 Found Official On-Chain Pool ID Match: ${SEPOLIA_CONFIG.POOL_ID}`);
    } else {
      // Hardcoded fallback backup parameter just in case
      SEPOLIA_CONFIG.POOL_ID = "0xde8425f83a965c99cfa40f2ebee4fdde37fd6224743168e3b3b33c72b474e767";
      console.log(`ℹ️ Initialize events not tracked within window. Fallback ID: ${SEPOLIA_CONFIG.POOL_ID}`);
    }
  } catch (err) {
    console.error("⚠️ Error querying logs index system:", err.message);
    SEPOLIA_CONFIG.POOL_ID = "0xde8425f83a965c99cfa40f2ebee4fdde37fd6224743168e3b3b33c72b474e767";
  }
}

function getFeePercentage(feeValue) {
  return parseFloat((feeValue / 10000).toFixed(2));
}

// ─────────────────────────────────────────────────────────────────────────────
// On-Chain Metric Synchronizer
// ─────────────────────────────────────────────────────────────────────────────
async function getActualOnChainData() {
  let currentTick = 0;
  let currentFee = SEPOLIA_CONFIG.FEE;
  let volatility = 0;

  if (!SEPOLIA_CONFIG.POOL_ID) return { currentTick, currentFee, volatility, timestamp: Date.now() };

  try {
    const poolIdBytes32 = SEPOLIA_CONFIG.POOL_ID;
    
    // 1. Fetch live metrics from PoolManager slot0 layout
    try {
      const slot0Data = await poolManagerContract.getSlot0(poolIdBytes32);
      if (slot0Data && slot0Data.tick !== undefined) {
        currentTick = Number(slot0Data.tick);
      }
    } catch (e) {
      console.debug("Slot0 fetching skipped or inactive.");
    }
    
    // 2. Fetch live metrics from hook runtime contract
    try {
      const hookFee = await hookContract.getCurrentFee();
      if (hookFee !== undefined) currentFee = Number(hookFee);
    } catch (e) {
      try {
        const poolIdFee = await hookContract.getCurrentFee(poolIdBytes32);
        if (poolIdFee !== undefined) currentFee = Number(poolIdFee);
      } catch (innerErr) { /* Non-fee hook fallback execution */ }
    }
    
    // 3. Fetch live volatility records
    try {
      const vol = await hookContract.getCurrentVolatility();
      if (vol !== undefined) volatility = Number(vol);
    } catch (e) {
      try {
        const poolIdVol = await hookContract.getCurrentVolatility(poolIdBytes32);
        if (poolIdVol !== undefined) volatility = Number(poolIdVol);
      } catch (innerErr) { /* Volatility logic omitted on target hook state */ }
    }
    
  } catch (globalError) {
    console.error("Global metrics retrieval engine error:", globalError.message);
  }

  return { currentTick, currentFee, volatility, timestamp: Date.now() };
}

async function updateHistoricalData() {
  const onChain = await getActualOnChainData();
  const tickMovement = lastKnownTick === 0 ? 0 : Math.abs(onChain.currentTick - lastKnownTick);
  
  // Arbitrary counter loop threshold for evaluation tracking context
  if (tickMovement > 5) totalSwaps++;
  
  const historyPoint = {
    time: new Date().toLocaleTimeString(),
    timestamp: Date.now(),
    tick: onChain.currentTick,
    tickMovement,
    fee: onChain.currentFee,
    volatility: onChain.volatility
  };
  
  historicalData.push(historyPoint);
  if (historicalData.length > 50) historicalData.shift();
  
  lastKnownTick = onChain.currentTick;
  lastUpdateTime = Date.now();
  
  app.locals.latestOnChain = onChain;
  app.locals.tickMovement = tickMovement;
  app.locals.historicalData = historicalData;
  
  console.log(`📊 Sync Active Pool Node Data [ID: ${SEPOLIA_CONFIG.POOL_ID.slice(0,10)}...] Tick: ${onChain.currentTick} | Fee: ${onChain.currentFee}`);
}

async function startOnChainSync() {
  await updateHistoricalData();
  setInterval(async () => {
    await updateHistoricalData();
  }, 10000); // 10-second tick sync index
}

// ─────────────────────────────────────────────────────────────────────────────
// --- Express REST Endpoints Routing ---
// ─────────────────────────────────────────────────────────────────────────────
app.get("/api/hook-data", async (req, res) => {
  try {
    const onChain = app.locals.latestOnChain || await getActualOnChainData();
    const tickMovement = app.locals.tickMovement || 0;
    const history = app.locals.historicalData || historicalData;
    
    res.json({
      success: true,
      poolId: SEPOLIA_CONFIG.POOL_ID, 
      hookAddress: SEPOLIA_CONFIG.HOOK_ADDRESS,
      status: {
        currentTick: onChain.currentTick,
        currentFee: onChain.currentFee,
        currentFeePercent: getFeePercentage(onChain.currentFee),
        tickMovement: tickMovement,
        totalSwaps: totalSwaps,
        lastUpdate: onChain.timestamp || lastUpdateTime
      },
      tokens: {
        token0: SEPOLIA_CONFIG.EURC_ADDRESS,
        token1: SEPOLIA_CONFIG.WETH_ADDRESS,
        token0Symbol: "EURC",
        token1Symbol: "WETH"
      },
      history: history.slice(-20)
    });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

app.get("/api/hook-config", (req, res) => {
  res.json({
    success: true,
    poolId: SEPOLIA_CONFIG.POOL_ID, 
    hookAddress: SEPOLIA_CONFIG.HOOK_ADDRESS,
    poolManagerAddress: SEPOLIA_CONFIG.POOL_MANAGER_ADDRESS
  });
});

app.get("/api/health", (req, res) => {
  res.json({ success: true, timestamp: Date.now(), syncActive: !!SEPOLIA_CONFIG.POOL_ID });
});

// ─────────────────────────────────────────────────────────────────────────────
// Server Bootstrap Initialization System Runtime
// ─────────────────────────────────────────────────────────────────────────────
const PORT = 3001;
autoFetchPoolId().then(() => {
  startOnChainSync();
  app.listen(PORT, () => {
    console.log(`\n🚀 Compliant V4 Smart Backend active at http://localhost:${PORT}`);
    console.log(`📡 Broadcast pipelines configuration synced to official Sepolia contracts layout.\n`);
  });
});