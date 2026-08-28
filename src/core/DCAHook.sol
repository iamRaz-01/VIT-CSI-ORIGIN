// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// DCAHook.sol
// CSI ORIGIN 2026, PS-12 - Hook worktree (Track C)
//
// Responsibilities (INTERFACE_CONTRACTS.md §9):
//   - Verify that the effective swap sender is the trusted DCACoordinator
//   - Enforce per-user tranche-size bound in beforeSwap (§9.1)
//   - Enforce per-user slippage/price-impact bound in afterSwap (§9.2)
//   - Revert entire transaction on any bound violation (§8 Atomicity Invariant)
//   - Expose coordinator() getter (§9.3)
//
// Security model (Technical Architecture §6.6, §10):
//   - hookData carries ONLY: abi.encode(user: address)
//   - Numeric bounds are NEVER trusted from hookData or caller
//   - Bounds are always re-read from DCACoordinator.getConstraints(user) (trusted)
//   - sender == address(coordinator) is the sole trust gate
//
// Hook is stateless. No per-user storage. All state lives in DCACoordinator.
//
// Permissions: BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG only.
// Address must be mined via HookMiner to encode these flags.
//
// FROZEN INTERFACES REFERENCED:
//   - INTERFACE_CONTRACTS.md §9: beforeSwap, afterSwap, coordinator getter
//   - INTERFACE_CONTRACTS.md §15: UntrustedCaller, TrancheCapExceeded, SlippageCapExceeded
//   - INTERFACE_CONTRACTS.md §18 Invariant 5: hook enforces unconditionally
//   - INTERFACE_CONTRACTS.md §18 Invariant 9: trust boundary — no hookData numbers trusted
// =============================================================================

import {IHooks}         from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager}   from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks}          from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey}        from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IDCACoordinator, Constraints} from "../interfaces/IDCACoordinator.sol";

