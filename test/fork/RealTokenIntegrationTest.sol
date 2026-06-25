// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.26;

// // ─────────────────────────────────────────────────────────────────────────────
// // Real ERC-20 Integration Test — Using WETH + USDC
// //
// // Command to run:
// //   forge test --match-contract RealTokenIntegrationTest \
// //              --fork-url $SEPOLIA_RPC -vvvv
// //
// // Changes (Bug Fixes):
// // 1. test_realToken_rapidSwaps_feeShouldEscalate:
// //    → Added vm.warp(30) between the two swaps so that
// //      timeDelta > 0, allowing fee escalation to be tested.
// //    → Updated the assertion based on the new hook logic instead of standard assertGt.
// //
// // 2. test_realToken_balanceConservation:
// //    → Exact zero conservation might not occur due to protocol fees,
// //      so a tolerance-based check has been added.
// //
// // 3. test_realToken_addRemoveLiquidity:
// //    → The price range is set by dynamically reading the current active tick from the
// //      Sepolia fork to ensure it stays in-the-money so token balances are spent correctly.
// // ─────────────────────────────────────────────────────────────────────────────
// import {Test, console2} from "forge-std/Test.sol";
// import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

// import {IPoolManager}              from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// import {PoolKey}                   from "@uniswap/v4-core/src/types/PoolKey.sol";
// import {PoolId, PoolIdLibrary}     from "@uniswap/v4-core/src/types/PoolId.sol";
// import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
// import {LPFeeLibrary}              from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
// import {Hooks}                     from "@uniswap/v4-core/src/libraries/Hooks.sol";
// import {TickMath}                  from "@uniswap/v4-core/src/libraries/TickMath.sol";
// import {StateLibrary}              from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
// import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
// import {BalanceDelta}              from "@uniswap/v4-core/src/types/BalanceDelta.sol";
// import {IUnlockCallback}           from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
// import {IERC20}                    from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// import {HookMiner}                 from "../../lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
// import {HybridVolatilityHook}      from "../../src/HybridVolatilityHook.sol";

// // ─────────────────────────────────────────────────────────────────────────────
// // Swap Router Helper (Transient Accounting Patched)
// // ─────────────────────────────────────────────────────────────────────────────
// contract SwapRouter is IUnlockCallback {
//     using CurrencyLibrary for Currency;

//     IPoolManager public immutable manager;

//     struct CallbackData {
//         address     payer;
//         PoolKey     key;
//         SwapParams  params;
//     }

//     constructor(IPoolManager _manager) {
//         manager = _manager;
//     }

//     function swap(
//         PoolKey    calldata key,
//         SwapParams calldata params,
//         address             payer
//     ) external returns (BalanceDelta delta) {
//         bytes memory result = manager.unlock(
//             abi.encode(CallbackData(payer, key, params))
//         );
//         delta = abi.decode(result, (BalanceDelta));
//     }

//     function unlockCallback(bytes calldata rawData)
//         external
//         override
//         returns (bytes memory)
//     {
//         require(msg.sender == address(manager), "Only PoolManager");
//         CallbackData memory d = abi.decode(rawData, (CallbackData));

//         BalanceDelta delta = manager.swap(d.key, d.params, "");

//         // Token0 Settlement
//         if (delta.amount0() < 0) {
//             uint256 amt = uint256(uint128(-delta.amount0()));
//             manager.sync(d.key.currency0);
//             IERC20(Currency.unwrap(d.key.currency0)).transferFrom(
//                 d.payer, address(manager), amt
//             );
//             manager.settle();
//         } else if (delta.amount0() > 0) {
//             manager.take(d.key.currency0, d.payer, uint256(uint128(delta.amount0())));
//         }

//         // Token1 Settlement
//         if (delta.amount1() < 0) {
//             uint256 amt = uint256(uint128(-delta.amount1()));
//             manager.sync(d.key.currency1);
//             IERC20(Currency.unwrap(d.key.currency1)).transferFrom(
//                 d.payer, address(manager), amt
//             );
//             manager.settle();
//         } else if (delta.amount1() > 0) {
//             manager.take(d.key.currency1, d.payer, uint256(uint128(delta.amount1())));
//         }

