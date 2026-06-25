// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ═══════════════════════════════════════════════════════════════════════════════
// Sandwich Security Enforcement Tests
// HybridVolatilityHook — MEV Protection Proof
//
// এই test file প্রমাণ করে যে:
//   ১. Sandwich attacker-কে 10% penalty fee দিতে হয়
//   ২. Normal trader-কে penalty দিতে হয় না
//   ৩. Volume threshold ঠিকমতো কাজ করে
//   ৪. বিভিন্ন ধরনের sandwich pattern ধরা পড়ে
// ═══════════════════════════════════════════════════════════════════════════════

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

    // ─── State ────────────────────────────────────────────────────
    HybridVolatilityHook hook;

    // Fee constants
    uint24 constant BASE_FEE        = 3000;    // 0.30%
    uint24 constant MID_FEE         = 6000;    // 0.60%
    uint24 constant HIGH_FEE        = 15000;   // 1.50%
    uint24 constant MEV_PENALTY_FEE = 100000;  // 10.00%

    // Attacker ও Victim-এর simulated address
    address constant ATTACKER = address(0xA77AC4E2);
    address constant VICTIM   = address(0xB1C71C10);
    address constant NORMAL   = address(0x4F0F4D41);

    PoolSwapTest.TestSettings internal SETTINGS =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    // ─── Events (hook থেকে) ───────────────────────────────────────
    event SandwichDetected(
        PoolId indexed poolId,
        int24 firstMove,
        int24 lastMove,
        uint256 blockVolume,
        uint24 feeApplied
    );

    // ─── setUp ────────────────────────────────────────────────────
    // function setUp() public {
    //     vm.warp(1000);
    //     vm.roll(1000);

    //     deployFreshManagerAndRouters();
    //     deployMintAndApprove2Currencies();

    //     IERC20(Currency.unwrap(currency0)).approve(address(manager), type(uint256).max);
    //     IERC20(Currency.unwrap(currency1)).approve(address(manager), type(uint256).max);

    //     swapRouter = new PoolSwapTest(manager);
    //     IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
    //     IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

    //     uint160 flags = uint160(
    //         Hooks.BEFORE_INITIALIZE_FLAG      |
    //         Hooks.AFTER_INITIALIZE_FLAG       |
    //         Hooks.AFTER_ADD_LIQUIDITY_FLAG    |
    //         Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
    //         Hooks.BEFORE_SWAP_FLAG            |
    //         Hooks.AFTER_SWAP_FLAG
    //     );

    //     (address predicted, bytes32 salt) = HookMiner.find(
    //         address(this), flags,
    //         type(HybridVolatilityHook).creationCode,
    //         abi.encode(manager)
    //     );

    //     hook = new HybridVolatilityHook{salt: salt}(manager);
    //     require(address(hook) == predicted, "Hook address mismatch");

    //     key = PoolKey({
    //         currency0:   currency0,
    //         currency1:   currency1,
    //         fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
    //         tickSpacing: 60,
    //         hooks:       IHooks(address(hook))
    //     });

    //     manager.initialize(key, SQRT_PRICE_1_1);

    //     // পর্যাপ্ত liquidity যোগ করি
    //     modifyLiquidityRouter.modifyLiquidity(
    //         key,
    //         ModifyLiquidityParams({
    //             tickLower:      -887220,
    //             tickUpper:       887220,
    //             liquidityDelta:  1_000_000 ether,
    //             salt:            bytes32(0)
    //         }),
    //         ZERO_BYTES
    //     );

    //     // lastBlock পেছনে সেট করি যাতে blockDelta = 1 হয়
    //     hook.setHistoryForTest(key, 0, block.number - 1);
    // }

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

    hook.setHistoryForTest(key, 0, block.number - 1);

    // ✅ LOW threshold — সব sandwich test এ কাজ করবে
    hook.setTickThresholds(500, 200, 0.001 ether, 10);
}

