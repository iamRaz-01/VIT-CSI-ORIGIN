// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// AaveYieldStrategy.sol
// CSI ORIGIN 2026, PS-12 - Vault worktree (Track B)
//
// Real yield via Aave v3 on a forked Base mainnet.
// Implements IYieldStrategy.  The vault deposits USDC into Aave via supply()
// and receives aUSDC (rebasing).  Withdrawal pulls from aUSDC.
//
// Pattern: lightweight Aave v3 wrapper (no full static-aToken needed for demo).
// Caller of all external functions: DCAVault only.
// Technical Architecture §6.3, §5 / INTERFACE_CONTRACTS.md §5.
//
// Aave v3 Pool on Base mainnet: 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5
// aToken discovery: IPool.getReserveData(asset).aTokenAddress
// =============================================================================

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IYieldStrategy} from "../interfaces/IYieldStrategy.sol";

// ─── Minimal Aave v3 interface (only what we need) ────────────────────────────

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveData(address asset) external view returns (
        uint256 configuration,
        uint128 liquidityIndex,
        uint128 currentLiquidityRate,
        uint128 variableBorrowIndex,
        uint128 currentVariableBorrowRate,
        uint128 currentStableBorrowRate,
        uint40 lastUpdateTimestamp,
        uint16 id,
        address aTokenAddress,
        address stableDebtTokenAddress,
        address variableDebtTokenAddress,
        address interestRateStrategyAddress,
        uint128 accruedToTreasury,
        uint128 unbacked,
        uint128 isolationModeTotalDebt
    );
}

/// @dev Separate resolver to avoid stack-too-deep when destructuring the 15-element tuple.
function _resolveAToken(IAavePool pool, address asset) view returns (address aTokenAddress) {
    // Slot 8 (0-indexed) of the return tuple is aTokenAddress.
    // We use a low-level staticcall to pluck just that slot.
    bytes memory data = abi.encodeWithSelector(IAavePool.getReserveData.selector, asset);
    (bool ok, bytes memory ret) = address(pool).staticcall(data);
    require(ok, "AaveYieldStrategy: getReserveData failed");
    // Each return value is 32 bytes.  aTokenAddress is at offset 8*32 = 256 bytes.
    require(ret.length >= 9 * 32, "AaveYieldStrategy: unexpected return length");
    assembly {
        aTokenAddress := mload(add(ret, add(32, mul(8, 32))))
    }
}

// ─── AaveYieldStrategy ────────────────────────────────────────────────────────

contract AaveYieldStrategy is IYieldStrategy {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    address public immutable override asset;
    address public immutable vault;
    IAavePool public immutable aavePool;

    /// @dev aToken address for the underlying (USDC → aUSDC).  Resolved once
    ///      at construction to avoid repeated external calls.
    address public immutable aToken;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param asset_     Underlying token (USDC on Base).
    /// @param vault_     The DCAVault that is the sole caller.
    /// @param aavePool_  Aave v3 Pool address on Base mainnet (forked).
    constructor(address asset_, address vault_, address aavePool_) {
        require(asset_    != address(0), "AaveYieldStrategy: zero asset");
        require(vault_    != address(0), "AaveYieldStrategy: zero vault");
        require(aavePool_ != address(0), "AaveYieldStrategy: zero pool");

        asset    = asset_;
        vault    = vault_;
        aavePool = IAavePool(aavePool_);

        // Resolve aToken once using helper (avoids stack-too-deep on 15-element tuple).
        address aTokenAddress = _resolveAToken(IAavePool(aavePool_), asset_);
        require(aTokenAddress != address(0), "AaveYieldStrategy: aToken not found");
        aToken = aTokenAddress;

        // Approve the Aave pool to pull USDC from this contract (supply path).
        IERC20(asset_).approve(aavePool_, type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyVault() {
        require(msg.sender == vault, "AaveYieldStrategy: only vault");
        _;
    }

    // -------------------------------------------------------------------------
    // IYieldStrategy
    // -------------------------------------------------------------------------

    /// @inheritdoc IYieldStrategy
    /// @dev DCAVault calls this after transferring `assets` of USDC here.
    ///      We immediately supply to Aave so no idle balance sits in this contract.
    function deposit(uint256 assets) external override onlyVault returns (uint256) {
        require(assets > 0, "AaveYieldStrategy: zero deposit");
        // Vault has already transferred USDC to us before calling deposit().
        // (DCAVault._afterDeposit pulls from msg.sender via ERC-4626, then calls
        //  strategy.deposit — we pull from ourselves below.)
        // NOTE: DCAVault sends USDC to this contract first (see DCAVault._deposit),
        //       then calls strategy.deposit(). So USDC is already here.
        aavePool.supply(asset, assets, address(this), 0);
        return assets;
    }

    /// @inheritdoc IYieldStrategy
    function withdraw(uint256 assets, address receiver) external override onlyVault returns (uint256) {
        require(assets > 0, "AaveYieldStrategy: zero withdraw");
        // Aave's withdraw returns the actual amount withdrawn.
        uint256 withdrawn = aavePool.withdraw(asset, assets, receiver);
        return withdrawn;
    }

    /// @inheritdoc IYieldStrategy
    /// @dev aToken balance == underlying balance including accrued interest (rebasing).
    function totalAssets() external view override returns (uint256) {
        return IERC20(aToken).balanceOf(address(this));
    }
}
