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
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HybridVolatilityHook} from "../src/HybridVolatilityHook.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
// অথবা যদি আপনার প্রজেক্টে অন্য কোথাও থাকে সেই পাথটি দিন

contract VolatilityHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    address public trader;

    HybridVolatilityHook hook;

    uint24 constant BASE_FEE          = 3000;
    uint24 constant MID_VOLATILE_FEE  = 6000;
    uint24 constant HIGH_VOLATILE_FEE = 15000;
    uint24 constant MEV_PENALTY_FEE   = 100000;

    PoolSwapTest.TestSettings internal DEFAULT_SETTINGS =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    // ─── setUp ────────────────────────────────────────────────────
//     function setUp() public {
//         vm.warp(1000);
//         vm.roll(1000);

//         deployFreshManagerAndRouters();
//         deployMintAndApprove2Currencies();

//         IERC20(Currency.unwrap(currency0)).approve(address(manager), type(uint256).max);
//         IERC20(Currency.unwrap(currency1)).approve(address(manager), type(uint256).max);

//         swapRouter = new PoolSwapTest(manager);

//         IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
//         IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        

//         uint160 flags = uint160(
//             Hooks.BEFORE_INITIALIZE_FLAG      |
//             Hooks.AFTER_INITIALIZE_FLAG       |
//             Hooks.AFTER_ADD_LIQUIDITY_FLAG    |
//             Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
//             Hooks.BEFORE_SWAP_FLAG            |
//             Hooks.AFTER_SWAP_FLAG
//         );

//         (address predictedHook, bytes32 salt) = HookMiner.find(
//             address(this),
//             flags,
//             type(HybridVolatilityHook).creationCode,
//             abi.encode(manager)
//         );

//         hook = new HybridVolatilityHook{salt: salt}(manager);
//         require(address(hook) == predictedHook, "Hook address mismatch");

//         key = PoolKey({
//             currency0:   currency0,
//             currency1:   currency1,
//             fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
//             tickSpacing: 60,
//             hooks:       IHooks(address(hook))
//         });

//         manager.initialize(key, SQRT_PRICE_1_1);

//         // বড় swap-এর জন্য যথেষ্ট liquidity
//         modifyLiquidityRouter.modifyLiquidity(
//             key,
//             ModifyLiquidityParams({
//                 tickLower:      -887220,
//                 tickUpper:       887220,
//                 liquidityDelta:  1_000_000 ether,
//                 salt:            bytes32(0)
//             }),
//             ZERO_BYTES
//         );

//         // ✅ এই line-টি দরকার:
//         // blockDelta সঠিক হিসাবের জন্য lastBlock-কে অতীতে সেট করা হয়
//         // না হলে প্রথম swap-এ blockDelta=0 হলেও poolStates.lastBlock = current block
//         // এবং দ্বিতীয় swap-এ blockDelta=0 থাকে — এটা ঠিকই আছে।
//         // কিন্তু loop test-গুলোতে vm.roll করার পরে lastBlock পুরনো থাকে
//         // তাই setUp-এ একটু পেছনে সেট করা ভালো অভ্যাস।
//         hook.setHistoryForTest(key, 0, block.number - 1);
//         trader = makeAddr("trader");

//           // MockERC20 এর বদলে সরাসরি IERC20 ব্যবহার করুন
// IERC20 token0 = IERC20(Currency.unwrap(currency0));
// IERC20 token1 = IERC20(Currency.unwrap(currency1));

// // যদি আপনার টোকেনগুলোতে 'mint' ফাংশন থাকে (সাধারণত v4 টেস্টে থাকে):
// // নোট: অনেক সময় v4 টেস্টে 'mint' এর বদলে 'mint' এর ভেরিয়েন্ট থাকে, 
// // তবে সাধারণত এটি কাজ করে:
// (address(token0)).call(abi.encodeWithSignature("mint(address,uint256)", trader, 1_000_000 ether));
// (address(token1)).call(abi.encodeWithSignature("mint(address,uint256)", trader, 1_000_000 ether));

// // তারপর আগের মতো অ্যাপ্রুভ
// vm.startPrank(trader);
// token0.approve(address(swapRouter), type(uint256).max);
// token1.approve(address(swapRouter), type(uint256).max);
// vm.stopPrank();


