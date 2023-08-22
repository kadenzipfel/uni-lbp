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
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";

error InvalidTimeRange();
error InvalidTickRange();
error BeforeStartTime();

contract LiquidityBootstrappingPool is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    struct LiquidityInfo {
        uint128 totalAmount; // The total amount of liquidity to provide
        uint32 startTime; // Start time of the liquidity bootstrapping period
        uint32 endTime; // End time of the liquidity bootstrapping period
        int24 minTick; // The minimum tick to provide liquidity at
        int24 maxTick; // The maximum tick to provide liquidity at
        bool isToken0; // Whether the token to provide liquidity for is token0
    }

    struct ModifyPositionCallback {
        PoolKey key;
        IPoolManager.ModifyPositionParams params;
    }

    struct SwapCallback {
        PoolKey key;
        IPoolManager.SwapParams params;
    }

    uint256 constant EPOCH_SIZE = 1 hours;

    mapping(uint256 => bool) epochSynced;

    LiquidityInfo public liquidityInfo;

    uint256 amountProvided;
    int24 currentMinTick;
    bool allowSwap;

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

        if (liquidityInfo_.startTime > block.timestamp || allowSwap) {
            // Liquidity bootstrapping period has not started yet,
            // or allowSwap is true, allow swapping as usual
            return LiquidityBootstrappingPool.beforeSwap.selector;
        }

        sync(key, liquidityInfo_);

        return LiquidityBootstrappingPool.beforeSwap.selector;
    }

    function sync(PoolKey calldata key, LiquidityInfo memory liquidityInfo_) public {
        if (epochSynced[_floorToEpoch(block.timestamp)]) {
            // Already synced for this epoch
            return;
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
            if (position.liquidity > 0) {
                _modifyPosition(key, IPoolManager.ModifyPositionParams(currentMinTick_, liquidityInfo_.maxTick, -int256(uint256(position.liquidity))));
            }

            // Open new position
            _modifyPosition(key, IPoolManager.ModifyPositionParams(targetMinTick, liquidityInfo_.maxTick, int256(newLiquidity)));

            // Update liquidity range
            currentMinTick = targetMinTick;
        } else {
            // Current tick is above target minimum tick
            // Sell all available tokens or enough to reach targetMinTick - 1
            // If remaining tokens, update liquidity range to [targetMinTick, maxTick]
            // and provide additional liquidity according to target liquidity

            // Get bootstrapping token balance before swap
            uint256 amountSwapped = _getTokenBalance(key);

            // Swap
            allowSwap = true; // Skip beforeSwap hook logic to avoid infinite loop
            _swap(key, IPoolManager.SwapParams(_getZeroForOne(), int256(amountToProvide), TickMath.getSqrtRatioAtTick(targetMinTick - 1)));
            allowSwap = false;

            // amountSwapped = token balance before - token balance after
            amountSwapped -= _getTokenBalance(key);

            if (amountSwapped < amountToProvide) {
                // Reached targetMinTick - 1 with remaining tokens
                // Update liquidity range to [targetMinTick, maxTick]
                // and provide additional liquidity according to target liquidity
                Position.Info memory position = poolManager.getPosition(poolId, address(this), currentMinTick_, liquidityInfo_.maxTick);
                uint256 newLiquidity = uint256(position.liquidity) + (amountToProvide - amountSwapped);

                // Close current position
                if (position.liquidity > 0) {
                    _modifyPosition(key, IPoolManager.ModifyPositionParams(currentMinTick_, liquidityInfo_.maxTick, -int256(uint256(position.liquidity))));
                }

                // Open new position
                _modifyPosition(key, IPoolManager.ModifyPositionParams(targetMinTick, liquidityInfo_.maxTick, int256(newLiquidity)));

                // Update liquidity range
                currentMinTick = targetMinTick;
            }
        }

        epochSynced[_floorToEpoch(block.timestamp)] = true;
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

    function _getTokenBalance(PoolKey calldata key) internal view returns (uint256) {
        LiquidityInfo memory liquidityInfo_ = liquidityInfo;

        if (liquidityInfo_.isToken0) {
            return ERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        } else {
            return ERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        }
    }

    function _getZeroForOne() internal view returns (bool) {
        LiquidityInfo memory liquidityInfo_ = liquidityInfo;

        return liquidityInfo_.isToken0;
    }

    function _modifyPosition(PoolKey calldata key, IPoolManager.ModifyPositionParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(poolManager.lock(abi.encode(IPoolManager.modifyPosition.selector, key, params)), (BalanceDelta));
    }

    function _swap(PoolKey calldata key, IPoolManager.SwapParams memory params) internal returns (BalanceDelta delta) {
        delta = abi.decode(poolManager.lock(abi.encode(IPoolManager.swap.selector, key, params)), (BalanceDelta));
    }

    function _takeDeltas(PoolKey memory key, BalanceDelta delta) internal {
        poolManager.take(key.currency0, address(this), uint256(uint128(-delta.amount0())));
        poolManager.take(key.currency1, address(this), uint256(uint128(-delta.amount1())));
    }

    function _settleDeltas(PoolKey memory key, BalanceDelta delta) internal {
        uint256 delta0 = uint256(uint128(delta.amount0()));
        uint256 delta1 = uint256(uint128(delta.amount1()));

        if (delta0 > 0) {
            key.currency0.transfer(address(poolManager), uint256(uint128(delta.amount0())));
            poolManager.settle(key.currency0);
        }

        if (delta1 > 0) {
            key.currency1.transfer(address(poolManager), uint256(uint128(delta.amount1())));
            poolManager.settle(key.currency1);
        }
    }

    function _floorToEpoch(uint256 timestamp) internal pure returns (uint256) {
        return (timestamp / EPOCH_SIZE) * EPOCH_SIZE;
    }

    function lockAcquired(bytes calldata data) external override poolManagerOnly returns (bytes memory) {
        bytes4 selector = abi.decode(data[:32], (bytes4));

        if (selector == IPoolManager.modifyPosition.selector) {
            ModifyPositionCallback memory callback = abi.decode(data[32:], (ModifyPositionCallback));

            BalanceDelta delta = poolManager.modifyPosition(callback.key, callback.params, bytes(""));

            if (callback.params.liquidityDelta < 0) {
                // Removing liquidity, take tokens from the poolManager
                _takeDeltas(callback.key, delta);
            } else {
                // Adding liquidity, settle tokens to the poolManager
                _settleDeltas(callback.key, delta);
            }

            return abi.encode(delta);
        }

        if (selector == IPoolManager.swap.selector) {
            SwapCallback memory callback = abi.decode(data[32:], (SwapCallback));

            BalanceDelta delta = poolManager.swap(callback.key, callback.params, bytes(""));

            // Take and settle deltas
            _takeDeltas(callback.key, delta);
            _settleDeltas(callback.key, delta);

            return abi.encode(delta);
        }

        return bytes("");
    }
}
