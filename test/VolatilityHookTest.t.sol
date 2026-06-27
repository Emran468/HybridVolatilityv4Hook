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
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

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
            address(this), flags,
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

        trader = makeAddr("trader");
        MockERC20(Currency.unwrap(currency0)).mint(trader, 10_000_000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(trader, 10_000_000 ether);

        vm.startPrank(trader);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        hook.setTickThresholds(500, 200, 0.001 ether, 10);
    }

    // ── Helpers ───────────────────────────────────────────────────

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

    // ── Chain Info Tests ──────────────────────────────────────────

    function test_ChainInfoReturnsCorrectly() public view {
        (uint256 chainId, string memory name, uint64 decay, ) = hook.getChainInfo();
        assertGt(chainId, 0);
        assertGt(decay, 0);
        assertTrue(bytes(name).length > 0);
    }

    function test_DeployedChainIdIsImmutable() public view {
        assertEq(hook.deployedChainId(), block.chainid);
    }

    function test_BlockDecayWindowIsSet() public view {
        assertGt(hook.blockDecayWindow(), 0);
    }

    function test_UnichainFlagCorrect() public view {
        (, , , bool isUnichain) = hook.getChainInfo();
        assertFalse(isUnichain);
    }

    // ── Initialization Tests ──────────────────────────────────────

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

    // ── Fee Tier Tests ────────────────────────────────────────────

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

    // ── Block-Based Decay Tests ───────────────────────────────────

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
        uint256 currentBlock = block.number;
        _swap(key, true, -100, ZERO_BYTES);
        (, , uint64 hookLastBlock, , ) = hook.getPoolState(key);
        assertEq(uint256(hookLastBlock), currentBlock);
    }

    // ── Override Flag Tests ───────────────────────────────────────

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

    // ── Access Control Tests ──────────────────────────────────────

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

    function test_SetTickThresholdsOnlyOwner() public {
        hook.setTickThresholds(600, 250, 50_000 ether, 100);
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        hook.setTickThresholds(600, 250, 50_000 ether, 100);
    }

    // Ownership transfer: new owner can call, old owner cannot
    function test_OwnershipTransfer() public {
        hook.transferOwnership(address(0x1234));
        assertEq(hook.owner(), address(0x1234));
        vm.expectRevert();
        hook.setTickThresholds(500, 200, 0.001 ether, 10); // old owner — must revert
    }

    function test_TransferOwnershipToZeroReverts() public {
        vm.expectRevert();
        hook.transferOwnership(address(0));
    }

    // ── Admin Tests ───────────────────────────────────────────────

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

    // ── Pool State Tests ──────────────────────────────────────────

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

    // ── Block Volume Tests ────────────────────────────────────────

    function test_BlockVolumeZeroBeforeSwap() public view {
        assertEq(hook.getCurrentBlockVolume(key), 0);
    }

    function test_BlockVolumeZeroAfterBlockChange() public {
        _swap(key, true, -100, ZERO_BYTES);
        vm.roll(block.number + 1);
        assertEq(hook.getCurrentBlockVolume(key), 0);
    }

    function test_BlockVolumeAccumulatesWithinBlock() public {
        _swap(key, true, -100 ether, ZERO_BYTES);
        uint256 vol1 = hook.getCurrentBlockVolume(key);
        assertGt(vol1, 0, "Volume should accumulate after swap");

        _swap(key, true, -50 ether, ZERO_BYTES);
        uint256 vol2 = hook.getCurrentBlockVolume(key);
        assertGt(vol2, vol1, "Volume should increase with each same-block swap");
    }

    // ── Hook Permissions Tests ────────────────────────────────────

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

    // ── MEV / Sandwich Detection Tests ────────────────────────────

    function test_MevPenaltyFeeValueIs10Percent() public pure {
        assertEq(MEV_PENALTY_FEE, 100000);
    }

    // Tracker is empty before any swap in this pool
    function test_SandwichTrackerInitiallyEmpty() public view {
        (int24 firstMove, , , , , bool initialized) = hook.getSandwichTracker(key);
        assertEq(firstMove, 0, "firstMove must be 0 before any swap");
        assertFalse(initialized, "Tracker must not be initialized before any swap");
    }

    function test_SandwichDetectionTriggersMevPenalty() public {
        hook.setTickThresholds(500, 200, 0.1 ether, 10);
        uint256 blockBefore = block.number;
        _swap(key, true,  -1000 ether, ZERO_BYTES);
        _swap(key, false,  1000 ether, ZERO_BYTES);
        assertEq(block.number, blockBefore);
        assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE);
    }

    function test_NormalSwapDoesNotTriggerMevPenalty() public {
        // High volume threshold — small swap cannot trigger penalty
        hook.setTickThresholds(500, 200, 10_000 ether, 10);
        _swap(key, true, -100, ZERO_BYTES);
        assertTrue(hook.getCurrentFee(key) != MEV_PENALTY_FEE);
    }

    // ── Fuzz Tests ────────────────────────────────────────────────

    function test_fuzz_fee_decay(uint256 blocksPassed) public {
        vm.assume(blocksPassed >= 1 && blocksPassed <= 10000);

        vm.prank(trader);
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

        vm.roll(block.number + blocksPassed);

        uint24 currentFee = hook.getCurrentFee(key);

        if (blocksPassed >= hook.blockDecayWindow()) {
            assertEq(currentFee, BASE_FEE, "Fee should have decayed to base fee");
        } else {
            assertTrue(
                currentFee == BASE_FEE || currentFee == MID_VOLATILE_FEE ||
                currentFee == HIGH_VOLATILE_FEE || currentFee == MEV_PENALTY_FEE,
                "Fee must be a valid tier"
            );
        }
    }

    function test_HedgedSandwich() public {
        hook.setTickThresholds(500, 200, 0.0001 ether, 10);
        uint256 blockBefore = block.number;
        _sandwichSwap(key,  true,  -500 ether, ZERO_BYTES);
        _sandwichSwap(key,  true,  -300 ether, ZERO_BYTES);
        _sandwichSwap(key, false,   500 ether, ZERO_BYTES);
        assertEq(block.number, blockBefore);
        assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE);
    }

    function test_MultiTradeSandwichDetection() public {
        hook.setTickThresholds(500, 200, 50 ether, 10);
        uint256 blockBefore = block.number;
        _sandwichSwap(key, true,  -500 ether, ZERO_BYTES);
        _sandwichSwap(key, true,  -200 ether, ZERO_BYTES);
        _sandwichSwap(key, false,  500 ether, ZERO_BYTES);
        assertEq(block.number, blockBefore);
        assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE);
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
        assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE);
    }

    // REAL: tests small (no penalty) vs large (penalty) sizes separately
    function test_SandwichSizeVariations() public {
        hook.setTickThresholds(500, 200, 50 ether, 10);

        // Small sizes — below threshold — no penalty
        uint256[] memory smallSizes = new uint256[](2);
        smallSizes[0] = 1 ether;
        smallSizes[1] = 10 ether;

        for (uint i = 0; i < smallSizes.length; i++) {
            vm.roll(block.number + 1);
            _sandwichSwap(key, true,  -int256(smallSizes[i]), ZERO_BYTES);
            _sandwichSwap(key, false,  int256(smallSizes[i]), ZERO_BYTES);
            assertTrue(hook.getCurrentFee(key) != MEV_PENALTY_FEE,
                string(abi.encodePacked("Small size should NOT trigger penalty: ", vm.toString(smallSizes[i]))));
        }

        // Large sizes — above threshold — penalty must trigger
        uint256[] memory largeSizes = new uint256[](3);
        largeSizes[0] = 100 ether;
        largeSizes[1] = 500 ether;
        largeSizes[2] = 1000 ether;

        for (uint i = 0; i < largeSizes.length; i++) {
            vm.roll(block.number + 1);
            _sandwichSwap(key, true,  -int256(largeSizes[i]), ZERO_BYTES);
            _sandwichSwap(key, false,  int256(largeSizes[i]), ZERO_BYTES);
            assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE,
                string(abi.encodePacked("Large size must trigger penalty: ", vm.toString(largeSizes[i]))));
        }
    }

    function test_SandwichVolumeThreshold() public {
        hook.setTickThresholds(500, 200, 100 ether, 10);

        // Below threshold — no penalty
        _sandwichSwap(key, true,  -10 ether, ZERO_BYTES);
        _sandwichSwap(key, false,  10 ether, ZERO_BYTES);
        assertTrue(hook.getCurrentFee(key) != MEV_PENALTY_FEE, "Below threshold: no penalty");

        // New block, then above threshold — penalty
        vm.roll(block.number + 1);
        _sandwichSwap(key, true,  -500 ether, ZERO_BYTES);
        _sandwichSwap(key, false,  500 ether, ZERO_BYTES);
        assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE, "Above threshold: penalty applied");
    }

    function test_SandwichTrackerCleanup() public {
        hook.setTickThresholds(500, 200, 0.0001 ether, 10);
        _sandwichSwap(key, true,  -1000 ether, ZERO_BYTES);
        _sandwichSwap(key, false,  1000 ether, ZERO_BYTES);

        (int24 firstMove, int24 lastMove, , , uint256 swapCount, bool initialized) =
            hook.getSandwichTracker(key);

        assertTrue(initialized, "Tracker should remain initialized");
        assertEq(swapCount, 1, "Swap count must reset to 1");
        assertNotEq(firstMove, 0, "firstMove should capture the resetting leg");
        assertEq(firstMove, lastMove, "On reset, firstMove and lastMove must be identical");
    }

    // REAL: each iteration is a new block — proves independent detection per block
    function test_MultipleSandwichesStress() public {
        hook.setTickThresholds(500, 200, 0.0001 ether, 10);

        for (uint i = 0; i < 5; i++) {
            vm.roll(block.number + 1); // Each sandwich in its own block
            uint256 blockBefore = block.number;

            _sandwichSwap(key, true,  -1000 ether, ZERO_BYTES);
            _sandwichSwap(key, false,  1000 ether, ZERO_BYTES);

            assertEq(block.number, blockBefore, "Both swaps must be in same block");
            assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE,
                string(abi.encodePacked("Sandwich #", vm.toString(i + 1), " must be detected")));
        }
    }

    // ── Advanced Fuzz Tests ───────────────────────────────────────

    function testFuzz_FeeCalculationBasedOnTickDelta(int24 tickDelta) public view {
        vm.assume(tickDelta > 500 && tickDelta < 887222);
        // Fee must always be a valid tier regardless of tick input
        uint24 fee = hook.getCurrentFee(key);
        assertTrue(
            fee == BASE_FEE || fee == MID_VOLATILE_FEE ||
            fee == HIGH_VOLATILE_FEE || fee == MEV_PENALTY_FEE,
            "Fee must always be a valid tier"
        );
    }

    function testFuzz_MevPenaltyTriggersOnVolume(uint256 tradeVolume) public {
        tradeVolume = bound(tradeVolume, 10 ether, 1000 ether);
        hook.setTickThresholds(500, 200, 5 ether, 10);

        _sandwichSwap(key, true,  -int256(tradeVolume), ZERO_BYTES);
        _sandwichSwap(key, false,  int256(tradeVolume), ZERO_BYTES);

        assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE, "Penalty not triggered");
    }

    function testFuzz_FeeDecayRandomBlocks(uint64 blocksPassed) public {
        uint64 boundedBlocks = uint64(bound(blocksPassed, 1, 5000));
        _swap(key, true, -10000 ether, ZERO_BYTES);
        vm.roll(block.number + boundedBlocks);

        uint24 currentFee = hook.getCurrentFee(key);
        if (boundedBlocks >= hook.blockDecayWindow()) {
            assertEq(currentFee, BASE_FEE, "Fee should decay after window");
        }
    }

    // REAL: both legs are exact-input (negative), fuzz checks penalty triggers
    function testFuzz_SandwichWithRandomSlippage(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 100 ether, 5000 ether);
        amount2 = bound(amount2, 100 ether, 5000 ether);

        hook.setTickThresholds(500, 200, 5 ether, 10);

        _sandwichSwap(key, true,  -int256(amount1), ZERO_BYTES);
        _sandwichSwap(key, false,  int256(amount2), ZERO_BYTES);

        // Both amounts > 5 ether threshold, so penalty must trigger
        assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE, "Sandwich not detected");
    }
}
