// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// DCACoordinator.sol
// CSI ORIGIN 2026, PS-12 - Coordinator worktree (Track A)
//
// Responsibilities:
//   - Store per-user Constraints (Feature 2)
//   - Track eligibility via lastPokeTimestamp (§23-D formula)
//   - Run decide() via DecisionEngine pure library (Feature 3)
//   - Record lastDecision per user (Feature 9)
//   - Expose permissionless poke() that is a clean no-op when ineligible (Feature 6)
//   - Integrate with DCAVault.withdrawForExecution() for the execute path (Feature 4)
//   - Rolling reference price via sqrtPriceX96 snapshot (Technical Architecture §6.5)
//
// OUT OF SCOPE for this workstream:
//   - PoolManager.unlock() / unlockCallback (Track C — Hook integration)
//   - DCAHook internals
//   - Frontend
//
// Integration seam: when action is EXECUTE_*, this contract calls
// vault.withdrawForExecution(user, amountIn) and emits ExecutionCompleted.
// The real PoolManager.unlock() → unlockCallback → swap path is wired by
// Track C (Hook workstream) and will replace the direct execution stub here.
//
// INTERFACE_CONTRACTS.md §6, §7, §8, §10, §15, §16, §17, §18.
// =============================================================================

import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {IERC20}          from "@openzeppelin/token/ERC20/IERC20.sol";
import {Constraints, IDCACoordinator} from "../interfaces/IDCACoordinator.sol";
import {DecisionEngine}  from "../libraries/DecisionEngine.sol";
import {DCAVault}        from "./DCAVault.sol";

