// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

// V4-এ লিকুইডিটি অ্যাড করার জন্য সাধারণত পেরিফেরি (periphery) বা টেস্ট রাউটার ব্যবহার করা হয়
// interface declarations are not valid in JavaScript files.
// If this script is intended to run with Hardhat/ethers, declare the router ABI instead.

contract MintLiquidityScript is Script {
    // আপনার Sepolia অ্যাড্রেসগুলো এখানে বসান
    address constant POOL_MANAGER = 0x...; // PoolManager Address
    address constant MODIFY_LIQUIDITY_ROUTER = 0x...; // PoolModifyLiquidityTest Address
    address constant EURC = 0x...; // Token0 Address
    address constant WETH = 0x...; // Token1 Address
    address constant HOOK_ADDRESS = address(0); // হুক থাকলে তার অ্যাড্রেস দিন, না থাকলে address(0)

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // ১. PoolKey তৈরি করা (আপনার ফ্রন্টএন্ডের পুলের সাথে হুবহু মিলতে হবে)
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(EURC),
            currency1: Currency.wrap(WETH),
            fee: 3000, // 0.30% fee (আপনার লগ অনুযায়ী)
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDRESS)
        });

        // ২. লিকুইডিটি প্যারামিটার সেট করা
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: 83940,
            tickUpper: 84060,
            liquidityDelta: 1000000, // আপনি কতটুকু লিকুইডিটি দিতে চান (প্রয়োজন অনুযায়ী বাড়ান/কমান)
            salt: 0
        });

        // ৩. রাউটারের মাধ্যমে লিকুইডিটি মিন্ট করা
        IPoolModifyLiquidityTest(MODIFY_LIQUIDITY_ROUTER).modifyLiquidity(
            poolKey,
            params,
            "" // Hook data (যদি হুকে কোনো ডেটা পাস করতে না হয়)
        );

        vm.stopBroadcast();
        console.log("Liquidity successfully added to the pool!");
    }
}