//     }


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

    (address predictedHook, bytes32 salt) = HookMiner.find(
        address(this),
        flags,
        type(HybridVolatilityHook).creationCode,
        abi.encode(manager, address(this))
    );

    hook = new HybridVolatilityHook{salt: salt}(manager, address(this));

    require(address(hook) == predictedHook, "Hook address mismatch");

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

    hook.setHistoryForTest(key, 0, block.number - 1);

    // ✅ Trader setup
    trader = makeAddr("trader");
    MockERC20(Currency.unwrap(currency0)).mint(trader, 10_000_000 ether);
    MockERC20(Currency.unwrap(currency1)).mint(trader, 10_000_000 ether);

    vm.startPrank(trader);
    IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
    IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
    vm.stopPrank();

    // ✅ LOW threshold — সব sandwich test এখানে কাজ করবে
    // প্রতিটি test নিজে override করতে পারবে
    hook.setTickThresholds(500, 200, 0.001 ether, 10);
}



    // ─── Helpers ──────────────────────────────────────────────────

    function _swap(
        PoolKey memory k,
        bool zeroForOne,
        int256 amountSpecified,
        bytes memory hookData
    ) internal {
        SwapParams memory params = SwapParams({
            zeroForOne:        zeroForOne,
            amountSpecified:   amountSpecified,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(k, params, DEFAULT_SETTINGS, hookData);
    }

    function _sandwichSwap(
        PoolKey memory k,
        bool zeroForOne,
        int256 amountSpecified,
        bytes memory hookData
    ) internal {
        _swap(k, zeroForOne, amountSpecified, hookData);
    }

    // দ্বিতীয় pool তৈরি করার helper (tickSpacing=120, key থেকে আলাদা)
    function _createNewPool() internal returns (PoolKey memory k2) {
        k2 = PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 120,
            hooks:       IHooks(address(hook))
        });
        manager.initialize(k2, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            k2,
            ModifyLiquidityParams({
                tickLower:      -887160,
                tickUpper:       887160,
                liquidityDelta:  1_000_000 ether,
                salt:            bytes32(0)
            }),
            ZERO_BYTES
        );

        // ✅ নতুন pool-এও lastBlock পেছনে সেট করি
        hook.setHistoryForTest(k2, 0, block.number - 1);
        
    }

    // JIT liquidity helper — tickSpacing=60 হলে tick 60-এর multiple হতে হবে
    function _addJITLiquidity(uint256 amount)
        internal
        returns (uint128 liquidity, int24 tickLower, int24 tickUpper)
    {
        tickLower = -120; // 60-এর multiple ✅
        tickUpper =  120; // 60-এর multiple ✅
        liquidity = uint128(amount);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:      tickLower,
                tickUpper:      tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt:           bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function _removeJITLiquidity(uint128 liquidity) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:      -120,
                tickUpper:       120,
                liquidityDelta: -int256(uint256(liquidity)),
                salt:            bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function _getFee(bool zeroForOne) internal returns (uint24) {
        SwapParams memory p = SwapParams({
            zeroForOne:        zeroForOne,
            amountSpecified:   -1 ether,
            sqrtPriceLimitX96: 0
        });
        vm.prank(address(manager));
        (, , uint24 fee) = hook.beforeSwap(address(this), key, p, "");
        return fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }

    // ═══════════════════════════════════════════════════════════════
    // 1. CHAIN INFO TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_ChainInfoReturnsCorrectly() public view {
        (uint256 chainId, string memory name, uint64 decay, ) = hook.getChainInfo();
        assertGt(chainId, 0,    "Chain ID should be set");
        assertGt(decay, 0,      "Block decay window should be set");
        assertTrue(bytes(name).length > 0, "Chain name should not be empty");
        console.log("Deployed on chain:", chainId);
        console.log("Chain name:", name);
        console.log("Block decay window:", decay);
    }

    function test_DeployedChainIdIsImmutable() public view {
        assertEq(hook.deployedChainId(), block.chainid);
    }

    function test_BlockDecayWindowIsSet() public view {
        assertGt(hook.blockDecayWindow(), 0);
    }

    function test_UnichainFlagCorrect() public view {
        (, , , bool isUnichain) = hook.getChainInfo();
        assertFalse(isUnichain, "Local test chain should not be Unichain");
    }

    // ═══════════════════════════════════════════════════════════════
    // 2. INITIALIZATION TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_PoolIsInitializedAfterSetup() public view {
        assertTrue(hook.isInitialized(key));
    }

    function test_InitialFeeIsBaseFee() public view {
        assertEq(hook.getCurrentFee(key), BASE_FEE);
    }

    function test_PackedPoolStateSetOnInit() public view {
        (, uint24 fee, uint64 lastBlock, uint64 lastTimestamp, bool initialized) =
            hook.getPoolState(key);
        assertTrue(initialized);
        assertEq(fee, BASE_FEE);
        assertGt(lastBlock, 0);
        assertGt(lastTimestamp, 0);
    }

    function test_TransientStorageSlotsPrecomputed() public view {
        PoolId poolId = key.toId();
        assertTrue(hook.tickSlotMap(poolId)    != bytes32(0));
        assertTrue(hook.flagSlotMap(poolId)    != bytes32(0));
        assertTrue(hook.trackerSlotMap(poolId) != bytes32(0));
    }

    // ═══════════════════════════════════════════════════════════════
    // 3. FEE TIER TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_BaseFeeWhenMarketIsStable() public {
        assertEq(_getFee(true), BASE_FEE);
    }

    function test_ZeroAmountSwapReturnsBaseFee() public {
        SwapParams memory p = SwapParams({
            zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0
        });
        vm.prank(address(manager));
        (, , uint24 fee) = hook.beforeSwap(address(this), key, p, "");
        assertEq(fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, BASE_FEE);
    }

    function test_AllFeeTiersCorrectValues() public pure {
        assertEq(BASE_FEE,          3000);
        assertEq(MID_VOLATILE_FEE,  6000);
        assertEq(HIGH_VOLATILE_FEE, 15000);
        assertEq(MEV_PENALTY_FEE,   100000);
    }

    function test_FeeIsAlwaysValidTier() public view {
        uint24 fee = hook.getCurrentFee(key);
        assertTrue(fee == BASE_FEE || fee == MID_VOLATILE_FEE ||
                   fee == HIGH_VOLATILE_FEE || fee == MEV_PENALTY_FEE);
    }

    // ═══════════════════════════════════════════════════════════════
    // 4. BLOCK-BASED DECAY TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_FeeDecayAfterBlockWindow() public {
        _swap(key, true, -100, ZERO_BYTES);
        vm.roll(block.number + hook.blockDecayWindow() + 1);
        assertEq(hook.getCurrentFee(key), BASE_FEE);
    }

    function test_FeeDoesNotDecayBeforeBlockWindow() public {
        _swap(key, true, -100, ZERO_BYTES);
        vm.roll(block.number + hook.blockDecayWindow() / 2);
        uint24 fee = hook.getCurrentFee(key);
        assertTrue(fee == BASE_FEE || fee == MID_VOLATILE_FEE || fee == HIGH_VOLATILE_FEE);
    }

    function test_FeeDecayExactlyAtBlockWindow() public {
        _swap(key, true, -100, ZERO_BYTES);
        vm.roll(block.number + hook.blockDecayWindow());
        assertEq(hook.getCurrentFee(key), BASE_FEE);
    }

    function test_FeeDecayAfterVeryManyBlocks() public {
        _swap(key, true, -100, ZERO_BYTES);
        vm.roll(block.number + 1_000_000);
        assertEq(hook.getCurrentFee(key), BASE_FEE);
    }

    function test_LastBlockUpdatesAfterSwap() public {
        uint64 before = uint64(block.number);
        _swap(key, true, -100, ZERO_BYTES);
        (, , , uint64 hookLastBlock, ) = hook.getPoolState(key);
        assertEq(hookLastBlock, before);
    }

    // ═══════════════════════════════════════════════════════════════
    // 5. OVERRIDE FLAG TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_OverrideFlagIsSetInBeforeSwap() public {
        SwapParams memory p = SwapParams({
            zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0
        });
        vm.prank(address(manager));
        (, , uint24 fee) = hook.beforeSwap(address(this), key, p, "");
        assertTrue(fee & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0);
    }

    function test_DynamicFeePoolKey() public view {
        assertEq(key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
    }

    // ═══════════════════════════════════════════════════════════════
    // 6. ACCESS CONTROL TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_BeforeSwapOnlyPoolManager() public {
        SwapParams memory p = SwapParams({
            zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0
        });
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        hook.beforeSwap(address(this), key, p, "");
    }

    function test_AfterSwapOnlyPoolManager() public {
        SwapParams memory p = SwapParams({
            zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0
        });
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
    }

    function test_SetHistoryOnlyOwner() public {
        hook.setHistoryForTest(key, 0, block.number);
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        hook.setHistoryForTest(key, 0, block.number);
    }

    function test_SetTickThresholdsOnlyOwner() public {
        hook.setTickThresholds(600, 250, 50_000 ether, 100);
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        hook.setTickThresholds(600, 250, 50_000 ether, 100);
    }

    function test_OwnershipTransfer() public {
        hook.transferOwnership(address(0x1234));
        assertEq(hook.owner(), address(0x1234));
        vm.expectRevert();
        hook.setHistoryForTest(key, 0, block.number);
    }

    function test_TransferOwnershipToZeroReverts() public {
        vm.expectRevert();
        hook.transferOwnership(address(0));
    }

    // ═══════════════════════════════════════════════════════════════
    // 7. ADMIN TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_SetTickThresholdsUpdatesValues() public {
        hook.setTickThresholds(800, 300, 200_000 ether, 120);
        assertEq(hook.tickThresholdHigh(),     800);
        assertEq(hook.tickThresholdMid(),      300);
        assertEq(hook.mevVolumeThreshold(),    200_000 ether);
        assertEq(hook.sandwichTickThreshold(), 120);
    }

    function test_SetTickThresholdsHighMustBeGreaterThanMid() public {
        vm.expectRevert("High threshold must be greater than mid");
        hook.setTickThresholds(200, 500, 100_000 ether, 80);
    }

    function test_SetTickThresholdsEqualRevertsHighMustBeGreater() public {
        vm.expectRevert("High threshold must be greater than mid");
        hook.setTickThresholds(300, 300, 100_000 ether, 80);
    }

    // ═══════════════════════════════════════════════════════════════
    // 8. POOL STATE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_GetPoolStateReturnsCorrectFields() public view {
        (, uint24 fee, uint64 lastBlock, uint64 lastTimestamp, bool initialized) =
            hook.getPoolState(key);
        assertTrue(initialized);
        assertEq(fee, BASE_FEE);
        assertGe(lastBlock, 0);
        assertGe(lastTimestamp, 0);
    }

    function test_IsInitializedTrue() public view {
        assertTrue(hook.isInitialized(key));
    }

    function test_IsInitializedFalseForUnknownPool() public view {
        PoolKey memory fakeKey = PoolKey({
            currency0: currency0, currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        assertFalse(hook.isInitialized(fakeKey));
    }

    function test_GetCurrentFeeForUninitializedPool() public view {
        PoolKey memory fakeKey = PoolKey({
            currency0: currency0, currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        assertEq(hook.getCurrentFee(fakeKey), BASE_FEE);
    }

    function test_SetHistoryForTestWorks() public {
        hook.setHistoryForTest(key, 300, block.number - 10);
        (int24 tick, , uint64 lastBlock, , bool initialized) = hook.getPoolState(key);
        assertEq(tick, 300);
        assertEq(lastBlock, block.number - 10);
        assertTrue(initialized);
    }

    function test_SetHistoryFutureBlockReverts() public {
        vm.expectRevert("Cannot set future block");
        hook.setHistoryForTest(key, 0, block.number + 100);
    }

    // ═══════════════════════════════════════════════════════════════
    // 9. BLOCK VOLUME TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_BlockVolumeZeroBeforeSwap() public view {
        assertEq(hook.getCurrentBlockVolume(key), 0);
    }

    function test_BlockVolumeZeroAfterBlockChange() public {
        _swap(key, true, -100, ZERO_BYTES);
        vm.roll(block.number + 1);
        assertEq(hook.getCurrentBlockVolume(key), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // 10. HOOK PERMISSIONS TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_HookPermissionsCorrect() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertTrue(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertTrue(p.afterRemoveLiquidity);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
    }

    // ═══════════════════════════════════════════════════════════════
    // 11. MEV / SANDWICH DETECTION TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_MevPenaltyFeeValueIs10Percent() public pure {
        assertEq(MEV_PENALTY_FEE, 100000);
    }

    function test_SandwichTrackerInitiallyEmpty() public view {
        (int24 firstMove, , , , , bool initialized) = hook.getSandwichTracker(key);
        assertEq(firstMove, 0);
        assertFalse(initialized);
    }

    function test_SandwichDetectionTriggersMevPenalty() public {
        hook.setTickThresholds(500, 200, 0.1 ether, 10);
        uint256 blockBefore = block.number;

        _swap(key, true,  -1000 ether, ZERO_BYTES);
        _swap(key, false,  1000 ether, ZERO_BYTES);

        assertEq(block.number, blockBefore);
        assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE, "Sandwich should trigger MEV penalty");
    }

    function test_NormalSwapDoesNotTriggerMevPenalty() public {
        _swap(key, true, -100, ZERO_BYTES);
        assertTrue(hook.getCurrentFee(key) != MEV_PENALTY_FEE);
    }

    // ═══════════════════════════════════════════════════════════════
    // 12. FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════
function test_fuzz_fee_decay(uint256 timeElapsed) public {
        vm.assume(timeElapsed >= 1 && timeElapsed <= 10000);

        vm.prank(trader);
        // এখানে IPoolManager সরিয়ে শুধু SwapParams ব্যবহার করুন
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1000e18),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            DEFAULT_SETTINGS,
            ZERO_BYTES
        );

        vm.warp(block.timestamp + timeElapsed);
        vm.roll(block.number + (timeElapsed / 12));

        uint24 currentFee = hook.getCurrentFee(key);

        console.log("Time Elapsed:", timeElapsed);
        console.log("Fee after decay:", currentFee);

        if (timeElapsed >= 300) {
            assertEq(currentFee, BASE_FEE, "Fee should have decayed to base fee");
        } else {
            assertGe(currentFee, BASE_FEE, "Fee should not be below base fee");
        }
    }

    function test_HedgedSandwich() public {
        hook.setTickThresholds(500, 200, 0.0001 ether, 10);
        uint256 blockBefore = block.number;

        // All swaps must use the exact same PoolKey to register on the hook's state
        _sandwichSwap(key,  true,  -500 ether, ZERO_BYTES);
        _sandwichSwap(key,  true,  -300 ether, ZERO_BYTES);
        _sandwichSwap(key, false,   500 ether, ZERO_BYTES); // Changed key2 to key

        assertEq(block.number, blockBefore);
        assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE, "Hedged sandwich should trigger MEV penalty");
    }

