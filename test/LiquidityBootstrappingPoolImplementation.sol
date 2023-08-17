// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseHook} from "@uniswap/v4-periphery/contracts/BaseHook.sol";
import {LiquidityBootstrappingPool} from "../src/LiquidityBootstrappingPool.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";

contract LiquidityBootstrappingPoolImplementation is LiquidityBootstrappingPool {
    constructor(
        IPoolManager _poolManager,
        LiquidityBootstrappingPool addressToEtch
    ) LiquidityBootstrappingPool(_poolManager) {
        Hooks.validateHookAddress(addressToEtch, getHooksCalls());
    }

    // make this a no-op in testing
    function validateHookAddress(BaseHook _this) internal pure override {}
}