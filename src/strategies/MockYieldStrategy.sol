// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// MockYieldStrategy.sol
// CSI ORIGIN 2026, PS-12 - Vault worktree (Track B)
//
// Fallback yield strategy: linear time-based accrual funded by a small reserve.
// Implements IYieldStrategy exactly.  Built in parallel with AaveYieldStrategy
// per Technical Architecture §6.3 — not a rushed afterthought.
//
// Yield model: simple fixed APR accrual on deposited principal.
// Default: 5% APR (configurable at deploy time for tests).
// Formula: yield = principal * APR * elapsed / (365 days * 10000)
// =============================================================================

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IYieldStrategy} from "../interfaces/IYieldStrategy.sol";

contract MockYieldStrategy is IYieldStrategy {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    address public immutable override asset;
    address public immutable vault;

    /// @dev Total principal deposited (excluding accrued yield).
    uint256 public totalPrincipal;

    /// @dev Annual yield rate in bps (e.g. 500 = 5% APR).
    uint256 public immutable annualYieldBps;

    /// @dev Timestamp of last yield accrual snapshot.
    uint256 public lastAccrualTimestamp;

    /// @dev Accumulated yield not yet claimed/compounded.
    uint256 public accruedYield;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param asset_          Underlying token (USDC).
    /// @param vault_          The DCAVault that is the sole caller.
    /// @param annualYieldBps_ Annual yield in bps (e.g. 500 = 5%).
    constructor(address asset_, address vault_, uint256 annualYieldBps_) {
        require(asset_ != address(0), "MockYieldStrategy: zero asset");
        require(vault_ != address(0), "MockYieldStrategy: zero vault");
        asset = asset_;
        vault = vault_;
        annualYieldBps = annualYieldBps_;
        lastAccrualTimestamp = block.timestamp;
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyVault() {
        require(msg.sender == vault, "MockYieldStrategy: only vault");
        _;
    }

    // -------------------------------------------------------------------------
    // IYieldStrategy
    // -------------------------------------------------------------------------

    /// @inheritdoc IYieldStrategy
    function deposit(uint256 assets) external override onlyVault returns (uint256) {
        require(assets > 0, "MockYieldStrategy: zero deposit");
        _accrueYield();
        // Vault transfers USDC to us before calling deposit() — we just account.
        totalPrincipal += assets;
        return assets;
    }

    /// @inheritdoc IYieldStrategy
    function withdraw(uint256 assets, address receiver) external override onlyVault returns (uint256) {
        require(assets > 0, "MockYieldStrategy: zero withdraw");
        _accrueYield();
        require(totalAssets() >= assets, "MockYieldStrategy: insufficient");
        // Drain from accrued yield first, then principal.
        if (accruedYield >= assets) {
            accruedYield -= assets;
        } else {
            uint256 fromYield = accruedYield;
            accruedYield = 0;
            uint256 fromPrincipal = assets - fromYield;
            require(totalPrincipal >= fromPrincipal, "MockYieldStrategy: principal underflow");
            totalPrincipal -= fromPrincipal;
        }
        IERC20(asset).safeTransfer(receiver, assets);
        return assets;
    }

    /// @inheritdoc IYieldStrategy
    function totalAssets() public view override returns (uint256) {
        return totalPrincipal + accruedYield + _pendingYield();
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Compute yield accrued since the last snapshot, without writing state.
    function _pendingYield() internal view returns (uint256) {
        if (totalPrincipal == 0) return 0;
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        // yield = principal * bps * elapsed / (365 days * 10000)
        return (totalPrincipal * annualYieldBps * elapsed) / (365 days * 10_000);
    }

    /// @dev Flush pending yield into accruedYield and update the snapshot.
    function _accrueYield() internal {
        accruedYield += _pendingYield();
        lastAccrualTimestamp = block.timestamp;
    }
}
