const { ethers } = require("ethers");

const SEPOLIA_RPC_URL             = "https://ethereum-sepolia-rpc.publicnode.com";
const PRIVATE_KEY                 = "0xff2fc42f64114cc432a27a8290b0c9b8e9fe2ebc3afdde90863ddff6051ed3fc"; 

const POOL_MANAGER_ADDRESS        = "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543";
const EURC_ADDRESS                = "0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4";
const WETH_ADDRESS                = "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14";

// আপনার সর্বশেষ ভেরিফাইড হুক অ্যাড্রেস
const HOOK_ADDRESS                = "0xF9c2Ec66C5D7a8CEaf8d2d8122fA4f07249CBFC0";

const FEE                         = 8388608; // Dynamic Fee Flag + 3000 base fee
const TICK_SPACING                = 60;

// 🚨 FIX: Ethers v6 এর অবজেক্ট প্যারামিটার রিড করার সুবিধার্থে ইন্টারফেইস স্পষ্ট করা হলো
const POOL_MANAGER_ABI = [
  {
    "inputs": [
      {
        "components": [
          { "internalType": "address", "name": "currency0", "type": "address" },
          { "internalType": "address", "name": "currency1", "type": "address" },
          { "internalType": "uint24", "name": "fee", "type": "uint24" },
          { "internalType": "int24", "name": "tickSpacing", "type": "int24" },
          { "internalType": "address", "name": "hooks", "type": "address" }
        ],
        "internalType": "struct PoolKey",
        "name": "key",
        "type": "tuple"
      },
      { "internalType": "uint160", "name": "sqrtPriceX96", "type": "uint160" }
    ],
    "name": "initialize",
    "outputs": [
      { "internalType": "int24", "name": "tick", "type": "int24" }
    ],
    "stateMutability": "external",
    "type": "function"
  }
];

async function main() {
  console.log("📡 Connecting to Sepolia Testnet...");
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const wallet   = new ethers.Wallet(PRIVATE_KEY, provider);
  console.log(`👤 Wallet Address: ${wallet.address}`);

  const token0 = EURC_ADDRESS.toLowerCase() < WETH_ADDRESS.toLowerCase() ? EURC_ADDRESS : WETH_ADDRESS;
  const token1 = EURC_ADDRESS.toLowerCase() < WETH_ADDRESS.toLowerCase() ? WETH_ADDRESS : EURC_ADDRESS;

  // 🚨 FIX: অ্যারের পরিবর্তে কড়াভাবে Named Object পাস করা হলো
  const poolKey = {
    currency0: ethers.getAddress(token0),
    currency1: ethers.getAddress(token1),
    fee: parseInt(FEE),
    tickSpacing: parseInt(TICK_SPACING),
    hooks: ethers.getAddress(HOOK_ADDRESS)
  };

  const sqrtPriceX96 = "3961408125713216879677197516800"; 

  console.log("\n==================================================");
  console.log("⚙️  🎯 INITIALIZING UNISWAP V4 POOL KEY DATA:");
  console.log(`   • Currency 0: ${poolKey.currency0}`);
  console.log(`   • Currency 1: ${poolKey.currency1}`);
  console.log(`   • Fee Tier  : ${poolKey.fee}`);
  console.log(`   • Tick Space: ${poolKey.tickSpacing}`);
  console.log(`   • Hook Addr : ${poolKey.hooks}`);
  console.log("==================================================\n");

  const poolManager = new ethers.Contract(POOL_MANAGER_ADDRESS, POOL_MANAGER_ABI, wallet);

  try {
    // 🚨 🧪 অল্টারনেটিভ চেক: যদি estimateGas ইকোনমি এরর দেয়, আমরা সরাসরি গ্যাস লিমিট হার্ডকোড করে ট্রানজেকশন পাঠাবো
    console.log("⏳ Bypassing estimateGas and sending transaction directly to ensure execution...");
    
    const tx = await poolManager.initialize(poolKey, sqrtPriceX96, {
      gasLimit: 1000000 // পর্যাপ্ত গ্যাস বাফার দিয়ে সরাসরি পুশ
    });

    console.log(`🚀 Transaction Broadcasted! Hash: ${tx.hash}`);
    console.log("⏳ Waiting for block confirmation...");
    const receipt = await tx.wait();

    if (receipt.status === 1) {
      console.log("\n🎉 ✅ Success! Your Uniswap v4 pool has been initialized on Sepolia.");
    } else {
      console.error("❌ Transaction executed but reverted on-chain.");
    }

  } catch (error) {
    console.error("\n❌ Initialization Failed!");
    if (error.message.includes("0x7983c051")) {
      console.error("💡 Analysis: This pool is ALREADY initialized on-chain!");
    } else {
      console.error(`🔍 Detailed Log: ${error.reason || error.message}`);
    }
  }
}

main();