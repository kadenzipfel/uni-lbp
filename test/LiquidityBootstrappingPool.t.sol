// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {LiquidityBootstrappingPoolImplementation} from "./LiquidityBootstrappingPoolImplementation.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";

contract LiquidityBootstrappingPool is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    int24 constant MAX_TICK_SPACING = 32767;
    uint160 constant SQRT_RATIO_2_1 = 112045541949572279837463876454;

    TestERC20 token0;
    TestERC20 token1;
    PoolManager manager;
    LiquidityBootstrappingPoolImplementation liquidityBootstrappingPool =
        LiquidityBootstrappingPoolImplementation(address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG)));
    PoolKey key;
    PoolId id;

    PoolSwapTest swapRouter;

    struct LiquidityInfo {
        uint128 totalAmount; // The total amount of liquidity to provide
        uint128 amountProvided; // The amount of liquidity already provided
        uint64 startTime; // Start time of the liquidity bootstrapping period
        uint64 endTime; // End time of the liquidity bootstrapping period
        int24 minTick; // The minimum tick to provide liquidity at
        int24 maxTick; // The maximum tick to provide liquidity at
    }

    function setUp() public {
        token0 = new TestERC20(2**128);
        token1 = new TestERC20(2**128);

        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }

        manager = new PoolManager(500000);

        vm.record();
        LiquidityBootstrappingPoolImplementation impl =
            new LiquidityBootstrappingPoolImplementation(manager, liquidityBootstrappingPool);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(liquidityBootstrappingPool), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(liquidityBootstrappingPool), slot, vm.load(address(impl), slot));
            }
        }
        key = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            0,
            MAX_TICK_SPACING,
            liquidityBootstrappingPool
        );
        id = key.toId();

        swapRouter = new PoolSwapTest(manager);

        token0.approve(address(liquidityBootstrappingPool), type(uint256).max);
        token1.approve(address(liquidityBootstrappingPool), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
    }

    function testAfterInitializeSetsStorage() public {
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            amountProvided: uint128(0),
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 86400),
            minTick: int24(0),
            maxTick: int24(1000)
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        (uint128 totalAmount, uint128 amountProvided, uint64 startTime, uint64 endTime, int24 minTick, int24 maxTick) =
            liquidityBootstrappingPool.liquidityInfo();

        assertEq(totalAmount, liquidityInfo.totalAmount);
        assertEq(amountProvided, liquidityInfo.amountProvided);
        assertEq(startTime, liquidityInfo.startTime);
        assertEq(endTime, liquidityInfo.endTime);
        assertEq(minTick, liquidityInfo.minTick);
        assertEq(maxTick, liquidityInfo.maxTick);
    }

    function testAfterInitializeRevertsInvalidAmountProvided() public {
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            amountProvided: uint128(1),
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 86400),
            minTick: int24(0),
            maxTick: int24(1000)
        });

        vm.expectRevert(bytes4(keccak256("InvalidAmountProvided()")));
        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));
    }
}
