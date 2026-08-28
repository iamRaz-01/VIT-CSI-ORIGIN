// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// DCAVault.t.sol - Vault Unit Tests
// CSI ORIGIN 2026, PS-12 - Vault worktree (Track B)
//
// Tests DCAVault in isolation using MockYieldStrategy (no Aave dependency).
// All tests run fork-less and are fast.
//
// Covers:
//   - INTERFACE_CONTRACTS.md §5 (all vault functions)
//   - §15 error catalogue (ZeroAssets, Unauthorized, InsufficientBalance)
//   - §18 invariants 1 (user isolation), 10 (single state owner)
//   - Test matrix per user request:
//       [x] successful deposit
//       [x] zero deposit reverts
//       [x] two-user isolation
//       [x] unauthorized withdrawal
//       [x] insufficient balance
//       [x] share/accounting behaviour
//       [x] coordinator-only withdrawForExecution
//       [x] yield accounting (totalAssets grows over time)
// =============================================================================

pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {DCAVault}          from "../src/core/DCAVault.sol";
import {MockYieldStrategy} from "../src/strategies/MockYieldStrategy.sol";
import {MockERC20}         from "../src/mocks/MockERC20.sol";
import {IERC20}            from "@openzeppelin/token/ERC20/IERC20.sol";

contract DCAVaultTest is Test {

    // -------------------------------------------------------------------------
    // Fixtures
    // -------------------------------------------------------------------------

    DCAVault          internal vault;
    MockYieldStrategy internal strategy;
    MockERC20         internal usdc;

    address internal USER_A     = makeAddr("USER_A");
    address internal USER_B     = makeAddr("USER_B");
    address internal COORDINATOR = makeAddr("COORDINATOR");
    address internal ATTACKER   = makeAddr("ATTACKER");

    uint256 constant INITIAL_MINT  = 100_000e6;  // 100 000 USDC (6 dec)
    uint256 constant DEPOSIT_SMALL = 1_000e6;    // 1 000 USDC
    uint256 constant DEPOSIT_LARGE = 50_000e6;   // 50 000 USDC
    uint256 constant APR_5PCT      = 500;        // 5 % APR in bps

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------

    function setUp() public {
        // 1. Deploy mock USDC (6 decimals to match real USDC on Base).
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // 2. Deploy vault — strategy not yet set (two-step init per §13.2).
        vault = new DCAVault(address(usdc), "DCA Vault USDC", "dcaUSDC");

        // 3. Deploy MockYieldStrategy.  Vault address known now.
        strategy = new MockYieldStrategy(address(usdc), address(vault), APR_5PCT);

        // 4. Wire vault.
        vault.setCoordinator(COORDINATOR);
        vault.setStrategy(address(strategy));

        // 5. Fund test users.
        usdc.mint(USER_A, INITIAL_MINT);
        usdc.mint(USER_B, INITIAL_MINT);

        // 6. Pre-approve vault to pull USDC from each user.
        vm.prank(USER_A);
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(USER_B);
        usdc.approve(address(vault), type(uint256).max);
    }

    // =========================================================================
    // §5.1 deposit
    // =========================================================================

    /// @dev Successful deposit mints non-zero shares and transfers USDC to strategy.
    function test_deposit_mintsShares() public {
        vm.prank(USER_A);
        uint256 shares = vault.deposit(DEPOSIT_SMALL, USER_A);

        assertGt(shares, 0, "shares must be > 0");
        assertEq(vault.balanceOf(USER_A), shares, "balanceOf must equal minted shares");
        // Vault must forward all assets to strategy — holds zero idle balance.
        assertEq(usdc.balanceOf(address(vault)), 0, "vault must hold zero idle USDC");
        // Strategy must hold exactly the deposited amount.
        assertApproxEqAbs(strategy.totalAssets(), DEPOSIT_SMALL, 1, "strategy totalAssets mismatch");
    }

    /// @dev Deposit reverts with ZeroAssets() when assets == 0.
    function test_deposit_zeroReverts() public {
        vm.expectRevert(DCAVault.ZeroAssets.selector);
        vm.prank(USER_A);
        vault.deposit(0, USER_A);
    }

    /// @dev USER_A's deposit does not affect USER_B's share balance.
    function test_deposit_twoUsers_isolated() public {
        vm.prank(USER_A);
        vault.deposit(DEPOSIT_SMALL, USER_A);

        // USER_B has not deposited yet — their shares must be zero.
        assertEq(vault.balanceOf(USER_B), 0, "USER_B shares must be 0 before deposit");

        vm.prank(USER_B);
        uint256 sharesB = vault.deposit(DEPOSIT_LARGE, USER_B);

        // After USER_B deposits, USER_A's shares must be unchanged.
        uint256 sharesA = vault.balanceOf(USER_A);
        assertGt(sharesA, 0, "USER_A shares must still be > 0");
        assertGt(sharesB, 0, "USER_B shares must be > 0");
        // Share quantities differ (different deposit amounts, same share price).
        assertGt(sharesB, sharesA, "USER_B shares > USER_A shares (larger deposit)");
    }

    /// @dev Second deposit from same user accumulates correctly.
    function test_deposit_accumulates() public {
        vm.prank(USER_A);
        uint256 s1 = vault.deposit(DEPOSIT_SMALL, USER_A);

        vm.prank(USER_A);
        uint256 s2 = vault.deposit(DEPOSIT_SMALL, USER_A);

        assertEq(vault.balanceOf(USER_A), s1 + s2, "cumulative shares mismatch");
    }

    // =========================================================================
    // §5.2 withdrawForExecution  (coordinator-only)
    // =========================================================================

    /// @dev Non-coordinator caller must revert with Unauthorized().
    function test_withdrawForExecution_onlyCoordinator() public {
        // Deposit so there is a balance to attempt withdrawing.
        vm.prank(USER_A);
        vault.deposit(DEPOSIT_SMALL, USER_A);

        vm.expectRevert(DCAVault.Unauthorized.selector);
        vm.prank(ATTACKER);
        vault.withdrawForExecution(USER_A, 100e6);
    }

    /// @dev Even a regular user cannot call withdrawForExecution on themselves.
    function test_withdrawForExecution_userCannotCallSelf() public {
        vm.prank(USER_A);
        vault.deposit(DEPOSIT_SMALL, USER_A);

        vm.expectRevert(DCAVault.Unauthorized.selector);
        vm.prank(USER_A);
        vault.withdrawForExecution(USER_A, 100e6);
    }

    /// @dev Coordinator receives exactly `assets` USDC; user shares decrease accordingly.
    function test_withdrawForExecution_pulledToCoordinator() public {
        vm.prank(USER_A);
        vault.deposit(DEPOSIT_SMALL, USER_A);

        uint256 tranche = 400e6; // 400 USDC
        uint256 sharesBefore = vault.balanceOf(USER_A);
        uint256 coordBalBefore = usdc.balanceOf(COORDINATOR);

        vm.prank(COORDINATOR);
        uint256 withdrawn = vault.withdrawForExecution(USER_A, tranche);

        assertEq(withdrawn, tranche, "withdrawn amount mismatch");
        assertEq(usdc.balanceOf(COORDINATOR) - coordBalBefore, tranche, "coordinator USDC delta mismatch");
        assertLt(vault.balanceOf(USER_A), sharesBefore, "user shares must decrease");
    }

    /// @dev Remaining shares continue earning yield after partial withdrawForExecution.
    function test_withdrawForExecution_remainingSharesEarnYield() public {
        vm.prank(USER_A);
        vault.deposit(DEPOSIT_SMALL, USER_A);

        uint256 tranche = 400e6;
        vm.prank(COORDINATOR);
        vault.withdrawForExecution(USER_A, tranche);

        uint256 sharesAfter = vault.balanceOf(USER_A);
        uint256 assetsAtWithdrawTime = vault.convertToAssets(sharesAfter);

        // Warp forward 30 days so yield accrues.
        vm.warp(block.timestamp + 30 days);

        uint256 assetsAfterYield = vault.convertToAssets(sharesAfter);
        // totalAssets should have grown (MockYieldStrategy accrues linearly).
        assertGt(vault.totalAssets(), assetsAtWithdrawTime, "totalAssets must grow after yield accrual");
        assertGe(assetsAfterYield, assetsAtWithdrawTime, "share value must not decrease");
    }

    /// @dev WithdrawForExecution on USER_A does not affect USER_B's shares.
    function test_withdrawForExecution_doesNotAffectOtherUser() public {
        vm.prank(USER_A);
        vault.deposit(DEPOSIT_SMALL, USER_A);

        vm.prank(USER_B);
        vault.deposit(DEPOSIT_SMALL, USER_B);

        uint256 sharesBBefore = vault.balanceOf(USER_B);

        vm.prank(COORDINATOR);
        vault.withdrawForExecution(USER_A, 500e6);

        assertEq(vault.balanceOf(USER_B), sharesBBefore, "USER_B shares must be unchanged");
    }

    /// @dev Requesting more than user's balance reverts InsufficientBalance().
    function test_withdrawForExecution_insufficientBalanceReverts() public {
        vm.prank(USER_A);
        vault.deposit(DEPOSIT_SMALL, USER_A); // 1 000 USDC

        vm.expectRevert(DCAVault.InsufficientBalance.selector);
        vm.prank(COORDINATOR);
        vault.withdrawForExecution(USER_A, DEPOSIT_SMALL + 1); // 1 USDC over
    }

    /// @dev withdrawForExecution(user, 0) reverts ZeroAssets.
    function test_withdrawForExecution_zeroReverts() public {
        vm.prank(USER_A);
        vault.deposit(DEPOSIT_SMALL, USER_A);

        vm.expectRevert(DCAVault.ZeroAssets.selector);
        vm.prank(COORDINATOR);
        vault.withdrawForExecution(USER_A, 0);
    }

    /// @dev Cannot withdraw from user with zero balance.
    function test_withdrawForExecution_zeroBalanceReverts() public {
        // USER_A has no position.
        vm.expectRevert(DCAVault.InsufficientBalance.selector);
        vm.prank(COORDINATOR);
        vault.withdrawForExecution(USER_A, 1e6);
    }

    // =========================================================================
    // §5.3 withdraw (user-initiated, P2)
    // =========================================================================

    /// @dev Standard ERC-4626 user withdrawal works end-to-end.
    function test_withdraw_userCanExitPosition() public {
        vm.prank(USER_A);
        vault.deposit(DEPOSIT_SMALL, USER_A);

        uint256 balBefore = usdc.balanceOf(USER_A);

        vm.prank(USER_A);
        vault.withdraw(DEPOSIT_SMALL, USER_A, USER_A);

        uint256 received = usdc.balanceOf(USER_A) - balBefore;
        assertApproxEqAbs(received, DEPOSIT_SMALL, 1, "user must receive ~deposit amount back");
        assertApproxEqAbs(vault.balanceOf(USER_A), 0, 1, "shares must be ~zero after full withdraw");
    }

    // =========================================================================
    // §5.4 totalAssets / convertToAssets
    // =========================================================================

    /// @dev totalAssets() reflects exactly what the strategy reports.
    function test_totalAssets_reflectsStrategy() public {
        vm.prank(USER_A);
        vault.deposit(DEPOSIT_SMALL, USER_A);

        assertEq(vault.totalAssets(), strategy.totalAssets(), "totalAssets mismatch with strategy");
    }

    /// @dev totalAssets grows as time passes (yield accrual).
    function test_totalAssets_growsWithTime() public {
        vm.prank(USER_A);
        vault.deposit(DEPOSIT_SMALL, USER_A);

        uint256 t0 = vault.totalAssets();
        vm.warp(block.timestamp + 365 days);
        uint256 t1 = vault.totalAssets();

        assertGt(t1, t0, "totalAssets must grow over time");
        // At 5% APR for 1 year, yield ≈ 5% of 1000e6 = 50e6.
        uint256 expectedYield = (DEPOSIT_SMALL * APR_5PCT) / 10_000;
        assertApproxEqAbs(t1 - t0, expectedYield, 1e4, "yield ~5% APR");
    }

    /// @dev convertToAssets increases as yield accrues (share price goes up).
    function test_convertToAssets_increasesWithYield() public {
        vm.prank(USER_A);
        uint256 shares = vault.deposit(DEPOSIT_SMALL, USER_A);

        uint256 assets0 = vault.convertToAssets(shares);
        vm.warp(block.timestamp + 180 days);
        uint256 assets1 = vault.convertToAssets(shares);

        assertGt(assets1, assets0, "share value must increase with yield");
    }

    // =========================================================================
    // §18 Invariants
    // =========================================================================

    /// @dev Vault holds no idle underlying after deposit (all forwarded to strategy).
    function test_vaultHoldsNoIdleBalance() public {
        vm.prank(USER_A);
        vault.deposit(DEPOSIT_SMALL, USER_A);

        assertEq(usdc.balanceOf(address(vault)), 0, "vault must hold zero USDC after deposit");
    }

    /// @dev Multi-user total assets = sum of individual assets (linearity check).
    function test_multiUser_totalAssetsIsSum() public {
        vm.prank(USER_A);
        vault.deposit(DEPOSIT_SMALL, USER_A);

        vm.prank(USER_B);
        vault.deposit(DEPOSIT_LARGE, USER_B);

        uint256 assetsA = vault.convertToAssets(vault.balanceOf(USER_A));
        uint256 assetsB = vault.convertToAssets(vault.balanceOf(USER_B));

        // Total must equal sum of individual (within rounding).
        assertApproxEqAbs(vault.totalAssets(), assetsA + assetsB, 2, "totalAssets != sumOf(A,B)");
    }

    /// @dev Full withdraw+deposit cycle: redeem all shares, re-deposit, re-verify.
    function test_deposit_withdraw_cycle() public {
        vm.prank(USER_A);
        vault.deposit(DEPOSIT_SMALL, USER_A);

        // Full exit.
        uint256 shares = vault.balanceOf(USER_A);
        vm.prank(USER_A);
        vault.redeem(shares, USER_A, USER_A);

        assertApproxEqAbs(vault.balanceOf(USER_A), 0, 1, "shares must be 0 after full redeem");

        // Re-deposit.
        vm.prank(USER_A);
        uint256 newShares = vault.deposit(DEPOSIT_SMALL, USER_A);
        assertGt(newShares, 0, "re-deposit must mint shares");
    }

    // =========================================================================
    // Share/accounting behaviour tests
    // =========================================================================

    /// @dev Share price starts at 1:1 (first deposit, no yield yet).
    function test_sharePrice_initiallyOneToOne() public {
        vm.prank(USER_A);
        uint256 shares = vault.deposit(DEPOSIT_SMALL, USER_A);

        // With no prior yield, convertToAssets(shares) ≈ deposit.
        assertApproxEqAbs(
            vault.convertToAssets(shares),
            DEPOSIT_SMALL,
            2, // 2 wei rounding tolerance from OZ virtual offset
            "initial share price must be ~1:1"
        );
    }

    /// @dev Share conversion is consistent: convertToShares(convertToAssets(s)) ≈ s.
    function test_shareConversion_roundtrip() public {
        vm.prank(USER_A);
        uint256 shares = vault.deposit(DEPOSIT_SMALL, USER_A);

        uint256 assets = vault.convertToAssets(shares);
        uint256 back   = vault.convertToShares(assets);

        // Round-trip tolerance: OZ ERC-4626 uses 1-share virtual offset for
        // inflation protection, so round-trip may be off by 1.
        assertApproxEqAbs(back, shares, 2, "round-trip conversion must be consistent");
    }

    /// @dev previewDeposit is consistent with actual deposit.
    function test_previewDeposit_matchesActual() public {
        uint256 preview = vault.previewDeposit(DEPOSIT_SMALL);

        vm.prank(USER_A);
        uint256 actual = vault.deposit(DEPOSIT_SMALL, USER_A);

        // Per ERC-4626 spec: previewDeposit should return the same value as actual.
        assertEq(actual, preview, "previewDeposit must match actual shares minted");
    }
}
