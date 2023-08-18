// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseHook} from "@uniswap/v4-periphery/contracts/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";

error InvalidAmountProvided();
error InvalidTimeRange();
error InvalidTickRange();

contract LiquidityBootstrappingPool is BaseHook {
    using PoolIdLibrary for PoolKey;

    struct LiquidityInfo {
        uint128 totalAmount; // The total amount of liquidity to provide
        uint128 amountProvided; // The amount of liquidity already provided
        uint64 startTime; // Start time of the liquidity bootstrapping period
        uint64 endTime; // End time of the liquidity bootstrapping period
        int24 minTick; // The minimum tick to provide liquidity at
        int24 maxTick; // The maximum tick to provide liquidity at
    }

    LiquidityInfo public liquidityInfo;

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

        if (liquidityInfo_.amountProvided != 0) revert InvalidAmountProvided();
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
        return LiquidityBootstrappingPool.beforeSwap.selector;
    }
}
