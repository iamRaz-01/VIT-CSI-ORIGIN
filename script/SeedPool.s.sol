// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// SeedPool.s.sol - Pool Initialization & Demo State Setup
// CSI ORIGIN 2026, PS-12
// =============================================================================

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager}   from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}        from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency}       from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks}         from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {DCACoordinator} from "../src/core/DCACoordinator.sol";

contract SeedPool is Script {
    using PoolIdLibrary for PoolKey;

    address internal POOL_MANAGER = vm.envAddress("POOL_MANAGER_ADDRESS");
    address internal USDC         = vm.envAddress("USDC_ADDRESS");
    address internal MOCK_TOKEN   = vm.envOr("MOCK_TOKEN_ADDRESS", address(0));
    address internal HOOK         = vm.envOr("HOOK_ADDRESS", address(0));
    address internal COORDINATOR  = vm.envOr("COORDINATOR_ADDRESS", address(0));

    uint256 internal deployerKey  = vm.envUint("DEPLOYER_PRIVATE_KEY");

    uint160 constant INITIAL_SQRT_PRICE = 79228162514264337593543950336; // 1:1 Q96

    function run() external {
        address deployer = vm.addr(deployerKey);
        if (deployer.balance < 10 ether) {
            vm.deal(deployer, 100 ether);
        }

        vm.startBroadcast(deployerKey);

        if (MOCK_TOKEN != address(0) && HOOK != address(0)) {
            address token0 = USDC < MOCK_TOKEN ? USDC : MOCK_TOKEN;
            address token1 = USDC < MOCK_TOKEN ? MOCK_TOKEN : USDC;

            PoolKey memory key = PoolKey({
                currency0:   Currency.wrap(token0),
                currency1:   Currency.wrap(token1),
                fee:         3000,
                tickSpacing: 60,
                hooks:       IHooks(HOOK)
            });

            try IPoolManager(POOL_MANAGER).initialize(key, INITIAL_SQRT_PRICE) returns (int24) {
                console2.log("[SEED] Pool initialized successfully");
            } catch {
                console2.log("[SEED] Pool was already initialized or skipped");
            }

            if (COORDINATOR != address(0)) {
                DCACoordinator(COORDINATOR).setReferencePrice(PoolId.unwrap(key.toId()), INITIAL_SQRT_PRICE);
                console2.log("[SEED] Reference price seeded on DCACoordinator");
            }
        } else {
            console2.log("[SEED] Missing MOCK_TOKEN_ADDRESS or HOOK_ADDRESS in env");
        }

        vm.stopBroadcast();

        console2.log("\n=== SEED COMPLETE ===");
    }
}