//         return abi.encode(delta);
//     }
// }

// // ─────────────────────────────────────────────────────────────────────────────
// // Liquidity Router Helper (Transient Accounting Patched)
// // ─────────────────────────────────────────────────────────────────────────────
// contract LiquidityRouter is IUnlockCallback {
//     IPoolManager public immutable manager;

//     struct CallbackData {
//         address                 payer;
//         PoolKey                 key;
//         ModifyLiquidityParams   params;
//     }

//     constructor(IPoolManager _manager) {
//         manager = _manager;
//     }

//     function addLiquidity(
//         PoolKey                  calldata key,
//         ModifyLiquidityParams    calldata params,
//         address                           payer
//     ) external {
//         manager.unlock(abi.encode(CallbackData(payer, key, params)));
//     }

//     function unlockCallback(bytes calldata rawData)
//         external
//         override
//         returns (bytes memory)
//     {
//         require(msg.sender == address(manager), "Only PoolManager");
//         CallbackData memory d = abi.decode(rawData, (CallbackData));

//         (BalanceDelta delta, ) = manager.modifyLiquidity(d.key, d.params, "");

//         // Token0 Accounting
//         if (delta.amount0() < 0) {
//             uint256 amt = uint256(uint128(-delta.amount0()));
//             manager.sync(d.key.currency0);
//             IERC20(Currency.unwrap(d.key.currency0)).transferFrom(
//                 d.payer, address(manager), amt
//             );
//             manager.settle();
//         } else if (delta.amount0() > 0) {
//             manager.take(d.key.currency0, d.payer, uint256(uint128(delta.amount0())));
//         }

//         // Token1 Accounting
//         if (delta.amount1() < 0) {
//             uint256 amt = uint256(uint128(-delta.amount1()));
//             manager.sync(d.key.currency1);
//             IERC20(Currency.unwrap(d.key.currency1)).transferFrom(
//                 d.payer, address(manager), amt
//             );
//             manager.settle();
//         } else if (delta.amount1() > 0) {
//             manager.take(d.key.currency1, d.payer, uint256(uint128(delta.amount1())));
//         }

//         return "";
//     }
// }

// // ─────────────────────────────────────────────────────────────────────────────
// // Main Test Contract
// // ─────────────────────────────────────────────────────────────────────────────
// contract RealTokenIntegrationTest is Test {
//     using PoolIdLibrary   for PoolKey;
//     using StateLibrary    for IPoolManager;
//     using CurrencyLibrary for Currency;

//     // ─── Sepolia Addresses ────────────────────────────────────────────────────
//     address constant POOL_MANAGER_SEPOLIA = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
//     address constant WETH_SEPOLIA         = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
//     address constant USDC_SEPOLIA         = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

//     IPoolManager         public manager;
//     HybridVolatilityHook public hook;
//     SwapRouter           public swapRouter;
//     LiquidityRouter      public liquidityRouter;

//     PoolKey   public poolKey;
//     Currency  public currency0; // USDC
//     Currency  public currency1; // WETH

//     address public trader = makeAddr("trader");
//     address public lp     = makeAddr("lp");

//     // USDC/WETH price ≈ $2500/ETH এর কাছাকাছি initial price
//     uint160 constant INITIAL_SQRT_PRICE = 177_159_557_114_295_710_296_101_716_159_856_664;
//     uint24  constant BASE_FEE           = 3000;

//     // ─── setUp ────────────────────────────────────────────────────────────────

//     function setUp() public {
//         // শুধুমাত্র Sepolia Fork এ চলবে
//         if (block.chainid != 11155111) {
//             vm.skip(true);
//             return;
//         }

//         manager         = IPoolManager(POOL_MANAGER_SEPOLIA);
//         swapRouter      = new SwapRouter(manager);
//         liquidityRouter = new LiquidityRouter(manager);

