// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// IYieldStrategy.sol
// CSI ORIGIN 2026, PS-12 - Vault worktree (Track B)
//
// Frozen interface from Technical Architecture §7 / INTERFACE_CONTRACTS.md §5.
// Do NOT modify signatures without an architecture-level decision.
// =============================================================================

interface IYieldStrategy {
    /// @notice Deposit `assets` of the underlying token into the yield strategy.
    ///         Called only by DCAVault.
    /// @param assets Amount of underlying to deposit.
    /// @return deposited The actual amount deposited (may differ due to rounding).
    function deposit(uint256 assets) external returns (uint256 deposited);

    /// @notice Withdraw exactly `assets` of the underlying token to `receiver`.
    ///         Called only by DCAVault.
    /// @param assets  Amount of underlying to withdraw.
    /// @param receiver Address that receives the withdrawn tokens.
    /// @return withdrawn The actual amount withdrawn.
    function withdraw(uint256 assets, address receiver) external returns (uint256 withdrawn);

    /// @notice Total underlying assets currently held / accrued by the strategy.
    ///         Used by DCAVault.totalAssets().
    function totalAssets() external view returns (uint256);

    /// @notice The underlying ERC-20 token address (USDC on Base).
    function asset() external view returns (address);
}
