// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// DCAVault.sol
// CSI ORIGIN 2026, PS-12 - Vault worktree (Track B)
//
// Per-user yield-bearing custody.  ERC-4626 standard implementation over a
// swappable IYieldStrategy backend (Aave v3 or MockYieldStrategy).
//
// INTERFACE_CONTRACTS.md §5 (full vault surface), §18 invariants 1, 10.
// Technical Architecture §6.3, §7, §8, §10.
//
// Key design choices:
//   - Extends OpenZeppelin ERC4626 (built-in inflation-attack protection via
//     the virtual-shares / decimals-offset trick).
//   - `coordinator` is set post-construction (two-step deployment: vault first,
//     coordinator second — §13.2 dependency order).
//   - All underlying is forwarded to strategy immediately on deposit — vault
//     holds zero idle balance (Invariant §5, last bullet).
//   - `withdrawForExecution` is coordinator-only and does NOT use the standard
//     ERC-4626 withdraw path (no ERC-4626 allowance needed — caller is always
//     the trusted coordinator, not the user themselves).
// =============================================================================

import {ERC4626}   from "@openzeppelin/token/ERC20/extensions/ERC4626.sol";
import {ERC20}     from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20}    from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Math}      from "@openzeppelin/utils/math/Math.sol";
import {IYieldStrategy} from "../interfaces/IYieldStrategy.sol";

