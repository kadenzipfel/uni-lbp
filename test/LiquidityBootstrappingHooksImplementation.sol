// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseHook} from "@uniswap/v4-periphery/contracts/BaseHook.sol";
import {LiquidityBootstrappingHooks} from "../src/LiquidityBootstrappingHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";

contract LiquidityBootstrappingHooksImplementation is LiquidityBootstrappingHooks {
    constructor(IPoolManager _poolManager, LiquidityBootstrappingHooks addressToEtch)
        LiquidityBootstrappingHooks(_poolManager)
    {
        Hooks.validateHookAddress(addressToEtch, getHooksCalls());
    }

    // make this a no-op in testing
    function validateHookAddress(BaseHook _this) internal pure override {}

    function getTargetMinTick(PoolId poolId, uint256 timestamp) public view returns (int24) {
        return _getTargetMinTick(poolId, timestamp);
    }

    function getTargetLiquidity(PoolId poolId, uint256 timestamp) public view returns (uint256) {
        return _getTargetLiquidity(poolId, timestamp);
    }
}
