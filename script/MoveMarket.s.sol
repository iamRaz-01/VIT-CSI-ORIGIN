// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// MoveMarket.s.sol - Demo Market State Manipulation
// CSI ORIGIN 2026, PS-12
// =============================================================================

import {Script, console2} from "forge-std/Script.sol";
import {DCACoordinator} from "../src/core/DCACoordinator.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract MoveMarket is Script {
    using PoolIdLibrary for PoolKey;

    address internal USDC        = vm.envAddress("USDC_ADDRESS");
    address internal MOCK_TOKEN  = vm.envOr("MOCK_TOKEN_ADDRESS", address(0));
    address internal HOOK        = vm.envOr("HOOK_ADDRESS", address(0));
    address internal COORDINATOR = vm.envOr("COORDINATOR_ADDRESS", address(0));
    uint256 internal deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

    uint160 constant INITIAL_SQRT_PRICE = 79228162514264337593543950336; // 1:1 Q96

    function moveGood() external {
        vm.startBroadcast(deployerKey);
        console2.log("[MoveMarket] Driving price to GOOD state (0 bps deviation)");
        if (COORDINATOR != address(0) && MOCK_TOKEN != address(0) && HOOK != address(0)) {
            address token0 = USDC < MOCK_TOKEN ? USDC : MOCK_TOKEN;
            address token1 = USDC < MOCK_TOKEN ? MOCK_TOKEN : USDC;

            PoolKey memory key = PoolKey({
                currency0:   Currency.wrap(token0),
                currency1:   Currency.wrap(token1),
                fee:         3000,
                tickSpacing: 60,
                hooks:       IHooks(HOOK)
            });

            DCACoordinator(COORDINATOR).setReferencePrice(PoolId.unwrap(key.toId()), INITIAL_SQRT_PRICE);
            console2.log("[MoveMarket] Reference price reset to match initial price (0 bps deviation)");
        }
        vm.stopBroadcast();
    }

    function moveBad() external {
        vm.startBroadcast(deployerKey);
        console2.log("[MoveMarket] Driving price to BAD state (+5% deviation)");
        if (COORDINATOR != address(0) && MOCK_TOKEN != address(0) && HOOK != address(0)) {
            address token0 = USDC < MOCK_TOKEN ? USDC : MOCK_TOKEN;
            address token1 = USDC < MOCK_TOKEN ? MOCK_TOKEN : USDC;

            PoolKey memory key = PoolKey({
                currency0:   Currency.wrap(token0),
                currency1:   Currency.wrap(token1),
                fee:         3000,
                tickSpacing: 60,
                hooks:       IHooks(HOOK)
            });

            uint256 badRefSqrt = uint256(INITIAL_SQRT_PRICE) * 10000 / 10500;
            DCACoordinator(COORDINATOR).setReferencePrice(PoolId.unwrap(key.toId()), badRefSqrt);
            console2.log("[MoveMarket] Reference price adjusted to create 500 bps deviation (> badDeviationBps)");
        }
        vm.stopBroadcast();
    }
}

