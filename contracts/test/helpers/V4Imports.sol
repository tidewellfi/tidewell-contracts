// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Compiles the real Uniswap v4 contracts so the tests can deploy them.
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
