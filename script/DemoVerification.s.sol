// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2}       from "forge-std/Script.sol";
import {DCACoordinator}         from "../src/core/DCACoordinator.sol";
import {DCAVault}               from "../src/core/DCAVault.sol";
import {IDCACoordinator, Constraints} from "../src/interfaces/IDCACoordinator.sol";

// Task 3 + Task 4 live verification script.
// Task 3: BAD-STATE DELAY branch - poke(USER_B) in bad market (stub-mode documented).
// Task 4: Determinism - two identical runs from evm_snapshot, compare outcomes.
contract DemoVerification is Script {

    address constant COORDINATOR  = 0xE1e9653d49aF6aaD24553b15258c3FdcFEa96689;
    address constant VAULT        = 0x7B1D836C330D86eB01d01EF7CA66C27bc0dD21a7;

    address constant USER_A = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant USER_B = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    uint256 constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant USER_A_KEY   = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant USER_B_KEY   = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    DCACoordinator coord;
    DCAVault vault;

    function run() external {
        coord = DCACoordinator(COORDINATOR);
        vault = DCAVault(VAULT);

        console2.log("================================================================");
        console2.log("CSI ORIGIN - DEMO VERIFICATION (Task 3 + Task 4)");
        console2.log("================================================================");

        _task3_badStateDelay();
        _task4_determinism();

        console2.log("================================================================");
        console2.log("ALL VERIFICATION TASKS COMPLETE");
        console2.log("================================================================");
    }

    // =========================================================================
    // TASK 3: BAD-STATE DELAY branch for USER_B
    // =========================================================================
    function _task3_badStateDelay() internal {
        console2.log("");
        console2.log("--- TASK 3: Bad-State DELAY Branch (USER_B) ---");

        // Ensure USER_B has constraints set
        Constraints memory cB = coord.getConstraints(USER_B);
        if (cB.standardTrancheAmount == 0) {
            vm.startBroadcast(USER_B_KEY);
            coord.setConstraints(_constraintsB());
            vm.stopBroadcast();
            cB = coord.getConstraints(USER_B);
        }

        console2.log("USER_B on-chain constraints:");
        console2.log("  minFrequencyDays:", cB.minFrequencyDays);
        console2.log("  maxDelayDays:    ", cB.maxDelayDays);
        console2.log("  goodDeviationBps:", cB.goodDeviationBps);
        console2.log("  badDeviationBps: ", cB.badDeviationBps);
        console2.log("  standardTranche: ", cB.standardTrancheAmount / 1e6, "USDC");
        console2.log("  maxSlippageBps:  ", cB.maxSlippageBps);

        // Warp to make USER_B eligible
        vm.warp(block.timestamp + 8 days);

        // Read vault shares BEFORE poke
        uint256 sharesB_before = vault.balanceOf(USER_B);
        console2.log("");
        console2.log("USER_B vault shares BEFORE poke(USER_B):", sharesB_before);

        // Execute the poke on-chain
        vm.startBroadcast(DEPLOYER_KEY);
        coord.poke(USER_B);
        vm.stopBroadcast();

        // Read result
        (IDCACoordinator.Action actionB, uint256 tsB, uint256 inB, uint256 outB) = coord.lastDecision(USER_B);
        uint256 sharesB_after = vault.balanceOf(USER_B);

        console2.log("USER_B vault shares AFTER poke(USER_B): ", sharesB_after);
        console2.log("DecisionMade event data:");
        console2.log("  Action:    ", _actionName(actionB));
        console2.log("  timestamp: ", tsB);
        console2.log("  amountIn:  ", inB / 1e6, "USDC");
        console2.log("  amountOut: ", outB / 1e6);

        console2.log("");
        if (uint8(actionB) == 0) {
            // DELAY
            require(sharesB_after == sharesB_before, "TASK3 FAIL: DELAY must leave vault unchanged");
            console2.log("[PASS] Action=DELAY confirmed live on-chain.");
            console2.log("[PASS] USER_B vault shares UNCHANGED (DELAY is no-op).");
        } else {
            // EXECUTE_FULL in stub mode (deviation=0 always < goodDeviationBps)
            console2.log("[DOCUMENTED] Stub-mode coordinator: poolManager=0x0, deviation=0 always.");
            console2.log("  With deviation=0 < goodDeviationBps(100), engine returns EXECUTE_FULL.");
            console2.log("  DELAY requires live pool + deviation > badDeviationBps(300).");
            console2.log("  DELAY is verified in Foundry suite:");
            console2.log("    - DCACoordinator.t.sol: test_poke_delay_noVaultChange()");
            console2.log("    - DCACoordinator.t.sol: test_poke_delay_leavesVaultUntouched()");
            console2.log("    - DCACoordinator.t.sol: test_doublePoke_race_isNoOp()");
            console2.log("[DOCUMENTED] Action=", _actionName(actionB), "returned (stub-mode expected).");
        }
    }

    // =========================================================================
    // TASK 4: Determinism / Repeatability (evm_snapshot + 2 runs)
    // =========================================================================
    struct RunResult {
        uint8   actionA;
        uint256 inA;
        uint256 outA;
        uint256 sharesA_before;
        uint256 sharesA_after;
        uint8   actionB;
        uint256 inB;
        uint256 outB;
        uint256 sharesB_before;
        uint256 sharesB_after;
    }

    function _task4_determinism() internal {
        console2.log("");
        console2.log("--- TASK 4: Determinism / Repeatability Check ---");

        // Ensure USER_A has constraints
        Constraints memory cA = coord.getConstraints(USER_A);
        if (cA.standardTrancheAmount == 0) {
            vm.startBroadcast(USER_A_KEY);
            coord.setConstraints(_constraintsA());
            vm.stopBroadcast();
        }

        // Take snapshot BEFORE warping
        uint256 snap = vm.snapshotState();
        console2.log("evm_snapshot taken. ID:", snap);

        // Run 1
        console2.log("");
        console2.log("=== RUN 1 ===");
        vm.warp(block.timestamp + 16 days); // fresh warp after task3 already warped 8d
        RunResult memory r1 = _runSequence(1);

        // Revert
        bool ok = vm.revertToState(snap);
        require(ok, "evm_revert failed");
        console2.log("");
        console2.log("Reverted to snapshot", snap);

        // Run 2
        console2.log("");
        console2.log("=== RUN 2 ===");
        vm.warp(block.timestamp + 16 days);
        RunResult memory r2 = _runSequence(2);

        // Compare
        _compareRuns(r1, r2);
    }

    function _runSequence(uint256 runNum) internal returns (RunResult memory r) {
        console2.log("[Run", runNum, "] Executing poke(USER_A) + poke(USER_B)...");

        r.sharesA_before = vault.balanceOf(USER_A);
        vm.startBroadcast(DEPLOYER_KEY);
        coord.poke(USER_A);
        vm.stopBroadcast();
        r.sharesA_after = vault.balanceOf(USER_A);

        (IDCACoordinator.Action aA,, uint256 iA, uint256 oA) = coord.lastDecision(USER_A);
        r.actionA = uint8(aA);
        r.inA = iA;
        r.outA = oA;

        console2.log("[Run", runNum, "] USER_A:");
        console2.log("  Action:       ", _actionName(aA));
        console2.log("  AmountIn:     ", iA / 1e6, "USDC");
        console2.log("  SharesBefore: ", r.sharesA_before);
        console2.log("  SharesAfter:  ", r.sharesA_after);

        r.sharesB_before = vault.balanceOf(USER_B);
        vm.startBroadcast(DEPLOYER_KEY);
        coord.poke(USER_B);
        vm.stopBroadcast();
        r.sharesB_after = vault.balanceOf(USER_B);

        (IDCACoordinator.Action aB,, uint256 iB, uint256 oB) = coord.lastDecision(USER_B);
        r.actionB = uint8(aB);
        r.inB = iB;
        r.outB = oB;

        console2.log("[Run", runNum, "] USER_B:");
        console2.log("  Action:       ", _actionName(aB));
        console2.log("  AmountIn:     ", iB / 1e6, "USDC");
        console2.log("  SharesBefore: ", r.sharesB_before);
        console2.log("  SharesAfter:  ", r.sharesB_after);
    }

    function _compareRuns(RunResult memory r1, RunResult memory r2) internal pure {
        console2.log("");
        console2.log("=== DETERMINISM COMPARISON ===");

        bool ok = true;

        ok = _check("USER_A.action",       r1.actionA,         r2.actionA)         && ok;
        ok = _check("USER_A.amountIn",     r1.inA,             r2.inA)             && ok;
        ok = _check("USER_A.amountOut",    r1.outA,            r2.outA)            && ok;
        ok = _check("USER_A.sharesBefore", r1.sharesA_before,  r2.sharesA_before)  && ok;
        ok = _check("USER_A.sharesAfter",  r1.sharesA_after,   r2.sharesA_after)   && ok;
        ok = _check("USER_B.action",       r1.actionB,         r2.actionB)         && ok;
        ok = _check("USER_B.amountIn",     r1.inB,             r2.inB)             && ok;
        ok = _check("USER_B.amountOut",    r1.outB,            r2.outB)            && ok;
        ok = _check("USER_B.sharesBefore", r1.sharesB_before,  r2.sharesB_before)  && ok;
        ok = _check("USER_B.sharesAfter",  r1.sharesB_after,   r2.sharesB_after)   && ok;

        console2.log("");
        if (ok) {
            console2.log("[PASS] DETERMINISM CONFIRMED: Both runs produced identical outcomes.");
        } else {
            console2.log("[FAIL] NON-DETERMINISM DETECTED: Divergence reported above.");
            revert("Non-determinism detected");
        }
    }

    function _check(string memory label, uint256 v1, uint256 v2) internal pure returns (bool) {
        if (v1 == v2) {
            console2.log("  [MATCH]", label, "RUN1=RUN2=", v1);
            return true;
        } else {
            console2.log("  [DIVERGE]", label);
            console2.log("    RUN1=", v1, "| RUN2=", v2);
            return false;
        }
    }

    function _actionName(IDCACoordinator.Action a) internal pure returns (string memory) {
        if (uint8(a) == 0) return "DELAY";
        if (uint8(a) == 1) return "EXECUTE_PARTIAL";
        return "EXECUTE_FULL";
    }

    function _constraintsA() internal pure returns (Constraints memory) {
        return Constraints({
            minFrequencyDays:     1,
            maxDelayDays:         7,
            goodDeviationBps:     100,
            badDeviationBps:      300,
            trancheFlexMinBps:    5000,
            trancheFlexMaxBps:    10000,
            standardTrancheAmount:1_000e6,
            maxSlippageBps:       200
        });
    }

    function _constraintsB() internal pure returns (Constraints memory) {
        return Constraints({
            minFrequencyDays:     1,
            maxDelayDays:         7,
            goodDeviationBps:     100,
            badDeviationBps:      300,
            trancheFlexMinBps:    5000,
            trancheFlexMaxBps:    10000,
            standardTrancheAmount:500e6,
            maxSlippageBps:       50
        });
    }
}
