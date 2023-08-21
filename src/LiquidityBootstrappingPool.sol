// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseHook} from "@uniswap/v4-periphery/contracts/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";

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
        bool isToken0; // Whether the token to provide liquidity for is token0
    }

    LiquidityInfo public liquidityInfo;
    uint256 amountProvided;
    int24 currentMinTick;

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

    function afterInitialize(address sender, PoolKey calldata key, uint160, int24, bytes calldata data)
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
        currentMinTick = liquidityInfo_.minTick;

        poolId = key.toId();

        // Transfer bootstrapping token to this contract
        if (liquidityInfo_.isToken0) {
            ERC20(Currency.unwrap(key.currency0)).transferFrom(sender, address(this), liquidityInfo_.totalAmount);
        } else {
            ERC20(Currency.unwrap(key.currency1)).transferFrom(sender, address(this), liquidityInfo_.totalAmount);
        } 

        return LiquidityBootstrappingPool.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
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

        int24 currentMinTick_ = currentMinTick;

        if (tick < targetMinTick) {
            // Current tick is below target minimum tick
            // Update liquidity range to [targetMinTick, maxTick]
            // and provide additional liquidity according to target liquidity
            Position.Info memory position = poolManager.getPosition(poolId, address(this), currentMinTick_, liquidityInfo_.maxTick);
            uint256 newLiquidity = uint256(position.liquidity) + amountToProvide;

            // Close current position
            poolManager.modifyPosition(key, IPoolManager.ModifyPositionParams(currentMinTick_, liquidityInfo_.maxTick, -int256(uint256(position.liquidity))), bytes(""));

            // Open new position
            poolManager.modifyPosition(key, IPoolManager.ModifyPositionParams(targetMinTick, liquidityInfo_.maxTick, int256(newLiquidity)), bytes(""));

            // Update liquidity range
            currentMinTick = targetMinTick;
        } else {
            // Current tick is above target minimum tick
            // Sell tokens to bring tick down below target minimum tick
            // If amount to sell is less than amount to provide, provide the remaining amount
            // Else sell all available tokens according to target liquidity
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

    // Note: target liquidity represents total of intended liquidity 
    // provided plus tokens sold, not just liquidity provided
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
