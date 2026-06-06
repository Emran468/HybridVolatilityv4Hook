// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract V4LiquiditySystem {
    IPoolManager public immutable poolManager;

    event Log(string message);

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }

    struct Data {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }

    function addLiquidity(bytes calldata data) external {
        emit Log("unlock start");
        poolManager.unlock(data);
    }

    function unlockCallback(bytes calldata raw)
        external
        returns (bytes memory)
    {
        require(msg.sender == address(poolManager), "ONLY_POOL_MANAGER");
        emit Log("callback hit");

        Data memory d = abi.decode(raw, (Data));

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower:      d.tickLower,
            tickUpper:      d.tickUpper,
            liquidityDelta: d.liquidityDelta,
            salt:           d.salt
        });

        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            d.poolKey,
            params,
            ""
        );
        emit Log("liquidity modified");

        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        Currency currency0 = d.poolKey.currency0;
        Currency currency1 = d.poolKey.currency1;

        address token0 = Currency.unwrap(currency0);
        address token1 = Currency.unwrap(currency1);

        // ✅ TOKEN0 SETTLE: sync → transfer → settle
        if (amount0 < 0) {
            uint256 pay0 = uint256(uint128(-amount0));
            poolManager.sync(currency0);
            IERC20Minimal(token0).transfer(address(poolManager), pay0);
            poolManager.settle();
            emit Log("token0 settled");
        }

        // ✅ TOKEN1 SETTLE: sync → transfer → settle
        if (amount1 < 0) {
            uint256 pay1 = uint256(uint128(-amount1));
            poolManager.sync(currency1);
            IERC20Minimal(token1).transfer(address(poolManager), pay1);
            poolManager.settle();
            emit Log("token1 settled");
        }

        // ✅ TAKE — positive delta থাকলে ফেরত নাও
        if (amount0 > 0) {
            poolManager.take(currency0, address(this), uint128(amount0));
        }
        if (amount1 > 0) {
            poolManager.take(currency1, address(this), uint128(amount1));
        }

        emit Log("done");
        return "";
    }
}
