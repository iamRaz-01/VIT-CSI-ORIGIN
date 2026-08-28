# INTERFACE CONTRACTS
Version: v1
Status: MVP FROZEN

---

## 1. Purpose

This document formalizes the public interfaces between the components of the **DCA Vault Protocol** (CSI ORIGIN 2026, PS-12), as already designed in the approved `Technical Architecture` and scoped by the PM-approved `Features of the Product`. It does not introduce new architecture, features, or technology decisions. It exists so that Vault, Coordinator, Hook, Frontend, and Environment/Deployment agents can implement in parallel Git worktrees against a single, stable contract surface.

Where the source documents leave a signature, validation rule, or behavior unstated, this document either (a) derives the minimum implementation-ready form directly and unambiguously implied by the architecture, or (b) flags it explicitly as **ARCHITECTURAL AMBIGUITY — REQUIRES DECISION** in §23. No new functionality is invented to fill gaps.

---

## 2. Source of Truth

Priority order when documents conflict (highest first):

1. `Project Context` (PS-12 source of truth)
2. `Technical Architecture` (approved system design)
3. `Features of the Product.txt` (approved MVP scope)
4. `Role` (execution discipline, not a source of facts)

This document is a derivative artifact of all four. It carries no independent authority to change scope.

---

## 3. System Components

Extracted from Technical Architecture §5, §7, §14. No components added or removed.

| Component | Type | Responsibility | Upstream Callers | Downstream Dependencies |
|---|---|---|---|---|
| `DCAVault` | Solidity contract (ERC-4626) | Per-user yield-bearing custody | `DCACoordinator`, user (deposit/withdraw), Frontend (reads) | `IYieldStrategy` |
| `IYieldStrategy` | Solidity interface | Swappable yield backend abstraction | `DCAVault` | `AaveYieldStrategy` or `MockYieldStrategy` (one active at a time) |
| `AaveYieldStrategy` | Solidity contract | Real yield via Aave v3 (forked Base) | `DCAVault` | Aave v3 `Pool` |
| `MockYieldStrategy` | Solidity contract | Fallback linear accrual | `DCAVault` | none |
| `DCACoordinator` | Solidity contract | Constraint storage, decision trigger, atomic withdraw+swap | Anyone (`poke`), user (`setConstraints`), Frontend (reads) | `DCAVault`, `PoolManager`, `DecisionEngine`, `DCAHook` (indirectly, via pool) |
| `DecisionEngine` | Solidity library (pure) | Deterministic 3-way decision | `DCACoordinator` | none |
| `DCAHook` | Solidity contract (v4 hook) | Execution-time enforcement | `PoolManager` (via callback) | `DCACoordinator` (read-only, `getConstraints`) |
| Frontend | Off-chain static app | Narratable demo status view | User/presenter | All contracts above (RPC reads), `DCACoordinator.poke` (write) |
| Environment/Deployment | Scripts (`Deploy.s.sol`, `SeedPool.s.sol`, `MoveMarket.s.sol`) | Fork setup, deployment, demo state seeding | Team | Anvil fork, all contracts above |

**Module boundary rule (Technical Architecture §6.1, §20):** No backend, no database, no indexer. All state lives in the three contracts + library above. The Frontend and Environment scripts are consumers, not state owners.

---

## 4. Interface Definitions

All function contracts below follow this schema per Role §11 / Instruction Step 2:

- Function Name / Purpose / Visibility / Caller
- Parameters (name: type)
- Return Values (name: type)
- State Read / State Written
- Preconditions / Postconditions
- Revert Conditions
- Events Emitted
- Dependencies
- Priority (P0/P1/P2 — see §20)

Every function below traces to an explicit requirement in Features of the Product.txt (feature #) or Technical Architecture (§ reference). No speculative functions are included.

---

## 5. Vault Interface — `DCAVault` (ERC-4626)

Traces to: Feature 1 (Per-User Deposit & Vault Position), Feature 10 (User-Initiated Withdrawal, COULD HAVE), Technical Architecture §6.3, §7, §8, §10.

### 5.1 `deposit`
- **Purpose:** User deposits the underlying asset (USDC), receives vault shares. (Feature 1)
- **Visibility:** `external`
- **Caller:** Any depositing user (holds `IERC20(asset).approve` beforehand — standard ERC-4626 flow)
- **Parameters:** `assets: uint256`, `receiver: address`
- **Returns:** `shares: uint256`
- **State Read:** `strategy.totalAssets()`, `totalSupply()`
- **State Written:** `balanceOf[receiver]` (shares), underlying transferred into `strategy` via `strategy.deposit()`
- **Preconditions:** `assets > 0`; caller has approved `assets` of `asset()` to this contract
- **Postconditions:** `balanceOf[receiver]` increases by `shares`; `strategy.totalAssets()` increases by `assets` (net of any strategy-specific rounding)
- **Reverts:** `ZeroAssets()` if `assets == 0`; underlying `SafeERC20` transfer failure; strategy `deposit()` revert propagates
- **Events:** standard ERC-4626 `Deposit(sender, owner, assets, shares)`
- **Dependencies:** `IYieldStrategy.deposit()`
- **Priority:** **P0**

### 5.2 `withdrawForExecution`
- **Purpose:** Coordinator-only pull of exactly the tranche needed for an atomic swap (Feature 4). This is **not** the standard ERC-4626 `withdraw()` — it is a privileged, coordinator-scoped withdrawal used inside the atomic execute path.
- **Visibility:** `external`
- **Caller:** `DCACoordinator` only
- **Parameters:** `user: address`, `assets: uint256`
- **Returns:** `withdrawn: uint256`
- **State Read:** `balanceOf[user]`, share-to-asset conversion rate
- **State Written:** `balanceOf[user]` (shares burned), underlying pulled from `strategy` and transferred to `msg.sender` (the coordinator)
- **Preconditions:** `msg.sender == coordinator`; `user` has sufficient share-equivalent balance for `assets`
- **Postconditions:** `user`'s remaining shares reflect only the untouched balance; the untouched balance continues earning yield (Feature 1's "return remaining capital" requirement, Project Context §9)
- **Reverts:** `Unauthorized()` if caller is not the coordinator; `InsufficientBalance()` if `assets` exceeds the user's withdrawable balance
- **Events:** `Withdraw(caller, receiver, owner, assets, shares)` (ERC-4626-style) or a dedicated `ExecutionWithdrawal(user, assets)` — **see §23-A, naming ambiguity**
- **Dependencies:** `IYieldStrategy.withdraw()`
- **Priority:** **P0**

### 5.3 `withdraw` (user-initiated, standard ERC-4626)
- **Purpose:** User exits their position outside the DCA flow (Feature 10, COULD HAVE)
- **Visibility:** `external`
- **Caller:** Vault position owner (or approved operator, per ERC-4626 allowance semantics)
- **Parameters:** `assets: uint256`, `receiver: address`, `owner: address`
- **Returns:** `shares: uint256`
- **State Read/Written:** standard ERC-4626
- **Preconditions:** `msg.sender == owner` or has ERC-4626 allowance
- **Reverts:** standard ERC-4626 insufficient-balance/allowance reverts
- **Events:** standard ERC-4626 `Withdraw`
- **Dependencies:** `IYieldStrategy.withdraw()`
- **Priority:** **P2** (COULD HAVE — build only if P0/P1 complete, per Features doc)

