// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {HybridVolatilityHook} from "../../src/HybridVolatilityHook.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract SimulateHistoryTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    HybridVolatilityHook hook;
    address trader = makeAddr("trader");

    PoolSwapTest.TestSettings internal SETTINGS =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    uint24 constant BASE_FEE        = 3000;
    uint24 constant MEV_PENALTY_FEE = 100000;

    function setUp() public {
        vm.warp(1000);
        vm.roll(1000);
        vm.chainId(31337);

        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG      |
            Hooks.AFTER_INITIALIZE_FLAG       |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG    |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG            |
            Hooks.AFTER_SWAP_FLAG
        );

        (address predictedHook, bytes32 salt) = HookMiner.find(
            address(this), flags,
            type(HybridVolatilityHook).creationCode,
            abi.encode(manager, address(this))
        );

        hook = new HybridVolatilityHook{salt: salt}(manager, address(this));
        require(address(hook) == predictedHook, "Hook address mismatch");

        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        manager.initialize(key, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams(-887220, 887220, 1_000_000 ether, 0),
            ZERO_BYTES
        );

        hook.setTickThresholds(500, 200, 0.001 ether, 10);

        deal(Currency.unwrap(currency0), trader, 10_000 ether);
        deal(Currency.unwrap(currency1), trader, 10_000 ether);

        vm.startPrank(trader);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ── Helper ────────────────────────────────────────────────────

    function _swap(bool zeroForOne, int256 amount) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne:        zeroForOne,
                amountSpecified:   amount,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            SETTINGS,
            ZERO_BYTES
        );
    }

    function _nextBlock() internal {
        vm.roll(block.number + 1);
    }

    // ── Tests ─────────────────────────────────────────────────────

    function test_DetectSandwichPenalty() public {
        vm.startPrank(trader);
        _swap(true, -500 ether);
        _swap(false, 500 ether);
        vm.stopPrank();

        uint24 currentFee = hook.getCurrentFee(key);
        console.log("Fee after detected sandwich:", currentFee);

        assertEq(currentFee, MEV_PENALTY_FEE, "MEV Penalty not applied!");
    }

    function test_GasUsage_Swap() public {
        uint256 startGas = gasleft();

        vm.prank(trader);
        _swap(true, -1 ether);

        uint256 gasUsed = startGas - gasleft();
        console.log("Gas used for swap with hook:", gasUsed);
        assertLt(gasUsed, 1_500_000, "Gas usage too high");
    }

    function test_NoPenalty_SmallSwap() public {
        // High threshold so small swap never triggers penalty
        hook.setTickThresholds(500, 200, 10_000 ether, 10);

        vm.startPrank(trader);
        _swap(true,  -0.001 ether);
        _swap(false,  0.001 ether);
        vm.stopPrank();

        uint24 fee = hook.getCurrentFee(key);
        console.log("Fee after small swap:", fee);

        assertTrue(fee != MEV_PENALTY_FEE,
            "Small swap below threshold should NOT trigger MEV penalty");
    }

    // Cross-block reversal should NOT trigger penalty
    // Hook tracks same-block reversals only
    function test_MultiBlockDetection_NoPenalty() public {
        vm.startPrank(trader);
        _swap(true, -500 ether);
        vm.stopPrank();

        // New block — tracker resets
        _nextBlock();

        vm.startPrank(trader);
        _swap(false, 500 ether);
        vm.stopPrank();

        uint24 fee = hook.getCurrentFee(key);
        console.log("Fee after cross-block swap:", fee);

        assertTrue(fee != MEV_PENALTY_FEE,
            "Cross-block reversal should NOT trigger sandwich penalty");
    }

    function test_FeeDecay_AfterBlockWindow() public {
        vm.startPrank(trader);
        _swap(true,  -500 ether);
        _swap(false,  500 ether);
        vm.stopPrank();

        assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE, "Should have penalty fee");

        uint64 decay = hook.blockDecayWindow();
        vm.roll(block.number + decay + 1);

        uint24 feeAfterDecay = hook.getCurrentFee(key);
        console.log("Fee after decay window:", feeAfterDecay);

        assertEq(feeAfterDecay, BASE_FEE,
            "Fee must decay to BASE_FEE after block decay window");
    }

    function test_RepeatedSandwich_EachBlockPenalized() public {
        for (uint i = 0; i < 3; i++) {
            _nextBlock();

            vm.startPrank(trader);
            _swap(true,  -500 ether);
            _swap(false,  500 ether);
            vm.stopPrank();

            assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE,
                string(abi.encodePacked("Block ", vm.toString(i + 1), ": sandwich not penalized")));
        }
    }

    function test_NormalTrader_NoPenalty() public {
        vm.prank(trader);
        _swap(true, -100 ether);

        uint24 fee1 = hook.getCurrentFee(key);
        assertTrue(fee1 != MEV_PENALTY_FEE, "Normal buy should NOT trigger penalty");

        _nextBlock();

        vm.prank(trader);
        _swap(false, 100 ether);

        uint24 fee2 = hook.getCurrentFee(key);
        assertTrue(fee2 != MEV_PENALTY_FEE, "Normal sell in new block should NOT trigger penalty");
    }
}
