// script/DeployUnichainSepolia.s.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HybridVolatilityHook} from "../src/HybridVolatilityHook.sol";

contract DeployUnichainSepolia is Script {

    address constant UNICHAIN_SEPOLIA_POOL_MANAGER =
        0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Unichain Sepolia Deployment ===");
        console.log("Deployer  :", deployer);
        console.log("Chain ID  :", block.chainid);

        require(block.chainid == 1301, "Must be Unichain Sepolia (1301)");

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG      |
            Hooks.AFTER_INITIALIZE_FLAG       |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG    |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG            |
            Hooks.AFTER_SWAP_FLAG
        );

        console.log("Mining hook address...");

        // ✅ সংশোধন: abi.encode-এ deployer অ্যাড্রেস যুক্ত করা হয়েছে
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,  
            flags,
            type(HybridVolatilityHook).creationCode,
            abi.encode(UNICHAIN_SEPOLIA_POOL_MANAGER, deployer) 
        );

        console.log("Hook address (predicted):", hookAddress);

        vm.startBroadcast(deployerPrivateKey);

        // ✅ সংশোধন: ডেপ্লয় করার সময় deployer অ্যাড্রেস ওনার হিসেবে পাস করা হয়েছে
        HybridVolatilityHook hook = new HybridVolatilityHook{salt: salt}(
            IPoolManager(UNICHAIN_SEPOLIA_POOL_MANAGER),
            deployer
        );

        require(address(hook) == hookAddress, "Hook address mismatch!");

        // এখন আপনার ওয়ালেট ওনার হওয়ায় এই ফাংশনটি সফলভাবে রান করবে
        hook.setTickThresholds(
            500,
            200,
            1 ether,
            10
        );

        vm.stopBroadcast();

        console.log("=== Deployment Success ===");
        console.log("Hook address :", address(hook));
        console.log("Chain        : Unichain Sepolia");
        console.log("Owner        :", deployer);
    }
}