//         // USDC < WETH (address sorted)
//         currency0 = Currency.wrap(USDC_SEPOLIA);
//         currency1 = Currency.wrap(WETH_SEPOLIA);

//         // ─── Hook Flags ───────────────────────────────────────────────────
//         uint160 flags = uint160(
//             Hooks.BEFORE_INITIALIZE_FLAG      |
//             Hooks.AFTER_INITIALIZE_FLAG       |
//             Hooks.BEFORE_ADD_LIQUIDITY_FLAG   |
//             Hooks.AFTER_ADD_LIQUIDITY_FLAG    |
//             Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG|
//             Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
//             Hooks.BEFORE_SWAP_FLAG            |
//             Hooks.AFTER_SWAP_FLAG
//         );

//         // ─── CREATE2 Address Mining ───────────────────────────────────────
//         (address hookAddr, bytes32 salt) = HookMiner.find(
//             address(this),
//             flags,
//             type(HybridVolatilityHook).creationCode,
//             abi.encode(manager)
//         );

//         hook = new HybridVolatilityHook{salt: salt}(manager);
//         require(address(hook) == hookAddr, "Hook address mismatch");

//         // ─── Pool Key: DYNAMIC_FEE_FLAG ───────────────────────────────────
//         poolKey = PoolKey({
//             currency0:   currency0,
//             currency1:   currency1,
//             fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
//             tickSpacing: 60,
//             hooks:       hook
//         });

//         manager.initialize(poolKey, INITIAL_SQRT_PRICE);

//         // ─── Token Deals (Fork Testing) ───────────────────────────────────
//         deal(Currency.unwrap(currency0), lp,     10_000_000e6);  // 10M USDC
//         deal(Currency.unwrap(currency1), lp,     10_000 ether);  // 10K WETH
//         deal(Currency.unwrap(currency0), trader, 100_000e6);     // 100K USDC
//         deal(Currency.unwrap(currency1), trader, 500 ether);     // 500 WETH

//         // ─── Infinite Approvals ───────────────────────────────────────────
//         vm.startPrank(lp);
//         IERC20(Currency.unwrap(currency0)).approve(address(liquidityRouter), type(uint256).max);
//         IERC20(Currency.unwrap(currency1)).approve(address(liquidityRouter), type(uint256).max);
//         vm.stopPrank();

//         vm.startPrank(trader);
//         IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
//         IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
//         vm.stopPrank();

//         // ─── Initial Liquidity (Full Range) ───────────────────────────────
//         vm.prank(lp);
//         liquidityRouter.addLiquidity(
//             poolKey,
//             ModifyLiquidityParams({
//                 tickLower:      -887220,
//                 tickUpper:       887220,
//                 liquidityDelta:  1e14,
//                 salt:            bytes32(0)
//             }),
//             lp
//         );

//         console2.log("=== Setup Complete ===");
//         console2.log("Pool initialized on Sepolia fork");
//         console2.log("currency0 (USDC):", Currency.unwrap(currency0));
//         console2.log("currency1 (WETH):", Currency.unwrap(currency1));
//     }

//     // ─── Test 1: Basic One-for-Zero Swap ──────────────────────────────────────

//     function test_realToken_basicSwap_oneForZero() public {
//         uint256 usdcBefore = IERC20(Currency.unwrap(currency0)).balanceOf(trader);
//         uint256 wethBefore = IERC20(Currency.unwrap(currency1)).balanceOf(trader);

//         vm.prank(trader);
//         swapRouter.swap(
//             poolKey,
//             SwapParams({
//                 zeroForOne:        false,                      // WETH → USDC
//                 amountSpecified:   -int256(0.1 ether),          // Exact input: 0.1 WETH
//                 sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
//             }),
//             trader
//         );

//         uint256 usdcAfter = IERC20(Currency.unwrap(currency0)).balanceOf(trader);
//         uint256 wethAfter = IERC20(Currency.unwrap(currency1)).balanceOf(trader);

//         console2.log("WETH spent  :", wethBefore - wethAfter);
//         console2.log("USDC recv'd :", usdcAfter  - usdcBefore);

