// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// SeedPool.s.sol - Pool Initialization & Demo State Setup
// CSI ORIGIN 2026, PS-12
//
// Runs AFTER Deploy.s.sol.  Initializes the isolated USDC/MockToken v4 pool
// with DCAHook attached, adds initial liquidity, and takes an evm_snapshot so
// the demo can be reset to a known-good state between rehearsals.
//
// Technical Architecture -13 demo-critical scripts.
// INTERFACE_CONTRACTS.md -13.2 step 6.
//
// USAGE:
//   forge script script/SeedPool.s.sol \
//     --rpc-url http://127.0.0.1:8545 \
//     --broadcast \
//     --private-key $DEPLOYER_PRIVATE_KEY \
//     -vvvv
//
// PREREQUISITES:
//   - Anvil fork running
//   - Deploy.s.sol already broadcast (addresses available from broadcast/ output)
//   - MOCK_TOKEN_ADDRESS set in env (output of Deploy.s.sol step 1)
// =============================================================================

import {Script, console2} from "forge-std/Script.sol";

// import {IPoolManager}   from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// import {PoolKey}        from "@uniswap/v4-core/src/types/PoolKey.sol";
// import {Currency}       from "@uniswap/v4-core/src/types/Currency.sol";
// import {IHooks}         from "@uniswap/v4-core/src/interfaces/IHooks.sol";
// import {TickMath}       from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract SeedPool is Script {
    // -------------------------------------------------------------------------
    // Deployed addresses - set these from Deploy.s.sol output
    // -------------------------------------------------------------------------
    address internal POOL_MANAGER = vm.envAddress("POOL_MANAGER_ADDRESS");
    address internal USDC         = vm.envAddress("USDC_ADDRESS");
    address internal MOCK_TOKEN   = vm.envAddress("MOCK_TOKEN_ADDRESS");
    address internal HOOK;        // = <DCAHook address from Deploy output>
    address internal COORDINATOR; // = <DCACoordinator address from Deploy output>

    uint256 internal deployerKey  = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address internal deployer     = vm.addr(deployerKey);

    // -------------------------------------------------------------------------
    // Demo pool parameters (tuned in Phase 8 against real seeded depth - -2 O3)
    // -------------------------------------------------------------------------
    // Starting sqrtPriceX96 - 1 USDC = 1 mockToken at 1:1 ratio (adjust for decimals)
    // uint160 constant INITIAL_SQRT_PRICE = 79228162514264337593543950336; // 1:1 ratio

    // Tick spacing (500 fee tier - tickSpacing 10; for demo isolation any tier works)
    // int24 constant TICK_SPACING = 10;
    // uint24 constant FEE         = 500; // 0.05%

    function run() external {
        vm.startBroadcast(deployerKey);

        // ---------------------------------------------------------------------
        // 1. Impersonate a USDC whale to fund the demo wallets
        //    (Anvil-only: anvil_impersonateAccount + anvil_setBalance)
        //    This is done via cast or a separate setup script rather than here,
        //    since `vm.prank` is a test-only cheatcode not available in broadcast.
        //    See scripts/fund-demo-wallets.sh for the cast equivalent.
        // ---------------------------------------------------------------------
        console2.log("[SEED] Step 1 - Fund demo wallets (see fund-demo-wallets.sh)");

        // ---------------------------------------------------------------------
        // 2. Initialize the USDC/MockToken v4 pool with DCAHook
        //
        // PoolKey construction:
        //   currency0 < currency1 by address (Uniswap v4 requirement)
        //   hook      = address(DCAHook) - must encode beforeSwap+afterSwap flags
        //
        // PoolKey memory key = PoolKey({
        //     currency0:   Currency.wrap(address(USDC) < address(MOCK_TOKEN) ? USDC : MOCK_TOKEN),
        //     currency1:   Currency.wrap(address(USDC) < address(MOCK_TOKEN) ? MOCK_TOKEN : USDC),
        //     fee:         FEE,
        //     tickSpacing: TICK_SPACING,
        //     hooks:       IHooks(HOOK)
        // });
        // IPoolManager(POOL_MANAGER).initialize(key, INITIAL_SQRT_PRICE);
        // console2.log("[SEED] Pool initialized with DCAHook");
        console2.log("[PLACEHOLDER] Step 2 - Pool init (needs DCAHook address)");

        // ---------------------------------------------------------------------
        // 3. Add initial liquidity (via PositionManager or direct modifyLiquidity)
        //    Sufficient depth for the demo tranche sizes; can be minimal.
        // ---------------------------------------------------------------------
        console2.log("[PLACEHOLDER] Step 3 - Add initial liquidity");

        // ---------------------------------------------------------------------
        // 4. Set up demo User A and User B constraints via DCACoordinator
        //    (can also be done interactively in the demo - seeded here for
        //    repeatable snapshot-revert)
        //
        // Constraints memory constraintsA = Constraints({
        //     minFrequencyDays:      1,
        //     maxDelayDays:          3,
        //     goodDeviationBps:      100,  // 1%
        //     badDeviationBps:       300,  // 3%
        //     trancheFlexMinBps:     5000, // 50%
        //     trancheFlexMaxBps:     10000,// 100%
        //     standardTrancheAmount: 100e6,// 100 USDC (6 decimals)
        //     maxSlippageBps:        50    // 0.5%
        // });
        // DCACoordinator(COORDINATOR).setConstraints(constraintsA); // as USER_A
        console2.log("[PLACEHOLDER] Step 4 - Set user constraints");

        vm.stopBroadcast();

        // ---------------------------------------------------------------------
        // 5. Take evm_snapshot for repeatable demo resets
        //    Done via cast after broadcast (cannot use vm.snapshot in broadcast):
        //    SNAPSHOT_ID=$(cast rpc evm_snapshot --rpc-url http://127.0.0.1:8545)
        //    echo "Snapshot ID: $SNAPSHOT_ID  (use evm_revert to reset demo)"
        // ---------------------------------------------------------------------
        console2.log("\n=== SEED COMPLETE ===");
        console2.log("Run the following to snapshot demo state:");
        console2.log("  SNAPSHOT_ID=$(cast rpc evm_snapshot --rpc-url http://127.0.0.1:8545)");
        console2.log("  echo Snapshot: $SNAPSHOT_ID");
        console2.log("To reset before each demo run:");
        console2.log("  cast rpc evm_revert $SNAPSHOT_ID --rpc-url http://127.0.0.1:8545");
    }
}
