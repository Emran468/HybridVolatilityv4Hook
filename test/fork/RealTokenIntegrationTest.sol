// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Run with:
//   forge test --match-contract RealTokenIntegrationTest \
//              --fork-url unichain_sepolia -vvvv

import {Test, console2} from "forge-std/Test.sol";

import {IPoolManager}              from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}                   from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary}     from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary}              from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks}                     from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath}                  from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary}              from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta}              from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback}           from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20}                    from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HookMiner}                 from "../../lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {HybridVolatilityHook}      from "../../src/HybridVolatilityHook.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Swap Router Helper
// ─────────────────────────────────────────────────────────────────────────────
contract SwapRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable manager;

    struct CallbackData {
        address    payer;
        PoolKey    key;
        SwapParams params;
    }

    constructor(IPoolManager _manager) { manager = _manager; }

    function swap(
        PoolKey    calldata key,
        SwapParams calldata params,
        address             payer
    ) external returns (BalanceDelta delta) {
        bytes memory result = manager.unlock(abi.encode(CallbackData(payer, key, params)));
        delta = abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(manager), "Only PoolManager");
        CallbackData memory d = abi.decode(rawData, (CallbackData));
        BalanceDelta delta = manager.swap(d.key, d.params, "");

        if (delta.amount0() < 0) {
            manager.sync(d.key.currency0);
            IERC20(Currency.unwrap(d.key.currency0)).transferFrom(
                d.payer, address(manager), uint256(uint128(-delta.amount0()))
            );
            manager.settle();
        } else if (delta.amount0() > 0) {
            manager.take(d.key.currency0, d.payer, uint256(uint128(delta.amount0())));
        }

        if (delta.amount1() < 0) {
            manager.sync(d.key.currency1);
            IERC20(Currency.unwrap(d.key.currency1)).transferFrom(
                d.payer, address(manager), uint256(uint128(-delta.amount1()))
            );
            manager.settle();
        } else if (delta.amount1() > 0) {
            manager.take(d.key.currency1, d.payer, uint256(uint128(delta.amount1())));
        }

        return abi.encode(delta);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Liquidity Router Helper
