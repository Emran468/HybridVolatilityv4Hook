// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HybridVolatilityHook} from "../src/HybridVolatilityHook.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract SandwichSecurityTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    HybridVolatilityHook hook;

    uint24 constant BASE_FEE        = 3000;
    uint24 constant MID_FEE         = 6000;
    uint24 constant HIGH_FEE        = 15000;
    uint24 constant MEV_PENALTY_FEE = 100000;

    PoolSwapTest.TestSettings internal SETTINGS =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    event SandwichDetected(
        PoolId indexed poolId,
        int24 firstMove,
        int24 lastMove,
        uint256 blockVolume,
        uint24 feeApplied
    );

    function setUp() public {
        vm.warp(1000);
        vm.roll(1000);

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        IERC20(Currency.unwrap(currency0)).approve(address(manager), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(manager), type(uint256).max);

        swapRouter = new PoolSwapTest(manager);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG      |
            Hooks.AFTER_INITIALIZE_FLAG       |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG    |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG            |
            Hooks.AFTER_SWAP_FLAG
        );

        (address predicted, bytes32 salt) = HookMiner.find(
            address(this), flags,
            type(HybridVolatilityHook).creationCode,
            abi.encode(manager, address(this))
        );

        hook = new HybridVolatilityHook{salt: salt}(manager, address(this));
        require(address(hook) == predicted, "Hook address mismatch");

        key = PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks:       IHooks(address(hook))
        });

        manager.initialize(key, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:      -887220,
                tickUpper:       887220,
                liquidityDelta:  1_000_000 ether,
                salt:            bytes32(0)
            }),
            ZERO_BYTES
        );

        hook.setTickThresholds(500, 200, 0.001 ether, 10);
    }

    // ── Helpers ───────────────────────────────────────────────────

    function _doSwap(bool zeroForOne, int256 amount) internal {
        SwapParams memory params = SwapParams({
            zeroForOne:        zeroForOne,
            amountSpecified:   amount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(key, params, SETTINGS, ZERO_BYTES);
    }

    function _setLowThreshold() internal {
        hook.setTickThresholds(500, 200, 0.001 ether, 10);
    }

    function _nextBlock() internal {
        vm.roll(block.number + 1);
    }

    // ── Tests ─────────────────────────────────────────────────────

    // Buy → Buy → Sell in same block → classic sandwich
    function test_fail_sandwich_fee_rejection_classic() public {
        _setLowThreshold();
        _doSwap(true, -500 ether);
        _doSwap(true, -200 ether);
        _doSwap(false, 500 ether);
        assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE,
            "Classic sandwich must trigger 10% MEV penalty fee");
    }

    // Sell → Buy in same block → reverse sandwich
    function test_fail_sandwich_fee_rejection_reverse() public {
        _setLowThreshold();
        _doSwap(false, 1000 ether);
        _doSwap(true, -500 ether);
        assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE,
            "Reverse sandwich must trigger 10% MEV penalty fee");
    }

    // Normal trader: each swap in a different block — no sandwich possible
    function test_fail_sandwich_normal_trader_no_penalty() public {
        // High threshold so small swaps never trigger penalty
        hook.setTickThresholds(500, 200, 10_000 ether, 10);

        _doSwap(true, -10 ether);
        uint24 fee1 = hook.getCurrentFee(key);
        assertTrue(fee1 != MEV_PENALTY_FEE, "Normal buy should NOT trigger penalty");

        _nextBlock(); // new block — tracker resets

        _doSwap(false, 10 ether);
        uint24 fee2 = hook.getCurrentFee(key);
        assertTrue(fee2 != MEV_PENALTY_FEE, "Normal sell in new block should NOT trigger penalty");
    }

    // Volume below threshold → no penalty
    function test_fail_sandwich_below_volume_threshold_no_penalty() public {
        hook.setTickThresholds(500, 200, 10 ether, 10);
        _doSwap(true,  -0.5 ether);
        _doSwap(false,  0.5 ether);
        assertTrue(hook.getCurrentFee(key) != MEV_PENALTY_FEE,
            "Small volume below threshold should NOT trigger penalty");
    }

    // Volume above threshold → penalty
    function test_fail_sandwich_above_volume_threshold_penalty() public {
        hook.setTickThresholds(500, 200, 100 ether, 10);
        _nextBlock();
        _doSwap(true,  -500 ether);
        _doSwap(false,  500 ether);
        assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE,
            "Large volume sandwich above threshold MUST trigger penalty");
    }

    // SandwichDetected event must be emitted on detection
    function test_fail_sandwich_event_emitted() public {
        _setLowThreshold();
        _doSwap(true, -1000 ether);
        vm.expectEmit(true, false, false, false);
        emit SandwichDetected(key.toId(), 0, 0, 0, MEV_PENALTY_FEE);
        _doSwap(false, 1000 ether);
    }

    // After blockDecayWindow blocks, fee must return to BASE_FEE
    function test_fail_sandwich_fee_decays_after_attack() public {
        _setLowThreshold();
        _doSwap(true,  -1000 ether);
        _doSwap(false,  1000 ether);
        assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE, "Should have penalty fee");

        vm.roll(block.number + hook.blockDecayWindow() + 1);
        assertEq(hook.getCurrentFee(key), BASE_FEE,
            "Fee must decay to BASE_FEE after blockDecayWindow");
    }

    // Buy in block N, sell in block N+1 — different blocks → no sandwich
    function test_fail_sandwich_cross_block_no_penalty() public {
        _setLowThreshold();
        _doSwap(true, -1000 ether);
        _nextBlock(); // tracker resets on new block
        _doSwap(false, 1000 ether);
        assertTrue(hook.getCurrentFee(key) != MEV_PENALTY_FEE,
            "Cross-block transactions should NOT trigger sandwich penalty");
    }

    // 5 consecutive blocks — each block has its own independent sandwich detection
    function test_fail_sandwich_repeated_attacks_all_penalized() public {
        _setLowThreshold();
        for (uint i = 0; i < 5; i++) {
            _nextBlock();
            uint256 blockNum = block.number;
            _doSwap(true,  -1000 ether);
            _doSwap(false,  1000 ether);
            assertEq(block.number, blockNum, "Must be same block");
            assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE,
                string(abi.encodePacked("Attack #", vm.toString(i + 1), " must be penalized")));
        }
    }

    // Attacker pays 33x more fee than normal trader
    function test_fail_sandwich_economic_deterrent_proof() public {
        _setLowThreshold();
        uint256 normalFee = uint256(BASE_FEE);

        _doSwap(true,  -1000 ether);
        _doSwap(false,  1000 ether);

        uint256 attackerFee  = uint256(hook.getCurrentFee(key));
        uint256 tradeAmount  = 1000 ether;
        uint256 normalCost   = (tradeAmount * normalFee)   / 1_000_000;
        uint256 attackerCost = (tradeAmount * attackerFee) / 1_000_000;

        assertEq(attackerFee, uint256(MEV_PENALTY_FEE));
        assertEq(normalFee,   uint256(BASE_FEE));
        assertTrue(attackerCost > normalCost * 30,
            "Attacker must pay 30x+ more than normal trader");
    }

    // After detection: tracker resets to 1 swap with the back-run move
    function test_fail_sandwich_tracker_cleanup_after_detection() public {
        hook.setTickThresholds(500, 200, 500 ether, 80);
        _doSwap(true, -1000 ether);
        _doSwap(false, 1000 ether);

        (int24 firstMove, int24 lastMove, , , uint256 swapCount, bool initialized) =
            hook.getSandwichTracker(key);

        assertTrue(initialized, "Tracker must remain initialized");
        assertEq(swapCount, 1, "Swap count must reset to 1 after detection");
        assertNotEq(firstMove, 0, "First move should capture the resetting swap");
        assertEq(firstMove, lastMove, "On reset, firstMove and lastMove must be identical");
    }

    // All 3 attack patterns must be independently detected
    function test_fail_sandwich_security_enforcement_summary() public {
        _setLowThreshold();
        uint256 detected = 0;

        { _nextBlock(); _doSwap(true, -1000 ether); _doSwap(false, 1000 ether);
          if (hook.getCurrentFee(key) == MEV_PENALTY_FEE) detected++; }

        { _nextBlock(); _doSwap(false, 1000 ether); _doSwap(true, -1000 ether);
          if (hook.getCurrentFee(key) == MEV_PENALTY_FEE) detected++; }

        { _nextBlock(); _doSwap(true, -500 ether); _doSwap(true, -300 ether);
          _doSwap(false, 500 ether);
          if (hook.getCurrentFee(key) == MEV_PENALTY_FEE) detected++; }

        assertEq(detected, 3, "All 3 sandwich attack patterns must be detected");
    }
}