/// @title DCAHook
/// @notice Uniswap v4 hook that enforces per-user DCA execution bounds.
///         Stateless — all user constraint state lives in DCACoordinator.
/// @dev Implements IHooks directly (v4-periphery in this version does not export BaseHook).
///      Only beforeSwap and afterSwap are active; all other callbacks revert.
///      Hook address MUST be mined with BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG set in its
///      lower 14 bits via HookMiner before deployment.
contract DCAHook is IHooks {
    using BalanceDeltaLibrary for BalanceDelta;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    // =========================================================================
    // Errors (INTERFACE_CONTRACTS.md §15)
    // =========================================================================

    /// @notice Swap sender is not the authorized DCACoordinator (§6.6, §9.1).
    error UntrustedCaller();

    /// @notice amountIn > standardTrancheAmount * trancheFlexMaxBps / 10000 (§9.1).
    error TrancheCapExceeded();

    /// @notice Post-swap price impact exceeds user's maxSlippageBps (§9.2).
    error SlippageCapExceeded();

    /// @notice Called a hook that is not implemented by this contract.
    error HookNotImplemented();

    // =========================================================================
    // Immutables
    // =========================================================================

    /// @notice The trusted DCACoordinator. Only this address may initiate swaps
    ///         through the hook-guarded pool. Set at construction; never changes.
    IDCACoordinator public immutable coordinator;

    /// @notice The Uniswap v4 PoolManager. Stored for caller-authentication of
    ///         hook callbacks (PoolManager is the only valid msg.sender for hooks).
    IPoolManager public immutable poolManager;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param coordinator_  Deployed DCACoordinator address.
    /// @param poolManager_  Deployed Uniswap v4 PoolManager address.
    constructor(address coordinator_, address poolManager_) {
        require(coordinator_ != address(0), "DCAHook: zero coordinator");
        require(poolManager_ != address(0), "DCAHook: zero poolManager");
        coordinator  = IDCACoordinator(coordinator_);
        poolManager  = IPoolManager(poolManager_);

        // Validate that this contract's address has the correct permission bits
        // encoded in its lower 14 bits (set via HookMiner at deploy time).
        // This is a constructor-time safety check — if the address was not mined
        // correctly, deployment reverts immediately rather than silently deploying
        // a non-functional hook.
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize:              false,
                afterInitialize:               false,
                beforeAddLiquidity:            false,
                afterAddLiquidity:             false,
                beforeRemoveLiquidity:         false,
                afterRemoveLiquidity:          false,
                beforeSwap:                    true,   // ← ACTIVE
                afterSwap:                     true,   // ← ACTIVE
                beforeDonate:                  false,
                afterDonate:                   false,
                beforeSwapReturnDelta:         false,
                afterSwapReturnDelta:          false,
                afterAddLiquidityReturnDelta:  false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    // =========================================================================
    // § 9.1 — beforeSwap: Tranche-size enforcement
    // =========================================================================

    /// @notice Called by PoolManager before a swap executes.
    ///         Enforces:
    ///           1. sender == coordinator (trust boundary §6.6)
    ///           2. amountIn <= standardTrancheAmount * trancheFlexMaxBps / 10000 (§9.1)
    ///
    /// @param sender   The address that called PoolManager.swap() — must be the coordinator.
    ///                 PoolManager passes the caller of unlock() as `sender`.
    /// @param params   Swap parameters. amountSpecified is negative for exactIn.
    /// @param hookData ABI-encoded user address only. Numeric bounds ignored (§6.6 trust model).
    ///
    /// @return selector     Must be IHooks.beforeSwap.selector.
    /// @return beforeDelta  ZERO_DELTA — hook takes no token delta here.
    /// @return fee          0 — not overriding the pool fee.
    function beforeSwap(
        address sender,
        PoolKey calldata,        // key — not used; pool context not needed
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external view override returns (bytes4 selector, BeforeSwapDelta beforeDelta, uint24 fee) {
        // ── Trust boundary (§6.6, §9.1, §15 UntrustedCaller) ─────────────────
        // sender is the address that called PoolManager.unlock() → the coordinator.
        // Any direct pool call (not via coordinator) must be rejected.
        if (sender != address(coordinator)) revert UntrustedCaller();

        // ── Decode user identity from hookData ────────────────────────────────
        // hookData carries ONLY: abi.encode(address user)
        // We do NOT trust numeric bounds from hookData (§6.6).
        address user = abi.decode(hookData, (address));

        // ── Read authoritative constraints from the Coordinator (trusted) ─────
        Constraints memory c = coordinator.getConstraints(user);

        // ── Compute amountIn as an absolute value ────────────────────────────
        // SwapParams.amountSpecified:
        //   - Negative for exactIn swaps (user specifies input amount)
        //   - Positive for exactOut swaps (user specifies output amount)
        // The coordinator always uses exactIn (negative amountSpecified).
        // We take the absolute value to compare against the cap.
        // Guard: if amountSpecified == 0, PoolManager itself reverts before reaching us.
        int256 amtSpec = params.amountSpecified;
        uint256 amountIn;
        if (amtSpec < 0) {
            // exactIn: amountIn = |amountSpecified|
            // Unchecked: amtSpec != type(int256).min (PoolManager rejects 0 swaps)
            unchecked { amountIn = uint256(-amtSpec); }
        } else {
            // exactOut: amountIn is the output amount requested.
            // Coordinator uses exactIn, so this branch should not fire in normal operation.
            // We still enforce the cap against the specified value for safety.
            amountIn = uint256(amtSpec);
        }

        // ── Tranche cap validation (§9.1, §15 TrancheCapExceeded) ─────────────
        // Cap = standardTrancheAmount * trancheFlexMaxBps / 10000
        // Multiply before divide to preserve precision (no intermediate rounding loss).
        // trancheFlexMaxBps is uint16 (max 10000), standardTrancheAmount is uint256 —
        // product fits in uint256 (10000 * type(uint256).max won't overflow because
        // standardTrancheAmount is bounded by real USDC balances).
        uint256 trancheCap = (c.standardTrancheAmount * uint256(c.trancheFlexMaxBps)) / 10_000;
        if (amountIn > trancheCap) revert TrancheCapExceeded();

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // =========================================================================
    // §9.2 — afterSwap: Slippage / price-impact enforcement
    // =========================================================================

    /// @notice Called by PoolManager after a swap settles.
    ///         Enforces: actual price impact <= user's maxSlippageBps.
    ///         A revert here rolls back the ENTIRE transaction (vault untouched).
    ///
    /// @param sender   Same as in beforeSwap — must equal coordinator.
    /// @param params   Swap parameters — needed for amountSpecified.
    /// @param delta    Actual execution result (signed token amounts from pool's perspective).
    ///                 BalanceDelta: upper 128 bits = amount0, lower 128 bits = amount1.
    ///                 Positive = pool owes tokens to swapper; negative = pool received tokens.
    /// @param hookData ABI-encoded user address (same as beforeSwap).
    ///
    /// @return selector  Must be IHooks.afterSwap.selector.
    /// @return hookDelta 0 — hook takes no additional token delta.
    function afterSwap(
        address sender,
        PoolKey calldata,        // key — not used
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external view override returns (bytes4 selector, int128 hookDelta) {
        // ── Trust boundary (same as beforeSwap — defense in depth) ────────────
        if (sender != address(coordinator)) revert UntrustedCaller();

        // ── Decode user ───────────────────────────────────────────────────────
        address user = abi.decode(hookData, (address));

        // ── Read authoritative constraints (trusted) ──────────────────────────
        Constraints memory c = coordinator.getConstraints(user);

        // ── Compute price impact in bps (§9.2, §22.4) ────────────────────────
        //
        // Price impact formula (implemented against exact v4 BalanceDelta semantics):
        //
        // BalanceDelta from PoolManager.swap() represents the SWAPPER's balance delta:
        //   amount0 (upper 128): positive = swapper received token0, negative = swapper sent token0
        //   amount1 (lower 128): positive = swapper received token1, negative = swapper sent token1
        //
        // For a zeroForOne exactIn swap (USDC→mockToken):
        //   amount0 is negative (swapper sent USDC)  → amountIn  = |amount0|
        //   amount1 is positive (swapper received mockToken) → amountOut = amount1
        //
        // For a oneForZero exactIn swap (mockToken→USDC):
        //   amount1 is negative (swapper sent mockToken) → amountIn  = |amount1|
        //   amount0 is positive (swapper received USDC)  → amountOut = amount0
        //
        // Price impact (slippage) in bps:
        //   slippageBps = (amountIn - amountOut) * 10000 / amountIn
        //
        // This measures how much less the swapper received vs. what they sent,
        // as a fraction of amountIn, in basis points.
        //
        // Note: this is a single-pool, team-controlled demo pool. The formula
        // is appropriate for a USDC/mockToken pool where both tokens have the same
        // nominal value at pool creation (1:1 seed price). For production, use
        // a reference price oracle to normalize different token decimals.
        //
        // Integer safety: all amounts fit in uint128 (BalanceDelta components are int128).
        // We operate entirely in uint128/uint256 after taking absolute values.

        uint256 impactBps = _priceImpactBps(params, delta);

        // ── Slippage cap validation (§9.2, §15 SlippageCapExceeded) ──────────
        if (impactBps > uint256(c.maxSlippageBps)) revert SlippageCapExceeded();

        return (IHooks.afterSwap.selector, 0);
    }

    // =========================================================================
    // §9.3 — coordinator() getter (public getter already provided by `public immutable`)
    // The IDCAHookView interface requires this — `public immutable` generates it.
    // =========================================================================

    // =========================================================================
    // IHooks — Unimplemented callbacks (revert to prevent accidental use)
    // =========================================================================
    // Only beforeSwap and afterSwap are active for this hook (permission flags).
    // All other IHooks callbacks must be implemented to satisfy the interface
    // but will never be called by PoolManager since the permission bits are not set.

    function beforeInitialize(address, PoolKey calldata, uint160)
        external pure override returns (bytes4) { revert HookNotImplemented(); }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external pure override returns (bytes4) { revert HookNotImplemented(); }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4) { revert HookNotImplemented(); }

    function afterAddLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4) { revert HookNotImplemented(); }

    function afterRemoveLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) { revert HookNotImplemented(); }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) { revert HookNotImplemented(); }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Compute slippage in bps from the swap's BalanceDelta.
    ///
    /// Convention (PoolManager.swap delta = SWAPPER's perspective):
    ///   zeroForOne = true:  amount0 < 0 (sent), amount1 > 0 (received)
    ///   zeroForOne = false: amount1 < 0 (sent), amount0 > 0 (received)
    ///
    /// Formula: slippageBps = (amountIn - amountOut) * 10000 / amountIn
    ///
    /// If amountIn == 0 (should never occur — PoolManager rejects zero-amount swaps),
    /// we return 0 to avoid division by zero rather than reverting (belt-and-suspenders).
    ///
    /// Returns 0 if amountOut >= amountIn (no negative slippage; pool paid MORE than sent —
    /// this happens with favorable rounding and is not a violation).
    function _priceImpactBps(
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta
    ) internal pure returns (uint256 impactBps) {
        int128 amt0 = delta.amount0();
        int128 amt1 = delta.amount1();

        uint256 amountIn;
        uint256 amountOut;

        if (params.zeroForOne) {
            // Sent token0 (negative from swapper's view), received token1 (positive)
            // amount0 should be <= 0; amount1 should be >= 0
            amountIn  = amt0 < 0 ? uint256(uint128(-amt0)) : 0;
            amountOut = amt1 > 0 ? uint256(uint128(amt1))  : 0;
        } else {
            // Sent token1 (negative), received token0 (positive)
            amountIn  = amt1 < 0 ? uint256(uint128(-amt1)) : 0;
            amountOut = amt0 > 0 ? uint256(uint128(amt0))  : 0;
        }

        // Guard: if amountIn == 0, no slippage can be computed (return 0, no revert).
        if (amountIn == 0) return 0;

        // If amountOut >= amountIn, impact is 0 or negative (favorable) — return 0.
        if (amountOut >= amountIn) return 0;

        // Multiply before divide to preserve precision.
        // amountIn is at most uint128 (derived from int128), so * 10000 fits uint256.
        impactBps = ((amountIn - amountOut) * 10_000) / amountIn;
    }
}