### 5.4 `totalAssets`, `balanceOf`, `convertToAssets`, `convertToShares` (read-only)
- **Purpose:** Standard ERC-4626 views; feed Feature 1's "growing yield balance visible per user" success metric, and Frontend's balance display (Feature 9)
- **Visibility:** `external view`
- **Caller:** Anyone (Frontend, tests, coordinator)
- **Priority:** **P0** (required for the visible-yield success metric and Frontend)

### 5.5 `strategy` (state variable, public getter)
- **Purpose:** Exposes the active `IYieldStrategy` (§6.3 swappable-strategy decision)
- **Visibility:** `public` (auto-getter)
- **Priority:** **P0**

### Invariants (Vault)
- `balanceOf[user]` is per-user and independent of all other users' balances (Multi-User Contract, §11).
- Only `DCACoordinator` may call `withdrawForExecution`.
- `totalAssets()` must equal the sum of what the active strategy reports; the Vault holds no idle underlying balance beyond dust from rounding.

### `IYieldStrategy` (already frozen in Technical Architecture §7 — reproduced, not modified)
```solidity
interface IYieldStrategy {
    function deposit(uint256 assets) external returns (uint256 deposited);
    function withdraw(uint256 assets, address receiver) external returns (uint256 withdrawn);
    function totalAssets() external view returns (uint256);
    function asset() external view returns (address);
}
```
- **Caller of all four functions:** `DCAVault` only.
- **Priority:** **P0** (interface), **P0** for `AaveYieldStrategy`, **P0** for `MockYieldStrategy` (built in parallel per §6.3 — not a fallback built later).
- **Failure behavior:** Reverts propagate unmodified to `DCAVault`, which propagates to the caller. No swallowed errors (Technical Architecture §11).

---

## 6. User Constraints Interface — `DCACoordinator` (constraint sub-surface)

Traces to: Feature 2 (Per-User Bounded DCA Constraints), Project Context §8, Technical Architecture §7 (`Constraints` struct), §8, §10.

### 6.1 `Constraints` struct (frozen, from Technical Architecture §7 — not modified)
```solidity
struct Constraints {
    uint64  minFrequencyDays;
    uint64  maxDelayDays;
    uint16  goodDeviationBps;
    uint16  badDeviationBps;
    uint16  trancheFlexMinBps;
    uint16  trancheFlexMaxBps;
    uint256 standardTrancheAmount;
    uint16  maxSlippageBps;
}
```

