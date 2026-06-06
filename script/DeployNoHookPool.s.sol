// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract DeployNoHookPool is Script {
    using CurrencyLibrary for address;

    // Sepolia Official Checksummed Addresses
    address constant POOL_MANAGER = 0x1F98400000000000000000000000000000000004; 
    address constant EURC         = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;         
    address constant WETH         = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14; 

    // run ফাংশনটি একদম ক্লিন এবং প্যারামিটারবিহীন রাখুন
    function run() external {
        // .env থেকে প্রাইভেট কি লোড করা
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);

        address token0 = EURC < WETH ? EURC : WETH;
        address token1 = EURC < WETH ? WETH : EURC;

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,                               
            tickSpacing: 60,                         
            hooks: IHooks(address(0))                
        });

        uint160 startingSqrtPriceX96 = 79228162514264337593543950336;

        IPoolManager manager = IPoolManager(POOL_MANAGER);
        manager.initialize(poolKey, startingSqrtPriceX96);

        console.log("SUCCESS: Clean No-Hook Pool Initialized!");
        vm.stopBroadcast();
    }
}