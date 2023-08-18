// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseHook} from "@uniswap/v4-periphery/contracts/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";

error InvalidTimeRange();
error InvalidTickRange();
error BeforeStartTime();

contract LiquidityBootstrappingPool is BaseHook {
    using PoolIdLibrary for PoolKey;

    struct LiquidityInfo {
        uint128 totalAmount; // The total amount of liquidity to provide
        uint32 startTime; // Start time of the liquidity bootstrapping period
        uint32 endTime; // End time of the liquidity bootstrapping period
        int24 minTick; // The minimum tick to provide liquidity at
        int24 maxTick; // The maximum tick to provide liquidity at
    }

    LiquidityInfo public liquidityInfo;
    uint256 amountProvided;

    PoolId poolId;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: true,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24, bytes calldata data)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        LiquidityInfo memory liquidityInfo_ = abi.decode(data, (LiquidityInfo));

        if (liquidityInfo_.startTime > liquidityInfo_.endTime || liquidityInfo_.endTime < block.timestamp) {
            revert InvalidTimeRange();
        }
        if (
            liquidityInfo_.minTick > liquidityInfo_.maxTick
                || liquidityInfo_.minTick < TickMath.minUsableTick(key.tickSpacing)
                || liquidityInfo_.maxTick > TickMath.maxUsableTick(key.tickSpacing)
        ) revert InvalidTickRange();

        liquidityInfo = liquidityInfo_;

        poolId = key.toId();

        return LiquidityBootstrappingPool.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        LiquidityInfo memory liquidityInfo_ = liquidityInfo;

        if (liquidityInfo_.startTime > block.timestamp) {
            // Liquidity bootstrapping period has not started yet,
            // allowing swapping as usual
            return LiquidityBootstrappingPool.beforeSwap.selector;
        }

        uint256 targetLiquidity = _getTargetLiquidity();
        uint256 amountToProvide = targetLiquidity - amountProvided;

        amountProvided = targetLiquidity;

        (, int24 tick, , , ,) = poolManager.getSlot0(poolId);
        int24 targetMinTick = _getTargetMinTick();

        if (tick < targetMinTick) {
            // Current tick is below target minimum tick
            // Update liquidity range to [targetMinTick, maxTick]
            // and provide additional liquidity according to target liquidity
            // Note: target liquidity represents total of liquidity 
            // provided and tokens sold, not just liquidity provided
        } else {
            // Current tick is above target minimum tick
            // Sell tokens to bring tick down below target minimum tick
            // If amount to sell is less than amount to provide, provide the remaining amount
            // Else sell all available tokens according to target liquidity
            // Note: target liquidity represents total of liquidity 
            // provided and tokens sold, not just liquidity provided
        }

        return LiquidityBootstrappingPool.beforeSwap.selector;
    }

    function _getTargetMinTick() internal view returns (int24) {
        LiquidityInfo memory liquidityInfo_ = liquidityInfo;

        if (block.timestamp < uint256(liquidityInfo_.startTime)) revert BeforeStartTime();

        if (block.timestamp >= uint256(liquidityInfo_.endTime)) return liquidityInfo_.minTick;

        uint256 timeElapsed = block.timestamp - uint256(liquidityInfo_.startTime);
        uint256 timeTotal = uint256(liquidityInfo_.endTime) - uint256(liquidityInfo_.startTime);

        // Get the target minimum tick of the liquidity range such that:
        // (maxTick - targetMinTick) / (maxTick - minTick) = timeElapsed / timeTotal
        // Solving for targetMinTick, we get:
        // targetMinTick = maxTick - ((timeElapsed / timeTotal) * (maxTick - minTick))
        // To avoid integer truncation, we rearrange as follows:
        // numerator = timeElapsed * (maxTick - minTick)
        // targetMinTick = maxTick - (numerator / timeTotal)
        int256 numerator = int256(timeElapsed) * int256(liquidityInfo_.maxTick - liquidityInfo_.minTick);
        return int24(int256(liquidityInfo_.maxTick) - (numerator / int256(timeTotal)));
    }

    function _getTargetLiquidity() internal view returns (uint256) {
        LiquidityInfo memory liquidityInfo_ = liquidityInfo;

        if (block.timestamp < uint256(liquidityInfo_.startTime)) revert BeforeStartTime();

        if (block.timestamp >= uint256(liquidityInfo_.endTime)) return liquidityInfo_.totalAmount;

        uint256 timeElapsed = block.timestamp - uint256(liquidityInfo_.startTime);
        uint256 timeTotal = uint256(liquidityInfo_.endTime) - uint256(liquidityInfo_.startTime);

        // Get the target liquidity such that:
        // (targetLiquidity / totalAmount) = timeElapsed / timeTotal
        // Solving for targetLiquidity, we get:
        // targetLiquidity = (timeElapsed / timeTotal) * totalAmount
        return (timeElapsed * liquidityInfo_.totalAmount) / timeTotal;
    }
}
