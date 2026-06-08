// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HybridVolatilityHook} from "../src/HybridVolatilityHook.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract VolatilityHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // hook declare 
   
    HybridVolatilityHook hook;

    function setUp() public {
       // 1. Time warp (To avoid Timestamp 0 issues)
        vm.warp(100);

         // 2. Deploy core system
        // This function sets up: manager, swapRouter, and modifyLiquidityRouter
        deployFreshManagerAndRouters();

       
        // This is the correct function name in the Deployers contract
        // It creates and mints currency0 and currency1
        deployMintAndApprove2Currencies();

       // 3. Approve — Allow the Pool Manager to transfer tokens
        IERC20(Currency.unwrap(currency0)).approve(address(manager), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(manager), type(uint256).max);

       // 4. Set all required flags for the hook
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG
        );

      // 5. Find the correct salt using HookMiner and deploy the hook via CREATE2
        (address predictedHook, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(HybridVolatilityHook).creationCode,
            abi.encode(manager)
        );

       // here we deploy the hook using the predicted salt to ensure it lands at the expected address
        hook = new HybridVolatilityHook{salt: salt}(manager);
        require(address(hook) == predictedHook, "Hook address mismatch");

        // 6 to make  PoolKey 
       
        // Dynamic fee pool এ শুধু DYNAMIC_FEE_FLAG 
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, 
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // 7initialized pool
        manager.initialize(key, SQRT_PRICE_1_1);
        PoolId poolId = key.toId();

       // 8. Initialize the hook state (mocking with vm.store)
        bytes32 isInitializedSlot = keccak256(abi.encode(poolId, uint256(2)));
        vm.store(address(hook), isInitializedSlot, bytes32(uint256(1)));

        bytes32 poolHistorySlot = keccak256(abi.encode(poolId, uint256(0)));
        vm.store(address(hook), poolHistorySlot, bytes32(0));
        vm.store(
            address(hook),
            bytes32(uint256(poolHistorySlot) + 1),
            bytes32(uint256(100))
        );
    }

    function test_BaseFeeWhenMarketIsStable() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(manager));

        (, , uint24 fee) = hook.beforeSwap(
            address(this),
            key,
            params,
            ""
        );

        uint24 actualFee = fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;

        assertEq(actualFee, 3000);
        console.log("Base fee test passed.");
    }

    function test_VolatilityLogic() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(manager));

        hook.afterSwap(
            address(this),
            key,
            params,
            BalanceDelta.wrap(0),
            ""
        );

        vm.warp(block.timestamp + 10 seconds);

        vm.prank(address(manager));

        (, , uint24 fee) = hook.beforeSwap(
            address(this),
            key,
            params,
            ""
        );

        uint24 actualFee = fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;

        assertEq(actualFee, 3000);
        console.log("Stable market fee confirmed.");
    }

    function testFuzz_FeeBounds(int24 tickMove, uint256 timeSkip) public {
        vm.assume(tickMove > -5000 && tickMove < 5000);
        vm.assume(timeSkip < 1 days);

        vm.warp(block.timestamp + timeSkip);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(manager));

        (, , uint24 fee) = hook.beforeSwap(
            address(this),
            key,
            params,
            ""
        );

        uint24 actualFee = fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;

        assertGe(actualFee, 3000);
        assertLe(actualFee, 15000);
    }
}
