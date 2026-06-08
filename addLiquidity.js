// addLiquidity.js — Fixed: balance check + correct liquidity amount

const { ethers } = require("ethers");

const PRIVATE_KEY          = "0xff2fc42f64114cc432a27a8290b0c9b8e9fe2ebc3afdde90863ddff6051ed3fc";
const RPC_URL              = "https://eth-sepolia.g.alchemy.com/v2/Vur31q2MBSuF6HB7nzKL_";
const PROXY_ADDRESS        = "0x698f4E9133c2B37c58674e6b696b4fE9b1C0aDe8";
const HOOK_ADDRESS         = "0x9f8677d875Ff9FCf31E8f9C49BBC98E9Ba58BFC0";
const POOL_MANAGER_ADDRESS = "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543";
const EURC                 = "0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4";
const WETH                 = "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14";

const ERC20_ABI = [
  "function transfer(address to, uint256 amount) external returns (bool)",
  "function balanceOf(address account) external view returns (uint256)",
  "function approve(address spender, uint256 amount) external returns (bool)"
];
const WETH_ABI  = [...ERC20_ABI, "function deposit() external payable"];
const PROXY_ABI = ["function addLiquidity(bytes calldata data) external"];

function isPoolAlreadyInitialized(e) {
  const msg  = (e.message || "").toLowerCase();
  const data = (e.data    || "");
  return (
    data.includes("7983c051") ||
    msg.includes("7983c051")  ||
    msg.includes("poolalreadyinitialized")
  );
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet   = new ethers.Wallet(PRIVATE_KEY, provider);
  console.log("🚀 Wallet Connected:", wallet.address);

  const [currency0, currency1] =
    BigInt(EURC) < BigInt(WETH) ? [EURC, WETH] : [WETH, EURC];
  console.log("📍 currency0:", currency0);
  console.log("📍 currency1:", currency1);

  const poolKey = {
    currency0,
    currency1,
    fee:         8388608,
    tickSpacing: 60,
    hooks:       HOOK_ADDRESS
  };

  const sqrtPriceX96 = 79228162514264337593543950336n;
  const poolKeyTuple = [
    poolKey.currency0,
    poolKey.currency1,
    poolKey.fee,
    poolKey.tickSpacing,
    poolKey.hooks
  ];

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 1: Pool check
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n🔍 Checking pool status...");
  let poolInitialized = false;

  try {
    const iface    = new ethers.Interface([
      "function initialize(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint160 sqrtPriceX96) external returns (int24)"
    ]);
    const calldata = iface.encodeFunctionData("initialize", [poolKeyTuple, sqrtPriceX96]);
    await provider.call({ to: POOL_MANAGER_ADDRESS, data: calldata });
    console.log("📭 Pool not yet initialized.");
  } catch (e) {
    if (isPoolAlreadyInitialized(e)) {
      console.log("✅ Pool already initialized! Skipping...");
      poolInitialized = true;
    } else {
      try {
        const ifaceB    = new ethers.Interface([
          "function initialize(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint160 sqrtPriceX96, bytes hookData) external returns (int24)"
        ]);
        const calldataB = ifaceB.encodeFunctionData("initialize", [poolKeyTuple, sqrtPriceX96, "0x"]);
        await provider.call({ to: POOL_MANAGER_ADDRESS, data: calldataB });
        console.log("📭 Pool not initialized (sig B).");
      } catch (e2) {
        if (isPoolAlreadyInitialized(e2)) {
          console.log("✅ Pool already initialized (sig B)! Skipping...");
          poolInitialized = true;
        }
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 2: Initialize if needed
  // ═══════════════════════════════════════════════════════════════════════
  if (!poolInitialized) {
    console.log("\n⏳ Initializing pool...");
    let initialized = false;

    try {
      const iface    = new ethers.Interface([
        "function initialize(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint160 sqrtPriceX96) external returns (int24)"
      ]);
      const calldata = iface.encodeFunctionData("initialize", [poolKeyTuple, sqrtPriceX96]);
      const tx       = await wallet.sendTransaction({ to: POOL_MANAGER_ADDRESS, data: calldata, gasLimit: 1000000n });
      console.log("📡 Tx:", tx.hash);
      const receipt  = await tx.wait();
      if (receipt.status === 1) { console.log("✅ Initialized! Block:", receipt.blockNumber); initialized = true; }
    } catch (e) {
      if (isPoolAlreadyInitialized(e)) { console.log("✅ Already initialized."); initialized = true; }
      else console.log("❌ Try A:", e.message.slice(0, 100));
    }

    if (!initialized) {
      try {
        const iface    = new ethers.Interface([
          "function initialize(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint160 sqrtPriceX96, bytes hookData) external returns (int24)"
        ]);
        const calldata = iface.encodeFunctionData("initialize", [poolKeyTuple, sqrtPriceX96, "0x"]);
        const tx       = await wallet.sendTransaction({ to: POOL_MANAGER_ADDRESS, data: calldata, gasLimit: 1000000n });
        console.log("📡 Tx:", tx.hash);
        const receipt  = await tx.wait();
        if (receipt.status === 1) { console.log("✅ Initialized (B)! Block:", receipt.blockNumber); initialized = true; }
      } catch (e) {
        if (isPoolAlreadyInitialized(e)) { console.log("✅ Already initialized (B)."); initialized = true; }
        else console.log("❌ Try B:", e.message.slice(0, 100));
      }
    }

    if (!initialized) { console.error("❌ Init failed."); process.exit(1); }
  }

  // ═══════════════════════════════════════════════════════════════════════
 // STEP 3: Balance check — first check the Proxy's balance
  // ═══════════════════════════════════════════════════════════════════════
  const token0 = new ethers.Contract(currency0, ERC20_ABI, wallet);
  const token1 = new ethers.Contract(
    currency1,
    currency1.toLowerCase() === WETH.toLowerCase() ? WETH_ABI : ERC20_ABI,
    wallet
  );

  const walletBal0 = await token0.balanceOf(wallet.address);
  const walletBal1 = await token1.balanceOf(wallet.address);
  const proxyBal0  = await token0.balanceOf(PROXY_ADDRESS);
  const proxyBal1  = await token1.balanceOf(PROXY_ADDRESS);

  console.log("\n📊 Current Balances:");
  console.log("┌─────────────────────────────────────────┐");
  console.log(`│ Wallet Token0 : ${walletBal0.toString().padEnd(24)}│`);
  console.log(`│ Wallet Token1 : ${walletBal1.toString().padEnd(24)}│`);
  console.log(`│ Proxy  Token0 : ${proxyBal0.toString().padEnd(24)}│`);
  console.log(`│ Proxy  Token1 : ${proxyBal1.toString().padEnd(24)}│`);
  console.log("└─────────────────────────────────────────┘");

  // ─── Calculate funding amount ──────────────────────────────────────
// EURC = 6 decimals, WETH = 18 decimals
// The Proxy must hold at least this amount
  const NEED0 = ethers.parseUnits("1", 6);    // 1 EURC  (6 decimals)
  const NEED1 = ethers.parseUnits("0.01", 18); // 0.01 WETH (18 decimals)

  // ─── Token0 Fund ──────────────────────────────────────────────────────
  if (proxyBal0 < NEED0) {
    const toSend0 = NEED0 - proxyBal0;
    console.log(`\n💰 Sending Token0 to Proxy: ${ethers.formatUnits(toSend0, 6)} EURC`);
    if (walletBal0 < toSend0) {
      console.error(`❌ Wallet Token0 insufficient! Have: ${ethers.formatUnits(walletBal0, 6)} EURC, Need: ${ethers.formatUnits(toSend0, 6)} EURC`);
      process.exit(1);
    }
    await (await token0.transfer(PROXY_ADDRESS, toSend0)).wait();
    console.log("✅ Token0 sent.");
  } else {
    console.log(`\n⏭️  Proxy Token0 OK: ${ethers.formatUnits(proxyBal0, 6)} EURC`);
  }

  // ─── Token1 Fund (WETH) ───────────────────────────────────────────────
  if (proxyBal1 < NEED1) {
    const toSend1 = NEED1 - proxyBal1;
    console.log(`💰 Need to send Token1: ${ethers.formatUnits(toSend1, 18)} WETH`);

    if (currency1.toLowerCase() === WETH.toLowerCase()) {
    // Wrap ETH to WETH if the WETH balance is low
      if (walletBal1 < toSend1) {
        console.log("🔄 Wrapping ETH to WETH...");
        const ethBal = await provider.getBalance(wallet.address);
        console.log(`   ETH balance: ${ethers.formatEther(ethBal)}`);
        if (ethBal < toSend1 + ethers.parseEther("0.01")) {
          console.error("❌ Not enough ETH to wrap!");
          process.exit(1);
        }
        const wethC = new ethers.Contract(WETH, WETH_ABI, wallet);
        await (await wethC.deposit({ value: toSend1 })).wait();
        console.log("✅ ETH wrapped to WETH.");
      }
      await (await token1.transfer(PROXY_ADDRESS, toSend1)).wait();
      console.log("✅ WETH sent to Proxy.");
    } else {
      if (walletBal1 < toSend1) {
        console.error(`❌ Wallet Token1 insufficient!`);
        process.exit(1);
      }
      await (await token1.transfer(PROXY_ADDRESS, toSend1)).wait();
      console.log("✅ Token1 sent.");
    }
  } else {
    console.log(`⏭️  Proxy Token1 OK: ${ethers.formatUnits(proxyBal1, 18)} WETH`);
  }

  // ─── Final balance confirm ────────────────────────────────────────────
  const finalBal0 = await token0.balanceOf(PROXY_ADDRESS);
  const finalBal1 = await token1.balanceOf(PROXY_ADDRESS);
  console.log("\n📦 Proxy Final Balance:");
  console.log(`   Token0: ${ethers.formatUnits(finalBal0, 6)} EURC`);
  console.log(`   Token1: ${ethers.formatUnits(finalBal1, 18)} WETH`);

 // ═══════════════════════════════════════════════════════════════════════
// STEP 4: liquidityDelta — use a safe value based on balance
// ═══════════════════════════════════════════════════════════════════════
// For 1 EURC = 100_000 units (6 decimals), this is a safe liquidity amount
// Keep liquidityDelta small — 100_000n is very safe
  const liquidityDelta = 100_000n;

  console.log(`\n🔢 liquidityDelta: ${liquidityDelta.toString()}`);

  // ═══════════════════════════════════════════════════════════════════════
  // STEP 5: addLiquidity
  // ═══════════════════════════════════════════════════════════════════════
  const abiCoder = ethers.AbiCoder.defaultAbiCoder();
  const data     = abiCoder.encode(
    [
      "tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)",
      "int24", "int24", "int256", "bytes32"
    ],
    [
      [poolKey.currency0, poolKey.currency1, poolKey.fee, poolKey.tickSpacing, poolKey.hooks],
      -60, 60,
      liquidityDelta,
      ethers.ZeroHash
    ]
  );

  const proxy = new ethers.Contract(PROXY_ADDRESS, PROXY_ABI, wallet);
  console.log("\n🚀 Adding liquidity...");

  try {
   // Simulate first
    await proxy.addLiquidity.staticCall(data, { gasLimit: 5000000 });
    console.log("✅ Simulation passed!");

    const tx      = await proxy.addLiquidity(data, { gasLimit: 5000000 });
    console.log("📡 TX:", tx.hash);
    const receipt = await tx.wait();

    if (receipt.status === 1) {
      console.log("\n🎉 Success! Liquidity added!");
      console.log("📦 Block   :", receipt.blockNumber);
      console.log("⛽ Gas used:", receipt.gasUsed.toString());
      console.log("🔗 Etherscan:", `https://sepolia.etherscan.io/tx/${receipt.hash}`);
    } else {
      console.log("❌ Reverted:", `https://sepolia.etherscan.io/tx/${receipt.hash}`);
    }
  } catch (err) {
    console.log("\n❌ addLiquidity failed:");
    if (err.data)   console.log("   Error data:", err.data);
    if (err.reason) console.log("   Reason    :", err.reason);
    console.log("   Message   :", err.message.slice(0, 400));

  // Debug: What is the Proxy balance now?
    const dbg0 = await token0.balanceOf(PROXY_ADDRESS);
    const dbg1 = await token1.balanceOf(PROXY_ADDRESS);
    console.log("\n🔍 Debug — Proxy balance at time of failure:");
    console.log(`   Token0: ${ethers.formatUnits(dbg0, 6)} EURC`);
    console.log(`   Token1: ${ethers.formatUnits(dbg1, 18)} WETH`);
  }
}

main().catch(console.error);