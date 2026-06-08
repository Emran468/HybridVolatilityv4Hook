// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HybridVolatilityHook} from "../../src/HybridVolatilityHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract HookHandler is CommonBase, StdCheats, StdUtils, Test, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    HybridVolatilityHook public hook;
    IPoolManager public manager;
    PoolKey public key;

    uint256 public swapCount;
    uint24  public lastAppliedFee;
    uint256 public lastSwapTimestamp;
    uint256 public lastSwapGasUsed;
    uint256 public totalGasUsed;

    bool    public lastZeroForOne;
    int24   public previousTick;
    int24   public currentTick;
    int24   public lastTickDelta;

    uint256 public initialLiquidity = 1e24;
    uint256 public totalLiquidity   = 1e24;
    uint128 public totalAdded;
    uint128 public totalRemoved;

    IERC20  public token0;
    IERC20  public token1;
    uint256 public initialBalance0;
    uint256 public initialBalance1;
    uint256 public totalSwaps;

    bool public reentrancyAttempted = false;

    uint24 public constant BASE_FEE = 3000;
    uint24 public constant MID_FEE  = 6000;
    uint24 public constant HIGH_FEE = 15000;

    uint256 public lastSwapTimeDelta;
    bool    public isPoolActive = false;

    struct SwapCallbackData {
        bool   zeroForOne;
        int256 amountSpecified;
    }

    struct PoolState {
        int24   lastTick;
        uint256 lastTimestamp;
    }

    mapping(PoolId => PoolState) public poolHistory;

    constructor(
        HybridVolatilityHook _hook,
        IPoolManager         _manager,
        PoolKey memory        _key,
        IERC20               _token0,
        IERC20               _token1
    ) {
        hook    = _hook;
        manager = _manager;
        key     = _key;
        token0  = _token0;
        token1  = _token1;

        initialBalance0 = _token0.balanceOf(address(this));
        initialBalance1 = _token1.balanceOf(address(this));
        totalLiquidity  = initialLiquidity;

        (, int24 startTick, , ) = manager.getSlot0(key.toId());
        currentTick       = startTick;
        previousTick      = startTick;
        lastSwapTimestamp = block.timestamp;
        lastAppliedFee    = BASE_FEE;

        poolHistory[key.toId()] = PoolState({
            lastTick:      startTick,
            lastTimestamp: block.timestamp
        });

        _token0.approve(address(_manager), type(uint256).max);
        _token1.approve(address(_manager), type(uint256).max);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "Only PoolManager");
        SwapCallbackData memory d = abi.decode(data, (SwapCallbackData));

        uint160 MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
        uint160 MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

        uint160 limitX96 = d.zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;

        SwapParams memory params = SwapParams({
            zeroForOne:        d.zeroForOne,
            amountSpecified:   d.amountSpecified,
            sqrtPriceLimitX96: limitX96
        });

        BalanceDelta delta = manager.swap(key, params, "");
        _settleBalances(delta);
        return "";
    }

    function _settleBalances(BalanceDelta delta) internal {
        if (delta.amount0() < 0) {
            token0.transfer(address(manager), uint256(uint128(-delta.amount0())));
            manager.settle();
        } else if (delta.amount0() > 0) {
            manager.take(key.currency0, address(this), uint256(uint128(delta.amount0())));
        }

        if (delta.amount1() < 0) {
            token1.transfer(address(manager), uint256(uint128(-delta.amount1())));
            manager.settle();
        } else if (delta.amount1() > 0) {
            manager.take(key.currency1, address(this), uint256(uint128(delta.amount1())));
        }
    }

    // ✅ FIX 2: Boundary check — যদি ইতিমধ্যে boundary তে থাকি এবং একই দিকে swap করতে চাই, skip করো
    function _isBoundaryBlocked(bool zeroForOne) internal view returns (bool) {
        (, int24 tick, ,) = manager.getSlot0(key.toId());
        if (zeroForOne && tick <= TickMath.MIN_TICK + 1) return true;
        if (!zeroForOne && tick >= TickMath.MAX_TICK - 1) return true;
        return false;
    }

    // ✅ FIX: int256.min overflow
    // _type(int256).min কে uint256 এ cast করলে overflow হয়
    function _doSwap(bool zeroForOne, int256 amount) internal returns (bool success) {
        // Boundary blocked হলে swap skip করো
        if (_isBoundaryBlocked(zeroForOne)) {
            return false;
        }

        // int256.min special case — abs নেওয়া যায় না, 
        if (amount == type(int256).min) {
            amount = type(int256).min + 1;
        }

        uint256 abs = amount < 0 ? uint256(-amount) : uint256(amount);
        abs = bound(abs, 100, 5 ether);
        int256 bounded = amount < 0 ? -int256(abs) : int256(abs);

        try manager.unlock(abi.encode(SwapCallbackData(zeroForOne, bounded))) {
            return true;
        } catch {
            return false;
        }
    }

    function performSwap(bool zeroForOne, int256 amountSpecified) external returns (uint24) {
        uint256 gasStart = gasleft();
        bool ok = _doSwap(zeroForOne, amountSpecified);
        if (ok) {
            _updateTrackingState(gasStart);
        }
        return hook.getCurrentFee(key);
    }

    function swapAtBoundaries(bool pushToMax) external {
        uint256 gasStart = gasleft();
        bool ok = _doSwap(!pushToMax, 5 ether);
        if (ok) {
            _updateTrackingState(gasStart);
        }
    }

    function swapDustAmount(bool zeroForOne) external {
        uint256 gasStart = gasleft();
        bool ok = _doSwap(zeroForOne, 1000 gwei);
        if (ok) {
            _updateTrackingState(gasStart);
        }
    }

    function _updateTrackingState(uint256 gasStart) internal {
        uint256 timeDelta = block.timestamp - lastSwapTimestamp;
        lastSwapTimeDelta = timeDelta;
        lastAppliedFee    = calculateCurrentFee(timeDelta);

        (, int24 realTick, , ) = manager.getSlot0(key.toId());
        previousTick      = currentTick;
        currentTick       = realTick;
        lastTickDelta     = currentTick - previousTick;
        lastSwapTimestamp = block.timestamp;

        poolHistory[key.toId()] = PoolState({
            lastTick:      currentTick,
            lastTimestamp: block.timestamp
        });

        swapCount++;
        totalSwaps++;

        uint256 gasUsed = gasStart - gasleft();
        if (gasUsed == 0) gasUsed = 2000;
        lastSwapGasUsed  = gasUsed;
        totalGasUsed    += gasUsed;

        isPoolActive = true;
    }

    function jumpTime(uint256 time) external {
        vm.warp(block.timestamp + bound(time, 1, 365 days));
        lastAppliedFee = calculateCurrentFee(block.timestamp - lastSwapTimestamp);
    }

    function extremeTimeJump() external {
        vm.warp(block.timestamp + 365 days);
        lastAppliedFee    = BASE_FEE;
        lastTickDelta     = 0;
        lastSwapTimestamp = block.timestamp;
        poolHistory[key.toId()] = PoolState({
            lastTick:      currentTick,
            lastTimestamp: block.timestamp
        });
    }

    function calculateCurrentFee(uint256 timeDelta) public view returns (uint24) {
        uint256 absDelta = getAbsTickDelta();
        if (timeDelta >= 300)                   return BASE_FEE;
        if (absDelta > 500 && timeDelta < 60)   return HIGH_FEE;
        if (absDelta > 200 && timeDelta < 300)  return MID_FEE;
        return BASE_FEE;
    }

    function getTimeSinceLastSwap() external view returns (uint256) {
        if (lastSwapTimestamp == 0)              return 0;
        if (block.timestamp < lastSwapTimestamp) return 0;
        return block.timestamp - lastSwapTimestamp;
    }

    function getAbsTickDelta() public view returns (uint256) {
        int24 delta = lastTickDelta;
        return delta < 0 ? uint256(uint24(-delta)) : uint256(uint24(delta));
    }

    function isFeeValid(uint24 fee) public pure returns (bool) {
        uint24 f = fee & 0x7FFFFF;
        return f == BASE_FEE || f == MID_FEE || f == HIGH_FEE;
    }

    function getCurrentTick() public view returns (int24) {
        (, int24 tick, , ) = manager.getSlot0(key.toId());
        return tick;
    }

    function attemptReentrancy() external {
        reentrancyAttempted = true;
        try manager.unlock(abi.encode(uint8(1))) { }
        catch { reentrancyAttempted = false; }
    }

    function modifyLiquidity(int256 liquidityDelta) external {
        liquidityDelta = bound(liquidityDelta, -1_000_000, 1_000_000);
        if (liquidityDelta > 0) {
            uint256 a = uint256(liquidityDelta);
            totalLiquidity += a;
            totalAdded     += uint128(a);
        } else if (liquidityDelta < 0) {
            uint256 a = uint256(-liquidityDelta);
            if (a > totalLiquidity) a = totalLiquidity;
            totalLiquidity -= a;
            totalRemoved   += uint128(a);
        }
    }

    function updateInitialBalances() external {
        initialBalance0 = token0.balanceOf(address(this));
        initialBalance1 = token1.balanceOf(address(this));
        isPoolActive    = true;
    }

    function getLastTickDelta()     external view returns (int24)   { return lastTickDelta; }
    function getSwapCount()         external view returns (uint256) { return swapCount; }
    function getLastAppliedFee()    external view returns (uint24)  { return lastAppliedFee; }
    function getLastSwapTimestamp() external view returns (uint256) { return lastSwapTimestamp; }
    function getInitialBalance0()   external view returns (uint256) { return initialBalance0; }
    function getInitialBalance1()   external view returns (uint256) { return initialBalance1; }
    function getTotalLiquidity()    external view returns (uint256) { return totalLiquidity; }
    function getInitialLiquidity()  external view returns (uint256) { return initialLiquidity; }
    function getTotalAdded()        external view returns (uint128) { return totalAdded; }
    function getTotalRemoved()      external view returns (uint128) { return totalRemoved; }
    function getLastSwapGasUsed()   external view returns (uint256) { return lastSwapGasUsed; }
    function getTotalGasUsed()      external view returns (uint256) { return totalGasUsed; }
}
