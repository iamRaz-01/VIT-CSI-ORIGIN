// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// DCAVault.t.sol - Vault Unit Tests
// CSI ORIGIN 2026, PS-12 - Vault worktree (Track B)
//
// Tests DCAVault in isolation.  Uses MockYieldStrategy (no Aave dependency)
// so these tests run fast without a fork and can also be run fork-less.
// Optionally, a fork variant can test against real Aave (see ForkTestBase).
//
// Covers: INTERFACE_CONTRACTS.md -5 (all vault functions),
//         -15 error catalogue entries owned by DCAVault,
//         -18 invariants 1 (user isolation), 10 (single state owner)
// =============================================================================

import {Test} from "forge-std/Test.sol";

// import {DCAVault}          from "../src/core/DCAVault.sol";
// import {MockYieldStrategy} from "../src/strategies/MockYieldStrategy.sol";
// import {MockERC20}         from "../src/mocks/MockERC20.sol";

contract DCAVaultTest is Test {
    // DCAVault          internal vault;
    // MockYieldStrategy internal strategy;
    // MockERC20         internal usdc;
    address internal USER_A = makeAddr("USER_A");
    address internal USER_B = makeAddr("USER_B");
    address internal COORDINATOR = makeAddr("COORDINATOR");

    function setUp() public {
        // usdc = new MockERC20("USD Coin", "USDC", 6);
        // strategy = new MockYieldStrategy(address(vault), address(usdc));
        // vault = new DCAVault(address(usdc));
        // vault.setCoordinator(COORDINATOR);
        // vault.setStrategy(address(strategy));
        // usdc.mint(USER_A, 10_000e6);
        // usdc.mint(USER_B, 10_000e6);
        // TODO: fill in once DCAVault is implemented
    }

    // --- -5.1 deposit --------------------------------------------------------
    function test_deposit_mintsShares() public {
        // VERIFY: deposit(1000e6, USER_A) - balanceOf(USER_A) > 0
        // TODO
    }

    function test_deposit_zeroReverts() public {
        // VERIFY: deposit(0, USER_A) reverts ZeroAssets()
        // TODO
    }

    function test_deposit_twoUsers_isolated() public {
        // VERIFY: USER_A deposit does not affect USER_B.balanceOf
        // TODO
    }

    // --- -5.2 withdrawForExecution -------------------------------------------
    function test_withdrawForExecution_onlyCoordinator() public {
        // VERIFY: non-coordinator caller reverts Unauthorized()
        // TODO
    }

    function test_withdrawForExecution_pulledToCoordinator() public {
        // VERIFY: coordinator receives exactly `assets` USDC, user shares decrease
        // VERIFY: remaining shares still earn yield (balance unchanged for other users)
        // TODO
    }

    function test_withdrawForExecution_insufficientBalanceReverts() public {
        // VERIFY: requesting more than user has reverts InsufficientBalance()
        // TODO
    }

    // --- -5.3 withdraw (user-initiated, P2) ----------------------------------
    function test_withdraw_userCanExitPosition() public {
        // VERIFY: standard ERC-4626 withdraw path works for user
        // TODO
    }

    // --- -5.4 totalAssets / convertToAssets ----------------------------------
    function test_totalAssets_reflectsStrategy() public {
        // VERIFY: vault.totalAssets() == strategy.totalAssets()
        // TODO
    }

    // --- Invariant: vault holds no idle underlying ---------------------------
    function test_vaultHoldsNoIdleBalance() public {
        // VERIFY: after deposit, IERC20(usdc).balanceOf(address(vault)) == 0
        //   (all assets forwarded to strategy immediately)
        // TODO
    }
}