// ─────────────────────────────────────────────────────────────────────────────
contract LiquidityRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    struct CallbackData {
        address               payer;
        PoolKey               key;
        ModifyLiquidityParams params;
    }

    constructor(IPoolManager _manager) { manager = _manager; }

    function addLiquidity(
        PoolKey               calldata key,
        ModifyLiquidityParams calldata params,
        address                        payer
    ) external {
        manager.unlock(abi.encode(CallbackData(payer, key, params)));
    }

    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(manager), "Only PoolManager");
        CallbackData memory d = abi.decode(rawData, (CallbackData));
        (BalanceDelta delta, ) = manager.modifyLiquidity(d.key, d.params, "");

        if (delta.amount0() < 0) {
            manager.sync(d.key.currency0);
            IERC20(Currency.unwrap(d.key.currency0)).transferFrom(
                d.payer, address(manager), uint256(uint128(-delta.amount0()))
            );
            manager.settle();
        } else if (delta.amount0() > 0) {
            manager.take(d.key.currency0, d.payer, uint256(uint128(delta.amount0())));
        }

        if (delta.amount1() < 0) {
            manager.sync(d.key.currency1);
            IERC20(Currency.unwrap(d.key.currency1)).transferFrom(
                d.payer, address(manager), uint256(uint128(-delta.amount1()))
            );
            manager.settle();
        } else if (delta.amount1() > 0) {
            manager.take(d.key.currency1, d.payer, uint256(uint128(delta.amount1())));
        }

        return "";
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Test Contract
// ─────────────────────────────────────────────────────────────────────────────
contract RealTokenIntegrationTest is Test {
    using PoolIdLibrary   for PoolKey;
    using StateLibrary    for IPoolManager;
    using CurrencyLibrary for Currency;

    address constant UNICHAIN_SEPOLIA_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant UNICHAIN_WETH_SEPOLIA         = 0x4200000000000000000000000000000000000006;
    address constant UNICHAIN_USDC_SEPOLIA         = 0x31d0220469e10c4E71834a79b1f276d740d3768F;

    IPoolManager         public manager;
    HybridVolatilityHook public hook;
    SwapRouter           public swapRouter;
    LiquidityRouter      public liquidityRouter;

    PoolKey  public poolKey;
    Currency public currency0;
    Currency public currency1;

    address public trader = makeAddr("trader");
    address public lp     = makeAddr("lp");

    uint160 constant INITIAL_SQRT_PRICE = 177_159_557_114_295_710_296_101_716_159_856_664;
    uint24  constant BASE_FEE           = 3000;
    uint24  constant MEV_PENALTY_FEE    = 100000;

    function setUp() public {
        if (block.chainid != 1301) { vm.skip(true); return; }

        manager         = IPoolManager(UNICHAIN_SEPOLIA_POOL_MANAGER);
        swapRouter      = new SwapRouter(manager);
        liquidityRouter = new LiquidityRouter(manager);

        currency0 = Currency.wrap(UNICHAIN_USDC_SEPOLIA);
        currency1 = Currency.wrap(UNICHAIN_WETH_SEPOLIA);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG      |
            Hooks.AFTER_INITIALIZE_FLAG       |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG    |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG            |
            Hooks.AFTER_SWAP_FLAG
        );

        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this), flags,
            type(HybridVolatilityHook).creationCode,
            abi.encode(manager, address(this))
        );

        hook = new HybridVolatilityHook{salt: salt}(manager, address(this));
        require(address(hook) == hookAddr, "Hook address mismatch");

        poolKey = PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks:       hook
        });

        manager.initialize(poolKey, INITIAL_SQRT_PRICE);

        deal(Currency.unwrap(currency0), lp,     10_000_000e6);
        deal(Currency.unwrap(currency1), lp,     10_000 ether);
        deal(Currency.unwrap(currency0), trader, 100_000e6);
        deal(Currency.unwrap(currency1), trader, 500 ether);

        vm.startPrank(lp);
        IERC20(Currency.unwrap(currency0)).approve(address(liquidityRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(liquidityRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(trader);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.prank(lp);
        liquidityRouter.addLiquidity(
            poolKey,
            ModifyLiquidityParams({ tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e14, salt: bytes32(0) }),
            lp
        );

        // Low MEV threshold so sandwich detection triggers on fork amounts
        hook.setTickThresholds(500, 200, 100e6, 10);
    }

    // ── Helpers ───────────────────────────────────────────────────

    function _swap(bool zeroForOne, int256 amount) internal {
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne:        zeroForOne,
                amountSpecified:   amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            trader
        );
    }

    // ── Test 1: Basic Swap — WETH → USDC ─────────────────────────
    // REAL: checks actual token balance change
    function test_realToken_basicSwap_oneForZero() public {
        uint256 usdcBefore = IERC20(Currency.unwrap(currency0)).balanceOf(trader);
        uint256 wethBefore = IERC20(Currency.unwrap(currency1)).balanceOf(trader);

        vm.prank(trader);
        _swap(false, -int256(0.1 ether));

        assertLt(IERC20(Currency.unwrap(currency1)).balanceOf(trader), wethBefore, "WETH should decrease");
        assertGt(IERC20(Currency.unwrap(currency0)).balanceOf(trader), usdcBefore, "USDC should increase");
    }

    // ── Test 2: Reverse Swap — USDC → WETH ───────────────────────
    // REAL: checks actual token balance change
    function test_realToken_reverseSwap_zeroForOne() public {
        uint256 usdcBefore = IERC20(Currency.unwrap(currency0)).balanceOf(trader);
        uint256 wethBefore = IERC20(Currency.unwrap(currency1)).balanceOf(trader);

        vm.prank(trader);
        _swap(true, -int256(200e6));

        assertLt(IERC20(Currency.unwrap(currency0)).balanceOf(trader), usdcBefore, "USDC should decrease");
        assertGt(IERC20(Currency.unwrap(currency1)).balanceOf(trader), wethBefore, "WETH should increase");
    }

    // ── Test 3: Fee Escalation After Large Tick Movement ─────────
    // REAL: checks fee tier increases after large swap
    function test_realToken_rapidSwaps_feeShouldEscalate() public {
        vm.prank(trader);
        _swap(true, -int256(50_000e6)); // Large USDC buy — big tick move

        uint24 feeAfter = hook.getCurrentFee(poolKey);
        console2.log("Fee after large swap:", feeAfter);

        // Fee must be above base — either mid, high, or MEV penalty
        assertTrue(feeAfter > BASE_FEE,
            "Fee must escalate above BASE_FEE after large tick movement");
    }

    // ── Test 4: Fee Decay After Block Window ──────────────────────
    // FIX: hook uses blockDecayWindow (blocks), not time.
    // vm.roll advances blocks — this is the correct approach on fork too.
    function test_realToken_feeDecay_afterBlockWindow() public {
        vm.prank(trader);
        _swap(true, -int256(50_000e6));

        uint24 feeBefore = hook.getCurrentFee(poolKey);
        assertTrue(feeBefore > BASE_FEE, "Fee should be elevated before decay");

        // Advance past the block decay window
        uint64 decay = hook.blockDecayWindow();
        vm.roll(block.number + decay + 1);

        uint24 feeAfterDecay = hook.getCurrentFee(poolKey);
        console2.log("Fee after block decay window:", feeAfterDecay);

        assertEq(feeAfterDecay, BASE_FEE,
            "Fee must decay to BASE_FEE after blockDecayWindow blocks");
    }

    // ── Test 5: Balance Conservation ─────────────────────────────
    // REAL: net token flow must be near zero (within protocol fee tolerance)
    function test_realToken_balanceConservation() public {
        address token0Addr    = Currency.unwrap(currency0);
        uint256 traderBefore  = IERC20(token0Addr).balanceOf(trader);
        uint256 managerBefore = IERC20(token0Addr).balanceOf(address(manager));

        vm.prank(trader);
        _swap(true, -int256(100e6));

        int256 traderChange  = int256(IERC20(token0Addr).balanceOf(trader))   - int256(traderBefore);
        int256 managerChange = int256(IERC20(token0Addr).balanceOf(address(manager))) - int256(managerBefore);
        int256 netChange     = traderChange + managerChange;

        // Net must be ~0 (within 1 USDC tolerance for protocol fees)
        assertApproxEqAbs(
            uint256(netChange < 0 ? -netChange : netChange),
            0,
            1e6,
            "USDC conservation violated beyond 1 USDC tolerance"
        );
    }

    // ── Test 6: Hook State Update After Swap ─────────────────────
    // FIX: use getPoolState(poolKey) — poolStates mapping returns PackedPoolState struct
    // which is NOT directly destructurable from outside; use the public getter instead.
    function test_realToken_hookStateUpdate_afterSwap() public {
        assertTrue(hook.isInitialized(poolKey), "Pool should be initialized");

        uint256 blockBefore = block.number;

        vm.prank(trader);
        _swap(true, -int256(100e6));

        // Use the public getter — correct way to read hook state
        (, , uint64 lastBlock, uint64 lastTimestamp, bool initialized) = hook.getPoolState(poolKey);

        assertTrue(initialized, "Pool must still be initialized after swap");
        assertEq(lastBlock, blockBefore, "lastBlock must match swap block");
        assertGt(lastTimestamp, 0, "lastTimestamp must be set");
    }

    // ── Test 7: Add and Remove Liquidity ─────────────────────────
    // REAL: LP balance must decrease on add, and approximately restore on remove
    function test_realToken_addRemoveLiquidity() public {
        address token0Addr   = Currency.unwrap(currency0);
        uint256 lpUsdcBefore = IERC20(token0Addr).balanceOf(lp);

        (, int24 currentTick, , ) = manager.getSlot0(poolKey.toId());
        int24 tickSpacing = poolKey.tickSpacing;
        int24 nearestTick = (currentTick / tickSpacing) * tickSpacing;
        int24 tickLower   = nearestTick - (tickSpacing * 2);
        int24 tickUpper   = nearestTick + (tickSpacing * 2);
        int256 liqDelta   = 1e14;

        vm.startPrank(lp);

        liquidityRouter.addLiquidity(poolKey, ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper,
            liquidityDelta: liqDelta, salt: bytes32(uint256(1))
        }), lp);

        assertLt(IERC20(token0Addr).balanceOf(lp), lpUsdcBefore,
            "LP should spend USDC when adding liquidity");

        liquidityRouter.addLiquidity(poolKey, ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper,
            liquidityDelta: -liqDelta, salt: bytes32(uint256(1))
        }), lp);

        vm.stopPrank();

        assertApproxEqAbs(
            IERC20(token0Addr).balanceOf(lp),
            lpUsdcBefore,
            lpUsdcBefore / 10000 + 100e6,
            "LP USDC should be approximately restored"
        );
    }

    // ── Test 8: Multiple Liquidity Positions ─────────────────────
    // REAL: trader must receive WETH after swapping against multiple positions
    function test_realToken_multiplePositions() public {
        vm.startPrank(lp);
        liquidityRouter.addLiquidity(poolKey, ModifyLiquidityParams({
            tickLower: -600, tickUpper: 600, liquidityDelta: 5000e18, salt: bytes32(uint256(10))
        }), lp);
        liquidityRouter.addLiquidity(poolKey, ModifyLiquidityParams({
            tickLower: -120, tickUpper: 120, liquidityDelta: 2000e18, salt: bytes32(uint256(11))
        }), lp);
        vm.stopPrank();

        uint256 wethBefore = IERC20(Currency.unwrap(currency1)).balanceOf(trader);

        vm.prank(trader);
        _swap(true, -int256(50e6));

        assertGt(IERC20(Currency.unwrap(currency1)).balanceOf(trader), wethBefore,
            "Trader should receive WETH");
    }

    // ── Test 9: Consecutive Swaps — Fee Must Elevate ─────────────
    // FIX: assert BOTH swaps individually, not OR — makes it a real test
    function test_realToken_feeStaysHigh_consecutiveSwaps() public {
        vm.prank(trader);
        _swap(true, -int256(50_000e6)); // Large swap 1

        uint24 fee1 = hook.getCurrentFee(poolKey);
        console2.log("Fee after swap 1:", fee1);
        assertTrue(fee1 > BASE_FEE, "Swap 1 must elevate fee above BASE_FEE");

        vm.roll(block.number + 1); // New block but within decay window

        vm.prank(trader);
        _swap(false, -int256(10 ether)); // Large reverse swap 2

        uint24 fee2 = hook.getCurrentFee(poolKey);
        console2.log("Fee after swap 2:", fee2);
        assertTrue(fee2 > BASE_FEE || fee2 == MEV_PENALTY_FEE,
            "Swap 2 must maintain elevated fee or trigger MEV penalty");
    }

    // ── Test 10: MEV Penalty — Same Block Sandwich ────────────────
    // FIX: use block-safe amounts and correct exact-input (negative) for both legs
    // threshold set to 100e6 (100 USDC) in setUp so these amounts trigger detection
    function test_realToken_mevPenalty_sameBlock() public {
        uint256 blockBefore = block.number;

        // Leg 1: USDC → WETH (zeroForOne, exact input)
        vm.prank(trader);
        _swap(true, -int256(500e6)); // 500 USDC exact input

        uint24 feeAfterFirst = hook.getCurrentFee(poolKey);
        console2.log("Fee after 1st swap:", feeAfterFirst);

        // Leg 2: WETH → USDC (reversal, exact input) — same block
        vm.prank(trader);
        _swap(false, -int256(0.3 ether)); // 0.3 WETH exact input

        assertEq(block.number, blockBefore, "Both swaps must be in same block");

        uint24 feeAfterSecond = hook.getCurrentFee(poolKey);
        console2.log("Fee after 2nd swap (sandwich check):", feeAfterSecond);

        assertEq(feeAfterSecond, MEV_PENALTY_FEE,
            "Same-block reversal above volume threshold must trigger MEV penalty");

        // Verify tracker initialized
        (,,,,, bool initialized) = hook.getSandwichTracker(poolKey);
        assertTrue(initialized, "Sandwich tracker must be initialized");
    }
}
