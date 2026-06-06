// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {HybridVolatilityHook} from "../src/HybridVolatilityHook.sol";

contract DeployHookScript is Script {
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    // ✅ CREATE2_FACTORY সরানো হয়েছে — forge-std/Base.sol এ already আছে

    function run() external {
        // ✅ তোমার সব 8টা permission flag
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG       |
            Hooks.AFTER_INITIALIZE_FLAG        |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG    |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG     |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG  |
            Hooks.BEFORE_SWAP_FLAG             |
            Hooks.AFTER_SWAP_FLAG
        );

        bytes memory constructorArgs = abi.encode(POOL_MANAGER);

        // ✅ CREATE2_FACTORY — forge-std থেকে inherited, আলাদা declare লাগবে না
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY,
            flags,
            type(HybridVolatilityHook).creationCode,
            constructorArgs
        );

        console.log("Found valid hook address:", hookAddress);
        console.log("Salt:", uint256(salt));

        vm.startBroadcast();

        HybridVolatilityHook hook = new HybridVolatilityHook{salt: salt}(
            IPoolManager(POOL_MANAGER)
        );

        vm.stopBroadcast();

        require(address(hook) == hookAddress, "Address mismatch!");
        console.log("Hook deployed successfully at:", address(hook));
        console.log("Update HOOK_ADDRESS in addLiquidity.js to:", address(hook));
    }
}
