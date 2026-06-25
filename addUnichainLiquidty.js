// addUnichainLiquidty.js — Unichain Sepolia Version
import { ethers } from "ethers";

// ─── Configuration ────────────────────────────────────────────────────────────
const PRIVATE_KEY          = process.env.PRIVATE_KEY || "0x0143ccf4400f5d10b0440e04fc29109aea5d26cb0cbdaac8f01f7178b3a383db";
const RPC_URL              = process.env.UNICHAIN_SEPOLIA_RPC || "https://sepolia.unichain.org";

const POOL_MANAGER_ADDRESS = "0x00B036B58a818B1BC34d502D3fE730Db729e62AC";
const HOOK_ADDRESS         = "0xA8B74ADfA5558F27A7c9983D14a302aBE13575c0"; 
const SWAP_ROUTER_ADDRESS  = "0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4"; 

const TOKEN_A              = "0x4200000000000000000000000000000000000006"; // WETH
const TOKEN_B              = "0x31d0220469e10c4E71834a79b1f276d740d3768F"; // MOCK USDC

// ─── ABIs ─────────────────────────────────────────────────────────────────────
const ERC20_ABI = [
  "function transfer(address to, uint256 amount) external returns (bool)",
  "function balanceOf(address account) external view returns (uint256)",
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function decimals() external view returns (uint8)",
  "function symbol() external view returns (string)",
  "function deposit() external payable"
];

const SWAP_ROUTER_ABI = [
  "function exactInputSingle(tuple(address tokenIn, address tokenOut, uint24 fee, address recipient, uint256 deadline, uint256 amountIn, uint256 amountOutMinimum, uint160 sqrtPriceLimitX96)) external payable returns (uint256 amountOut)"
];

const POOL_MANAGER_ABI = [
  "function initialize(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint160 sqrtPriceX96) external returns (int24)",
  "function modifyLiquidity(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, tuple(int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt) params, bytes calldata hookData) external returns (tuple(int128 amount0, int128 amount1), tuple(int128 amount0, int128 amount1))"
];

function isPoolAlreadyInitialized(e) {
  const msg  = (e.message || "").toLowerCase();
  const data = (e.data    || "");
  return data.includes("7983c051") || msg.includes("7983c051") || msg.includes("poolalreadyinitialized");
}