// ✅ _setLowThreshold এখন আর দরকার নেই
// কিন্তু রেখে দিতে পারেন backward compatibility এর জন্য

    // ─── Helper: swap করার function ──────────────────────────────
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

    // ─── Helper: threshold সেট করি ───────────────────────────────
    function _setLowThreshold() internal {
        // sandwich ধরতে low threshold সেট করি
        hook.setTickThresholds(500, 200, 0.001 ether, 10);
    }

    // ═══════════════════════════════════════════════════════════════
    // TEST 1: Classic Sandwich — Buy → Victim → Sell
    // Attacker প্রথমে buy করে, তারপর victim buy করে,
    // তারপর attacker sell করে profit নেয়
    // ═══════════════════════════════════════════════════════════════

    function test_fail_sandwich_fee_rejection_classic() public {
        _setLowThreshold();

        console.log("=== Classic Sandwich Attack Test ===");
        console.log("Attacker buys first to push price up...");

        // Step 1: Attacker buy (price উপরে ঠেলে দেয়)
        _doSwap(true, -500 ether);
        uint24 feeAfterAttackerBuy = hook.getCurrentFee(key);
        console.log("Fee after attacker buy:", feeAfterAttackerBuy);

        // Step 2: Victim buy (বেশি দামে কেনে — এখানে sandwich complete)
        _doSwap(true, -200 ether);

        // এখন পর্যন্ত sandwich pattern নেই (দুটোই একই direction)
        // Step 3: Attacker sell (দাম ফিরিয়ে আনে → sandwich detected!)
        _doSwap(false, 500 ether);

        uint24 feeAfterSell = hook.getCurrentFee(key);
        console.log("Fee after attacker sell (sandwich complete):", feeAfterSell);

        // ✅ Sandwich ধরা পড়েছে — 10% penalty
        assertEq(
            feeAfterSell, MEV_PENALTY_FEE,
            "Classic sandwich must trigger 10% MEV penalty fee"
        );

        console.log("[PASS] Classic sandwich detected! Attacker penalized with 10% fee.");
    }

    // ═══════════════════════════════════════════════════════════════
    // TEST 2: Reverse Sandwich — Sell → Buy → Sell
    // Attacker প্রথমে sell করে দাম নামায়,
    // victim-কে কম দামে sell করতে বাধ্য করে,
    // তারপর attacker buy করে profit নেয়
    // ═══════════════════════════════════════════════════════════════

    function test_fail_sandwich_fee_rejection_reverse() public {
        _setLowThreshold();

        console.log("=== Reverse Sandwich Attack Test ===");

        // Step 1: Attacker sell (price নিচে নামায়)
        _doSwap(false, 1000 ether);

        // Step 2: Victim — sandwich এখানে detect হয়
        _doSwap(true, -500 ether);

        uint24 detectedFee = hook.getCurrentFee(key);
        console.log("Fee after reverse sandwich detected:", detectedFee);

        assertEq(
            detectedFee, MEV_PENALTY_FEE,
            "Reverse sandwich must trigger 10% MEV penalty fee"
        );

        console.log("[PASS] Reverse sandwich detected!");
    }

    // ═══════════════════════════════════════════════════════════════
    // TEST 3: Normal Trader — Penalty হওয়া উচিত নয়
    // এটা প্রমাণ করে যে hook শুধু attacker-কে penalize করে,
    // normal trader-কে নয়
    // ═══════════════════════════════════════════════════════════════

    function test_fail_sandwich_normal_trader_no_penalty() public {
        _setLowThreshold();

        console.log("=== Normal Trader - No Penalty Test ===");

        // Normal buy
        _doSwap(true, -100 ether);
        uint24 fee1 = hook.getCurrentFee(key);
        console.log("Fee after normal buy:", fee1);

        // Normal sell (ভিন্ন block-এ)
        vm.roll(block.number + 1);
        hook.setHistoryForTest(key, 0, block.number - 1);

        _doSwap(false, 100 ether);
        uint24 fee2 = hook.getCurrentFee(key);
        console.log("Fee after normal sell (new block):", fee2);

        // ✅ কোনো penalty নেই
        assertTrue(fee1 != MEV_PENALTY_FEE, "Normal buy should NOT trigger penalty");
        assertTrue(fee2 != MEV_PENALTY_FEE, "Normal sell in new block should NOT trigger penalty");

        console.log("[PASS] Normal trader protected - no penalty applied.");
    }

    // ═══════════════════════════════════════════════════════════════
    // TEST 4: Volume Below Threshold — Penalty নেই
    // ছোট পরিমাণের sandwich attempt-এ penalty হবে না
    // ═══════════════════════════════════════════════════════════════

    function test_fail_sandwich_below_volume_threshold_no_penalty() public {
    // ✅ threshold = 10 ether, swap = 0.5 ether → নিচে তাই penalty নেই
    hook.setTickThresholds(500, 200, 10 ether, 10);

    _doSwap(true,  -0.5 ether);
    _doSwap(false,  0.5 ether);

    uint24 fee = hook.getCurrentFee(key);
    assertTrue(fee != MEV_PENALTY_FEE,
        "Small volume below threshold should NOT trigger penalty");
}

    // ═══════════════════════════════════════════════════════════════
    // TEST 5: Volume Above Threshold — Penalty আছে
    // পর্যাপ্ত volume-এর sandwich-এ penalty হবে
    // ═══════════════════════════════════════════════════════════════
