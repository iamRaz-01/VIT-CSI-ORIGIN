// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// MoveMarket.s.sol - Demo Market State Manipulation
// CSI ORIGIN 2026, PS-12
//
// Manufactures "good" and "bad" market deviation states for the demo by
// executing swaps against the demo pool.  Makes both demo branches
// (EXECUTE_FULL and DELAY/rejection) deterministic and repeatable.
//
// Technical Architecture -13: "MoveMarket.s.sol - executes swaps against
// the pool to manufacture a 'bad deviation' state on demand, and to move
// it back for a 'good' state - makes both demo branches deterministic and
// repeatable, not dependent on real market timing."
//
// USAGE:
//   # Drive price toward "bad" deviation (triggers DELAY or hook rejection):
//   forge script script/MoveMarket.s.sol --sig "moveBad()" \
//     --rpc-url http://127.0.0.1:8545 --broadcast --private-key $DEPLOYER_PRIVATE_KEY
//
//   # Restore price to "good" deviation (triggers EXECUTE_FULL):
//   forge script script/MoveMarket.s.sol --sig "moveGood()" \
//     --rpc-url http://127.0.0.1:8545 --broadcast --private-key $DEPLOYER_PRIVATE_KEY
//
// NOTE: Before calling either function, reset to snapshot:
//   cast rpc evm_revert $SNAPSHOT_ID --rpc-url http://127.0.0.1:8545
// =============================================================================

import {Script, console2} from "forge-std/Script.sol";

// import {IPoolManager}      from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// import {PoolKey}           from "@uniswap/v4-core/src/types/PoolKey.sol";
// import {IPoolSwapTest}     from "@uniswap/v4-core/src/test/IPoolSwapTest.sol";

contract MoveMarket is Script {
    address internal POOL_MANAGER = vm.envAddress("POOL_MANAGER_ADDRESS");
    address internal USDC         = vm.envAddress("USDC_ADDRESS");
    address internal MOCK_TOKEN   = vm.envAddress("MOCK_TOKEN_ADDRESS");
    uint256 internal deployerKey  = vm.envUint("DEPLOYER_PRIVATE_KEY");

    // PoolKey must match the one used in SeedPool.s.sol
    // PoolKey internal poolKey;

    // -------------------------------------------------------------------------
    // moveGood() - Restores price to near-reference (within goodDeviationBps)
    // - poke() will return EXECUTE_FULL for any eligible user
    // -------------------------------------------------------------------------
    function moveGood() external {
        vm.startBroadcast(deployerKey);
        console2.log("[MoveMarket] Driving price to GOOD state (within deviation band)");
        // TODO (Track D/E): execute swap to restore sqrtPriceX96 close to referencePrice
        // Exact swap amount calibrated in Phase 8 against actual pool depth (-2 O3)
        console2.log("[PLACEHOLDER] Real swap pending pool deployment");
        vm.stopBroadcast();
    }

    // -------------------------------------------------------------------------
    // moveBad() - Drives price outside badDeviationBps
    // - poke() will return DELAY (or EXECUTE_PARTIAL near deadline)
    // - With tight maxSlippageBps, the hook will revert (demo Feature 5)
    // -------------------------------------------------------------------------
    function moveBad() external {
        vm.startBroadcast(deployerKey);
        console2.log("[MoveMarket] Driving price to BAD state (outside deviation band)");
        // TODO (Track D/E): execute swap to push sqrtPriceX96 beyond badDeviationBps
        console2.log("[PLACEHOLDER] Real swap pending pool deployment");
        vm.stopBroadcast();
    }
}
