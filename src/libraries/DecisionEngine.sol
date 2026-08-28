// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// DecisionEngine.sol
// CSI ORIGIN 2026, PS-12 - Coordinator worktree (Track A)
//
// Pure, stateless, deterministic decision library.
// Frozen formula from INTERFACE_CONTRACTS.md §7 / Technical Architecture §9.
//
// Inputs:  deviationBps, daysUntilDeadline, Constraints
// Outputs: Action, trancheBps
//
// Do NOT add ML signals, volatility prediction, or additional branches.
// Same inputs must ALWAYS produce same outputs (auditability requirement §7.1).
// =============================================================================

import {Constraints} from "../interfaces/IDCACoordinator.sol";

library DecisionEngine {

    // =========================================================================
    // Types
    // =========================================================================

    enum Action { DELAY, EXECUTE_PARTIAL, EXECUTE_FULL }

    // =========================================================================
    // Core Decision Function
    // =========================================================================

    /// @notice Convert TWAP deviation + urgency + user bounds into a deterministic action.
    ///
    /// @dev Formula exactly as frozen in INTERFACE_CONTRACTS.md §7 / Technical Architecture §9:
    ///
    ///   if daysUntilDeadline <= 0:
    ///       return (EXECUTE_FULL, 10000)          // hard bound: never breach max-delay
    ///   absDev = |deviationBps|
    ///   if absDev <= c.goodDeviationBps:
    ///       return (EXECUTE_FULL, 10000)           // favourable / neutral
    ///   if absDev >= c.badDeviationBps:
    ///       if daysUntilDeadline <= 1:
    ///           return (EXECUTE_PARTIAL, c.trancheFlexMinBps)   // urgency override
    ///       return (DELAY, 0)                       // delay — bad conditions, not urgent
    ///   // middle band — linear interpolation between flex bounds
    ///   frac = (absDev - c.goodDeviationBps) / (c.badDeviationBps - c.goodDeviationBps)
    ///   trancheBps = c.trancheFlexMaxBps - frac * (c.trancheFlexMaxBps - c.trancheFlexMinBps)
    ///   return (EXECUTE_PARTIAL, trancheBps)
    ///
    /// @param deviationBps     Signed: current spot vs. rolling reference, in bps.
    ///                          Negative = price is below reference (buying at a discount).
    /// @param daysUntilDeadline Days remaining until maxDelayDays is breached.
    ///                          Signed: <=0 means already overdue → force EXECUTE_FULL.
    /// @param c                 The calling user's Constraints (already validated upstream).
    /// @return action           One of {DELAY, EXECUTE_PARTIAL, EXECUTE_FULL}.
    /// @return trancheBps       Fraction of standardTrancheAmount to execute, in bps (0–10000).
    ///                          Always 0 when action == DELAY.
    function decide(
        int256      deviationBps,
        int256      daysUntilDeadline,
        Constraints memory c
    ) internal pure returns (Action action, uint16 trancheBps) {

        // ------------------------------------------------------------------
        // Branch 1: Deadline already passed — force full execution.
        //   Invariant §18-8: system must never delay indefinitely.
        // ------------------------------------------------------------------
        if (daysUntilDeadline <= 0) {
            return (Action.EXECUTE_FULL, 10_000);
        }

        // ------------------------------------------------------------------
        // Compute absolute deviation (|deviationBps|).
        // deviationBps can be negative (price below reference = favourable for buyer).
        // We use absolute value because the bounds are symmetric — both a large
        // positive and a large negative deviation increase execution risk.
        // ------------------------------------------------------------------
        uint256 absDev;
        unchecked {
            absDev = deviationBps >= 0
                ? uint256(deviationBps)
                : uint256(-deviationBps);
        }

        // ------------------------------------------------------------------
        // Branch 2: Within the "good" band — full execute.
        // ------------------------------------------------------------------
        if (absDev <= uint256(c.goodDeviationBps)) {
            return (Action.EXECUTE_FULL, 10_000);
        }

        // ------------------------------------------------------------------
        // Branch 3: In or beyond the "bad" band.
        // ------------------------------------------------------------------
        if (absDev >= uint256(c.badDeviationBps)) {
            // Urgency override: within 1 day of deadline, execute partial rather
            // than delay (Invariant §18-8: bounded autonomy — cannot defer forever).
            if (daysUntilDeadline <= 1) {
                return (Action.EXECUTE_PARTIAL, c.trancheFlexMinBps);
            }
            return (Action.DELAY, 0);
        }

        // ------------------------------------------------------------------
        // Branch 4: Middle band — linear interpolation.
        //   frac ∈ (0, 1): how deep into the bad zone we are.
        //   trancheBps = trancheFlexMaxBps - frac * (flexMax - flexMin)
        //
        //   Integer arithmetic: multiply before dividing to preserve precision.
        //   Denominator > 0 guaranteed by setConstraints validation:
        //     goodDeviationBps < badDeviationBps (§23-C, enforced upstream).
        // ------------------------------------------------------------------
        uint256 numerator   = absDev - uint256(c.goodDeviationBps);
        uint256 denominator = uint256(c.badDeviationBps) - uint256(c.goodDeviationBps);
        uint256 range       = uint256(c.trancheFlexMaxBps) - uint256(c.trancheFlexMinBps);

        // trancheBps = trancheFlexMaxBps - (numerator * range / denominator)
        uint256 reduction   = (numerator * range) / denominator;
        uint256 result      = uint256(c.trancheFlexMaxBps) - reduction;

        // Clamp to [trancheFlexMinBps, trancheFlexMaxBps] to guard rounding edge cases.
        if (result < uint256(c.trancheFlexMinBps)) result = uint256(c.trancheFlexMinBps);
        if (result > uint256(c.trancheFlexMaxBps)) result = uint256(c.trancheFlexMaxBps);

        return (Action.EXECUTE_PARTIAL, uint16(result));
    }
}
