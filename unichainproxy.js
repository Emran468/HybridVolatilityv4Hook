const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

const RPC_URL = "https://ethereum-sepolia-rpc.publicnode.com";
const PRIVATE_KEY = "0x0143ccf4400f5d10b0440e04fc29109aea5d26cb0cbdaac8f01f7178b3a383db"; // Replace with your actual private key
const POOL_MANAGER = "0x00B036B58a818B1BC34d502D3fE730Db729e62AC"; // Sepolia PoolManager address

// Proxy deployment option
const USE_PROXY = false; // Set to true if you want to use proxy pattern

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log("🚀 Wallet Connected:", wallet.address);
  console.log("💰 Balance:", ethers.formatEther(await provider.getBalance(wallet.address)), "ETH");

  // Load contract artifact
  const artifactPath = "./out/V4LiquiditySystem.sol/V4LiquiditySystem.json";
  
  if (!fs.existsSync(artifactPath)) {
    throw new Error(`Artifact not found at ${artifactPath}. Please run 'forge build' first.`);
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
  const bytecode = artifact.bytecode.object || artifact.bytecode;

  if (!USE_PROXY) {
    // ============================================================
    // OPTION 1: DIRECT DEPLOYMENT (Recommended for this contract)
    // ============================================================
    console.log("⏳ Deploying V4LiquiditySystem directly...");
    
    const factory = new ethers.ContractFactory(
      artifact.abi,
      bytecode,
      wallet
    );

    const contract = await factory.deploy(POOL_MANAGER);
    console.log("📡 Deployment Tx Hash:", contract.deploymentTransaction().hash);
    
    await contract.waitForDeployment();
    const contractAddress = await contract.getAddress();
    
    console.log("\n--------------------------------------------------");
    console.log("✅ SUCCESS: V4LiquiditySystem Deployed!");
    console.log("📍 Contract Address:", contractAddress);
    console.log("📍 Pool Manager:", POOL_MANAGER);
    console.log("--------------------------------------------------\n");
    
    // Verify the contract
    const poolManager = await contract.poolManager();
    console.log("🔍 Verification:");
    console.log("  - Pool Manager:", poolManager);
    console.log("  - Matches:", poolManager === POOL_MANAGER ? "✅" : "❌");
    
    // Optional: Save deployment info
    saveDeploymentInfo(contractAddress, "direct");
    
  } else {
    // ============================================================
    // OPTION 2: PROXY DEPLOYMENT (For upgradeability)
    // ============================================================
    console.log("⏳ Deploying with Proxy pattern...");
    
    // Step 1: Deploy implementation
    console.log("  📦 Deploying implementation...");
    const implFactory = new ethers.ContractFactory(artifact.abi, bytecode, wallet);
    const implContract = await implFactory.deploy(POOL_MANAGER);
    await implContract.waitForDeployment();
    const implAddress = await implContract.getAddress();
    console.log("  ✅ Implementation deployed at:", implAddress);

    // Step 2: Deploy proxy (Using OpenZeppelin's UUPS or Transparent proxy)
    // You need to have the proxy contract in your project
    const proxyArtifactPath = "./out/TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json";
    
    if (!fs.existsSync(proxyArtifactPath)) {
      console.error("❌ Proxy artifact not found. Please add OpenZeppelin contracts.");
      console.log("Run: forge install OpenZeppelin/openzeppelin-contracts");
      process.exit(1);
    }

    const proxyArtifact = JSON.parse(fs.readFileSync(proxyArtifactPath, "utf8"));
    const proxyBytecode = proxyArtifact.bytecode.object || proxyArtifact.bytecode;

    // For TransparentUpgradeableProxy: constructor(implementation, admin, data)
    // For UUPSProxy: constructor(implementation, data)
    // Using TransparentProxy as example:
    const proxyFactory = new ethers.ContractFactory(
      proxyArtifact.abi,
      proxyBytecode,
      wallet
    );

    // Create initialization data (if your contract had an initialize function)
    // Since your contract uses constructor, we don't need initialization data
    // But for proxy pattern, you should use an initialize function instead of constructor
    const initData = "0x"; // Empty if no initialization needed
    
    console.log("  📦 Deploying proxy...");
    const proxyContract = await proxyFactory.deploy(
      implAddress,  // implementation
      wallet.address, // admin (can be different address)
      initData      // initialization data
    );
    await proxyContract.waitForDeployment();
    const proxyAddress = await proxyContract.getAddress();
    console.log("  ✅ Proxy deployed at:", proxyAddress);

    // Step 3: Interact through proxy
    const proxiedContract = new ethers.Contract(proxyAddress, artifact.abi, wallet);
    
    console.log("\n--------------------------------------------------");
    console.log("✅ SUCCESS: Proxy Deployment Complete!");
    console.log("📍 Implementation Address:", implAddress);
    console.log("📍 Proxy Address:", proxyAddress);
    console.log("📍 Pool Manager:", POOL_MANAGER);
    console.log("--------------------------------------------------\n");
    
    // Verify the contract through proxy
    try {
      const poolManager = await proxiedContract.poolManager();
      console.log("🔍 Verification through proxy:");
      console.log("  - Pool Manager:", poolManager);
      console.log("  - Matches:", poolManager === POOL_MANAGER ? "✅" : "❌");
    } catch (e) {
      console.log("⚠️  Could not verify through proxy:", e.message);
    }
    
    saveDeploymentInfo(proxyAddress, "proxy", implAddress);
  }
}

function saveDeploymentInfo(address, type, implAddress = "") {
  const deploymentInfo = {
    contract: "V4LiquiditySystem",
    network: "sepolia",
    poolManager: POOL_MANAGER,
    deploymentType: type,
    address: address,
    implementationAddress: implAddress || address,
    deployedAt: new Date().toISOString(),
    rpcUrl: RPC_URL
  };

  const deploymentPath = path.join(__dirname, "deployment.json");
  fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("📄 Deployment info saved to:", deploymentPath);
}

main().catch((error) => {
  console.error("❌ Deployment Failed:", error);
  if (error.reason) console.error("Reason:", error.reason);
  process.exit(1);
});