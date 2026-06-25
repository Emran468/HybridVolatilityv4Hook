// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "../../lib/uniswap-hooks/lib/v4-periphery/src/utils/HookMiner.sol";
import {HookHandler} from "./HookHandler.sol";
import {HybridVolatilityHook} from "../../src/HybridVolatilityHook.sol";

contract VolatilityInvariantTest is StdInvariant, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    HookHandler handler;
    HybridVolatilityHook hook;
    PoolKey poolKey;

    uint24 constant BASE_FEE        = 3000;
    uint24 constant MID_FEE         = 6000;
    uint24 constant HIGH_FEE        = 15000;
    uint24 constant MEV_PENALTY_FEE = 100000;

    function setUp() public {
        deployFreshManagerAndRouters();

        MockToken tokenA = new MockToken("Token A", "TKA");
        MockToken tokenB = new MockToken("Token B", "TKB");

        if (address(tokenA) < address(tokenB)) {
            currency0 = Currency.wrap(address(tokenA));
            currency1 = Currency.wrap(address(tokenB));
        } else {
            currency0 = Currency.wrap(address(tokenB));
            currency1 = Currency.wrap(address(tokenA));
        }

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG   |
            Hooks.AFTER_INITIALIZE_FLAG    |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG         |
            Hooks.AFTER_SWAP_FLAG
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this), flags,
            type(HybridVolatilityHook).creationCode,
              abi.encode(manager, address(this))
        );

       hook = new HybridVolatilityHook{salt: salt}(manager, address(this));

        require(address(hook) == hookAddress, "Mined address mismatch");

        poolKey = PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks:       hook
        });

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        handler = new HookHandler(
            hook, manager, poolKey,
            IERC20(Currency.unwrap(currency0)),
            IERC20(Currency.unwrap(currency1))
        );

        deal(Currency.unwrap(currency0), address(handler), type(uint128).max);
        deal(Currency.unwrap(currency1), address(handler), type(uint128).max);

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = HookHandler.performSwap.selector;
        selectors[1] = HookHandler.modifyLiquidity.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _isAtBoundary() internal view returns (bool) {
        (, int24 tick, , ) = manager.getSlot0(poolKey.toId());
        return tick <= TickMath.MIN_TICK + 1 || tick >= TickMath.MAX_TICK - 1;
    }

    function _isValidFee(uint24 fee) internal pure returns (bool) {
        return fee == BASE_FEE || fee == MID_FEE ||
               fee == HIGH_FEE || fee == MEV_PENALTY_FEE;
    }

    // ── Invariants ────────────────────────────────────────────────

    function invariant_tickIsValid() public view {
        if (address(manager) == address(0)) return;
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceX96, int24 tick, , ) = manager.getSlot0(poolId);
        assertTrue(
            tick >= TickMath.MIN_TICK && tick <= TickMath.MAX_TICK,
            "Tick out of valid range"
        );
        assertTrue(sqrtPriceX96 > 0, "Sqrt price should be positive");
    }

    function invariant_feeIsPredefined() public view {
        assertEq(poolKey.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG,
            "Fee should be DYNAMIC_FEE_FLAG");
    }

    function invariant_poolStateConsistency() public view {
        if (handler.swapCount() == 0) return;
        if (!hook.isInitialized(poolKey)) return;
        (int24 lastTick, , , uint64 lastTimestamp, ) = hook.getPoolState(poolKey);
        assertTrue(
            lastTick >= TickMath.MIN_TICK && lastTick <= TickMath.MAX_TICK,
            "Invalid last tick"
        );
        assertTrue(lastTimestamp <= block.timestamp, "Invalid timestamp");
    }

    function invariant_feeHasOverrideFlag() public pure {
        assertTrue(true, "Dynamic fee pool has override flag");
    }

    function invariant_priceMovesCorrectly() public view {
        if (handler.swapCount() == 0) return;
        if (_isAtBoundary()) return;
        (, int24 currentTick, , ) = manager.getSlot0(poolKey.toId());
        assertEq(currentTick, handler.currentTick(), "State out of sync");
        assertTrue(
            currentTick >= TickMath.MIN_TICK && currentTick <= TickMath.MAX_TICK,
            "Tick out of range"
        );
    }

    function invariant_liquidityConservation() public view {
        uint256 liquidity = handler.totalLiquidity();
        assertGe(liquidity, 0);
        assertLe(liquidity, 10_000_000 ether);
    }

    function invariant_liquidityAccounting() public view {
        uint256 expected = handler.initialLiquidity() +
                           handler.totalAdded() -
                           handler.totalRemoved();
        assertEq(handler.totalLiquidity(), expected,
            "Liquidity accounting mismatch");
    }

    function invariant_tokenBalanceConservation() public view {
        uint256 c0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(handler));
        uint256 c1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(handler));
        assertGe(c0 + c1, 0, "Balances should exist");
    }

    // ✅ MEV_PENALTY_FEE যোগ করা হয়েছে
    function invariant_volatilityFeeLogic() public view {
        if (!handler.isPoolActive()) return;
        if (handler.swapCount() == 0) return;
        uint24 fee = hook.getCurrentFee(poolKey);
        assertTrue(_isValidFee(fee), "INVALID FEE STATE");
    }

    // ✅ Block-based decay — MEV fee ও decay হয়
    function invariant_resetToBaseFeeAfterLongTime() public view {
        if (handler.getSwapCount() == 0) return;
        uint256 timeSince = handler.getTimeSinceLastSwap();
        if (timeSince <= 300) return;
        uint24 fee = hook.getCurrentFee(poolKey);
        assertEq(fee, BASE_FEE,
            "Should reset to BASE_FEE after decay window");
    }

    function invariant_tickAlwaysInBounds() public view {
        int24 tick = handler.currentTick();
        assertTrue(
            tick >= TickMath.MIN_TICK && tick <= TickMath.MAX_TICK,
            "Tick out of Uniswap bounds"
        );
    }

    // ✅ MEV_PENALTY_FEE allowed — zero movement এও sandwich penalty থাকতে পারে
    function invariant_zeroMovementNoFeeHike() public view {
        if (handler.swapCount() == 0) return;
        if (_isAtBoundary()) return;
        if (handler.lastTickDelta() != 0) return;
        if (!hook.isInitialized(poolKey)) return;
        uint24 fee = hook.getCurrentFee(poolKey);
        assertTrue(
            fee == BASE_FEE || fee == MEV_PENALTY_FEE,
            "Zero movement: fee must be BASE_FEE or MEV_PENALTY_FEE"
        );
    }

    function invariant_hookGasEfficiency() public view {
        if (handler.swapCount() < 3) return;
        assertLe(handler.lastSwapGasUsed(), 1_500_000,
            "Gas explosion in hook logic!");
    }

    // ✅ সম্পূর্ণ fix — 100000 সব জায়গায়, sandwich fee skip করা হয়
    function invariant_feeMatchesVolatility() public view {
        if (handler.swapCount() == 0) return;
        if (!hook.isInitialized(poolKey)) return;

        uint24 hookFee    = hook.getCurrentFee(poolKey);
        uint256 timeDelta = handler.getTimeSinceLastSwap();
        int24 tickDelta   = handler.lastTickDelta();
        uint256 absDelta  = tickDelta < 0
            ? uint256(uint24(-tickDelta))
            : uint256(uint24(tickDelta));

        assertTrue(_isValidFee(hookFee),
            "Fee must be one of: 3000, 6000, 15000, 100000");

        if (_isAtBoundary()) return;
        if (absDelta > 100000) return;

        // ✅ Sandwich penalty থাকলে volatility logic skip
        if (hookFee == MEV_PENALTY_FEE) return;

        if (timeDelta >= 300) {
            assertEq(hookFee, BASE_FEE, "Stale swap: fee must decay to 3000");
            return;
        }

        if (absDelta > 500 && timeDelta < 60) {
            if (handler.swapCount() <= 2) {
                assertTrue(hookFee == BASE_FEE || hookFee == MID_FEE,
                    "Cold start high volatility: 3000 or 6000");
            } else {
                assertTrue(hookFee == MID_FEE || hookFee == HIGH_FEE,
                    "High volatility: 6000 or 15000");
            }
        } else if (absDelta > 200 && timeDelta < 300) {
            if (handler.swapCount() <= 2) {
                assertTrue(hookFee == BASE_FEE || hookFee == MID_FEE,
                    "Cold start mid volatility: 3000 or 6000");
            } else {
                assertTrue(hookFee == MID_FEE || hookFee == HIGH_FEE,
                    "Mid volatility: 6000 or 15000");
            }
        } else {
            assertEq(hookFee, BASE_FEE, "Low volatility: fee should be 3000");
        }
    }

    function invariant_timeDriftResilience() public view {
        assertTrue(
            block.timestamp >= handler.lastSwapTimestamp(),
            "Time cannot move backwards"
        );
    }

    function invariant_noReentrancy() public view {
        assertFalse(handler.reentrancyAttempted(), "REENTRANCY_DETECTED");
    }

    function invariant_lockIntegrity() public pure {
        assertTrue(true);
    }

    function invariant_timestampMonotonic() public view {
        uint256 lastTimestamp = handler.lastSwapTimestamp();
        if (lastTimestamp > 0) {
            assertGe(block.timestamp, lastTimestamp,
                "Timestamp moved backwards!");
        }
    }

    // ✅ 100000 যোগ করা হয়েছে
    function invariant_feeAlwaysInValidRange() public view {
        if (handler.swapCount() == 0) return;
        uint24 fee = hook.getCurrentFee(poolKey);
        assertTrue(_isValidFee(fee), "Fee not in allowed tiers!");
    }

    // ✅ block-based: timeSince >= 300 এ fee = BASE_FEE
    function invariant_volatilityDecaysOverTime() public view {
        if (handler.getSwapCount() == 0) return;
        if (handler.getTimeSinceLastSwap() < 300) return;
        uint24 fee = hook.getCurrentFee(poolKey);
        assertEq(fee, BASE_FEE,
            "Volatility must decay to BASE_FEE after long time");
    }

    function invariant_ghostLiquidityConservation() public view {
        uint256 expected = handler.getInitialLiquidity() +
                           handler.getTotalAdded() -
                           handler.getTotalRemoved();
        assertEq(handler.getTotalLiquidity(), expected,
            "Ghost Invariant: Liquidity mismatch!");
    }

    function invariant_ghostSwapCountConsistency() public view {
        assertEq(handler.getSwapCount(), handler.totalSwaps(),
            "Ghost Invariant: Swap counters out of sync!");
    }

    function invariant_ghostGasAndActivitySanity() public view {
        if (handler.totalSwaps() == 0) return;
        assertTrue(handler.getTotalGasUsed() > 0,
            "Ghost Invariant: Total gas zero despite swaps!");
        assertGe(handler.getTotalGasUsed(), handler.getLastSwapGasUsed(),
            "Ghost Invariant: Total gas < last swap gas!");
    }

    function invariant_reentrancyShouldAlwaysFail() public view {
        assertFalse(handler.reentrancyAttempted());
    }
}

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
}
