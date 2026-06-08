// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract HybridVolatilityHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct PoolState {
        int24   lastTick;
        uint256 lastTimestamp;
    }

    struct PositionInfo {
        uint128 liquidity;
        uint256 feeGrowth0;
        uint256 feeGrowth1;
    }

    mapping(PoolId => PoolState)     public poolHistory;
    mapping(PoolId => uint24)        public poolFees;
    mapping(PoolId => bool)          public isInitialized;
    mapping(bytes32 => PositionInfo) public storedPositions;
    
    // প্রতিটি সোয়াপের শুরুর টিক ট্র্যাক রাখার জন্য নতুন ম্যাপিং
    mapping(PoolId => int24)         public preSwapTicks; 

    uint24 public constant BASE_FEE          = 3000;
    uint24 public constant MID_VOLATILE_FEE  = 6000;
    uint24 public constant HIGH_VOLATILE_FEE = 15000;

    event LiquidityUpdated(bytes32 indexed positionKey, uint128 newLiquidity);
    event FeeUpdated(PoolId indexed poolId, uint24 newFee);
    event HistoryUpdated(PoolId indexed poolId, int24 newTick, uint256 timestamp);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize:                true,
            afterInitialize:                 true,
            beforeAddLiquidity:              true,
            afterAddLiquidity:               true,
            beforeRemoveLiquidity:           true,
            afterRemoveLiquidity:            true,
            beforeSwap:                      true,
            afterSwap:                       true,
            beforeDonate:                    false,
            afterDonate:                     false,
            beforeSwapReturnDelta:           false,
            afterSwapReturnDelta:            false,
            afterAddLiquidityReturnDelta:    false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Initialize ───────────────────────────────────────────────────────────

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external override onlyPoolManager returns (bytes4)
    {
        PoolId poolId = key.toId();
        if (!isInitialized[poolId]) {
            isInitialized[poolId] = true;
            poolFees[poolId]      = BASE_FEE;
            poolHistory[poolId]   = PoolState({ lastTick: 0, lastTimestamp: block.timestamp });
        }
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external override onlyPoolManager returns (bytes4)
    {
        PoolId poolId         = key.toId();
        isInitialized[poolId] = true;
        poolFees[poolId]      = BASE_FEE;
        poolHistory[poolId]   = PoolState({ lastTick: tick, lastTimestamp: block.timestamp });
        return this.afterInitialize.selector;
    }

    // ─── Liquidity ────────────────────────────────────────────────────────────

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external view override onlyPoolManager returns (bytes4)
    { return this.beforeAddLiquidity.selector; }

    function afterAddLiquidity(
        address sender, PoolKey calldata key, ModifyLiquidityParams calldata params,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        _updatePositionLiquidity(sender, key, params, true);
        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external view override onlyPoolManager returns (bytes4)
    { return this.beforeRemoveLiquidity.selector; }

    function afterRemoveLiquidity(
        address sender, PoolKey calldata key, ModifyLiquidityParams calldata params,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        _updatePositionLiquidity(sender, key, params, false);
        return (this.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _updatePositionLiquidity(
        address sender, PoolKey calldata key,
        ModifyLiquidityParams calldata params, bool isAdding
    ) internal {
        bytes32 positionKey = keccak256(
            abi.encodePacked(sender, key.toId(), params.tickLower, params.tickUpper)
        );
        int256 delta = params.liquidityDelta;
        if (delta == 0) return;

        if (isAdding) {
            require(delta > 0, "Delta must be positive when adding");
            uint256 temp = uint256(delta);
            require(temp <= type(uint128).max, "Delta too large");
            storedPositions[positionKey].liquidity += uint128(temp);
        } else {
            require(delta < 0, "Delta must be negative when removing");
            uint256 temp = uint256(-delta);
            require(temp <= type(uint128).max, "Delta too large");
            uint128 toRemove = uint128(temp);
            require(storedPositions[positionKey].liquidity >= toRemove, "Insufficient liquidity");
            storedPositions[positionKey].liquidity -= toRemove;
        }
        emit LiquidityUpdated(positionKey, storedPositions[positionKey].liquidity);
    }

    // ─── Swap ─────────────────────────────────────────────────────────────────

    function beforeSwap(
        address, PoolKey calldata key, SwapParams calldata params, bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        (, int24 currentTick, , ) = poolManager.getSlot0(poolId);
        
        // ১. সোয়াপ শুরু হওয়ার আগের কারেন্ট টিক স্টোরেজে সেভ করি (afterSwap এ ব্যবহারের জন্য)
        preSwapTicks[poolId] = currentTick;

        if (params.amountSpecified == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA,
                    BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        PoolState memory state = poolHistory[poolId];
        uint256 timeDelta = block.timestamp > state.lastTimestamp
            ? block.timestamp - state.lastTimestamp : 0;

        uint24 feeToApply;
        
        // ২. যদি সর্বশেষ হাই-ভোলাটাইল সোয়াপ থেকে ৫ মিনিট (৩০০ সেকেন্ড) পার হয়ে যায়, তবে ফি decay হবে
        if (timeDelta >= 300) {
            feeToApply = BASE_FEE;
        } else {
            // ৫ মিনিটের ভেতর হলে পূর্ববর্তী সোয়াপের কারণে তৈরি হওয়া বর্ধিত ফি-টি ব্যবহার হবে
            feeToApply = poolFees[poolId];
            if (feeToApply == 0) feeToApply = BASE_FEE;
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA,
                feeToApply | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(
        address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        (, int24 postSwapTick, , ) = poolManager.getSlot0(poolId);
        int24 preSwapTick = preSwapTicks[poolId];

       // 3. Calculate how much this specific swap moved the price (volatility)
        int256 rawDelta  = int256(postSwapTick) - int256(preSwapTick);
        int24 tickDelta = rawDelta < 0 ? int24(-rawDelta) : int24(rawDelta);

       // 4. Calculate the new fee level for the next swap based on this swap's impact
        uint24 feeToSave = _computeFee(tickDelta, 0);

        // 5. Update the fee and state for the next swap
        poolFees[poolId] = feeToSave;
        poolHistory[poolId] = PoolState({ lastTick: postSwapTick, lastTimestamp: block.timestamp });

        emit FeeUpdated(poolId, feeToSave);
        emit HistoryUpdated(poolId, postSwapTick, block.timestamp);
        
        return (this.afterSwap.selector, 0);
    }

    // ─── Fee Logic ────────────────────────────────────────────────────────────

    function _computeFee(int24 tickDelta, uint256 timeDelta) internal pure returns (uint24) {
        uint256 absTick = uint256(int256(tickDelta));
        if (timeDelta >= 300)  return BASE_FEE;
        if (absTick > 500)     return HIGH_VOLATILE_FEE;
        if (absTick > 200)     return MID_VOLATILE_FEE;
        return BASE_FEE;
    }

    // ─── View ─────────────────────────────────────────────────────────────────

    function getCurrentFee(PoolKey calldata key) external view returns (uint24) {
        PoolId poolId = key.toId();
        if (!isInitialized[poolId]) return BASE_FEE;

        PoolState memory state = poolHistory[poolId];
        uint256 timeDelta = block.timestamp > state.lastTimestamp
            ? block.timestamp - state.lastTimestamp : 0;

        if (timeDelta >= 300) return BASE_FEE;

        return poolFees[poolId] == 0 ? BASE_FEE : poolFees[poolId];
    }

    function setHistoryForTest(PoolKey calldata key, int24 lastTick, uint256 lastTimestamp) external {
        PoolId poolId = key.toId();
        poolHistory[poolId] = PoolState({ lastTick: lastTick, lastTimestamp: lastTimestamp });
    }

    function updatePositionMetadata(
        bytes32 positionKey, uint128 liquidity, uint256 feeGrowth0, uint256 feeGrowth1
    ) external onlyPoolManager {
        storedPositions[positionKey] = PositionInfo({
            liquidity: liquidity, feeGrowth0: feeGrowth0, feeGrowth1: feeGrowth1
        });
    }
}