function test_fail_sandwich_above_volume_threshold_penalty() public {
    // threshold = 100 ether, swap total = 1000 ether > 100 ether
    hook.setTickThresholds(500, 200, 100 ether, 10);

    vm.roll(block.number + 1);
    hook.setHistoryForTest(key, 0, block.number - 1);

    _doSwap(true,  -500 ether);
    _doSwap(false,  500 ether);

    assertEq(hook.getCurrentFee(key), MEV_PENALTY_FEE,
        "Large volume sandwich above threshold MUST trigger penalty");
}
   
    // ═══════════════════════════════════════════════════════════════
    // TEST 6: SandwichDetected Event Emission
    // Hook সঠিক event emit করছে কিনা তা যাচাই
    // ═══════════════════════════════════════════════════════════════

    function test_fail_sandwich_event_emitted() public {
        _setLowThreshold();

        console.log("=== Sandwich Event Emission Test ===");

        // Attacker buy
        _doSwap(true, -1000 ether);

        // Sell এ sandwich detect হবে — event emit হওয়া উচিত
        vm.expectEmit(true, false, false, false);
        emit SandwichDetected(
            key.toId(),
            0,    // firstMove (exact value জানা নেই)
            0,    // lastMove (exact value জানা নেই)
            0,    // blockVolume (exact value জানা নেই)
            MEV_PENALTY_FEE
        );

        _doSwap(false, 1000 ether);

        console.log("[PASS] SandwichDetected event emitted correctly.");
    }

    // ═══════════════════════════════════════════════════════════════
    // TEST 7: Fee Decay After Attack
    // Sandwich-এর পরে নতুন block-এ fee স্বাভাবিক হয়
    // ═══════════════════════════════════════════════════════════════

    function test_fail_sandwich_fee_decays_after_attack() public {
        _setLowThreshold();

        console.log("=== Fee Decay After Sandwich Attack ===");

        // Sandwich করি
        _doSwap(true,  -1000 ether);
        _doSwap(false,  1000 ether);

        uint24 penaltyFee = hook.getCurrentFee(key);
        console.log("Fee during attack:", penaltyFee);
        assertEq(penaltyFee, MEV_PENALTY_FEE, "Should have penalty fee");

        // blockDecayWindow পার করি
        uint64 decay = hook.blockDecayWindow();
        vm.roll(block.number + decay + 1);

        uint24 decayedFee = hook.getCurrentFee(key);
        console.log("Fee after decay window:", decayedFee);

        // ✅ Penalty fee decay হয়ে base fee-তে ফিরে আসে
        assertEq(
            decayedFee, BASE_FEE,
            "Fee must decay to BASE_FEE after blockDecayWindow"
        );

        console.log("[PASS] Fee correctly decayed to BASE_FEE after attack window.");
    }

    // ═══════════════════════════════════════════════════════════════
    // TEST 8: Multi-Block Attack Prevention
    // ভিন্ন block-এ sandwich করলে penalty হয় না
    // (attacker যদি block split করে)
    // ═══════════════════════════════════════════════════════════════

    function test_fail_sandwich_cross_block_no_penalty() public {
        _setLowThreshold();

        console.log("=== Cross-Block Sandwich - No Penalty Test ===");

        // Block 1: Buy
        _doSwap(true, -1000 ether);
        console.log("Block 1: Attacker buys");

        // নতুন block-এ যাই (sandwich আর possible নয়)
        vm.roll(block.number + 1);
        hook.setHistoryForTest(key, 0, block.number - 1);

        // Block 2: Sell (ভিন্ন block, তাই sandwich নয়)
        _doSwap(false, 1000 ether);
        uint24 fee = hook.getCurrentFee(key);
        console.log("Block 2: Sell fee:", fee);

        // ✅ ভিন্ন block-এ sandwich ধরা পড়ে না
        assertTrue(
            fee != MEV_PENALTY_FEE,
            "Cross-block transactions should NOT trigger sandwich penalty"
        );

        console.log("[PASS] Cross-block attack correctly ignored.");
    }

    // ═══════════════════════════════════════════════════════════════
    // TEST 9: Repeated Sandwich Attempts
    // বারবার sandwich try করলেও প্রতিবার penalty হয়
    // ═══════════════════════════════════════════════════════════════

    function test_fail_sandwich_repeated_attacks_all_penalized() public {
        _setLowThreshold();

        console.log("=== Repeated Sandwich Attacks Test ===");

        for (uint i = 0; i < 5; i++) {
            // নতুন block + reset
            vm.roll(block.number + 1);
            hook.setHistoryForTest(key, 0, block.number - 1);

            uint256 blockNum = block.number;

            _doSwap(true,  -1000 ether);
            _doSwap(false,  1000 ether);

            assertEq(block.number, blockNum, "Must be same block");

            uint24 fee = hook.getCurrentFee(key);
            assertEq(
                fee, MEV_PENALTY_FEE,
                string(abi.encodePacked(
                    "Attack #", vm.toString(i + 1), " must be penalized"
                ))
            );

            console.log(string(abi.encodePacked(
                "Attack #", vm.toString(i + 1), " penalized: fee = 100000"
            )));
        }

        console.log("[PASS] All 5 repeated sandwich attacks detected and penalized.");
    }

    // ═══════════════════════════════════════════════════════════════
    // TEST 10: Attacker vs Normal Trader — Economic Impact
    // Attacker ১০% বেশি fee দেয়, normal trader মাত্র ০.৩%
    // এটা economic deterrent proof করে
    // ═══════════════════════════════════════════════════════════════

 function test_fail_sandwich_economic_deterrent_proof() public {
    _setLowThreshold();

    console.log("=== Economic Deterrent Proof ===");

    uint256 normalFee   = uint256(BASE_FEE);   // uint24 → uint256 explicitly
    console.log("Normal trader fee: 0.30% (3000 bps)");

    _doSwap(true,  -1000 ether);
    _doSwap(false,  1000 ether);

    uint256 attackerFee = uint256(hook.getCurrentFee(key)); // uint24 → uint256
    console.log("Attacker fee after sandwich: 10.00% (100000 bps)");

    // ✅ uint256 দিয়ে calculate করুন — overflow নেই
    uint256 tradeAmount  = 1000 ether;
    uint256 normalCost   = (tradeAmount * normalFee)   / 1_000_000;
    uint256 attackerCost = (tradeAmount * attackerFee) / 1_000_000;

    console.log("Normal trade cost (1000 ether):", normalCost);
    console.log("Attacker trade cost (1000 ether):", attackerCost);
    console.log("Penalty multiplier:", attackerCost / normalCost, "x");

    assertEq(attackerFee, uint256(MEV_PENALTY_FEE));
    assertEq(normalFee,   uint256(BASE_FEE));
    assertTrue(
        attackerCost > normalCost * 30,
        "Attacker must pay 30x+ more than normal trader"
    );

    console.log("[PASS] Economic deterrent proven: Attacker pays 33x more fee!");
}

    // ═══════════════════════════════════════════════════════════════
    // TEST 11: Tracker Cleanup After Detection
    // Sandwich detect হলে tracker clear হয়
    // পরের transaction নতুন context-এ শুরু হয়
    // ═══════════════════════════════════════════════════════════════

    // function test_fail_sandwich_tracker_cleanup_after_detection() public {
    //     _setLowThreshold();

    //     console.log("=== Tracker Cleanup Test ===");

    //     // Sandwich করি
    //     _doSwap(true,  -1000 ether);
    //     _doSwap(false,  1000 ether);

    //     // Tracker clear হওয়া উচিত
    //     (int24 firstMove, , , , , bool initialized) = hook.getSandwichTracker(key);

    //     console.log("Tracker initialized after sandwich:", initialized);
    //     console.log("First move after cleanup:", firstMove);

    //     assertTrue(
    //         firstMove == 0 || !initialized,
    //         "Tracker must be cleared after sandwich detection"
    //     );

    //     console.log("[PASS] Tracker correctly cleared after sandwich detection.");
    // }

    function test_fail_sandwich_tracker_cleanup_after_detection() public {
    // ১. থ্রেশহোল্ড কমিয়ে দেওয়া যাতে এই ১০০০ ether সোয়াপেই লজিক ট্রিগার হয়
    // (নাহলে থ্রেশহোল্ড ম্যাচ না করায় আগের মতো সাইলেন্টলি পাস হয়ে যাবে)
    hook.setTickThresholds(500, 200, 500 ether, 80);

    // ২. প্রথম সোয়াপ (Front-run leg)
    _doSwap(true, -1000 ether);

    // ৩. দ্বিতীয় সোয়াপ (Back-run leg - Reversal ও Sandwich Detection ট্রিগার)
    _doSwap(false, 1000 ether);

    // ৪. getSandwichTracker থেকে কারেন্ট ট্রানজিয়েন্ট/স্টোরেজ স্টেট রিড করা
    (
        int24 firstMove,
        int24 lastMove,
        ,
        ,
        uint256 swapCount,
        bool initialized
    ) = hook.getSandwichTracker(key);

    // 🎯 ভুল কারণে পাস হওয়া ঠেকাতে নতুন আর্কিটেকচারের সঠিক অ্যাসার্থন (Assertions):
    // যেহেতু স্যান্ডউইচ ডিটেকশনের পর ডাটা একদম ০ বা uninitialized হয় না, 
    // বরং কারেন্ট লেগের মুভমেন্ট নিয়ে নতুন সেশন শুরু করে, তাই নিচের লজিকগুলো চেক করতে হবে:
    
    assertTrue(initialized, "Tracker must remain initialized");
    assertEq(swapCount, 1, "Swap count must reset to 1 after sandwich detection");
    
    // packed = 0 বা firstMove == 0 হওয়ার ভুল অ্যাসার্থন ভাঙার জন্য:
    assertNotEq(firstMove, 0, "First move should capture the resetting swap movement, not 0");
    assertEq(firstMove, lastMove, "On reset, firstMove and lastMove must be identical");
}

    // ═══════════════════════════════════════════════════════════════
    // TEST 12: Security Enforcement Summary
    // সব security feature একসাথে test করি
    // ═══════════════════════════════════════════════════════════════

    function test_fail_sandwich_security_enforcement_summary() public {
        _setLowThreshold();

        console.log("=== Security Enforcement Summary ===");
        console.log("Testing all sandwich detection scenarios...");

        uint256 attacksDetected = 0;
        uint256 totalAttacks    = 3;

        // Attack 1: Buy-Sell sandwich
        {
            vm.roll(block.number + 1);
            hook.setHistoryForTest(key, 0, block.number - 1);
            _doSwap(true,  -1000 ether);
            _doSwap(false,  1000 ether);
            if (hook.getCurrentFee(key) == MEV_PENALTY_FEE) {
                attacksDetected++;
                console.log("Attack 1 (Buy-Sell): DETECTED");
            }
        }

        // Attack 2: Sell-Buy sandwich
        {
            vm.roll(block.number + 1);
            hook.setHistoryForTest(key, 0, block.number - 1);
            _doSwap(false,  1000 ether);
            _doSwap(true,  -1000 ether);
            if (hook.getCurrentFee(key) == MEV_PENALTY_FEE) {
                attacksDetected++;
                console.log("Attack 2 (Sell-Buy): DETECTED");
            }
        }

        // Attack 3: Large multi-swap sandwich
        {
            vm.roll(block.number + 1);
            hook.setHistoryForTest(key, 0, block.number - 1);
            _doSwap(true,  -500 ether);
            _doSwap(true,  -300 ether);
            _doSwap(false,  500 ether);
            if (hook.getCurrentFee(key) == MEV_PENALTY_FEE) {
                attacksDetected++;
                console.log("Attack 3 (Multi-trade): DETECTED");
            }
        }

        console.log("Total attacks detected:", attacksDetected, "/", totalAttacks);

        assertEq(
            attacksDetected, totalAttacks,
            "All sandwich attack patterns must be detected"
        );

        console.log("[PASS] 100% sandwich detection rate confirmed!");
        console.log("HybridVolatilityHook Security Enforcement: VERIFIED");
    }
}
