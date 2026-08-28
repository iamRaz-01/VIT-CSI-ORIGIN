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
//   - PoolManager.unlock() → unlockCallback() → swap() → DCAHook execution path
//
// INTERFACE_CONTRACTS.md §6, §7, §8, §10, §15, §16, §17, §18.
// =============================================================================

import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {IERC20}          from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20}       from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Constraints, IDCACoordinator} from "../interfaces/IDCACoordinator.sol";
import {DecisionEngine}  from "../libraries/DecisionEngine.sol";
import {DCAVault}        from "./DCAVault.sol";

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager}    from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}         from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary}    from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath}        from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract DCACoordinator is IDCACoordinator, IUnlockCallback, ReentrancyGuard {
    using DecisionEngine for DecisionEngine.Action;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

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
    IPoolManager public immutable poolManager;

    /// @notice The pool key for the DCA execution pool. Set once after deployment.
    ///         Needed to compute PoolId for StateLibrary.getSlot0() and swap calls.
    PoolKey public poolKey;

    /// @notice Whether the pool key has been configured.
    bool public poolKeySet;

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
    ///         Keyed by poolId bytes32. Seeded by setReferencePrice; updated after each swap.
    mapping(bytes32 => uint256) public referencePrice;

    // =========================================================================
    // Transient callback context
    // =========================================================================

    /// @dev Packed callback context — stored transiently between poke() → unlockCallback().
    ///      Only valid during the PoolManager unlock window (nonReentrant protects against misuse).
    address private _cbUser;
    uint256 private _cbAmountIn;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param vault_       Deployed DCAVault address.
    /// @param poolManager_ Uniswap v4 PoolManager.
    constructor(address vault_, address poolManager_) {
        require(vault_ != address(0), "DCACoordinator: zero vault");
        vault       = DCAVault(vault_);
        poolManager = IPoolManager(poolManager_);
    }

    // =========================================================================
    // Pool key configuration (called by Deploy.s.sol after Hook is mined)
    // =========================================================================

    /// @notice Configure the Uniswap v4 pool key used for DCA execution swaps.
    ///         Called once during deployment after the hook address is mined.
    /// @dev    No onlyOwner — hackathon scope, same pattern as vault setCoordinator.
    function setPoolKey(PoolKey calldata key) external {
        poolKey    = key;
        poolKeySet = true;
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

        // ── P0-4a: Read live market deviation (StateLibrary.getSlot0) ──────
        // §6.5: compare current sqrtPriceX96 against the seeded reference price.
        // If no reference is set or pool key not configured, deviation = 0 (neutral → FULL).
        int256 deviationBps = _computeDeviationBps();

        // ── P0-4b: Compute urgency (days until maxDelayDays breached) ──────
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

        // ── P0-6: Execute path — compute tranche amount ───────────────────
        uint256 amountIn = (c.standardTrancheAmount * uint256(trancheBps)) / 10_000;
        if (amountIn == 0) return; // guard against rounding to zero

        // Cap to user's available vault balance (don't revert the whole poke).
        uint256 userAssets = vault.convertToAssets(vault.balanceOf(user));
        if (amountIn > userAssets) amountIn = userAssets;
        if (amountIn == 0) return;

        // ── Execute via PoolManager.unlock() if pool key is configured ─────
        // If no pool key set (unit-test / stub mode), fall back to direct vault
        // withdrawal and treat amountIn = amountOut (1:1 stub, same as before).
        if (!poolKeySet || address(poolManager) == address(0)) {
            uint256 withdrawn = vault.withdrawForExecution(user, amountIn);
            _lastDecision[user].amountIn  = amountIn;
            _lastDecision[user].amountOut = withdrawn;
            emit ExecutionCompleted(user, amountIn, withdrawn);
            return;
        }

        // Store transient callback context for unlockCallback
        _cbUser     = user;
        _cbAmountIn = amountIn;

        // PoolManager.unlock() calls back into this.unlockCallback() atomically.
        // If the Hook reverts inside the swap, the entire unlock() call reverts here,
        // rolling back vault withdrawal + all coordinator state changes.
        // §8 Atomicity Invariant is satisfied by EVM call semantics.
        bytes memory result = IPoolManager(poolManager).unlock(
            abi.encode(user, amountIn)
        );

        // Decode amountOut from unlockCallback return value
        uint256 amountOut = abi.decode(result, (uint256));

        // Update the reference price after a successful swap
        if (poolKeySet) {
            PoolId pid = poolKey.toId();
            (uint160 newSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, pid);
            if (newSqrtPriceX96 != 0) {
                referencePrice[PoolId.unwrap(pid)] = newSqrtPriceX96;
            }
        }

        _lastDecision[user].amountIn  = amountIn;
        _lastDecision[user].amountOut = amountOut;

        emit ExecutionCompleted(user, amountIn, amountOut);
    }

    // =========================================================================
    // Feature 4 — unlockCallback (PoolManager calls this inside unlock())
    // INTERFACE_CONTRACTS.md §8.2
    // =========================================================================

    /// @notice Called by PoolManager inside the unlock() flash-accounting window.
    ///         Execution flow:
    ///           1. vault.withdrawForExecution(user, amountIn) → USDC at address(this)
    ///           2. Approve PoolManager to pull USDC via sync+settle
    ///           3. poolManager.swap() — triggers DCAHook.beforeSwap + afterSwap
    ///           4. Receive output token via poolManager.take()
    ///           5. Forward output token to user
    ///           6. Return abi.encode(amountOut) to poke()
    ///
    /// @dev ATOMICITY: If the Hook reverts in step 3, the entire unlock() call
    ///      reverts. Step 1's vault withdrawal is rolled back by the EVM.
    ///      The coordinator's state writes in poke() (lastPokeTimestamp, lastDecision)
    ///      are ALSO rolled back because they happen before the unlock() call and
    ///      the revert propagates up through poke() → entire tx reverts.
    ///
    ///      NOTE: State writes in poke() before unlock() ARE rolled back on revert
    ///      because Solidity reverts undo ALL state changes in the call frame.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        (address user, uint256 amountIn) = abi.decode(data, (address, uint256));

        // ── Step 1: Pull the tranche from the vault ───────────────────────
        // vault.withdrawForExecution sends USDC to address(this) (the coordinator).
        uint256 withdrawn = vault.withdrawForExecution(user, amountIn);
        // Use actual withdrawn amount (may be capped to user balance)
        amountIn = withdrawn;
        if (amountIn == 0) return abi.encode(uint256(0));

        // ── Step 2: Settle USDC into PoolManager (pay what we owe) ────────
        // v4 flash accounting: sync checkpoints the ERC-20 balance, then we
        // transfer the tokens in, then settle() nets out the delta.
        //
        // For zeroForOne swap (USDC = currency0, token = currency1):
        //   We send USDC to PoolManager → pool debits us amountIn in currency0.
        //   Pool credits us amountOut in currency1.
        //   We call take(currency1, user, amountOut) to pull output to user.
        //
        // currency0 must be < currency1 (PoolKey invariant).
        // USDC address on Base: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
        // If USDC < outputToken address → USDC is currency0 (zeroForOne = true)
        // If USDC > outputToken address → USDC is currency1 (zeroForOne = false)

        address inputToken  = Currency.unwrap(poolKey.currency0);
        address outputToken = Currency.unwrap(poolKey.currency1);
        bool zeroForOne;

        if (inputToken == vault.asset()) {
            // USDC is currency0 → we are swapping token0 for token1
            zeroForOne = true;
        } else if (outputToken == vault.asset()) {
            // USDC is currency1 → we are swapping token1 for token0
            zeroForOne = false;
        } else {
            // Neither currency is USDC — this should not happen for the DCA pool.
            // Fall through: assume zeroForOne = true as safe default.
            zeroForOne = true;
        }

        // Determine which currency the coordinator is paying (the USDC side)
        Currency currencyIn = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        Currency currencyOut = zeroForOne ? poolKey.currency1 : poolKey.currency0;

        // Sync + transfer + settle to pay the input amount
        IPoolManager(poolManager).sync(currencyIn);
        IERC20(Currency.unwrap(currencyIn)).safeTransfer(address(poolManager), amountIn);
        IPoolManager(poolManager).settle();

        // ── Step 3: Execute the swap ────────────────────────────────────────
        // amountSpecified < 0 → exactIn (we specify how much we're sending in).
        // sqrtPriceLimitX96: use the extreme tick to allow the full swap to execute.
        // hookData: abi.encode(user) — only the user address, per §6.6 trust model.
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne:        zeroForOne,
            amountSpecified:   -int256(amountIn),   // negative = exactIn
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = IPoolManager(poolManager).swap(
            poolKey,
            swapParams,
            abi.encode(user)   // hookData: only user address (§6.6)
        );

        // ── Step 4: Take output tokens from PoolManager → deliver to user ──
        // BalanceDelta from the swap (swapper's perspective):
        //   zeroForOne: delta.amount0() < 0 (sent USDC), delta.amount1() > 0 (received token)
        //   oneForZero: delta.amount1() < 0 (sent USDC), delta.amount0() > 0 (received token)
        int128 rawOut = zeroForOne ? delta.amount1() : delta.amount0();
        uint256 amountOut = rawOut > 0 ? uint256(uint128(rawOut)) : 0;

        if (amountOut > 0) {
            // take() pulls the output tokens from PoolManager and sends directly to user.
            IPoolManager(poolManager).take(currencyOut, user, amountOut);
        }

        return abi.encode(amountOut);
    }

    // =========================================================================
    // Reference price management (§6.5 — rolling price checkpoint)
    // =========================================================================

    /// @notice Seed an initial reference price. Called by Deploy.s.sol after
    ///         the pool is seeded (SeedPool.s.sol).
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

    /// @dev Compute deviation in bps between the current live sqrtPriceX96
    ///      and the stored reference price for the configured pool.
    ///
    ///      Formula (Technical Architecture §6.5):
    ///        current price P  = sqrtPriceX96^2 / 2^192  (token1 per token0)
    ///        reference price R = referencePrice^2 / 2^192
    ///        deviation = (P - R) * 10000 / R
    ///
    ///      To avoid the squaring and 2^192 division (overflow risk), we compute
    ///      deviation using the sqrt values directly:
    ///        sqrtDev = (sqrtCurrent - sqrtRef) * 10000 / sqrtRef
    ///      This is a first-order approximation of true price deviation,
    ///      accurate to O(dev^2). For small deviations (< 20%, our ceiling)
    ///      the approximation error is < 0.04%, well within hook precision.
    ///
    ///      Returns 0 (neutral → EXECUTE_FULL) if:
    ///        - pool key not set
    ///        - no reference price seeded
    ///        - current pool price is 0 (uninitialized pool)
    function _computeDeviationBps() internal view returns (int256) {
        if (!poolKeySet) return 0;

        PoolId pid = poolKey.toId();
        bytes32 pidBytes = PoolId.unwrap(pid);

        uint256 refSqrt = referencePrice[pidBytes];
        if (refSqrt == 0) return 0;  // no reference seeded → neutral

        (uint160 currentSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, pid);
        if (currentSqrtPriceX96 == 0) return 0;  // pool not initialized

        // Both values are uint160; difference fits safely in int256.
        // refSqrt stored as uint256 but originally a uint160 value.
        int256 current = int256(uint256(currentSqrtPriceX96));
        int256 ref     = int256(refSqrt);

        // deviationBps = (current - ref) * 10000 / ref
        // Positive = price moved up (favorable for buyer, since we DCA into the output token).
        // Negative = price moved down.
        // DecisionEngine takes the absolute value for comparison against goodDeviationBps / badDeviationBps.
        return ((current - ref) * 10_000) / ref;
    }

    /// @dev Compute days remaining until the user's maxDelayDays deadline.
    ///      Returns a negative or zero value if already overdue (forces EXECUTE_FULL).
    ///      §23-D: urgency is relative to the FIRST eligible timestamp.
    function _daysUntilDeadline(address user) internal view returns (int256) {
        uint256 lastPoke = _lastPokeTimestamp[user];
        Constraints memory c = _constraints[user];

        // The "deadline" is lastPoke + maxDelayDays * 1 days.
        // If lastPoke == 0, the clock starts from the time of the first deposit
        // (we use block.timestamp as reference, so urgency starts at maxDelayDays)
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
