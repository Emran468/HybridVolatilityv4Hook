const { ethers } = require("ethers");
const fs = require("fs");

const RPC_URL = "https://ethereum-sepolia-rpc.publicnode.com";

const PRIVATE_KEY =YOUR_PRIVATE_KEY;
  

const POOL_MANAGER = "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543";

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log("🚀 Wallet Connected:", wallet.address);

//  Fixed path: Path set according to the contract name V4LiquiditySystem
//   const artifactPath = "./out/VolatilityLiquidityProxy.sol/V4LiquiditySystem.json";
  const artifactPath = "./out/V4LiquiditySystem.sol/V4LiquiditySystem.json";
  
  if (!fs.existsSync(artifactPath)) {
    throw new Error(`Artifact not found at ${artifactPath}. Please run 'forge build' first.`);
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));

  /// Bytecode object handling in Ethers v6
  const bytecode = artifact.bytecode.object || artifact.bytecode;

 // 2. Create contract factory
  const factory = new ethers.ContractFactory(
    artifact.abi,
    bytecode,
    wallet
  );

  console.log("⏳ Deploying V4LiquiditySystem Contract to Sepolia...");

 // 3. Trigger deployment
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