### 6.2 `setConstraints`
- **Purpose:** User defines/updates their own bounded-autonomy parameters (Feature 2)
- **Visibility:** `external`
- **Caller:** The position owner only (`msg.sender` is implicitly the `user` key — no `user` parameter, to prevent one user setting another's constraints)
- **Parameters:** `c: Constraints`
- **Returns:** none
- **State Read:** none required
- **State Written:** `constraints[msg.sender] = c`
- **Preconditions (validation, Technical Architecture §10):**
  - `c.minFrequencyDays != 0`
  - `c.maxDelayDays != 0`
  - `c.trancheFlexMinBps <= c.trancheFlexMaxBps`
  - `c.maxSlippageBps` below a sane ceiling (**see §23-B — exact ceiling value not specified in source docs**)
  - `c.goodDeviationBps <= c.badDeviationBps` (required for DecisionEngine's linear interpolation in §9's spec to be well-defined — **derived, not explicitly stated in source; flagged §23-C**)
- **Reverts:** `InvalidConstraints(reason)` — single error with a reason code/string covering all validation branches above (see Error Catalogue §15)
- **Events:** `ConstraintsSet(address indexed user, Constraints c)`
- **Dependencies:** none
- **Priority:** **P0**

### 6.3 `getConstraints`
- **Purpose:** Trusted read used by `DCAHook` to re-derive bounds (§6.6 of Technical Architecture — the entire hook trust model depends on this being a reliable, unspoofable view call)
- **Visibility:** `external view`
- **Caller:** `DCAHook` (trusted), Frontend (display), anyone (public view — no reason to restrict a read)
- **Parameters:** `user: address`
- **Returns:** `Constraints memory`
- **Priority:** **P0** (blocking — Hook cannot function without this)

### Invariants (Constraints)
- Only `msg.sender` can write `constraints[msg.sender]` — no third party, including the coordinator's own owner/admin if one exists, can set another user's constraints (this system has no privileged admin role at all — confirmed absent from all three source docs).
- `constraints[userA]` and `constraints[userB]` are fully independent mappings entries (Multi-User Contract, §11).

---

## 7. Decision Engine Interface — `DecisionEngine` (library)

Traces to: Feature 3, Technical Architecture §6.4, §9. Frozen exactly as specified — no additional signals.

```solidity
library DecisionEngine {
    enum Action { DELAY, EXECUTE_PARTIAL, EXECUTE_FULL }

    function decide(
        int256 deviationBps,
        int256 daysUntilDeadline,
        Constraints memory c
    ) internal pure returns (Action action, uint16 trancheBps);
}
```

### 7.1 `decide`
- **Purpose:** Convert TWAP deviation + urgency + user bounds into one deterministic action (Feature 3)
- **Visibility:** `internal pure` (library function — no external call surface; always invoked in-process by `DCACoordinator`)
- **Caller:** `DCACoordinator` only
- **Parameters:**
  - `deviationBps: int256` — current spot vs. rolling reference price, in basis points, signed
  - `daysUntilDeadline: int256` — days remaining until the user's `maxDelayDays` bound is breached; signed to allow representing an already-overdue state as `<= 0`
  - `c: Constraints memory` — the calling user's bounds
- **Returns:**
  - `action: DecisionEngine.Action` — one of `{DELAY, EXECUTE_PARTIAL, EXECUTE_FULL}` — **no other value is ever valid** (System Invariant, §18)
  - `trancheBps: uint16` — fraction (in bps, 0–10000) of `c.standardTrancheAmount` to execute; `0` when `action == DELAY`
- **State Read/Written:** none — pure function, stateless (Technical Architecture §6.4's explicit determinism/auditability requirement)
- **Preconditions:** none beyond well-formed `Constraints` (validated upstream at `setConstraints` time, §6.2) — `decide` performs no input validation itself, per §6.4 ("cannot fail except on malformed input, validated upstream")
- **Postconditions:** identical inputs always produce identical outputs (hard determinism requirement, Feature 3 acceptance criterion)
- **Reverts:** none under normal operation (pure arithmetic over already-validated bounds)
- **Events:** none (library functions cannot emit; `DCACoordinator` emits `DecisionMade` after calling this — see §14)
- **Dependencies:** none
- **Priority:** **P0**

### Formula (frozen from Technical Architecture §9 — reproduced verbatim as the implementation spec)
```
decide(deviationBps, daysUntilDeadline, c):
    if daysUntilDeadline <= 0:
        return (EXECUTE_FULL, 10000)
    absDev = |deviationBps|
    if absDev <= c.goodDeviationBps:
        return (EXECUTE_FULL, 10000)
    if absDev >= c.badDeviationBps:
        if daysUntilDeadline <= 1:
            return (EXECUTE_PARTIAL, c.trancheFlexMinBps)
        return (DELAY, 0)
    frac = (absDev - c.goodDeviationBps) / (c.badDeviationBps - c.goodDeviationBps)
    return (EXECUTE_PARTIAL, c.trancheFlexMaxBps - frac * (c.trancheFlexMaxBps - c.trancheFlexMinBps))
```
Default threshold values (`goodDeviationBps = 100`, `badDeviationBps = 300`) are **ASSUMED placeholders**, tunable per-user via `Constraints`, per Technical Architecture §2 (A5) and §9. Calibration happens in Phase 8 against the seeded pool — this is a runtime parameter, not an interface change.

### AI/ML boundary (frozen, not to be crossed by any worktree)
Per Features doc's Product→AI/ML Handoff and Technical Architecture §9: if an AI/ML signal is ever integrated, its **only** legitimate entry point is an additional optional argument that nudges `trancheBps` within the already-computed `[trancheFlexMinBps, trancheFlexMaxBps]` band. It **never** selects `action`. This interface does not currently expose such a parameter — adding one is an **out-of-scope, conditional, not-started** change per the Features doc, and must not be added by any agent without an explicit architecture-level decision.

---

## 8. Coordinator Interface — `DCACoordinator`

Traces to: Feature 4 (Atomic Withdraw + Swap Coordinator), Feature 6 (Poke), Technical Architecture §6.2, §6.4, §7, §8, §10, §11.

### 8.1 `poke`
- **Purpose:** Permissionless trigger that runs the full evaluate→decide→execute loop for one user (Feature 6)
- **Visibility:** `external`
- **Caller:** **Anyone** — explicitly permissionless, no access control (Feature 6 acceptance criterion; Project Context §5)
- **Parameters:** `user: address`
- **Returns:** none (state change + events are the observable output)
- **State Read:** `constraints[user]`, `lastPokeTimestamp[user]`, current pool `sqrtPriceX96` (via `StateLibrary.getSlot0()`), `referencePrice[poolId]`
- **State Written (on eligible + decided-to-execute path):** `lastDecision[user]`, `lastPokeTimestamp[user]`, `referencePrice[poolId]`, vault shares (via `withdrawForExecution`), pool state (via `swap`)
- **State Written (on DELAY or ineligible path):** `lastDecision[user]` only (for DELAY — a logged decision, not a failure) or nothing at all (for ineligible — a clean no-op per Feature 6 acceptance criterion)
- **Preconditions:** `_isEligible(user)` — **see §23-D, exact eligibility formula not specified** beyond "frequency/max-delay based"
- **Postconditions:**
  - If ineligible: no state change, no revert (safe no-op, Feature 6)
  - If eligible and `DELAY`: `lastDecision[user]` updated, no vault/pool state touched
  - If eligible and `EXECUTE_FULL`/`EXECUTE_PARTIAL`: vault withdrawal + pool swap complete atomically, or the entire call reverts and **all** of the above state (including `lastDecision`, `lastPokeTimestamp`, `referencePrice`) remains exactly as before the call (Atomicity Invariant, §18)
- **Reverts:** `NotEligible()` is **not** a revert path per the acceptance criterion (must no-op, not revert) — **see §23-E, no-op vs. revert semantics need explicit confirmation**; hook-triggered reverts propagate up unmodified from `unlockCallback`
- **Events:** `DecisionMade` always (on eligible path); `ExecutionCompleted` on successful execute; `ExecutionRejectedByHook` is emitted **only if** the hook reverts in a way that is caught and re-emitted — **see §23-F, this is a real ambiguity: a hook revert reverts the entire transaction, so no event can be emitted for a reverted tx.** `ExecutionRejectedByHook` as specified in Technical Architecture §7 cannot fire under a hard-revert atomicity model. Resolution required — see §23-F.
- **Dependencies:** `DecisionEngine.decide()`, `DCAVault.withdrawForExecution()`, `PoolManager.unlock()`
- **Reentrancy:** `nonReentrant` (Technical Architecture §10)
- **Priority:** **P0**

### 8.2 `unlockCallback`
- **Purpose:** `PoolManager` callback that performs the actual withdraw+swap inside the atomic `unlock` context (Technical Architecture §7 pseudocode)
- **Visibility:** `external`
- **Caller:** `PoolManager` only
- **Parameters:** `data: bytes` (ABI-encoded `(address user, uint256 amountIn)`)
- **Returns:** `bytes memory` (empty per the illustrative pseudocode)
- **State Read/Written:** as in §8.1's execute path
- **Preconditions:** `msg.sender == address(poolManager)`
- **Reverts:** `OnlyPoolManager()` if caller check fails; any revert inside `_settle`/`_creditUserOutput` propagates and unwinds the entire `poke()` call, including the vault withdrawal (flash-accounting atomicity)
- **Events:** `ExecutionCompleted` on success
- **Dependencies:** `DCAVault.withdrawForExecution()`, `PoolManager.swap()`
- **Priority:** **P0**

### 8.3 `lastDecision`
- **Purpose:** Read the most recent decision + execution result for a user (Frontend Feature 9, comparison Feature 8)
- **Visibility:** `external view`
- **Returns:** `(DecisionEngine.Action action, uint256 timestamp, uint256 amountIn, uint256 amountOut)`
- **Priority:** **P0** (Frontend and comparison feature both depend on this; also useful for tests)

### Atomicity Invariant (formalized, Feature 4 + Technical Architecture §11)
> If `DCAHook.beforeSwap` or `afterSwap` reverts for any reason, the **entire** `poke()` transaction reverts. This means: the vault withdrawal that occurred earlier in the same transaction is rolled back by the EVM (it was never actually committed — Solidity/EVM transactions are all-or-nothing). Post-revert, `DCAVault.balanceOf[user]` and all `DCACoordinator` state (`lastDecision`, `lastPokeTimestamp`, `referencePrice`) are byte-for-byte identical to their pre-call values. This must be asserted by a dedicated forced-failure unit test (Technical Architecture §16, §19 — named the single highest silent-bug risk in the build).

---

## 9. Uniswap v4 Hook Interface — `DCAHook`

Traces to: Feature 5, Technical Architecture §6.6, §7, §10.

### 9.1 `_beforeSwap`
- **Purpose:** Enforce tranche-size bound before the swap executes (Feature 5, condition 1 of 2)
- **Visibility:** `internal override` (invoked by `BaseHook`'s public `beforeSwap` dispatcher, per v4-periphery pattern)
- **Caller (effective):** `PoolManager`, in the context of a swap initiated by `DCACoordinator.unlockCallback`
- **Parameters:** `sender: address`, `key: PoolKey`, `params: IPoolManager.SwapParams`, `hookData: bytes` (ABI-encoded `user: address` only — no numeric bounds, per §6.6's trust model)
- **Returns:** `(bytes4 selector, BeforeSwapDelta, uint24 fee)`
- **State Read:** `coordinator.getConstraints(user)` (trusted external view call — never trusts `hookData`-supplied numbers)
- **State Written:** none (hook is stateless per Technical Architecture §8)
- **Preconditions:** `sender == address(coordinator)` — rejects any caller that is not the Coordinator, closing the bypass described in §6.6
- **Reverts:** `UntrustedCaller()` if `sender != coordinator`; `TrancheCapExceeded()` if `amountIn > c.standardTrancheAmount * c.trancheFlexMaxBps / 10000`
- **Events:** none directly (a revert here unwinds the whole tx — see §23-F on `ExecutionRejectedByHook`)
- **Dependencies:** `DCACoordinator.getConstraints()`
- **Priority:** **P0**

### 9.2 `_afterSwap`
- **Purpose:** Enforce slippage/price-impact bound after settlement, using actual execution results (Feature 5, condition 2 of 2)
- **Visibility:** `internal override`
- **Parameters:** `sender: address`, `key: PoolKey`, `params: IPoolManager.SwapParams`, `delta: BalanceDelta`, `hookData: bytes`
- **Returns:** `(bytes4 selector, int128 hookDelta)`
- **State Read:** `coordinator.getConstraints(user)`
- **Preconditions:** same trust checks as `_beforeSwap`
- **Reverts:** `SlippageCapExceeded()` if computed price impact from `delta` exceeds `c.maxSlippageBps` — this reverts the **whole transaction**, vault untouched (Technical Architecture §7)
- **Dependencies:** `DCACoordinator.getConstraints()`, `_priceImpactBps(delta)` helper (implementation detail, not an interface)
- **Priority:** **P0**

### 9.3 `coordinator` (public getter, `IDCAHookView`)
- **Purpose:** Exposes the trusted coordinator address for tests/inspection
- **Visibility:** `external view`
- **Priority:** **P1** (nice for testing/inspection, not on the critical execution path itself)

### Hook Permission Bits (frozen, Technical Architecture §7)
`beforeSwap = true`, `afterSwap = true`, all other `Hooks.Permissions` flags = `false`. Address must be mined via `HookMiner` (Technical Architecture §14, §19) to encode these flags into the deployed address — this is a **deployment-time constraint**, not a runtime interface concern, but any worktree that deploys `DCAHook` must not deviate from this permission set without an architecture-level decision.

### Trust Model Invariant (formalized, §6.6)
> `DCAHook` never derives enforcement bounds from `hookData` or any caller-supplied numeric value. It always re-reads bounds from `DCACoordinator.getConstraints(user)`, a trusted state read. `hookData` carries only an identity claim (`user: address`), and that claim is only actionable because `sender` is independently verified to equal `address(coordinator)`.

---

## 10. Permissionless Poke Interface

This is `DCACoordinator.poke` (§8.1) — restated here per Instruction Step 8 as its own contract section since Feature 6 is its own MUST HAVE line item.

| Property | Value |
|---|---|
| Function | `poke(address user)` |
| Caller | Anyone — no allowlist, no `onlyOwner`, no keeper role |
| Eligibility check | `_isEligible(user)` — internal, gates whether execution logic runs |
| No-op condition | User not yet eligible (frequency/max-delay window not reached) → return with zero state change, **no revert** |
| State changes (eligible path) | `lastDecision`, `lastPokeTimestamp`, `referencePrice`, and conditionally vault + pool state |
| Events | `DecisionMade` (always, eligible path); `ExecutionCompleted` (execute path) |
| Errors | None expected on the no-op path; hook/atomicity reverts propagate on the execute path |
| Repeated-call behavior | Calling `poke(user)` again before the next eligible window must be a clean no-op (idempotent-safe), and the double-call/race case is separately covered by `nonReentrant` |
| Reentrancy | `nonReentrant` modifier required |

**Priority:** **P0**. This is explicitly the function that makes "continuous monitoring" real (Project Context §1, §9) — without it nothing in the system ever executes.

---

## 11. Multi-User Contract

Traces to: Feature 7, Project Context §2 (repeated FACT), Technical Architecture §8 ("every piece of mutable per-user state is `mapping(address => X)`").

### 11.1 Multi-User Invariants

| Invariant | Enforced By |
|---|---|
| Each user's vault share balance is independent | `DCAVault.balanceOf: mapping(address => uint256)` (inherited ERC-4626 storage) |
| Each user's constraints are independent | `DCACoordinator.constraints: mapping(address => Constraints)` |
| Each user's eligibility/frequency state is independent | `DCACoordinator.lastPokeTimestamp: mapping(address => uint256)` |
| Each user's decision history (latest) is independent | `DCACoordinator.lastDecision: mapping(address => (...))` |
| No user can write another user's constraints | `setConstraints` keys exclusively off `msg.sender` (§6.2) |
| No user can trigger a withdrawal that credits another user | `withdrawForExecution` and `unlockCallback` always credit output to the `user` encoded in `hookData`, never to `msg.sender`/poke-caller (Technical Architecture §10) |
| Two users, same market snapshot, different `Constraints` → different `lastDecision` | Direct consequence of `DecisionEngine.decide()` being a pure function of `(deviationBps, daysUntilDeadline, c)` — different `c` mechanically produces different output given identical market inputs |

### 11.2 Demo verification requirement (Feature 7 acceptance criterion)
Two users, different `frequency`/`maxDelayDays`/tranche settings, same market snapshot → visibly different logged actions in `lastDecision`. No new interface is required to prove this — it falls out of the mappings above being correctly keyed. **This is a testing/demo-scripting concern, not an additional interface (Technical Architecture §3, row 7: "Low — discipline, not engineering").**

---

## 12. Frontend Integration Contract

Traces to: Feature 9 (SHOULD HAVE, Minimal Frontend), Technical Architecture §5, §6.1 ("frontend reads chain state directly by RPC; nothing else is required").

No backend/API layer exists between Frontend and contracts. All calls below are direct RPC (`viem`/`ethers`) calls against the contracts already specified in §5–§9. No frontend-specific contract methods are introduced.

| Frontend Need | Contract → Function | Direction | Inputs | Outputs |
|---|---|---|---|---|
| Show user's vault balance/yield | `DCAVault.balanceOf`, `DCAVault.convertToAssets` | Read | `user: address` | `assets: uint256` |
| Show user's constraints | `DCACoordinator.getConstraints` | Read | `user: address` | `Constraints` |
| Show latest decision | `DCACoordinator.lastDecision` | Read | `user: address` | `(Action, timestamp, amountIn, amountOut)` |
| Show decision/execution history | `getLogs()` on `DecisionMade`, `ExecutionCompleted`, (and `ExecutionRejectedByHook` pending §23-F) | Read (event log replay) | block range filter | array of decoded events |
| Set/update constraints | `DCACoordinator.setConstraints` | Write | `Constraints` | tx receipt |
| Deposit into vault | `DCAVault.deposit` | Write | `assets: uint256`, `receiver: address` | `shares: uint256` |
| Trigger evaluation | `DCACoordinator.poke` | Write | `user: address` | tx receipt |
| Show before/after $ delta (Feature 8) | Off-chain script/frontend computation over replayed events | Read (derived, no new contract call) | event log set | computed delta |

**Priority:** **P1** overall (SHOULD HAVE per Features doc) — but the underlying reads/writes it depends on (`balanceOf`, `getConstraints`, `lastDecision`, `setConstraints`, `deposit`, `poke`) are all **P0** because they're needed for testing regardless of whether the frontend itself ships. If Frontend is cut, the identical calls are exercised via `cast`/Foundry console (Technical Architecture §11, rehearsed fallback).

**Frontend does not own any state.** It does not cache, mutate, or become a second source of truth for any value listed above (Technical Architecture §6.1).

---

## 13. Deployment / Environment Contract

Traces to: Technical Architecture §6.2, §13, §14, §2 (Open Questions O1–O3).

### 13.1 Required environment variables (names only — no values/secrets)

| Variable | Purpose | Required By |
|---|---|---|
| `BASE_RPC_URL` | Fork source for Anvil | Environment/Deployment |
| `FORK_BLOCK_NUMBER` | Pins the fork for reproducibility | Environment/Deployment |
| `DEPLOYER_PRIVATE_KEY` | Burner key only — never a funded key | Deploy script |
| `USDC_ADDRESS` | Real Base USDC address, deposit/yield asset (Technical Architecture §2 A3) | `DCAVault`, `AaveYieldStrategy` |
| `AAVE_POOL_ADDRESS` | Aave v3 `Pool` on Base | `AaveYieldStrategy` |
| `POOL_MANAGER_ADDRESS` | Uniswap v4 `PoolManager` on Base | `DCACoordinator`, `DCAHook`, deploy/seed scripts |
| `MOCK_TOKEN_ADDRESS` | Deployed fresh per run (not fixed) — counter-asset for the demo pool | `SeedPool.s.sol`, `MoveMarket.s.sol` |

### 13.2 Address dependency order (deployment sequence — not new architecture, just sequencing already implied by §7's dependency graph)
1. `MockERC20` (counter-asset)
2. `DCAVault` (needs `USDC_ADDRESS`)
3. `AaveYieldStrategy` / `MockYieldStrategy` (needs `AAVE_POOL_ADDRESS` or none; needs `DCAVault` address to authorize)
4. `DCACoordinator` (needs `DCAVault`, `POOL_MANAGER_ADDRESS`)
5. `DCAHook` — **mined address**, must encode permission bits (§9.3) and needs `DCACoordinator` address baked in at construction
6. Pool initialization (`SeedPool.s.sol`) — needs `DCAHook` address, `MOCK_TOKEN_ADDRESS`, `USDC_ADDRESS`

This sequence is a hard dependency chain — no worktree can deploy `DCAHook` before `DCACoordinator` exists, and no worktree can initialize the pool before `DCAHook` is mined and deployed.

### 13.3 Fork configuration (frozen, Technical Architecture §6.2, §13)
```
anvil --fork-url $BASE_RPC_URL --fork-block-number <PIN> --code-size-limit 40000
```
`--code-size-limit 40000` is a required flag (documented risk if omitted, Technical Architecture §13).

**Priority:** **P0** for the fork + deployment sequence itself (nothing else can be tested without it); **P1** for the optional Base Sepolia public deployment (Open Question O2).

---

## 14. Event Catalogue

Traces to: Technical Architecture §7, §8, §11. Only events required for Frontend, debugging, testing, or demo narration are included — no decorative events.

| Event | Emitting Module | Purpose | Parameters (indexed marked) | Consumers |
|---|---|---|---|---|
| `Deposit(sender, owner*, assets, shares)` | `DCAVault` | Standard ERC-4626 — confirms deposit succeeded | `sender: address`, `owner*: address`, `assets: uint256`, `shares: uint256` | Frontend, tests |
| `Withdraw(sender, receiver, owner*, assets, shares)` | `DCAVault` | Standard ERC-4626 — confirms user-initiated withdrawal (Feature 10) | as above | Frontend, tests |
| `ConstraintsSet(user*, c)` | `DCACoordinator` | Confirms a user's bounds were stored (Feature 2) | `user*: address`, `c: Constraints` | Frontend, tests |
| `DecisionMade(user*, action, deviationBps, timestamp)` | `DCACoordinator` | Records every evaluation outcome, including `DELAY` (Feature 3, Feature 8 source data) | `user*: address`, `action: Action`, `deviationBps: int256`, `timestamp: uint256` | Frontend, comparison script, tests |
| `ExecutionCompleted(user*, amountIn, amountOut)` | `DCACoordinator` | Confirms atomic execute succeeded (Feature 4) | `user*: address`, `amountIn: uint256`, `amountOut: uint256` | Frontend, comparison script, tests |
| `ExecutionRejectedByHook(user*, reason)` | `DCACoordinator` (as declared in Technical Architecture §7) | Intended to record a hook rejection for demo narration/logs | `user*: address`, `reason: string` | Frontend, demo narration | **See §23-F — cannot fire under hard-revert atomicity as currently specified. Needs resolution before implementation.** |

`*` = indexed parameter (standard practice for the entity being filtered on — `owner`/`user` — consistent with the "no indexer needed, `getLogs()` covers it" decision in Technical Architecture §8).

**Priority:** `Deposit`, `DecisionMade`, `ExecutionCompleted` — **P0** (directly required by Definition of Done checklist, Technical Architecture §21). `Withdraw` — **P2** (tied to COULD HAVE Feature 10). `ConstraintsSet` — **P1** (useful for tests/frontend, not itself a Definition-of-Done line item). `ExecutionRejectedByHook` — **blocked pending §23-F**.

---

## 15. Error Catalogue

Traces to: Technical Architecture §10, §11; derived directly from stated validation rules and failure modes — no invented error conditions.

| Error | Module | Trigger Condition | Meaning | Expected Caller Behavior |
|---|---|---|---|---|
| `ZeroAssets()` | `DCAVault` | `deposit(0, ...)` | No-op deposit attempted | Caller must pass a positive amount |
| `Unauthorized()` | `DCAVault` | Non-coordinator calls `withdrawForExecution` | Privileged-caller boundary violated | Only `DCACoordinator` should call this path |
| `InsufficientBalance()` | `DCAVault` | Withdrawal exceeds user's balance | Requested amount exceeds entitlement | Caller (coordinator) has a logic bug if this fires — should never happen given `decide()`'s tranche math is bounded by the user's own balance-derived `standardTrancheAmount` |
| `InvalidConstraints(reason)` | `DCACoordinator` | `setConstraints` fails any validation rule in §6.2 | User submitted out-of-bound or contradictory constraints | User must correct and resubmit |
| `NotEligible()` | `DCACoordinator` | **Only if the no-op path is implemented as a revert rather than a silent return — see §23-E** | User not yet in an eligible window | Not an error under the "clean no-op" reading of Feature 6; flagged for resolution |
| `OnlyPoolManager()` | `DCACoordinator` | `unlockCallback` called by anything other than `PoolManager` | Prevents spoofed callback | Should never fire in normal operation; indicates an attack or misconfiguration |
| `UntrustedCaller()` | `DCAHook` | `sender != address(coordinator)` in `_beforeSwap`/`_afterSwap` | Someone attempted to call the pool directly, bypassing the Coordinator | Confirms the trust model (§6.6) is holding; expected to fire only in the adversarial-input test |
| `TrancheCapExceeded()` | `DCAHook` | `amountIn` exceeds `c.trancheFlexMaxBps`-derived cap | Execution-time tranche bound violated | Whole tx reverts, vault unchanged (this is the Feature 5 success-metric rejection path) |
| `SlippageCapExceeded()` | `DCAHook` | Post-swap price impact exceeds `c.maxSlippageBps` | Execution-time slippage bound violated | Whole tx reverts, vault unchanged (also usable to reliably stage the Feature 5 demo rejection per Technical Architecture §13) |

**Priority:** `InvalidConstraints`, `TrancheCapExceeded`, `SlippageCapExceeded`, `OnlyPoolManager`, `Unauthorized` — **P0** (each maps directly to a named risk in Technical Architecture §19 Red Team or a Definition-of-Done check). `ZeroAssets`, `InsufficientBalance` — **P1** (defensive, not central to the demo path). `NotEligible` — **status pending §23-E**.

---

## 16. State Ownership Matrix

Traces to: Technical Architecture §8 ("Rule: every piece of mutable per-user state is `mapping(address => X)`. No singleton globals.").

| State | Owner Module | Readers | Writers | Authorized Writers |
|---|---|---|---|---|
| `balanceOf[user]` (vault shares) | `DCAVault` | Anyone (view) | `DCAVault` internal logic only | `deposit` (self-write for `msg.sender`/`receiver`), `withdrawForExecution` (coordinator-triggered), `withdraw` (owner-triggered) |
| `strategy` (active `IYieldStrategy`) | `DCAVault` | Anyone (view) | `DCAVault` | Deployment/config only — **no runtime strategy-switch function is specified in source docs; see §23-G** |
| `constraints[user]` | `DCACoordinator` | Anyone (view, incl. `DCAHook`) | `DCACoordinator` | `setConstraints`, keyed strictly to `msg.sender` |
| `lastPokeTimestamp[user]` | `DCACoordinator` | `DCACoordinator` internal (eligibility check) | `DCACoordinator` | `poke()` internal update only |
| `lastDecision[user]` | `DCACoordinator` | Anyone (view), Frontend | `DCACoordinator` | `poke()` internal update only |
| `referencePrice[poolId]` | `DCACoordinator` | `DCACoordinator` internal | `DCACoordinator` | `poke()` internal update only — **this is a shared, per-pool (not per-user) checkpoint; see §23-H on whether cross-user pokes can race this value** |
| Hook enforcement bounds | *(not separately stored)* | `DCAHook` (via `getConstraints`) | n/a — `DCAHook` is stateless | n/a |
| Pool price/liquidity state | `PoolManager` (external, not owned by this system) | `DCACoordinator`, `DCAHook` | `PoolManager` only | n/a — out of this system's ownership by design |

**Rule enforced:** No module reads another module's storage directly. `DCAHook` reads `DCACoordinator`'s constraints exclusively through the `getConstraints()` view function, never through direct storage slot access. `DCACoordinator` reads `DCAVault`'s balances exclusively through `DCAVault`'s public functions.

---

## 17. Critical Call Graph

Traces to: Technical Architecture §4, §7 pseudocode.

### 17.1 Success path
```
USER/PRESENTER/SCRIPT
   → DCACoordinator.poke(user)                         [external, permissionless]
       → _isEligible(user)                               [internal read: lastPokeTimestamp, constraints]
       → StateLibrary.getSlot0() / referencePrice read    [external read: PoolManager]
       → DecisionEngine.decide(dev, urgency, constraints) [internal, pure]
       → _recordDecision(user, action, dev)               [internal write: lastDecision]
           → emits DecisionMade
       → if action == DELAY: return                       [no further calls]
       → PoolManager.unlock(abi.encode(user, amountIn))   [external call]
           → DCACoordinator.unlockCallback(data)            [callback, external, PoolManager-only]
               → DCAVault.withdrawForExecution(user, amountIn)  [external call]
                   → IYieldStrategy.withdraw(...)                [external call]
               → PoolManager.swap(poolKey, params, hookData=user) [external call]
                   → DCAHook._beforeSwap(...)                      [callback]
                       → DCACoordinator.getConstraints(user)         [external view, trusted]
                   → (swap executes)
                   → DCAHook._afterSwap(...)                       [callback]
                       → DCACoordinator.getConstraints(user)         [external view, trusted]
               → _settle(delta)                                  [internal, flash-accounting]
               → _creditUserOutput(user, delta)                  [internal write]
                   → emits ExecutionCompleted
```

### 17.2 Rejection path
```
... (identical up to DCAHook._afterSwap or _beforeSwap)
   → DCAHook reverts (TrancheCapExceeded or SlippageCapExceeded)
       → entire poke() transaction reverts
       → DCAVault.balanceOf[user] unchanged
       → DCACoordinator.lastDecision[user], lastPokeTimestamp[user], referencePrice unchanged
       → NO event is emitted (a reverted transaction emits nothing — see §23-F)
```

Every arrow above is either already an interface defined in §5–§10, or an external call into `PoolManager`/`IYieldStrategy` already named in Technical Architecture §7. No new call edges are introduced.

---

## 18. System Invariants

Traces to: Project Context §8, §10; Features doc acceptance criteria; Technical Architecture §6, §10, §11.

1. **User isolation:** No user's `Constraints`, vault shares, or decision history can be read-modified by another user's actions. (§11)
2. **No unauthorized constraint writes:** `setConstraints` is keyed exclusively to `msg.sender`. No admin override exists anywhere in this system.
3. **Decision output is closed-set:** `DecisionEngine.decide()` returns only `{DELAY, EXECUTE_PARTIAL, EXECUTE_FULL}` — never any other value, never reverts on well-formed input. (§7)
4. **Determinism:** Identical `(deviationBps, daysUntilDeadline, Constraints)` always produces identical `(action, trancheBps)`. (§7)
5. **Hook enforces at settlement, unconditionally:** No swap through the demo pool can settle outside `trancheFlexMaxBps` or `maxSlippageBps`, regardless of what any pre-swap logic decided. (§9)
6. **Atomicity:** A hook rejection reverts the entire `poke()` transaction; the vault position is provably unchanged after a rejected attempt. (§8)
7. **Permissionless-safe triggering:** Anyone may call `poke(user)`; repeated or premature calls are safe no-ops and never corrupt state or misdirect funds — output is always credited to `user`, never to `msg.sender`. (§10)
8. **Bounded autonomy:** The system never executes outside a user's own configured bounds, and `daysUntilDeadline <= 0` forces `EXECUTE_FULL` rather than allowing indefinite delay (Project Context §8's "must never delay indefinitely"). (§7)
9. **Trust boundary:** `DCAHook` never derives enforcement numbers from caller-supplied `hookData` — only from `DCACoordinator.getConstraints()`. (§9)
10. **Single state owner per field:** every mutable field in §16 has exactly one authorized writer module.

---

## 19. Worktree Integration Rules

Per Instruction Step 17 — applies verbatim, restated as the binding rule set for this freeze:

1. Public function signatures defined in §5–§10 are **frozen**. Changing a parameter type, return type, or visibility requires an architecture-level decision, not a unilateral worktree change.
2. Event names and schemas in §14 are **frozen**, except `ExecutionRejectedByHook`, which is explicitly **blocked pending §23-F** and must not be implemented as specified until resolved.
3. Custom error names and meanings in §15 are **frozen**, except `NotEligible()`, which is **pending §23-E**.
4. Any new cross-module dependency not already listed in §3's Upstream/Downstream columns requires architectural approval before implementation.
5. Internal implementation (e.g., how `_priceImpactBps` computes its value, how `AaveYieldStrategy` wraps `aToken` accounting) may change freely behind the stable interface, without cross-worktree coordination.
6. No worktree may read another module's storage directly (e.g., Hook worktree must not add direct `constraints` mapping access — it must go through `getConstraints()`).
7. Breaking changes to anything in §5–§10 require review by all worktrees whose components appear as callers or callees of the changed interface, before merge.

### Worktree assignment (mirrors Technical Architecture §18 Tracks A–E, not redefined)

| Worktree | Owns | Must Not Touch |
|---|---|---|
| Vault Agent (Track B) | `DCAVault`, `IYieldStrategy`, `AaveYieldStrategy`, `MockYieldStrategy` | `DCACoordinator`, `DCAHook` internals |
| Coordinator Agent (Track A) | `DCACoordinator`, `DecisionEngine` | `DCAVault` internal storage, `DCAHook` internal storage |
| Hook Agent (Track C) | `DCAHook` | `DCACoordinator` storage (must use `getConstraints()`), `DCAVault` |
| Frontend Agent (Track D) | Frontend app, `MoveMarket.s.sol`, comparison script | Any contract source |
| Environment Agent (Track E) | `Deploy.s.sol`, `SeedPool.s.sol`, fork config, `.env.example` | Contract logic (deployment-only scope) |

---

## 20. P0/P1/P2 Classification

Consolidated from priority tags assigned throughout §5–§15.

### P0 — Critical to end-to-end MVP (blocks the Critical Demo Path)
- `DCAVault.deposit`, `withdrawForExecution`, `totalAssets`, `balanceOf`, `convertToAssets`
- `IYieldStrategy` (interface) + both `AaveYieldStrategy` and `MockYieldStrategy` (built in parallel, per §6.3)
- `DCACoordinator.setConstraints`, `getConstraints`, `poke`, `unlockCallback`, `lastDecision`
- `DecisionEngine.decide` (full formula, §7)
- `DCAHook._beforeSwap`, `_afterSwap` (both bounds)
- Events: `Deposit`, `DecisionMade`, `ExecutionCompleted`
- Errors: `InvalidConstraints`, `TrancheCapExceeded`, `SlippageCapExceeded`, `OnlyPoolManager`, `Unauthorized`
- Deployment sequence §13.2, fork config §13.3
- Multi-user isolation (§11) — no new code, but a mandatory verification step

### P1 — Important, not blocking
- Frontend read/write surface (§12) as a whole app (its underlying calls are P0 individually, listed above)
- `ConstraintsSet` event
- `DCAHook.coordinator` getter
- `ZeroAssets`, `InsufficientBalance` errors
- Before/After comparison script (Feature 8)
- Base Sepolia public deployment (O2)

### P2 — Optional, defer without blocking P0
- `DCAVault.withdraw` (user-initiated exit, Feature 10)
- `Withdraw` event (tied to the above)

**18-hour rule (Role §21, restated):** No P1/P2 item may block P0 integration. If a worktree is behind, P1/P2 items are cut, not P0 items.

---

## 21. Master Interface Matrix

| Caller | Callee | Function / Event | Direction | Inputs | Outputs | State Changed | Errors | Priority | Worktree |
|---|---|---|---|---|---|---|---|---|---|
| User | `DCAVault` | `deposit` | Write | `assets, receiver` | `shares` | `balanceOf`, strategy balance | `ZeroAssets` | P0 | Vault |
| `DCACoordinator` | `DCAVault` | `withdrawForExecution` | Write | `user, assets` | `withdrawn` | `balanceOf`, strategy balance | `Unauthorized`, `InsufficientBalance` | P0 | Vault ↔ Coordinator |
| User | `DCAVault` | `withdraw` | Write | `assets, receiver, owner` | `shares` | `balanceOf` | standard ERC-4626 | P2 | Vault |
| Anyone | `DCAVault` | `totalAssets`/`balanceOf`/`convertToAssets` | Read | `user`/none | `uint256` | none | none | P0 | Vault |
| `DCAVault` | `IYieldStrategy` | `deposit`/`withdraw`/`totalAssets`/`asset` | Read/Write | per §5 | per §5 | strategy-internal | propagated | P0 | Vault |
| User | `DCACoordinator` | `setConstraints` | Write | `Constraints` | none | `constraints[msg.sender]` | `InvalidConstraints` | P0 | Coordinator |
| `DCAHook` / Anyone | `DCACoordinator` | `getConstraints` | Read | `user` | `Constraints` | none | none | P0 | Coordinator ↔ Hook |
| Anyone | `DCACoordinator` | `poke` | Write | `user` | none | `lastDecision`, `lastPokeTimestamp`, `referencePrice`, vault/pool (conditional) | `OnlyPoolManager` (internal callback only) | P0 | Coordinator |
| `PoolManager` | `DCACoordinator` | `unlockCallback` | Callback | `bytes data` | `bytes` | as `poke` execute path | `OnlyPoolManager` | P0 | Coordinator |
| `DCACoordinator` | `DecisionEngine` | `decide` | Internal call | `deviationBps, daysUntilDeadline, Constraints` | `(Action, trancheBps)` | none (pure) | none | P0 | Coordinator |
| `DCACoordinator` | `PoolManager` | `unlock`, `swap` | External call | per Uniswap v4 API | `BalanceDelta` | pool state | propagated | P0 | Coordinator ↔ external |
| `PoolManager` | `DCAHook` | `beforeSwap`/`afterSwap` (via `_beforeSwap`/`_afterSwap`) | Callback | `sender, key, params, hookData` | selector/delta | none (stateless) | `UntrustedCaller`, `TrancheCapExceeded`, `SlippageCapExceeded` | P0 | Hook |
| Anyone | `DCACoordinator` | `lastDecision` | Read | `user` | `(Action, timestamp, amountIn, amountOut)` | none | none | P0 | Coordinator |
| Frontend | `DCAVault`, `DCACoordinator` | reads (§12 table) | Read | various | various | none | none | P1 (app), P0 (underlying calls) | Frontend |
| Frontend | `DCACoordinator` | `setConstraints`, `poke`, `DCAVault.deposit` | Write | various | tx receipt | as above | as above | P1 (app), P0 (underlying calls) | Frontend |
| Environment scripts | all contracts | deployment/seed calls | Write | constructor/init args | deployed addresses | initial state | deployment reverts | P0 | Environment |

---

## 22. Consistency Audit

Cross-checked against Project Context, Features of the Product.txt, and Technical Architecture. Findings:

### 22.1 No missing interfaces found for any MUST HAVE feature (1–7)
Every MUST HAVE feature in the Features doc maps to at least one P0 interface element above.

### 22.2 No duplicate interfaces found.

### 22.3 No type mismatches found between Technical Architecture §7's frozen `Constraints`/`DecisionEngine` signatures and this document — they are reproduced verbatim, not altered.

### 22.4 CONFLICT — Event emission vs. atomicity model
**SOURCE A:** Technical Architecture §7, `IDCACoordinator` interface: declares `event ExecutionRejectedByHook(address indexed user, string reason);` as part of the frozen interface.
**SOURCE B:** Technical Architecture §7, §11: "If the swap fails validation inside the hook, the whole transaction (including the withdrawal) must revert" and Project Context §5: atomicity means the entire transaction reverts on hook rejection.
**IMPACT:** An EVM transaction that reverts emits **no** events — any event emitted before the revert point is also rolled back. As written, `ExecutionRejectedByHook` can never actually be observed on-chain under the hard-revert atomicity model both documents mandate elsewhere. This is a genuine internal inconsistency in the approved architecture, not something this document can silently resolve.
**REQUIRED DECISION:** See §23-F.

### 22.5 CONFLICT — No-op vs. revert semantics for ineligible `poke()`
**SOURCE A:** Features of the Product.txt, Feature 6 Acceptance Criteria: "Function callable by any address; correctly **no-ops** if the user isn't yet eligible."
**SOURCE B:** Technical Architecture §7 pseudocode: `require(_isEligible(user), "not eligible");` — a `require` **reverts**, it does not no-op.
**IMPACT:** These are two different behaviors from a caller's perspective — a revert causes `poke()` to fail (a transaction receipt with `status: 0`), while a true no-op succeeds with no state change. For a keeper/script calling `poke()` repeatedly across many users, this materially changes error-handling logic.
**REQUIRED DECISION:** See §23-E.

### 22.6 No conflicting state ownership found — §16's matrix is internally consistent across all three source documents.

### 22.7 No undefined dependencies found beyond the two ambiguities above.

### 22.8 No unapproved functionality or scope expansion introduced by this document. All P0/P1/P2 items trace to an existing feature or architectural decision.

---

## 23. Open Architectural Ambiguities

These require an explicit decision before the affected worktree can finalize implementation. None are resolved silently by this document.

**§23-A — `withdrawForExecution` event naming.** Technical Architecture §7 does not name a specific event for the coordinator-triggered vault withdrawal step (only the standard ERC-4626 `Withdraw` is shown, which is user-initiated language). Decide whether `withdrawForExecution` reuses the standard `Withdraw` event or needs a distinct `ExecutionWithdrawal` event for clean log-based demo narration.

**§23-B — `maxSlippageBps` ceiling value.** Technical Architecture §10 requires `setConstraints` to reject `maxSlippageBps` "above a sane ceiling" but does not specify the number. Needs a concrete value (e.g., a hardcoded max like 2000 bps / 20%) before `setConstraints` can be fully implemented and tested.

**§23-C — Ordering constraint between `goodDeviationBps` and `badDeviationBps`.** Not explicitly stated as a validation rule in any source document, but required for the linear-interpolation branch of `DecisionEngine.decide()` (§9 of Technical Architecture) to be mathematically well-defined (avoids division producing a value outside `[0,1]` or a negative denominator). Recommend adding `c.goodDeviationBps <= c.badDeviationBps` to `setConstraints`'s validation set — flagged here rather than silently added to §6.2's preconditions as authoritative, since it's a derived requirement, not a directly stated one.

**§23-D — Exact `_isEligible(user)` formula.** Technical Architecture §7 references `_isEligible(user)` but never specifies its formula. It is clearly frequency/max-delay based per Feature 2 (`minFrequencyDays`, `maxDelayDays` exist in `Constraints`), but the exact comparison (e.g., `block.timestamp >= lastPokeTimestamp[user] + minFrequencyDays * 1 days`) is not written anywhere in the three source documents. Needs confirmation before Coordinator Agent can implement `poke()`.

**§23-E — No-op vs. revert for ineligible `poke()`.** See Consistency Audit §22.5. Needs an explicit decision: either (a) change the Technical Architecture's pseudocode from `require(...)` to an `if (!eligible) return;` pattern to match the Features doc's stated acceptance criterion, or (b) reinterpret "no-op" in the Features doc to mean "reverts cleanly with a clear reason, at negligible gas cost" rather than "succeeds with a no-op receipt." This affects `NotEligible()`'s status in §15 and how Frontend/keeper scripts should be written to call `poke()` in a loop across many users without a failed call halting a batch script.

**§23-F — `ExecutionRejectedByHook` cannot fire under hard-revert atomicity.** See Consistency Audit §22.4. This is the most material ambiguity in the frozen interface set, because Technical Architecture §11's Failure Modes table and §13's demo strategy both describe "one deliberately-triggered rejection" as a **visible, demonstrable event** during the live demo — but a reverted transaction produces no event log by EVM design. Two realistic resolutions exist (neither is a redesign, both are clarifications of the same architecture):
  - **(i)** The "visible rejection" is demonstrated via the **transaction's revert reason string** surfaced in the Frontend/console (e.g., `cast call` showing a revert with `"TrancheCapExceeded"` or `"SlippageCapExceeded"`), not via an event. `ExecutionRejectedByHook` is then dropped from the frozen Event Catalogue entirely.
  - **(ii)** The Coordinator wraps the pool interaction in a `try/catch` around `PoolManager.unlock()`, catches the hook's revert, deliberately does **not** revert the outer `poke()` transaction, and instead emits `ExecutionRejectedByHook` and leaves vault state untouched by construction (since the withdrawal itself would need to also be inside the `try` scope or separately guarded). This changes the atomicity mechanism from "revert propagation" to "explicit catch-and-log," which is a materially different implementation of Feature 4's atomicity guarantee and needs Architect sign-off before Coordinator Agent builds it.
  This must be decided before Coordinator Agent and Hook Agent finalize `poke()` / `unlockCallback` / `_afterSwap`.

**§23-G — No runtime yield-strategy-switch function specified.** Technical Architecture §6.3 describes the strategy as "swappable" (an architectural property, allowing `MockYieldStrategy` to substitute for `AaveYieldStrategy` if Aave proves unstable near the demo), but no source document specifies whether this swap happens via a redeploy + reconfigured `.env`, or via a live `DCAVault.setStrategy()` function callable pre-demo. If the latter is intended, it needs a frozen signature and an access-control decision (who may call it — likely a one-time deployer-only setup call, not a runtime user-facing function). Currently assumed to be a deployment-time choice (redeploy/reconfigure), not a runtime interface — flagged for confirmation.

**§23-H — `referencePrice[poolId]` concurrency across users.** Technical Architecture §8 stores `referencePrice` keyed by `poolId`, not by `user` — meaning it is **shared state updated by every user's `poke()` call**, not per-user state like everything else in the Multi-User Contract (§11). This is likely intentional (there's only one pool, so one rolling reference price is correct), but it means `poke(userA)` followed immediately by `poke(userB)` can have the second call observe a reference price already updated by the first call within the same block. Confirm this is the intended behavior (a shared market-reference checkpoint, not a per-user one) — if so, no change is needed, but it should be explicitly noted in the Multi-User Contract as the one piece of state that is deliberately *not* per-user, to avoid a worktree agent assuming it should be `mapping(address => uint160)` by pattern-matching the rest of §8.

---

**End of INTERFACE_CONTRACTS.md — MVP FROZEN, pending resolution of §23-E and §23-F before Coordinator/Hook worktrees begin `poke()`/`unlockCallback`/`_afterSwap` implementation. All other P0 interfaces in this document are implementation-ready as written.**