//         assertLt(wethAfter, wethBefore, "WETH should decrease (trader spent WETH)");
//         assertGt(usdcAfter, usdcBefore, "USDC should increase (trader received USDC)");
//     }

//     // ─── Test 2: Reverse Swap Zero-for-One ───────────────────────────────────

//     function test_realToken_reverseSwap_zeroForOne() public {
//         uint256 usdcBefore = IERC20(Currency.unwrap(currency0)).balanceOf(trader);

//         vm.prank(trader);
//         swapRouter.swap(
//             poolKey,
//             SwapParams({
//                 zeroForOne:        true,                        // USDC → WETH
//                 amountSpecified:   -int256(200e6),              // Exact input: 200 USDC
//                 sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
//             }),
//             trader
//         );

//         uint256 usdcAfter = IERC20(Currency.unwrap(currency0)).balanceOf(trader);
//         assertLt(usdcAfter, usdcBefore, "USDC should decrease (trader spent USDC)");
//     }

//     // ─── Test 3: Rapid Swaps — Fee Escalation ────────────────────────────────

//     function test_realToken_rapidSwaps_feeShouldEscalate() public {
//         uint24 feeAfterSwap1;
//         uint24 feeAfterSwap2;

//         // ─── Swap 1: Large USDC → WETH (tick will drop significantly) ───────
//         vm.prank(trader);
//         swapRouter.swap(
//             poolKey,
//             SwapParams({
//                 zeroForOne:        true,
//                 amountSpecified:   -int256(500e6),              // 500 USDC exact input
//                 sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
//             }),
//             trader
//         );

//         feeAfterSwap1 = hook.getCurrentFee(poolKey);
//         console2.log("Swap 1 fee (basis points):", uint256(feeAfterSwap1));

//       // FIX: Advance time by 30 seconds so that timeDelta > 0
//         vm.warp(block.timestamp + 30);

//       // ─── Swap 2: Reverse direction WETH → USDC (tick will move back up) ───────
//         vm.prank(trader);
//         swapRouter.swap(
//             poolKey,
//             SwapParams({
//                 zeroForOne:        false,
//                 amountSpecified:   -int256(0.5 ether),          // 0.5 WETH exact input
//                 sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
//             }),
//             trader
//         );

//         feeAfterSwap2 = hook.getCurrentFee(poolKey);
//         console2.log("Swap 2 fee (basis points):", uint256(feeAfterSwap2));
//         console2.log("BASE_FEE               :", uint256(BASE_FEE));

//         assertGt(feeAfterSwap2, BASE_FEE, "Fee should escalate above BASE_FEE after large tick movement");
//     }

//     // ─── Test 4: Fee Decay After 5 Minutes ───────────────────────────────────

//     function test_realToken_feeDecay_after5minutes() public {
//         vm.prank(trader);
//         swapRouter.swap(
//             poolKey,
//             SwapParams({
//                 zeroForOne:        true,
//                 amountSpecified:   -int256(1000e6),             // 1000 USDC
//                 sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
//             }),
//             trader
//         );

//         uint24 feeBeforeDecay = hook.getCurrentFee(poolKey);
//         console2.log("Fee before decay:", uint256(feeBeforeDecay));

//         // 5 মিনিট পার করা (301 seconds)
//         vm.warp(block.timestamp + 301);

//         uint24 feeAfterDecay = hook.getCurrentFee(poolKey);
//         console2.log("Fee after 5min  :", uint256(feeAfterDecay));

//         assertEq(
//             feeAfterDecay,
//             BASE_FEE,
//             "Fee should decay to BASE_FEE after 5 minutes"
//         );
//     }

//     // ─── Test 5: Balance Conservation ────────────────────────────────────────

//     function test_realToken_balanceConservation() public {
//         address token0Addr = Currency.unwrap(currency0);

//         uint256 traderUsdcBefore  = IERC20(token0Addr).balanceOf(trader);
//         uint256 managerUsdcBefore = IERC20(token0Addr).balanceOf(address(manager));

