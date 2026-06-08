// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract AddLiquidityScript is Test {
   
    address public constant POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address public constant EURC = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;
    address public constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address public constant HOOK = 0x56b66B92e394910E14Dd5273Fce6867323b5FCC0;

    function test_AddLiquidity() external {
      // 1. Currency determination and sorting (Uniswap V4 standard)
        Currency currency0 = Currency.wrap(EURC < WETH ? EURC : WETH);
        Currency currency1 = Currency.wrap(EURC < WETH ? WETH : EURC);

        // 2. Pool key structure (Your successful Dynamic Fee: 8388608)
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 8388608,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });

        // 3. Action and parameter packing (MINT_POSITION = 0x02, SETTLE_PAIR = 0x0b)
        bytes memory actions = abi.encodePacked(uint8(0x02), uint8(0x0b));
        
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            int24(83940),       // tickLower
            int24(84060),       // tickUpper
            int256(10000000),   // liquidityDelta
            uint128(100 ether), // amount0Max
            uint128(1 ether),   // amount1Max
            msg.sender,         // recipient
            ""                  // hookData
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        uint256 deadline = block.timestamp + 60;

       // 4. FIXED: Bypass interface error using a low-level call
        bytes memory callData = abi.encodeWithSignature(
            "execute(bytes,bytes[],uint256)", 
            actions, 
            params, 
            deadline
        );

        (bool success, bytes memory reason) = POSITION_MANAGER.call(callData);
        
      // If it fails, the actual revert message will bubble up in the test
        if (!success) {
            if (reason.length > 0) {
                assembly {
                    revert(add(32, reason), mload(reason))
                }
            } else {
                revert("PositionManager execute failed without reason");
            }
        }
    }
}