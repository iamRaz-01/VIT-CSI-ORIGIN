// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// Deploy.s.sol - DCA Vault Protocol Deployment Script
// CSI ORIGIN 2026, PS-12
//
// DEPLOYMENT ORDER (INTERFACE_CONTRACTS.md -13.2 - hard dependency chain):
//   1. MockERC20        (counter-asset - no upstream dependencies)
//   2. DCAVault         (needs USDC_ADDRESS)
//   3. AaveYieldStrategy | MockYieldStrategy (needs AAVE_POOL_ADDRESS or none;
//                                              needs DCAVault address to authorize)
//   4. DCACoordinator   (needs DCAVault, POOL_MANAGER_ADDRESS)
//   5. DCAHook          (mined address - needs DCACoordinator, POOL_MANAGER_ADDRESS)
//   6. Pool init        (handled by SeedPool.s.sol - needs DCAHook, MockToken, USDC)
//
// USAGE (from repo root, with Anvil running):
//   forge script script/Deploy.s.sol \
//     --rpc-url http://127.0.0.1:8545 \
//     --broadcast \
//     --private-key $DEPLOYER_PRIVATE_KEY \
//     -vvvv
//
// OUTPUT: Deployed addresses printed to console and written to broadcast/
//         directory for downstream script consumption.
// =============================================================================

import {Script, console2} from "forge-std/Script.sol";

// --- Core contracts (implemented by Vault / Coordinator / Hook worktrees) ---
// Uncomment each import as the owning worktree merges its contract.
//
// import {DCAVault}          from "../src/core/DCAVault.sol";
// import {DCACoordinator}    from "../src/core/DCACoordinator.sol";
// import {DCAHook}           from "../src/core/DCAHook.sol";
// import {AaveYieldStrategy} from "../src/strategies/AaveYieldStrategy.sol";
// import {MockYieldStrategy} from "../src/strategies/MockYieldStrategy.sol";
// import {MockERC20}         from "../src/mocks/MockERC20.sol";