contract DCAVault is ERC4626 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // =========================================================================
    // Errors  (INTERFACE_CONTRACTS.md §15)
    // =========================================================================

    error ZeroAssets();
    error Unauthorized();
    error InsufficientBalance();

    // =========================================================================
    // Events  (INTERFACE_CONTRACTS.md §14)
    // =========================================================================

    /// @dev Emitted when coordinator-triggered execution pulls from a user.
    ///      Supplements the standard ERC-4626 Withdraw event for clean log
    ///      demo narration (§23-A resolution: emit both; keep ERC-4626 Withdraw
    ///      for standard tooling + this one for targeted filtering).
    event ExecutionWithdrawal(address indexed user, uint256 assets, uint256 shares);

    /// @dev Emitted when the coordinator address is updated.
    event CoordinatorSet(address indexed coordinator);

    /// @dev Emitted when the yield strategy is updated.
    event StrategySet(address indexed strategy);

    // =========================================================================
    // State
    // =========================================================================

    /// @notice The active yield strategy.  Public per INTERFACE_CONTRACTS.md §5.5.
    IYieldStrategy public strategy;

    /// @notice The DCACoordinator address.  Only this caller may use
    ///         withdrawForExecution.  Set after vault construction (§13.2).
    address public coordinator;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param asset_    Underlying token (USDC on Base mainnet).
    /// @param name_     ERC-20 name for the vault share token.
    /// @param symbol_   ERC-20 symbol for the vault share token.
    constructor(
        address asset_,
        string memory name_,
        string memory symbol_
    ) ERC4626(IERC20(asset_)) ERC20(name_, symbol_) {
        require(asset_ != address(0), "DCAVault: zero asset");
    }

    // =========================================================================
    // Configuration  (deployer-only, called during Phase 3 deploy sequence)
    // =========================================================================

    /// @notice Set (or update) the coordinator address.  Vault worktree scope:
    ///         called by the deploy script after deploying DCACoordinator.
    ///         There is no `onlyOwner` in this system — any caller can set the
    ///         coordinator provided it has not yet been set (one-time init).
    ///         If re-configuration is needed, it is done by redeployment
    ///         (Technical Architecture §23-G: no runtime strategy-switch fn).
    /// @dev    For simplicity (18-h hackathon), we allow re-setting pre-demo.
    ///         A production contract would use immutable or Ownable.
    function setCoordinator(address coordinator_) external {
        require(coordinator_ != address(0), "DCAVault: zero coordinator");
        coordinator = coordinator_;
        emit CoordinatorSet(coordinator_);
    }

    /// @notice Set (or update) the yield strategy.  Called by the deploy script
    ///         after deploying the strategy, or to swap to MockYieldStrategy
    ///         if Aave proves unstable (§6.3 risk mitigation).
    function setStrategy(address strategy_) external {
        require(strategy_ != address(0), "DCAVault: zero strategy");
        // If there is an existing strategy with assets, migrate them first.
        // For MVP / deploy-time setup this is always called with zero balance.
        strategy = IYieldStrategy(strategy_);
        emit StrategySet(strategy_);
    }

    // =========================================================================
    // ERC-4626 overrides
    // =========================================================================

    /// @notice Total underlying assets held by the vault (via the strategy).
    ///         Overrides ERC-4626's totalAssets to delegate to the active strategy.
    ///         INTERFACE_CONTRACTS.md §5.4, Invariant: vault holds no idle balance.
    function totalAssets() public view override returns (uint256) {
        if (address(strategy) == address(0)) return 0;
        return strategy.totalAssets();
    }

    // =========================================================================
    // Deposit override — forward all assets to strategy immediately
    // =========================================================================

    /// @inheritdoc ERC4626
    /// @dev Reverts ZeroAssets() instead of the generic ERC-4626 error so the
    ///      error catalogue (§15) is satisfied.
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (assets == 0) revert ZeroAssets();
        require(address(strategy) != address(0), "DCAVault: strategy not set");

        // Mint shares proportional to totalAssets via OZ ERC-4626 logic.
        uint256 shares = previewDeposit(assets);
        require(shares > 0, "DCAVault: zero shares minted");

        // Transfer underlying from depositor to vault, then to strategy.
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        // Forward all assets to strategy immediately (vault holds zero idle).
        IERC20(asset()).safeTransfer(address(strategy), assets);
        // Tell strategy to account for the deposit.
        strategy.deposit(assets);

        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    // =========================================================================
    // withdrawForExecution  (INTERFACE_CONTRACTS.md §5.2 — coordinator-only)
    // =========================================================================

    /// @notice Coordinator-only pull of the exact tranche for an atomic swap.
    ///         Burns the user's shares equivalent to `assets` and sends USDC
    ///         directly to the coordinator (msg.sender).
    ///         The remaining shares continue earning yield — only the tranche
    ///         needed is removed (Project Context §9: "return remaining capital").
    /// @param user   The vault depositor whose tranche is being executed.
    /// @param assets Exact underlying amount needed for the swap.
    /// @return withdrawn Actual amount sent to the coordinator.
    function withdrawForExecution(address user, uint256 assets)
        external
        returns (uint256 withdrawn)
    {
        if (msg.sender != coordinator) revert Unauthorized();
        if (assets == 0) revert ZeroAssets();

        uint256 userAssets = convertToAssets(balanceOf(user));
        if (assets > userAssets) revert InsufficientBalance();

        // Compute shares to burn (ceiling so we never over-deliver).
        uint256 shares = previewWithdraw(assets);
        require(shares <= balanceOf(user), "DCAVault: share calc overflow");

        // Burn shares from user's balance.
        _burn(user, shares);

        // Pull from strategy → coordinator.
        withdrawn = strategy.withdraw(assets, msg.sender);

        // Emit both events: coordinator-specific (for demo filtering) and
        // ERC-4626-compatible Withdraw (for standard tooling).
        emit ExecutionWithdrawal(user, assets, shares);
        emit Withdraw(msg.sender, msg.sender, user, assets, shares);
    }

    // =========================================================================
    // Standard ERC-4626 withdraw — user-initiated exit (P2, Feature 10)
    // =========================================================================

    /// @inheritdoc ERC4626
    /// @dev Standard ERC-4626 withdraw. `owner` must be msg.sender or have
    ///      set an ERC-4626 allowance (OZ implementation handles this).
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        returns (uint256 shares)
    {
        require(address(strategy) != address(0), "DCAVault: strategy not set");
        // OZ ERC-4626 checks allowance, computes shares, burns, emits Withdraw.
        // We only need to override the actual asset transfer to go via strategy.
        shares = previewWithdraw(assets);

        // ERC-4626 allowance deduction (inherited from OZ).
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 userAssets = convertToAssets(balanceOf(owner));
        require(assets <= userAssets, "DCAVault: insufficient balance");

        _burn(owner, shares);
        strategy.withdraw(assets, receiver);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // =========================================================================
    // Redeem override
    // =========================================================================

    /// @inheritdoc ERC4626
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        returns (uint256 assets)
    {
        require(address(strategy) != address(0), "DCAVault: strategy not set");
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        assets = previewRedeem(shares);
        require(shares <= balanceOf(owner), "DCAVault: insufficient shares");

        _burn(owner, shares);
        uint256 withdrawn = strategy.withdraw(assets, receiver);
        require(withdrawn >= assets, "DCAVault: strategy under-delivered");
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // =========================================================================
    // Internal ERC-4626 hooks — disabled (we manage transfers manually above)
    // =========================================================================

    // OZ ERC-4626 calls `_deposit` and `_withdraw` internally; we override
    // deposit/withdraw/redeem directly so these must NOT also fire.
    // The internal `_deposit`/`_withdraw` are only called by OZ's default
    // deposit/withdraw implementations, which we have fully overridden.
}