function sleep(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

async function main() {
  console.log("═══════════════════════════════════════════════════");
  console.log("  HybridVolatilityHook — Auto Convert & Add Liquidity");
  console.log("═══════════════════════════════════════════════════\n");

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet   = new ethers.Wallet(PRIVATE_KEY, provider);

  const safeTokenA = ethers.getAddress(TOKEN_A.toLowerCase());
  const safeTokenB = ethers.getAddress(TOKEN_B.toLowerCase());

  const [currency0, currency1] = BigInt(safeTokenA) < BigInt(safeTokenB) ? [safeTokenA, safeTokenB] : [safeTokenB, safeTokenA];

  console.log("🚀 Wallet:", wallet.address);
  console.log("📍 Token Addresses:\n   currency0:", currency0, "\n   currency1:", currency1);

  const token0Contract = new ethers.Contract(currency0, ERC20_ABI, wallet);
  const token1Contract = new ethers.Contract(currency1, ERC20_ABI, wallet);

  let dec0 = 18n, dec1 = 18n;
  try {
    dec0 = await token0Contract.decimals();
    dec1 = await token1Contract.decimals();
    console.log(`   Token0 Decimals: ${dec0}, Token1 Decimals: ${dec1}`);
  } catch (e) {
    console.log("⚠️  Could not fetch token info — Check if Token_B is actually deployed! Error:", e.message.slice(0, 80));
  }

  const poolKeyTuple = [currency0, currency1, 8388608, 60, ethers.getAddress(HOOK_ADDRESS.toLowerCase())];
  const sqrtPriceX96 = 79228162514264337593543950336n;

  // ─── STEP 1: Pool Initialize Check ──────────────────────────────────────
  let poolInitialized = false;
  try {
    const iface    = new ethers.Interface(["function initialize(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint160 sqrtPriceX96) external returns (int24)"]);
    const calldata = iface.encodeFunctionData("initialize", [poolKeyTuple, sqrtPriceX96]);
    await provider.call({ to: ethers.getAddress(POOL_MANAGER_ADDRESS.toLowerCase()), data: calldata });
    console.log("📭 Pool not yet initialized.");
  } catch (e) {
    if (isPoolAlreadyInitialized(e)) {
      console.log("✅ Pool already initialized! Skipping...");
      poolInitialized = true;
    }
  }

  // ─── STEP 2: Initializing Pool ─────────────────────────────────────────────
/// ─── STEP 2: Initializing Pool ─────────────────────────────────────────────
  // একটি গ্লোবাল ননস ট্র্যাকার তৈরি করা হলো
  let activeNonce = await wallet.getNonce("pending");

  if (!poolInitialized) {
    console.log("\n─── STEP 2: Initializing Pool ───────────────────────");
    try {
      const iface    = new ethers.Interface(["function initialize(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint160 sqrtPriceX96) external returns (int24)"]);
      const calldata = iface.encodeFunctionData("initialize", [poolKeyTuple, sqrtPriceX96]);

      console.log(`📡 Using Nonce: ${activeNonce}`);

      const feeData = await provider.getFeeData();
      const bumpedPriorityFee = feeData.maxPriorityFeePerGas 
        ? (feeData.maxPriorityFeePerGas * 500n) / 100n 
        : ethers.parseUnits("2", "gwei");
        
      const bumpedMaxFee = feeData.maxFeePerGas 
        ? (feeData.maxFeePerGas * 500n) / 100n 
        : ethers.parseUnits("10", "gwei");

      console.log("🚀 Submitting EIP-1559 replacement transaction with Aggressive Fees...");
      const tx = await wallet.sendTransaction({
        to: ethers.getAddress(POOL_MANAGER_ADDRESS.toLowerCase()),
        data: calldata,
        gasLimit: 3000000n,
        nonce: activeNonce,
        maxFeePerGas: bumpedMaxFee,
        maxPriorityFeePerGas: bumpedPriorityFee
      });

      console.log("📡 TX Hash:", tx.hash);
      console.log("⏳ Waiting for confirmation via custom polling...");
      
      let receipt = null;
      let attempts = 0;
      while (!receipt && attempts < 30) {
        receipt = await provider.getTransactionReceipt(tx.hash);
        if (!receipt) {
          await sleep(2000);
          attempts++;
        }
      }

      if (receipt && receipt.status === 1) {
        console.log("🎉 Pool initialized successfully in block:", receipt.blockNumber);
        await sleep(2000);
      }
      activeNonce++; // সাকসেস হলে ননস কাউন্টার ১ বাড়বে
    } catch (e) {
      const errorStr = JSON.stringify(e).toLowerCase() + (e.message || "").toLowerCase();
      
      if (isPoolAlreadyInitialized(e)) {
        console.log("✅ Already initialized.");
        activeNonce = await wallet.getNonce("pending"); // অলরেডি চেইনে থাকলে ফ্রেশ ননস নেওয়া হবে
      } 
      else if (errorStr.includes("already known") || errorStr.includes("alreadyknown") || errorStr.includes("underpriced")) {
        console.log("⏳ TX is already pending in network mempool ('already known').");
        activeNonce++; // ননস ৭ অলরেডি মেমপুলে বুকড, তাই পরবর্তী কাজের ননস হবে ৮
      } else {
        console.error("❌ Init failed:", e.message || e);
        process.exit(1);
      }
    }
  }

  // ─── AUTO CONVERT: ETH ➡️ WETH ➡️ USDC ──────────────────────────────────
  console.log("\n─── AUTO CONVERT: ETH ➡️ WETH ➡️ USDC ────────────────");
  const wethContract = new ethers.Contract(safeTokenA, ERC20_ABI, wallet);
  const swapRouter   = new ethers.Contract(ethers.getAddress(SWAP_ROUTER_ADDRESS.toLowerCase()), SWAP_ROUTER_ABI, wallet);

  const totalEthToWrap = ethers.parseEther("0.05");
  const amountToSwap   = ethers.parseEther("0.025");

  const feeDataForConvert = await provider.getFeeData();
  const convertMaxFee = feeDataForConvert.maxFeePerGas ? (feeDataForConvert.maxFeePerGas * 200n) / 100n : undefined;
  const convertPriorityFee = feeDataForConvert.maxPriorityFeePerGas ? (feeDataForConvert.maxPriorityFeePerGas * 200n) / 100n : undefined;

  console.log(`🌀 Wrapping ${ethers.formatEther(totalEthToWrap)} ETH... Using Nonce: ${activeNonce}`);
  const wrapTx = await wethContract.deposit({ 
    value: totalEthToWrap,
    gasLimit: 150000n, 
    nonce: activeNonce++, // ম্যানুয়াল ননস পুশ
    maxFeePerGas: convertMaxFee,
    maxPriorityFeePerGas: convertPriorityFee
  });
  console.log("📡 Wrap TX Sent:", wrapTx.hash);
  await wrapTx.wait();

  console.log(`🔓 Approving SwapRouter... Using Nonce: ${activeNonce}`);
  const appTx = await wethContract.approve(
    ethers.getAddress(SWAP_ROUTER_ADDRESS.toLowerCase()), 
    ethers.MaxUint256,
    {
      gasLimit: 150000n,
      nonce: activeNonce++, // ম্যানুয়াল ননস পুশ
      maxFeePerGas: convertMaxFee,
      maxPriorityFeePerGas: convertPriorityFee
    }
  );
  console.log("📡 Approve TX Sent:", appTx.hash);
  await appTx.wait();

  console.log(`🔄 Swapping WETH for USDC... Using Nonce: ${activeNonce}`);
  const swapTx = await swapRouter.exactInputSingle({
    tokenIn: safeTokenA,
    tokenOut: safeTokenB,
    fee: 3000, 
    recipient: wallet.address,
    deadline: Math.floor(Date.now() / 1000) + 600, 
    amountIn: amountToSwap,
    amountOutMinimum: 0, 
    sqrtPriceLimitX96: 0
  }, { 
    gasLimit: 500000n, 
    nonce: activeNonce++, // ম্যানুয়াল ননস পুশ
    maxFeePerGas: convertMaxFee,
    maxPriorityFeePerGas: convertPriorityFee
  });
  console.log("📡 Swap TX Sent:", swapTx.hash);
  await swapTx.wait();
  console.log("✅ Successfully swapped WETH to USDC!");

  // ─── STEP 4 & 5: Approve & Add Liquidity ──────────────────────────────────
  console.log("\n─── STEP 4 & 5: Adding Liquidity ─────────────────────");
  const walletBal0 = await token0Contract.balanceOf(wallet.address);
  const walletBal1 = await token1Contract.balanceOf(wallet.address);
  console.log(`📊 Balances - Token0: ${ethers.formatUnits(walletBal0, dec0)}, Token1: ${ethers.formatUnits(walletBal1, dec1)}`);

  console.log(`🔓 Approving Token0 to PoolManager... Using Nonce: ${activeNonce}`);
  await (await token0Contract.approve(ethers.getAddress(POOL_MANAGER_ADDRESS.toLowerCase()), ethers.MaxUint256, { gasLimit: 150000n, nonce: activeNonce++, maxFeePerGas: convertMaxFee, maxPriorityFeePerGas: convertPriorityFee })).wait();
  
  console.log(`🔓 Approving Token1 to PoolManager... Using Nonce: ${activeNonce}`);
  await (await token1Contract.approve(ethers.getAddress(POOL_MANAGER_ADDRESS.toLowerCase()), ethers.MaxUint256, { gasLimit: 150000n, nonce: activeNonce++, maxFeePerGas: convertMaxFee, maxPriorityFeePerGas: convertPriorityFee })).wait();

  const pmInterface = new ethers.Interface(POOL_MANAGER_ABI);
  const modifyLiqData = pmInterface.encodeFunctionData("modifyLiquidity", [
    poolKeyTuple, [-887220, 887220, ethers.parseUnits("0.01", 18), ethers.ZeroHash], "0x"
  ]);

  console.log(`🚀 Submitting Liquidity Transaction... Using Nonce: ${activeNonce}`);
  const liqTx = await wallet.sendTransaction({
    to: ethers.getAddress(POOL_MANAGER_ADDRESS.toLowerCase()),
    data: modifyLiqData,
    gasLimit: 3000000n, 
    nonce: activeNonce++, // ম্যানুয়াল ননস পুশ
    maxFeePerGas: convertMaxFee,
    maxPriorityFeePerGas: convertPriorityFee
  });
  
  console.log("⏳ Waiting for Liquidity confirmation...");
  const liqReceipt = await liqTx.wait();
  if (liqReceipt.status === 1) {
    console.log("\n🎉 SUCCESS! Liquidity Added Successfully!");
    console.log("🔗 Explorer : https://unichain-sepolia.blockscout.com/tx/" + liqReceipt.hash);
  }
}

main().catch(console.error);