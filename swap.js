const { ethers } = require("ethers");

const PRIVATE_KEY          = YOUR_PRIVATE_KEY;
const RPC_URL              = "https://ethereum-sepolia-rpc.publicnode.com";


const HOOK_ADDRESS         = "0xF9c2Ec66C5D7a8CEaf8d2d8122fA4f07249CBFC0"; 
const POOL_MANAGER_ADDRESS = "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543";
const EURC                 = "0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4";
const WETH                 = "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14";

const SWAP_ROUTER_ADDRESS  = "0x9b6b46e2c869aa39918db7f52f5557fe577b6eee".toLowerCase();

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function balanceOf(address account) external view returns (uint256)"
];

const SWAP_ROUTER_ABI = [
  "function swap(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, tuple(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) params, tuple(bool withdrawTokens, bool settleUsingTransfer) testSettings, bytes hookData) external payable returns (int256 delta)"
];

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet   = new ethers.Wallet(PRIVATE_KEY, provider);
  console.log("🚀 Wallet Connected:", wallet.address);

  // Currency Sorting
  const [currency0, currency1] =
    BigInt(EURC) < BigInt(WETH) ? [EURC, WETH] : [WETH, EURC];
  console.log("📍 currency0 (EURC):", currency0);
  console.log("📍 currency1 (WETH):", currency1);

  const poolKey = {
    currency0,
    currency1,
    fee:         8388608, // DYNAMIC_FEE_FLAG (0x800000)
    tickSpacing: 60,
    hooks:       HOOK_ADDRESS
  };

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 1: Swap Parameter Setup (Using Standard v4 Price Limits)
  // ═══════════════════════════════════════════════════════════════════════
  const zeroForOne = true; 
  
// Swap 0.5 EURC = 500,000 units (6 decimals)
  const amountToSwap = ethers.parseUnits("0.5", 6);
  const amountSpecified = -BigInt(amountToSwap); 

// ✅ Set safe boundaries according to Uniswap v4 standards (without getSlot0 overhead)
// If zeroForOne = true, price decreases, so the boundary is set just above the minimum.
// If zeroForOne = false, price increases, so the boundary is set just below the maximum.
  const sqrtPriceLimitX96 = zeroForOne 
    ? 4295128740n                                    // TickMath.MIN_SQRT_PRICE + 1
    : 1461446703485210103287273052203988822378723970341n; // TickMath.MAX_SQRT_PRICE - 1

  console.log("🛡️ SqrtPriceLimitX96 Set To:", sqrtPriceLimitX96.toString());

  const swapParams = {
    zeroForOne,
    amountSpecified,
    sqrtPriceLimitX96
  };

  const testSettings = {
    withdrawTokens: true,      
    settleUsingTransfer: true  
  };

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 2: Token Approval Check
  // ═══════════════════════════════════════════════════════════════════════
  const token0 = new ethers.Contract(currency0, ERC20_ABI, wallet);
  const walletBal0 = await token0.balanceOf(wallet.address);
  
  console.log(`\n📊 Wallet EURC Balance: ${ethers.formatUnits(walletBal0, 6)} EURC`);
  if (walletBal0 < amountToSwap) {
    console.error("❌ Insufficient EURC balance in wallet!");
    process.exit(1);
  }

  console.log(`\n🔓 Approving Swap Router to spend ${ethers.formatUnits(amountToSwap, 6)} EURC...`);
  await (await token0.approve(SWAP_ROUTER_ADDRESS, amountToSwap)).wait();
  console.log("✅ Approval Successful!");

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 3: Execute Swap
  // ═══════════════════════════════════════════════════════════════════════
  const router = new ethers.Contract(SWAP_ROUTER_ADDRESS, SWAP_ROUTER_ABI, wallet);
  console.log("\n🔄 Executing Swap on Uniswap v4 Pool...");

  try {
    // Static Call (Simulation)
    await router.swap.staticCall(poolKey, swapParams, testSettings, "0x", { gasLimit: 2000000 });
    console.log("✅ Swap Simulation passed!");

    // Real Transaction
    const tx = await router.swap(poolKey, swapParams, testSettings, "0x", { gasLimit: 2000000 });
    console.log("📡 TX Sent:", tx.hash);
    const receipt = await tx.wait();

    if (receipt.status === 1) {
      console.log("\n🎉Success! Swap completed!");
      console.log("📦 Block   :", receipt.blockNumber);
      console.log("⛽ Gas used:", receipt.gasUsed.toString());
      console.log("🔗 Etherscan:", `https://sepolia.etherscan.io/tx/${receipt.hash}`);
    } else {
      console.log("❌ Transaction Reverted on-chain.");
    }
  } catch (err) {
    console.log("\n❌ Swap Execution Failed:");
    if (err.data)   console.log("   Error data:", err.data);
    if (err.reason) console.log("   Reason    :", err.reason);
    console.log("   Message   :", err.message.slice(0, 300));
  }
}

main().catch(console.error);