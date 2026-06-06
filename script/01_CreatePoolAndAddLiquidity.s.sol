// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract CreatePoolAndAddLiquidity is Script {
    using PoolIdLibrary for PoolKey;

    function run() public {
        address poolManagerAddress = 0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A;
        address hookAddress = 0x88Bb6571DB4f0eb66831E1De0804D033686ab0c0;
        address eurc = 0x1a7e4e63778B4f12a199C062f3eFdD288afCBce8;
        address weth = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Sort tokens
        address token0 = eurc < weth ? eurc : weth;
        address token1 = eurc < weth ? weth : eurc;
        
        // Create Pool Key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        
        IPoolManager poolManager = IPoolManager(poolManagerAddress);
        
        // sqrtPriceX96 for price 0.0003
        uint160 sqrtPriceX96 = 1372272028650297984479657984;
        
        // [FIXED] এখানে poolKey.toId() এর বদলে সরাসরি poolKey (struct) পাস করা হয়েছে
        poolManager.initialize(poolKey, sqrtPriceX96);
        
        console.log("Pool initialized successfully");
        
        // লিকুইডিটি অ্যাড করার সময় আপনার poolId প্রয়োজন হতে পারে, তাই এটি নিচে কমেন্ট করে রাখা হলো:
        // bytes32 poolId = PoolIdLibrary.toId(poolKey);
        
        vm.stopBroadcast();
    }
}