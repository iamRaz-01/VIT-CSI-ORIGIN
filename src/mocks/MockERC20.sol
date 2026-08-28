// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// MockERC20.sol
// CSI ORIGIN 2026, PS-12 - Vault worktree (Track B)
//
// Minimal ERC-20 for testing.  Used as a USDC stand-in in unit tests and as
// the demo counter-asset (MockToken) in the seeded v4 pool.
// INTERFACE_CONTRACTS.md §13.2 step 1 — deployed before DCAVault.
// =============================================================================

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
    {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Unrestricted mint — test/demo use only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Unrestricted burn — test/demo use only.
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