// --- Uniswap v4 deployment helpers (from v4-periphery) ---
// import {HookMiner}         from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
// import {IPoolManager}      from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// import {Hooks}             from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract Deploy is Script {
    // -------------------------------------------------------------------------
    // Environment variables (loaded from .env / shell - see .env.example)
    // -------------------------------------------------------------------------
    address internal USDC          = vm.envAddress("USDC_ADDRESS");
    address internal AAVE_POOL     = vm.envAddress("AAVE_POOL_ADDRESS");
    address internal POOL_MANAGER  = vm.envAddress("POOL_MANAGER_ADDRESS");
    uint256 internal deployerKey   = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address internal deployer      = vm.addr(deployerKey);

    // -------------------------------------------------------------------------
    // Deployed address slots (set during run(), read by downstream scripts)
    // -------------------------------------------------------------------------
    address public mockToken;
    address public vault;
    address public yieldStrategy;
    address public coordinator;
    address public hook;

    // -------------------------------------------------------------------------
    // DCAHook permission flags (INTERFACE_CONTRACTS.md -9, -13.2 step 5)
    // beforeSwap = true, afterSwap = true, all else false.
    // These bits must be encoded into the hook's deployed address via HookMiner.
    // -------------------------------------------------------------------------
    // uint160 internal constant HOOK_FLAGS =
    //     uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    function run() external {
        vm.startBroadcast(deployerKey);

        // ---------------------------------------------------------------------
        // STEP 1 - MockERC20 (counter-asset for the demo pool)
        // No external dependencies.
        // ---------------------------------------------------------------------
        // mockToken = address(new MockERC20("Mock DCA Target", "mDCA", 18));
        // console2.log("MockERC20:          ", mockToken);
        _step1_placeholder();

        // ---------------------------------------------------------------------
        // STEP 2 - DCAVault (ERC-4626, deposit asset = USDC)
        // Depends on: USDC_ADDRESS
        // ---------------------------------------------------------------------
        // vault = address(new DCAVault(USDC));
        // console2.log("DCAVault:           ", vault);
        _step2_placeholder();

        // ---------------------------------------------------------------------
        // STEP 3 - Yield Strategy (Aave primary, Mock fallback)
        // Depends on: DCAVault address, AAVE_POOL_ADDRESS
        //
        // To swap to MockYieldStrategy: change the deployed contract below and
        // pass the same `vault` address - zero downstream changes (-6.3).
        // ---------------------------------------------------------------------
        // yieldStrategy = address(new AaveYieldStrategy(AAVE_POOL, vault, USDC));
        // -- OR for fallback: --
        // yieldStrategy = address(new MockYieldStrategy(vault, USDC));
        //
        // DCAVault(vault).setStrategy(yieldStrategy); // one-time deployer call
        // console2.log("YieldStrategy:      ", yieldStrategy);
        _step3_placeholder();

        // ---------------------------------------------------------------------
        // STEP 4 - DCACoordinator
        // Depends on: DCAVault address, POOL_MANAGER_ADDRESS
        // Hook address is not known yet (mined in step 5); Coordinator stores it
        // via a post-mine setHook() or constructor arg - see -23-G pattern.
        // ---------------------------------------------------------------------
        // coordinator = address(new DCACoordinator(vault, POOL_MANAGER));
        // console2.log("DCACoordinator:     ", coordinator);
        _step4_placeholder();

        // ---------------------------------------------------------------------
        // STEP 5 - DCAHook (mined address, Technical Architecture -6.2, -19)
        //
        // HookMiner finds a salt such that CREATE2(deployer, salt, bytecode)
        // produces an address whose lower bits encode HOOK_FLAGS.
        //
        // Pattern from v4-template (canonical reference):
        //   (address hookAddr, bytes32 salt) = HookMiner.find(
        //       deployer,
        //       HOOK_FLAGS,
        //       type(DCAHook).creationCode,
        //       abi.encode(coordinator, POOL_MANAGER)
        //   );
        //   hook = address(new DCAHook{salt: salt}(coordinator, POOL_MANAGER));
        //   require(hook == hookAddr, "hook address mismatch");
        //
        // Flags required: beforeSwap = true, afterSwap = true, all else false.
        // RISK: Address mining can take seconds to minutes depending on hardware.
        // De-risked by using HookMiner exactly as in v4-template (-19 Red Team).
        // ---------------------------------------------------------------------
        // console2.log("DCAHook:            ", hook);
        _step5_placeholder();

        // ---------------------------------------------------------------------
        // POST-DEPLOY: authorize Coordinator in Vault (if Vault has an
        // explicit coordinator setter rather than constructor-arg)
        // ---------------------------------------------------------------------
        // DCAVault(vault).setCoordinator(coordinator);

        vm.stopBroadcast();

        // ---------------------------------------------------------------------
        // Print summary for copy-paste into .env / team Slack
        // ---------------------------------------------------------------------
        console2.log("\n=== DEPLOYMENT COMPLETE ===");
        console2.log("MockERC20:          ", mockToken);
        console2.log("DCAVault:           ", vault);
        console2.log("YieldStrategy:      ", yieldStrategy);
        console2.log("DCACoordinator:     ", coordinator);
        console2.log("DCAHook:            ", hook);
        console2.log("===========================\n");
        console2.log("Next: run SeedPool.s.sol with MOCK_TOKEN_ADDRESS=", mockToken);
    }

    // -------------------------------------------------------------------------
    // Placeholder functions - remove each when the real contract is merged in.
    // -------------------------------------------------------------------------
    function _step1_placeholder() internal {
        console2.log("[PLACEHOLDER] Step 1 - MockERC20 not yet deployed (Vault worktree)");
    }
    function _step2_placeholder() internal {
        console2.log("[PLACEHOLDER] Step 2 - DCAVault not yet deployed (Vault worktree)");
    }
    function _step3_placeholder() internal {
        console2.log("[PLACEHOLDER] Step 3 - YieldStrategy not yet deployed (Vault worktree)");
    }
    function _step4_placeholder() internal {
        console2.log("[PLACEHOLDER] Step 4 - DCACoordinator not yet deployed (Coordinator worktree)");
    }
    function _step5_placeholder() internal {
        console2.log("[PLACEHOLDER] Step 5 - DCAHook not yet mined/deployed (Hook worktree)");
    }
}