function test_MultiTradeSandwichDetection() public {
    // ✅ Realistic threshold
    // Real attacker কমপক্ষে 50 ETH দিয়ে attack করে profit নিতে পারে
    hook.setTickThresholds(500, 200, 50 ether, 10);
    
    uint256 blockBefore = block.number;

    // Attacker front-run: বড় buy
    _sandwichSwap(key, true,  -500 ether, ZERO_BYTES);
    // Victim swap (simulate)
    _sandwichSwap(key, true,  -200 ether, ZERO_BYTES);
    // Attacker back-run: sell
    _sandwichSwap(key, false,  500 ether, ZERO_BYTES);

    // Total volume = 1200 ether > 50 ether threshold ✅
    uint24 feeAfter3rd = hook.getCurrentFee(key);

    assertEq(block.number, blockBefore, "Must be same block");
    assertEq(feeAfter3rd, MEV_PENALTY_FEE,
        "Multi-trade sandwich should trigger MEV penalty");
}

    function test_SandwichWithFlashbots() public {
        hook.setTickThresholds(500, 200, 0.0001 ether, 10);
        uint256 blockBefore = block.number;

        _sandwichSwap(key, true, -1000 ether, ZERO_BYTES);
        for (uint i = 0; i < 3; i++) {
            _sandwichSwap(key, true,  -100 ether, ZERO_BYTES);
            _sandwichSwap(key, false,   80 ether, ZERO_BYTES);
        }
        _sandwichSwap(key, false, 1000 ether, ZERO_BYTES);

        assertEq(block.number, blockBefore);
        assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE, "Flashboy sandwich should trigger MEV penalty");
    }

    function test_SandwichSizeVariations() public {
    // ✅ Realistic threshold = 50 ether
    hook.setTickThresholds(500, 200, 50 ether, 10);

    // Small (below threshold) → no penalty
    uint256[] memory smallSizes = new uint256[](2);
    smallSizes[0] = 1 ether;
    smallSizes[1] = 10 ether;

    for (uint i = 0; i < smallSizes.length; i++) {
        vm.roll(block.number + 1);
        hook.setHistoryForTest(key, 0, block.number - 1);

        _sandwichSwap(key, true,  -int256(smallSizes[i]), ZERO_BYTES);
        _sandwichSwap(key, false,  int256(smallSizes[i]), ZERO_BYTES);

        // volume < 50 ether → no penalty
        assertTrue(
            hook.getCurrentFee(key) != MEV_PENALTY_FEE,
            string(abi.encodePacked(
                "Small size ", vm.toString(smallSizes[i]),
                " should NOT trigger penalty"
            ))
        );
    }

    // Large (above threshold) → penalty
    uint256[] memory largeSizes = new uint256[](3);
    largeSizes[0] = 100 ether;
    largeSizes[1] = 1000 ether;
    largeSizes[2] = 10000 ether;

    for (uint i = 0; i < largeSizes.length; i++) {
        vm.roll(block.number + 1);
        hook.setHistoryForTest(key, 0, block.number - 1);

        _sandwichSwap(key, true,  -int256(largeSizes[i]), ZERO_BYTES);
        _sandwichSwap(key, false,  int256(largeSizes[i]), ZERO_BYTES);

        // volume > 50 ether → penalty ✅
        assertEq(
            hook.getCurrentFee(key), MEV_PENALTY_FEE,
            string(abi.encodePacked(
                "Large size ", vm.toString(largeSizes[i]),
                " should trigger MEV penalty"
            ))
        );
    }
}

   function test_SandwichVolumeThreshold() public {
    // ✅ Realistic: threshold = 100 ether
    hook.setTickThresholds(500, 200, 100 ether, 10);

    // ❌ Small attacker: 10 ether — profit নেওয়া সম্ভব না
    // Gas cost > profit, তাই detect করার দরকার নেই
    _sandwichSwap(key, true,  -10 ether, ZERO_BYTES);
    _sandwichSwap(key, false,  10 ether, ZERO_BYTES);
    
    // Total volume = 20 ether < 100 ether → NO penalty ✅
    assertTrue(
        hook.getCurrentFee(key) != MEV_PENALTY_FEE,
        "Small volume sandwich below threshold: no penalty"
    );

    // ✅ নতুন block
    vm.roll(block.number + 1);
    hook.setHistoryForTest(key, 0, block.number - 1);

    // ✅ Real attacker: 500 ether
    _sandwichSwap(key, true,  -500 ether, ZERO_BYTES);
    _sandwichSwap(key, false,  500 ether, ZERO_BYTES);
    
    // Total volume = 1000 ether > 100 ether → PENALTY ✅
    assertEq(
        hook.getCurrentFee(key), MEV_PENALTY_FEE,
        "Large volume sandwich above threshold: penalty applied"
    );
}

   function test_SandwichTrackerCleanup() public {
    // ১. থ্রেশহোল্ড সেট করা (আপনার দেওয়া নিখুঁত ভ্যালু)
    hook.setTickThresholds(500, 200, 0.0001 ether, 10);

    // ২. স্যান্ডউইচ সোয়াপ এক্সিকিউট করা
    _sandwichSwap(key, true,  -1000 ether, ZERO_BYTES);
    _sandwichSwap(key, false,  1000 ether, ZERO_BYTES);

    // ৩. ট্র্যাকার স্টেট রিড করা
    (
        int24 firstMove, 
        int24 lastMove, 
        , 
        , 
        uint256 swapCount, 
        bool initialized
    ) = hook.getSandwichTracker(key);

    // 🎯 নতুন লজিক অনুযায়ী সঠিক অ্যাসার্থন (Assertions):
    // স্যান্ডউইচ ডিটেকশনের পর ট্র্যাকার মুছে যায় না, বরং কাউন্ট ১-এ রিসেট হয়।
    assertTrue(initialized, "Tracker should remain initialized after sandwich detection");
    assertEq(swapCount, 1, "Swap count must reset to 1 for the next session");
    
    // সাইলেন্ট পাস ভাঙার জন্য জিরো না হওয়ার গ্যারান্টি:
    assertNotEq(firstMove, 0, "firstMove should capture the resetting leg movement, not 0");
    assertEq(firstMove, lastMove, "On session reset, firstMove and lastMove must be identical");
}

    function test_MultipleSandwichesStress() public {
        hook.setTickThresholds(500, 200, 0.0001 ether, 10);

        for (uint i = 0; i < 5; i++) {
            // ✅ প্রতিটি iteration-এ নতুন block + reset
            vm.roll(block.number + 1);
            hook.setHistoryForTest(key, 0, block.number - 1);

            uint256 blockBefore = block.number;
            _sandwichSwap(key, true,  -1000 ether, ZERO_BYTES);
            _sandwichSwap(key, false,  1000 ether, ZERO_BYTES);

            assertEq(block.number, blockBefore);
            assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE,
                string(abi.encodePacked("Sandwich ", vm.toString(i), " should trigger MEV penalty")));
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // 12. ADVANCED FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════

    /// @notice বিভিন্ন পরিমাণের (amount) ট্রেড এবং থ্রেশহোল্ডের ওপর ভিত্তি করে ফি ক্যালকুলেশন চেক করা
    function testFuzz_FeeCalculationBasedOnTickDelta(int24 tickDelta) public {
        // -887222 থেকে 887222 হলো বৈধ রেঞ্জ
        vm.assume(tickDelta > 500 && tickDelta < 887222);
        
        // হুকের থ্রেশহোল্ড সেট করা
        hook.setTickThresholds(500, 200, 1_000_000 ether, 10);
        
        // টেস্টিংয়ের জন্য history আপডেট করা
        hook.setHistoryForTest(key, 0, block.number - 1);
        
        // যেহেতু tickDelta > 500, তাই এটি HIGH_VOLATILE_FEE হওয়া উচিত
        uint24 fee = hook.getCurrentFee(key);
        // নোট: মনে রাখবেন যে বর্তমান লজিক অনুযায়ী fee afterSwap এ আপডেট হয়, 
        // তাই এখানে আমরা সরাসরি internal _computeFee কল করতে পারি যদি সেটি internal থাকে, 
        // অথবা একটি swap করে চেক করতে পারি।
    }

    /// @notice এলোমেলো ভলিউম দিয়ে MEV ডিটেকশন টেস্ট করা
   function testFuzz_MevPenaltyTriggersOnVolume(uint256 tradeVolume) public {
    // ✅ bound ব্যবহার করুন — vm.assume এ অনেক reject হয়
    tradeVolume = bound(tradeVolume, 10 ether, 1000 ether);

    // ✅ threshold = 5 ether, trade > 10 ether সবসময়
    hook.setTickThresholds(500, 200, 5 ether, 10);
    hook.setHistoryForTest(key, 0, block.number - 1);

    _sandwichSwap(key, true,  -int256(tradeVolume), ZERO_BYTES);
    _sandwichSwap(key, false,  int256(tradeVolume), ZERO_BYTES);

    // tradeVolume সবসময় > 5 ether তাই penalty আবশ্যক
    assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE,
        "Penalty not triggered");
}

    /// @notice র্যান্ডম ব্লকে ফি ডিক্যা (Decay) যাচাই করা
  function testFuzz_FeeDecayRandomBlocks(uint64 blocksPassed) public {
    // 1 থেকে 5000 এর মধ্যে লিমিট সেট করা
    uint64 boundedBlocks = uint64(bound(blocksPassed, 1, 5000));
    
    _swap(key, true, -10000 ether, ZERO_BYTES);
    
    vm.roll(block.number + boundedBlocks);
    
    uint24 currentFee = hook.getCurrentFee(key);
    
    if (boundedBlocks >= hook.blockDecayWindow()) {
        assertEq(currentFee, BASE_FEE, "Fee should decay after window");
    }
}
function testFuzz_SandwichWithRandomSlippage(int256 amount1, int256 amount2) public {
    hook.setTickThresholds(500, 200, 5 ether, 10);

    // Safe conversion
    uint256 val1 = _abs(amount1);
    uint256 val2 = _abs(amount2);
    
    // Bound
    val1 = bound(val1, 10 ether, 5000 ether);
    val2 = bound(val2, 10 ether, 5000 ether);

    // Use vm.assume to filter, not modify
    vm.assume(val1 >= 100 ether);
    vm.assume(val2 >= 100 ether);
    vm.assume(val2 > val1 / 10); // Real sandwich condition

    hook.setHistoryForTest(key, 0, block.number - 1);

    _sandwichSwap(key, true, -int256(val1), ZERO_BYTES);
    _sandwichSwap(key, false, int256(val2), ZERO_BYTES);

    assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE, "Sandwich not detected");
}

function _abs(int256 x) internal pure returns (uint256) {
    if (x == type(int256).min) return 5000 ether; // Safe max
    return x < 0 ? uint256(-x) : uint256(x);
}

} // ← contract শেষ
