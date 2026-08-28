// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// IDCACoordinator.sol
// CSI ORIGIN 2026, PS-12 - Coordinator worktree (Track A)
//
// Frozen interface from INTERFACE_CONTRACTS.md §6-§8, §10.
// Do NOT modify signatures without an architecture-level decision.
// =============================================================================

// Constraints struct — frozen from Technical Architecture §7 / INTERFACE_CONTRACTS.md §6.1
struct Constraints {
    uint64  minFrequencyDays;      // minimum interval between pokes
    uint64  maxDelayDays;          // hard max — never breach this
    uint16  goodDeviationBps;      // ≤ this → EXECUTE_FULL  (e.g. 100 = 1%)
    uint16  badDeviationBps;       // ≥ this → DELAY / urgency override  (e.g. 300 = 3%)
    uint16  trancheFlexMinBps;     // min execution size as % of standardTrancheAmount (bps)
    uint16  trancheFlexMaxBps;     // max execution size as % of standardTrancheAmount (bps)
    uint256 standardTrancheAmount; // full tranche in asset units (e.g. USDC with 6 decimals)
    uint16  maxSlippageBps;        // hard cap enforced by DCAHook (bps)
}

interface IDCACoordinator {
    // -------------------------------------------------------------------------
    // Enums (mirrors DecisionEngine.Action)
    // -------------------------------------------------------------------------
    enum Action { DELAY, EXECUTE_PARTIAL, EXECUTE_FULL }

    // -------------------------------------------------------------------------
    // Events  (INTERFACE_CONTRACTS.md §14)
    // -------------------------------------------------------------------------

    /// @dev Emitted on every eligible poke, including DELAY.
    event DecisionMade(
        address indexed user,
        Action  action,
        int256  deviationBps,
        uint256 timestamp
    );

    /// @dev Emitted when an atomic execute path completes (withdraw + swap succeeded).
    event ExecutionCompleted(
        address indexed user,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @dev User updated their constraints.
    event ConstraintsSet(address indexed user, Constraints c);

    // -------------------------------------------------------------------------
    // Feature 2 — Constraints
    // -------------------------------------------------------------------------

    /// @notice Store or update the calling user's DCA constraint parameters.
    ///         Keyed to msg.sender — no user can write another user's constraints.
    function setConstraints(Constraints calldata c) external;

    /// @notice Read any user's constraints (trusted read for DCAHook).
    function getConstraints(address user) external view returns (Constraints memory);

    // -------------------------------------------------------------------------
    // Feature 6 — Permissionless poke
    // -------------------------------------------------------------------------

    /// @notice Permissionless entry-point.  Evaluates a user's eligibility and,
    ///         if eligible, runs the decision → (optionally) execute loop.
    ///         MUST be a clean no-op (no revert) if user is ineligible.
    function poke(address user) external;

    // -------------------------------------------------------------------------
    // Feature 9 — Last decision read (Frontend + tests)
    // -------------------------------------------------------------------------

    /// @notice Latest decision recorded for a user.
    function lastDecision(address user) external view returns (
        Action  action,
        uint256 timestamp,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Timestamp of the last poke that updated user state.
    function lastPokeTimestamp(address user) external view returns (uint256);
}
