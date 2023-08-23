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
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";

contract LiquidityBootstrappingPoolTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    int24 constant MIN_TICK_SPACING = 1;
    uint160 constant SQRT_RATIO_2_1 = 112045541949572279837463876454;

    TestERC20 token0;
    TestERC20 token1;
    PoolManager manager;
    LiquidityBootstrappingPoolImplementation liquidityBootstrappingPool =
        LiquidityBootstrappingPoolImplementation(address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG)));
    PoolKey key;
    PoolId id;

    PoolSwapTest swapRouter;
    PoolModifyPositionTest modifyPositionRouter;

    struct LiquidityInfo {
        uint128 totalAmount; // The total amount of liquidity to provide
        uint32 startTime; // Start time of the liquidity bootstrapping period
        uint32 endTime; // End time of the liquidity bootstrapping period
        int24 minTick; // The minimum tick to provide liquidity at
        int24 maxTick; // The maximum tick to provide liquidity at
        bool isToken0; // Whether the token to provide liquidity for is token0
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
            MIN_TICK_SPACING,
            liquidityBootstrappingPool
        );
        id = key.toId();

        swapRouter = new PoolSwapTest(manager);
        modifyPositionRouter = new PoolModifyPositionTest(IPoolManager(address(manager)));

        token0.approve(address(liquidityBootstrappingPool), type(uint256).max);
        token1.approve(address(liquidityBootstrappingPool), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyPositionRouter), type(uint256).max);
        token1.approve(address(modifyPositionRouter), type(uint256).max);
    }

    function testAfterInitializeSetsStorageAndTransfersTokens() public {
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 86400),
            minTick: int24(0),
            maxTick: int24(1000),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        (uint128 totalAmount, uint32 startTime, uint32 endTime, int24 minTick, int24 maxTick, bool isToken0) =
            liquidityBootstrappingPool.liquidityInfo();

        assertEq(totalAmount, liquidityInfo.totalAmount);
        assertEq(startTime, liquidityInfo.startTime);
        assertEq(endTime, liquidityInfo.endTime);
        assertEq(minTick, liquidityInfo.minTick);
        assertEq(maxTick, liquidityInfo.maxTick);
        assertEq(isToken0, liquidityInfo.isToken0);

        assertEq(token0.balanceOf(address(liquidityBootstrappingPool)), liquidityInfo.totalAmount);
    }

    function testAfterInitializeRevertsInvalidTimeRange() public {
        // CASE 1: startTime > endTime
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(block.timestamp + 86400),
            endTime: uint32(block.timestamp),
            minTick: int24(0),
            maxTick: int24(1000),
            isToken0: true
        });

        vm.expectRevert(bytes4(keccak256("InvalidTimeRange()")));
        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        // CASE 2: endTime < block.timestamp
        vm.warp(1000);

        liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(998),
            endTime: uint32(999),
            minTick: int24(0),
            maxTick: int24(1000),
            isToken0: true
        });

        vm.expectRevert(bytes4(keccak256("InvalidTimeRange()")));
        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));
    }

    function testAfterInitializeRevertsInvalidTickRange() public {
        // CASE 1: minTick > maxTick
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 86400),
            minTick: int24(1000),
            maxTick: int24(0),
            isToken0: true
        });

        vm.expectRevert(bytes4(keccak256("InvalidTickRange()")));
        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        // CASE 2: minTick < minUsableTick
        int24 minUsableTick = TickMath.minUsableTick(MIN_TICK_SPACING);

        liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 86400),
            minTick: int24(minUsableTick - 1),
            maxTick: int24(0),
            isToken0: true
        });

        vm.expectRevert(bytes4(keccak256("InvalidTickRange()")));
        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        // CASE 3: maxTick > maxUsableTick
        int24 maxUsableTick = TickMath.maxUsableTick(MIN_TICK_SPACING);

        liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 86400),
            minTick: int24(0),
            maxTick: int24(maxUsableTick + 1),
            isToken0: true
        });

        vm.expectRevert(bytes4(keccak256("InvalidTickRange()")));
        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));
    }

    function testGetTargetMinTick() public {
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(100000),
            endTime: uint32(100000 + 864000), // 10 day range
            minTick: int24(-42069),
            maxTick: int24(42069),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        // CASE 1: No time has passed, so the target min tick should be the max tick
        liquidityBootstrappingPool.getTargetMinTick(100000);

        // CASE 2: Half the time has passed, so the target min tick should be the average of the min and max ticks
        assertEq(liquidityBootstrappingPool.getTargetMinTick(100000 + 864000 / 2), 0);

        // CASE 3: All the time has passed, so the target min tick should be the min tick
        assertEq(liquidityBootstrappingPool.getTargetMinTick(100000 + 864000), -42069);

        // CASE 4: More time has passed, so the target min tick should still be the min tick
        assertEq(liquidityBootstrappingPool.getTargetMinTick(100000 + 864000 + 1000), -42069);
    }

    function testGetTargetMinTickRevertsBeforeStartTime() public {
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(100000),
            endTime: uint32(100000 + 864000), // 10 day range
            minTick: int24(-42069),
            maxTick: int24(42069),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        vm.expectRevert(bytes4(keccak256("BeforeStartTime()")));
        liquidityBootstrappingPool.getTargetMinTick(99999);
    }

    // int16 ticks to ensure they're within the usable tick range
    // uint16 startTime to ensure the endTime doesn't exceed uint32.max
    function testFuzzGetTargetMinTick(
        uint16 startTime,
        uint16 timeRange,
        int16 minTick,
        int16 maxTick,
        uint8 timePassedDenominator
    ) public {
        vm.assume(minTick < maxTick);
        vm.assume(timePassedDenominator > 0);

        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(block.timestamp + startTime),
            endTime: uint32(block.timestamp + startTime + timeRange),
            minTick: int24(minTick),
            maxTick: int24(maxTick),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        // Assert less than or equal to maxTick and greater than or equal to minTick
        int24 targetMinTick =
            liquidityBootstrappingPool.getTargetMinTick(block.timestamp + startTime + timeRange / timePassedDenominator);
        assertTrue(targetMinTick < maxTick || targetMinTick == maxTick);
        assertTrue(targetMinTick > minTick || targetMinTick == minTick);
    }

    function testGetTargetLiquidity() public {
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(42069e18),
            startTime: uint32(100000),
            endTime: uint32(100000 + 864000), // 10 day range
            minTick: int24(-42069),
            maxTick: int24(42069),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        // CASE 1: No time has passed, so the target liquidity should be 0
        assertEq(liquidityBootstrappingPool.getTargetLiquidity(100000), 0);

        // CASE 2: Half the time has passed, so the target liquidity should be half the total amount
        assertEq(liquidityBootstrappingPool.getTargetLiquidity(100000 + 864000 / 2), 210345e17);

        // CASE 3: All the time has passed, so the target liquidity should be the total amount
        assertEq(liquidityBootstrappingPool.getTargetLiquidity(100000 + 864000), 42069e18);

        // CASE 4: More time has passed, so the target liquidity should still be the total amount
        assertEq(liquidityBootstrappingPool.getTargetLiquidity(100000 + 864000 + 3600), 42069e18);
    }

    function testGetTargetLiquidityRevertsBeforeStartTime() public {
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(100000),
            endTime: uint32(100000 + 864000), // 10 day range
            minTick: int24(-42069),
            maxTick: int24(42069),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        vm.expectRevert(bytes4(keccak256("BeforeStartTime()")));
        liquidityBootstrappingPool.getTargetLiquidity(99999);
    }

    function testFuzzGetTargetLiquidity(
        uint128 totalAmount,
        uint16 startTime,
        uint16 timeRange,
        int16 minTick,
        int16 maxTick,
        uint8 timePassedDenominator
    ) public {
        vm.assume(minTick < maxTick);
        vm.assume(timePassedDenominator > 0);

        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(totalAmount),
            startTime: uint32(block.timestamp + startTime),
            endTime: uint32(block.timestamp + startTime + timeRange),
            minTick: int24(minTick),
            maxTick: int24(maxTick),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        uint256 targetLiquidity = liquidityBootstrappingPool.getTargetLiquidity(
            block.timestamp + startTime + timeRange / timePassedDenominator
        );
        // Assert less than or equal to target amount
        assertTrue(targetLiquidity < totalAmount || targetLiquidity == totalAmount);
    }

    function testBeforeSwapOutOfRangeSetsLiquidityPosition() public {
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(10000),
            endTime: uint32(10000 + 86400),
            minTick: int24(10000),
            maxTick: int24(20000),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        // CASE 1: Before start time, doesn't add liquidity
        vm.warp(9999);

        vm.prank(address(manager));
        liquidityBootstrappingPool.beforeSwap(address(0xBEEF), key, IPoolManager.SwapParams(true, 0, 0), bytes(""));

        assertEq(manager.getLiquidity(id), 0);

        // CASE 2: Part way through, adds correct amount of liquidity at correct range
        vm.warp(50000);

        vm.prank(address(manager));
        liquidityBootstrappingPool.beforeSwap(address(0xBEEF), key, IPoolManager.SwapParams(true, 0, 0), bytes(""));

        // Check liquidity at expected tick range
        Position.Info memory position = manager.getPosition(id, address(liquidityBootstrappingPool), 15741, 20000);

        // Assert liquidity value is proportional amount of liquidity to time passed
        assertEq(position.liquidity, 4878558521669597624372);

        // CASE 3: At end time, adds all liquidity at full range
        vm.warp(10000 + 86400 + 3600);

        vm.prank(address(manager));
        liquidityBootstrappingPool.beforeSwap(address(0xBEEF), key, IPoolManager.SwapParams(true, 0, 0), bytes(""));

        // Check liquidity at full tick range
        position = manager.getPosition(id, address(liquidityBootstrappingPool), 10000, 20000);

        // Assert liquidity value at new position is total amount of liquidity
        assertEq(position.liquidity, 4190272079389499705764);

        // Assert no liquidity at old position
        position = manager.getPosition(id, address(liquidityBootstrappingPool), 15741, 20000);
        assertEq(position.liquidity, 0);
    }

    function testBeforeSwapInRangeSwapsAndSetsLiquidity() public {
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(10000),
            endTime: uint32(10000 + 86400),
            minTick: int24(0),
            maxTick: int24(5000),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        // CASE 1: Tick is in range, swaps out of range and adds liquidity with remaining amount

        vm.warp(50000);

        // Get tick before swap
        (, int24 beforeTick,,,,) = manager.getSlot0(id);

        vm.prank(address(manager));
        liquidityBootstrappingPool.beforeSwap(address(0xBEEF), key, IPoolManager.SwapParams(true, 0, 0), bytes(""));

        // Get tick after swap
        (, int24 afterTick,,,,) = manager.getSlot0(id);

        // Assert tick has lowered
        assertTrue(afterTick < beforeTick);

        // Assert expected tick
        assertEq(afterTick, 2870);

        // Check liquidity at expected tick range
        Position.Info memory position = manager.getPosition(id, address(liquidityBootstrappingPool), 2871, 5000);

        // Assert liquidity value is proportional amount of liquidity to time passed
        assertEq(position.liquidity, 4869217071209495223347);

        // CASE 2: Time has passed, tick back in range, swaps out of range and adds liquidity with remaining amount

        vm.warp(60000);

        // Get tick before swap
        (, beforeTick,,,,) = manager.getSlot0(id);

        vm.prank(address(manager));
        liquidityBootstrappingPool.beforeSwap(address(0xBEEF), key, IPoolManager.SwapParams(true, 0, 0), bytes(""));

        // Get tick after swap
        (, afterTick,,,,) = manager.getSlot0(id);

        // Assert tick has lowered
        assertTrue(afterTick < beforeTick);

        // Assert expected tick
        assertEq(afterTick, 2245);

        // Check liquidity at expected tick range
        position = manager.getPosition(id, address(liquidityBootstrappingPool), 2246, 5000);

        // Assert liquidity value is proportional amount of liquidity to time passed - amount swapped
        assertEq(position.liquidity, 4791885898590874707175);
    }

    function testExit() public {
        // Get balance before exit
        uint256 balanceBefore = token0.balanceOf(address(this));

        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(10000),
            endTime: uint32(10000 + 86400),
            minTick: int24(0),
            maxTick: int24(5000),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        // Sync part way through
        vm.warp(50000);
        liquidityBootstrappingPool.sync(key);

        // Skip to end time
        vm.warp(10000 + 86400 + 3600);

        // Exit
        liquidityBootstrappingPool.exit(key);

        // Get balance after exit
        uint256 balanceAfter = token0.balanceOf(address(this));

        // Assert balance is the same since no swaps occured
        assertEq(balanceBefore / 10, balanceAfter / 10); // Acceptable amount of precision loss (< 10 wei)
    }

    function testFullFlow() public {
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(10000),
            endTime: uint32(10000 + 86400),
            minTick: int24(0),
            maxTick: int24(5000),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        // Before start time
        vm.warp(5000);

        // Provide external liquidity
        token0.mint(address(0xBEEF), 1000 ether);
        token1.mint(address(0xBEEF), 1000 ether);
        vm.startPrank(address(0xBEEF));
        token0.approve(address(modifyPositionRouter), 1000 ether);
        token1.approve(address(modifyPositionRouter), 1000 ether);
        modifyPositionRouter.modifyPosition(key, IPoolManager.ModifyPositionParams(0, 4000, 10 ether));
        vm.stopPrank();

        // Swap before start time each way
        token0.mint(address(0xdeadbeef), 1000 ether);
        token1.mint(address(0xdeadbeef), 1000 ether);
        vm.startPrank(address(0xdeadbeef));
        token0.approve(address(swapRouter), 1000 ether);
        token1.approve(address(swapRouter), 1000 ether);
        swapRouter.swap(
            key, IPoolManager.SwapParams(true, 1 ether, SQRT_RATIO_1_1), PoolSwapTest.TestSettings(true, true)
        );
        swapRouter.swap(
            key,
            IPoolManager.SwapParams(false, 2 ether, SQRT_RATIO_2_1 - 91239123),
            PoolSwapTest.TestSettings(true, true)
        );
        vm.stopPrank();

        // Part way through duration
        vm.warp(50000);

        // Sync
        liquidityBootstrappingPool.sync(key);

        // Swap
        vm.startPrank(address(0xdeadbeef));
        swapRouter.swap(
            key, IPoolManager.SwapParams(false, 100 ether, SQRT_RATIO_4_1), PoolSwapTest.TestSettings(true, true)
        );
        vm.stopPrank();

        // Skip to end time
        vm.warp(10000 + 86400 + 3600);

        // Swap
        vm.startPrank(address(0xdeadbeef));
        swapRouter.swap(
            key, IPoolManager.SwapParams(true, 20 ether, SQRT_RATIO_1_2), PoolSwapTest.TestSettings(true, true)
        );
        vm.stopPrank();

        // Exit
        liquidityBootstrappingPool.exit(key);
    }

    function testFullFlowToken1() public {
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(10000),
            endTime: uint32(10000 + 86400),
            minTick: int24(0),
            maxTick: int24(5000),
            isToken0: false
        });

        manager.initialize(key, SQRT_RATIO_1_2, abi.encode(liquidityInfo));

        // Before start time
        vm.warp(5000);

        // Provide external liquidity
        token0.mint(address(0xBEEF), 1000 ether);
        token1.mint(address(0xBEEF), 1000 ether);
        vm.startPrank(address(0xBEEF));
        token0.approve(address(modifyPositionRouter), 1000 ether);
        token1.approve(address(modifyPositionRouter), 1000 ether);
        modifyPositionRouter.modifyPosition(key, IPoolManager.ModifyPositionParams(-4000, 0, 10 ether));
        vm.stopPrank();

        // Swap before start time each way
        token0.mint(address(0xdeadbeef), 1000 ether);
        token1.mint(address(0xdeadbeef), 1000 ether);
        vm.startPrank(address(0xdeadbeef));
        token0.approve(address(swapRouter), 1000 ether);
        token1.approve(address(swapRouter), 1000 ether);
        swapRouter.swap(
            key, IPoolManager.SwapParams(false, 1 ether, SQRT_RATIO_1_1), PoolSwapTest.TestSettings(true, true)
        );
        swapRouter.swap(
            key,
            IPoolManager.SwapParams(true, 2 ether, SQRT_RATIO_1_2 - 91239123),
            PoolSwapTest.TestSettings(true, true)
        );
        vm.stopPrank();

        // Part way through duration
        vm.warp(50000);

        // Sync
        liquidityBootstrappingPool.sync(key);

        // Swap
        vm.startPrank(address(0xdeadbeef));
        swapRouter.swap(
            key, IPoolManager.SwapParams(true, 100 ether, SQRT_RATIO_1_4), PoolSwapTest.TestSettings(true, true)
        );
        vm.stopPrank();

        // Skip to end time
        vm.warp(10000 + 86400 + 3600);

        // Swap
        vm.startPrank(address(0xdeadbeef));
        swapRouter.swap(
            key, IPoolManager.SwapParams(false, 20 ether, SQRT_RATIO_2_1), PoolSwapTest.TestSettings(true, true)
        );
        vm.stopPrank();

        // Exit
        liquidityBootstrappingPool.exit(key);
    }
}