contract DCACoordinator is IDCACoordinator, ReentrancyGuard {
    using DecisionEngine for DecisionEngine.Action;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @dev Maximum allowed maxSlippageBps.  §23-B resolution: 2000 bps = 20%.
    uint16 public constant MAX_SLIPPAGE_CEILING = 2_000;

    /// @dev Seconds per day — used for eligibility + urgency calculations.
    uint256 private constant SECONDS_PER_DAY = 1 days;

    // =========================================================================
    // Errors  (INTERFACE_CONTRACTS.md §15)
    // =========================================================================

    error InvalidConstraints(string reason);
    error OnlyPoolManager();

    // =========================================================================
    // Immutables / Config
    // =========================================================================

    /// @notice The DCAVault this coordinator is paired with.
    DCAVault public immutable vault;

    /// @notice Uniswap v4 PoolManager — set at construction for callback auth.
    ///         Can be address(0) while Hook Track C is not yet integrated.
    address public immutable poolManager;

    // =========================================================================
    // Per-user storage  (INTERFACE_CONTRACTS.md §16)
    // =========================================================================

    /// @notice User-defined DCA constraint parameters (Feature 2).
    mapping(address => Constraints) private _constraints;

    /// @notice Whether a user has ever called setConstraints (guards zero-struct reads).
    mapping(address => bool) private _hasConstraints;

    /// @notice Timestamp of the last eligible poke for frequency gating.
    mapping(address => uint256) private _lastPokeTimestamp;

    /// @notice Latest decision record for each user (Feature 9, Frontend).
    mapping(address => _DecisionRecord) private _lastDecision;

    struct _DecisionRecord {
        DecisionEngine.Action action;
        uint256 timestamp;
        uint256 amountIn;
        uint256 amountOut;
    }

    /// @notice Rolling reference price per pool (§6.5, §8 — shared, NOT per-user).
    ///         Keyed by poolId bytes32.  For MVP: we use address(0) as the key
    ///         since there is one pool.  Track C wires the real PoolKey.
    mapping(bytes32 => uint256) public referencePrice;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param vault_       Deployed DCAVault address.
    /// @param poolManager_ Uniswap v4 PoolManager (may be address(0) until Track C).
    constructor(address vault_, address poolManager_) {
        require(vault_ != address(0), "DCACoordinator: zero vault");
        vault       = DCAVault(vault_);
        poolManager = poolManager_;
    }

    // =========================================================================
    // Feature 2 — Constraints  (INTERFACE_CONTRACTS.md §6.2, §6.3)
    // =========================================================================

    /// @inheritdoc IDCACoordinator
    function setConstraints(Constraints calldata c) external override {
        // ── Validation rules from INTERFACE_CONTRACTS.md §6.2 ─────────────
        if (c.minFrequencyDays == 0)
            revert InvalidConstraints("minFrequencyDays must be > 0");
        if (c.maxDelayDays == 0)
            revert InvalidConstraints("maxDelayDays must be > 0");
        if (c.trancheFlexMinBps > c.trancheFlexMaxBps)
            revert InvalidConstraints("trancheFlexMin must be <= trancheFlexMax");
        if (c.maxSlippageBps > MAX_SLIPPAGE_CEILING)
            revert InvalidConstraints("maxSlippageBps exceeds ceiling");
        // §23-C: required for DecisionEngine's linear interpolation to be well-defined.
        if (c.goodDeviationBps > c.badDeviationBps)
            revert InvalidConstraints("goodDeviationBps must be <= badDeviationBps");
        if (c.standardTrancheAmount == 0)
            revert InvalidConstraints("standardTrancheAmount must be > 0");

        // ── Write (keyed exclusively to msg.sender — invariant §18-2) ─────
        _constraints[msg.sender] = c;
        _hasConstraints[msg.sender] = true;

        emit ConstraintsSet(msg.sender, c);
    }

    /// @inheritdoc IDCACoordinator
    function getConstraints(address user) external view override returns (Constraints memory) {
        return _constraints[user];
    }

    // =========================================================================
    // Feature 9 — lastDecision / lastPokeTimestamp views
    // =========================================================================

    /// @inheritdoc IDCACoordinator
    function lastDecision(address user) external view override returns (
        Action  action,
        uint256 timestamp,
        uint256 amountIn,
        uint256 amountOut
    ) {
        _DecisionRecord storage r = _lastDecision[user];
        return (Action(uint8(r.action)), r.timestamp, r.amountIn, r.amountOut);
    }

    /// @inheritdoc IDCACoordinator
    function lastPokeTimestamp(address user) external view override returns (uint256) {
        return _lastPokeTimestamp[user];
    }

    // =========================================================================
    // Feature 6 — Permissionless poke  (INTERFACE_CONTRACTS.md §8.1, §10)
    // =========================================================================

    /// @inheritdoc IDCACoordinator
    /// @dev §23-E resolution: ineligible poke is a clean no-op (silent return),
    ///      NOT a revert — matches Feature 6 acceptance criterion exactly.
    ///      The nonReentrant guard prevents double-execution races (§10, §18-6).
    function poke(address user) external override nonReentrant {
        // ── P0-3: Eligibility check ────────────────────────────────────────
        if (!_isEligible(user)) {
            // Clean no-op: no state change, no event, no revert.
            return;
        }

        // ── P0-4a: Read market signal (rolling reference price) ────────────
        // §6.5: Coordinator maintains a simple checkpointed rolling reference.
        // For MVP without Hook, we use a stored reference set once.
        // Track C will replace this with a real StateLibrary.getSlot0() call.
        int256 deviationBps = _computeDeviationBps();

        // ── P0-4b: Compute urgency (days until maxDelayDays breached) ──────
        // §23-D formula: block.timestamp >= lastPokeTimestamp + minFrequencyDays * 1 days
        int256 daysUntilDeadline = _daysUntilDeadline(user);

        // ── P0-2: Call DecisionEngine ──────────────────────────────────────
        Constraints memory c = _constraints[user];
        (DecisionEngine.Action engineAction, uint16 trancheBps) =
            DecisionEngine.decide(deviationBps, daysUntilDeadline, c);

        // ── P0-5: Record decision (always, on eligible path) ───────────────
        _lastPokeTimestamp[user] = block.timestamp;
        _lastDecision[user] = _DecisionRecord({
            action:    engineAction,
            timestamp: block.timestamp,
            amountIn:  0,
            amountOut: 0
        });

        // Map internal engine action to IDCACoordinator.Action for the event.
        Action publicAction = Action(uint8(engineAction));
        emit DecisionMade(user, publicAction, deviationBps, block.timestamp);

        // ── P0-7: DELAY — stop here, no vault interaction ─────────────────
        if (engineAction == DecisionEngine.Action.DELAY) {
            return;
        }

        // ── P0-6: Execute path — compute tranche amount and call vault ─────
        uint256 amountIn = (c.standardTrancheAmount * uint256(trancheBps)) / 10_000;
        if (amountIn == 0) return; // guard against rounding to zero

        // Validate user has sufficient vault balance before attempting withdrawal.
        uint256 userAssets = vault.convertToAssets(vault.balanceOf(user));
        if (amountIn > userAssets) {
            // Cap to what the user actually has — don't revert the whole poke.
            amountIn = userAssets;
        }
        if (amountIn == 0) return;

        // ── Vault integration: pull exactly the tranche from the vault ─────
        // This calls DCAVault.withdrawForExecution(user, amountIn).
        // Tokens arrive at address(this) (the coordinator).
        uint256 withdrawn = vault.withdrawForExecution(user, amountIn);

        // ── Execute stub: Track C will replace this with PoolManager.unlock() ──
        // For now, we record the withdrawal as the "output" (amountOut = withdrawn).
        // The full atomic swap path (unlock → unlockCallback → swap → hook) is
        // wired by Hook workstream (Track C) into unlockCallback below.
        uint256 amountOut = withdrawn; // stub: 1:1 until real swap is wired

        // Update the decision record with execution data.
        _lastDecision[user].amountIn  = amountIn;
        _lastDecision[user].amountOut = amountOut;

        emit ExecutionCompleted(user, amountIn, amountOut);
    }

    // =========================================================================
    // Feature 4 — unlockCallback (Track C wires real swap here)
    // =========================================================================

    /// @notice Called by PoolManager inside the unlock() flash-accounting context.
    ///         INTERFACE_CONTRACTS.md §8.2.
    ///         For now this is a stub — Track C (Hook) will fill in the real
    ///         poolManager.swap() + settle/take flash-accounting calls.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != poolManager) revert OnlyPoolManager();
        // Track C: decode (address user, uint256 amountIn), call vault.withdrawForExecution,
        // call poolManager.swap(poolKey, swapParams, abi.encode(user)), _settle(delta).
        (address user, uint256 amountIn) = abi.decode(data, (address, uint256));
        vault.withdrawForExecution(user, amountIn);
        // Swap + settle will be filled in by Track C.
        return "";
    }

    // =========================================================================
    // Reference price management (§6.5 — rolling price checkpoint)
    // =========================================================================

    /// @notice Seed an initial reference price.  Called by Deploy.s.sol after
    ///         the pool is seeded (SeedPool.s.sol).
    ///         Track C will replace this with a live StateLibrary.getSlot0() read.
    function setReferencePrice(bytes32 poolId, uint256 sqrtPriceX96) external {
        referencePrice[poolId] = sqrtPriceX96;
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev §23-D: A user is eligible if:
    ///       1. They have set constraints (have a vault position).
    ///       2. block.timestamp >= lastPokeTimestamp + minFrequencyDays * 1 days
    ///         (first poke is always eligible if constraints exist).
    function _isEligible(address user) internal view returns (bool) {
        if (!_hasConstraints[user]) return false;
        Constraints memory c = _constraints[user];
        if (c.standardTrancheAmount == 0) return false;

        uint256 lastPoke = _lastPokeTimestamp[user];
        // First-ever poke: lastPoke == 0 → always eligible.
        if (lastPoke == 0) return true;

        uint256 nextEligible = lastPoke + (uint256(c.minFrequencyDays) * SECONDS_PER_DAY);
        return block.timestamp >= nextEligible;
    }

    /// @dev Compute deviation in bps between current reference price and a snapshot.
    ///      For MVP: returns 0 (neutral) until Track C wires StateLibrary.getSlot0().
    ///      §6.5: a deviation of 0 always results in EXECUTE_FULL (within goodDeviationBps).
    function _computeDeviationBps() internal pure returns (int256) {
        // TODO Track C: replace with real sqrtPriceX96 deviation computation.
        // bytes32 poolId = ...; 
        // uint160 current = StateLibrary.getSlot0(poolManager, poolKey).sqrtPriceX96;
        // uint160 reference = uint160(referencePrice[poolId]);
        // return _sqrtPriceDeviationBps(current, reference);
        return 0; // neutral → EXECUTE_FULL when conditions are good
    }

    /// @dev Compute days remaining until the user's maxDelayDays deadline.
    ///      Returns a negative or zero value if already overdue (forces EXECUTE_FULL).
    ///      §23-D: urgency is relative to the FIRST eligible timestamp.
    function _daysUntilDeadline(address user) internal view returns (int256) {
        uint256 lastPoke = _lastPokeTimestamp[user];
        Constraints memory c = _constraints[user];

        // The "deadline" is lastPoke + maxDelayDays * 1 days.
        // If lastPoke == 0, the clock starts from the time of the first deposit
        // (we use block.timestamp as reference, so urgency starts at maxDelayDays).
        if (lastPoke == 0) {
            return int256(uint256(c.maxDelayDays));
        }

        uint256 deadline = lastPoke + (uint256(c.maxDelayDays) * SECONDS_PER_DAY);
        if (block.timestamp >= deadline) {
            return 0; // overdue → EXECUTE_FULL
        }

        uint256 remaining = deadline - block.timestamp;
        // Convert seconds to days (round down — conservative urgency).
        return int256(remaining / SECONDS_PER_DAY);
    }
}