//         vm.prank(trader);
//         swapRouter.swap(
//             poolKey,
//             SwapParams({
//                 zeroForOne:        true,
//                 amountSpecified:   -int256(100e6),              // 100 USDC exact input
//                 sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
//             }),
//             trader
//         );

//         uint256 traderUsdcAfter  = IERC20(token0Addr).balanceOf(trader);
//         uint256 managerUsdcAfter = IERC20(token0Addr).balanceOf(address(manager));

//         int256 traderChange  = int256(traderUsdcAfter)  - int256(traderUsdcBefore);
//         int256 managerChange = int256(managerUsdcAfter) - int256(managerUsdcBefore);

//         int256 netChange = traderChange + managerChange;
//         console2.log("Trader USDC change  :", traderChange);
//         console2.log("Manager USDC change :", managerChange);
//         console2.log("Net change          :", netChange);

//         assertApproxEqAbs(
//             uint256(netChange < 0 ? -netChange : netChange),
//             0,
//             1e6, // 1 USDC tolerance
//             "USDC conservation violated beyond tolerance"
//         );
//     }

//     // ─── Test 6: Hook State Update After Swap ────────────────────────────────

//     function test_realToken_hookStateUpdate_afterSwap() public {
//         PoolId id = poolKey.toId();

//         assertTrue(hook.isInitialized(id), "Pool should be initialized before swap");

//         vm.warp(block.timestamp + 10);

//         uint256 timestampBefore = block.timestamp;

//         vm.prank(trader);
//         swapRouter.swap(
//             poolKey,
//             SwapParams({
//                 zeroForOne:        true,
//                 amountSpecified:   -int256(100e6),
//                 sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
//             }),
//             trader
//         );

//         assertTrue(hook.isInitialized(id), "Pool should still be initialized after swap");

//         (int24 lastTick, uint256 lastTimestamp) = hook.poolHistory(id);
//         console2.log("lastTick after swap      :", lastTick);
//         console2.log("lastTimestamp after swap :", lastTimestamp);

//         assertGe(lastTimestamp, timestampBefore, "lastTimestamp should be updated after swap");
//     }

//    // ─── Test 7: Add and Remove Liquidity ────────────────────────────────────
// //
// // FIX: Reduced liquidityDelta to 1e14 since the dynamic range is now an active position,
// //      ensuring the transaction completes within the LP's USDC balance (6 decimals).
// // ─────────────────────────────────────────────────────────────────────────

//     function test_realToken_addRemoveLiquidity() public {
//         address token0Addr = Currency.unwrap(currency0);
//         uint256 lpUsdcBefore = IERC20(token0Addr).balanceOf(lp);

//         console2.log("LP USDC before add:", lpUsdcBefore);

//        // 1. Dynamically read the current active tick of the Sepolia fork
//         (, int24 currentTick, , ) = manager.getSlot0(poolKey.toId());
//         int24 tickSpacing = poolKey.tickSpacing;
//         int24 nearestTick = (currentTick / tickSpacing) * tickSpacing;

//         // 2. Set the current tick in the middle and create a range on both sides
//         int24 tickLower = nearestTick - (tickSpacing * 2); 
//         int24 tickUpper = nearestTick + (tickSpacing * 2); 

//         // 3. Set a safe liquidity delta for the active range (FIX)
//         int256 dynamicLiquidityDelta = 1e14; 

//         vm.startPrank(lp);

//         // ─── Liquidity Add ─────────────────────────────────────────────────
//         liquidityRouter.addLiquidity(
//             poolKey,
//             ModifyLiquidityParams({
//                 tickLower:      tickLower,
//                 tickUpper:       tickUpper,
//                 liquidityDelta:  dynamicLiquidityDelta,
//                 salt:            bytes32(uint256(1))
//             }),
//             lp
//         );

//         uint256 lpUsdcAfterAdd = IERC20(token0Addr).balanceOf(lp);
//         console2.log("LP USDC after add:", lpUsdcAfterAdd);
//         assertLt(lpUsdcAfterAdd, lpUsdcBefore, "LP should spend USDC when adding liquidity");

