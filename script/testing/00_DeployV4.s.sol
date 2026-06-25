// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.26;

// import {Script} from "forge-std/Script.sol";
// import {console} from "forge-std/console.sol";
// import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
// import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// import {HookMiner}                 from "../../lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
// import {HybridVolatilityHook}      from "../../src/HybridVolatilityHook.sol";

// contract DeployHook is Script {
//     function run() external {
//         uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
//         // 🚨 UPDATE: আপনার দেওয়া অফিশিয়াল Sepolia PoolManager অ্যাড্রেস
//         address poolManager = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543; 

//         // লিকুইডিটি, ইনিশিয়ালাইজ এবং সোয়াপ সবকটি ফ্ল্যাগ অন রাখা হয়েছে (UI ফ্রন্টএন্ড সাপোর্টের জন্য)
//         uint160 flags = uint160(
//             Hooks.BEFORE_INITIALIZE_FLAG |
//             Hooks.AFTER_INITIALIZE_FLAG |
//             Hooks.BEFORE_ADD_LIQUIDITY_FLAG |  
//             Hooks.AFTER_ADD_LIQUIDITY_FLAG |   
//             Hooks.BEFORE_SWAP_FLAG |
//             Hooks.AFTER_SWAP_FLAG
//         );

//         console.log("Mining hook address using Official PoolManager... Please wait.");
        
//         // নতুন PoolManager এর সাপেক্ষে CREATE2 সল্ট খোঁজা
//         (address hookAddress, bytes32 salt) = HookMiner.find(
//             address(this), 
//             flags,
//             type(HybridVolatilityHook).creationCode,
//             abi.encode(poolManager)
//         );

//         console.log("Mined Hook Address for Official PM:", hookAddress);

//         // সেপোলিয়া অফিশিয়াল টেস্টনেটে ডিপ্লয়মেন্ট ব্রডকাস্ট
//         vm.startBroadcast(deployerPrivateKey);

//         HybridVolatilityHook myHook = new HybridVolatilityHook{salt: salt}(IPoolManager(poolManager));
//         require(address(myHook) == hookAddress, "Address mining mismatch!");

//         vm.stopBroadcast();

//         console.log("--------------------------------------------------");
//         console.log("SUCCESS: Volatility Hook Deployed on Official Sepolia!");
//         console.log("Contract Address:", address(myHook));
//         console.log("--------------------------------------------------");
//     }
// }