const { ethers } = require("ethers");
const fs = require("fs");

const RPC_URL =
  "https://eth-sepolia.g.alchemy.com/v2/Vur31q2MBSuF6HB7nzKL_";

const PRIVATE_KEY =
  "ff2fc42f64114cc432a27a8290b0c9b8e9fe2ebc3afdde90863ddff6051ed3fc"; // 0x প্রিফিক্সসহ ফিক্সড

const POOL_MANAGER = "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543";

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log("🚀 Wallet Connected:", wallet.address);

  // 📍 ফিক্সড প্যাথ: কন্ট্রাক্ট নাম V4LiquiditySystem অনুযায়ী প্যাথ সেট করা হয়েছে
//   const artifactPath = "./out/VolatilityLiquidityProxy.sol/V4LiquiditySystem.json";
  const artifactPath = "./out/V4LiquiditySystem.sol/V4LiquiditySystem.json";
  
  if (!fs.existsSync(artifactPath)) {
    throw new Error(`Artifact not found at ${artifactPath}. Please run 'forge build' first.`);
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));

  // ethers v6 এ bytecode অবজেক্ট হ্যান্ডলিং
  const bytecode = artifact.bytecode.object || artifact.bytecode;

  // ২. কন্ট্রাক্ট ফ্যাক্টরি তৈরি
  const factory = new ethers.ContractFactory(
    artifact.abi,
    bytecode,
    wallet
  );

  console.log("⏳ Deploying V4LiquiditySystem Contract to Sepolia...");

  // ৩. ডেপ্লয়মেন্ট ট্রিগার
  const contract = await factory.deploy(POOL_MANAGER);

  console.log("📡 Deployment Tx Broadcasted! Hash:", contract.deploymentTransaction().hash);
  console.log("⏳ Waiting for blocks confirmation...");

  await contract.waitForDeployment();

  const proxyAddress = await contract.getAddress();
  console.log("\n--------------------------------------------------");
  console.log("✅ SUCCESS: V4LiquiditySystem Deployed Successfully!");
  console.log("📍 Proxy Contract Address:", proxyAddress);
  console.log("--------------------------------------------------\n");
}

main().catch((error) => {
  console.error("❌ Deployment Failed:", error);
  process.exit(1);
});