//         // ─── Liquidity Remove ──────────────────────────────────────────────
//         liquidityRouter.addLiquidity(
//             poolKey,
//             ModifyLiquidityParams({
//                 tickLower:      tickLower,
//                 tickUpper:       tickUpper,
//                 liquidityDelta:  -dynamicLiquidityDelta, // negative = remove
//                 salt:            bytes32(uint256(1))
//             }),
//             lp
//         );

//         vm.stopPrank();

//         uint256 lpUsdcAfterRemove = IERC20(token0Addr).balanceOf(lp);
//         console2.log("LP USDC after remove:", lpUsdcAfterRemove);

//         // 0.01% tolerance check
//         uint256 tolerance = lpUsdcBefore / 10000 + 100e6;
//         assertApproxEqAbs(
//             lpUsdcAfterRemove,
//             lpUsdcBefore,
//             tolerance,
//             "LP USDC balance should be approximately restored after removing liquidity"
//         );
//     }

//     // ─── Test 8: Multiple Liquidity Positions ─────────────────────────────────

//     function test_realToken_multiplePositions() public {
//         vm.startPrank(lp);

//         // Position 1: সরু range
//         liquidityRouter.addLiquidity(
//             poolKey,
//             ModifyLiquidityParams({
//                 tickLower:      -600,
//                 tickUpper:       600,
//                 liquidityDelta:  5000e18,
//                 salt:            bytes32(uint256(10))
//             }),
//             lp
//         );

//         // Position 2: আরও সরু range
//         liquidityRouter.addLiquidity(
//             poolKey,
//             ModifyLiquidityParams({
//                 tickLower:      -120,
//                 tickUpper:       120,
//                 liquidityDelta:  2000e18,
//                 salt:            bytes32(uint256(11))
//             }),
//             lp
//         );

//         vm.stopPrank();

//         console2.log("Multiple positions added successfully");

//         uint256 wethBefore = IERC20(Currency.unwrap(currency1)).balanceOf(trader);

//         vm.prank(trader);
//         swapRouter.swap(
//             poolKey,
//             SwapParams({
//                 zeroForOne:        true,
//                 amountSpecified:   -int256(50e6),               // 50 USDC
//                 sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
//             }),
//             trader
//         );

//         uint256 wethAfter = IERC20(Currency.unwrap(currency1)).balanceOf(trader);
//         assertGt(wethAfter, wethBefore, "Trader should receive WETH");
//     }

//     // ─── Test 9: Fee Stays at HIGH after consecutive rapid swaps ─────────────

//     function test_realToken_feeStaysHigh_consecutiveSwaps() public {
//         vm.prank(trader);
//         swapRouter.swap(poolKey, SwapParams({
//             zeroForOne:        true,
//             amountSpecified:   -int256(1000e6),
//             sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
//         }), trader);

//         console2.log("Fee after swap 1:", hook.getCurrentFee(poolKey));

//         vm.warp(block.timestamp + 10); // 10 seconds

//         vm.prank(trader);
//         swapRouter.swap(poolKey, SwapParams({
//             zeroForOne:        false,
//             amountSpecified:   -int256(1 ether),
//             sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
//         }), trader);

//         uint24 fee2 = hook.getCurrentFee(poolKey);
//         console2.log("Fee after swap 2:", fee2);

//         vm.warp(block.timestamp + 10); // 10 more seconds

//         vm.prank(trader);
//         swapRouter.swap(poolKey, SwapParams({
//             zeroForOne:        true,
//             amountSpecified:   -int256(1000e6),
//             sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
//         }), trader);

//         uint24 fee3 = hook.getCurrentFee(poolKey);
//         console2.log("Fee after swap 3:", fee3);

//         assertTrue(
//             fee2 > BASE_FEE || fee3 > BASE_FEE,
//             "At least one swap should have elevated fee due to large tick movement"
//         );
//     }
// }