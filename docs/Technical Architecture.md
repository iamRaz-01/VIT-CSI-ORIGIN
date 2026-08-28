# DCA Vault Protocol — Technical Architecture & Engineering Handoff
**CSI ORIGIN 2026, PS-12 — 18-Hour Build**
Principal Solutions Architect deliverable. Source: PM-approved `Features of the Product.txt` (MUST/SHOULD/COULD/REMOVE lists, Product→Architecture Handoff).
 
> **Template note:** The standard package has slots for "Backend/API," "Database," and "AI/ML Contract." This system has no backend, no database, and no AI/ML in MVP scope (confirmed below). Those slots are relabeled **Contract Interfaces**, **On-Chain Storage Schema**, and **Decision Engine Spec** — same content requirement, correct medium.
 
---
 
## 1. Executive Decision
 
The MVP is a **pure on-chain system — no backend, no database.** All state (vault shares, per-user constraints, decision history) lives in three Solidity contracts: `DCAVault` (ERC-4626), `DCACoordinator`, `DCAHook`. They deploy to a **local Anvil fork of Base mainnet**, which gives the team a real, audited Uniswap v4 `PoolManager` and real Aave v3 for genuine yield, with **zero live network dependency once forked** — the single biggest lever on demo reliability. `DCACoordinator` is the only privileged caller of the vault and the pool: it computes a deterministic, side-effect-free decision (execute-full / execute-partial / delay) from TWAP deviation + urgency, then withdraws and swaps atomically through the `PoolManager`'s `unlock`/`unlockCallback` pattern. `DCAHook` is a second, independent line of defense — it re-derives each user's bounds from trusted on-chain state (never trusts caller-supplied swap data) and reverts any swap that breaches tranche or slippage limits, closing the gap between decision-time and settlement-time. A thin frontend (SHOULD HAVE) reads chain state directly by RPC; nothing else is required to prove the core value.
 
---
 
## 2. Requirement Triage — Facts, Assumptions, Open Questions
 
**FACTS (from PM doc, non-negotiable):**
- 7 MUST HAVE features, atomic withdraw+swap, Uniswap v4 hook enforcement, permissionless poke, ≥2 concurrent users, deterministic (non-ML) decision engine on TWAP deviation + urgency only.
- No AI/ML in MVP core (Product→AI/ML Handoff is explicit and conditional-only).
- No KYC, no multi-token, no keeper network, no MEV mitigation, no admin dashboard.
 
**ASSUMPTIONS (stated explicitly, materially affect the plan below):**
| # | Assumption | Why it's safe to assume and proceed |
|---|---|---|
| A1 | Team of 3–4, able to split Solidity contract work from frontend work in parallel | Not specified anywhere in context; the plan below gives both a parallel-team and a solo-fallback critical path (§17) so this doesn't block |
| A2 | Target chain: **Base** (mainnet fork for dev/demo; Base Sepolia as optional public deployment) | Confirmed: Uniswap v4 `PoolManager` is deployed on Base (chain 8453) and Base Sepolia (84532); Aave v3 is deployed and active on Base. Cheap gas, large hackathon tooling ecosystem. Arbitrum is the fallback (also confirmed v4 + Aave v3) if Base RPC/fork access is unreliable on-site |
| A3 | Deposit/yield asset = USDC (real, Aave-listed); demo swap counter-asset = a fresh mock ERC-20 the team deploys and controls | Lets the vault earn **real** Aave yield while keeping the swap pool's price fully controllable for a repeatable live demo (see §13) |
| A4 | Judging requires a **live local demo**, not necessarily a persistent public deployment | See Open Question O2 — architecture supports either with the same codebase |
| A5 | Default numeric thresholds (deviation bands, slippage cap, tranche flex) are **placeholders the team tunes** against their actual seeded pool, not fixed product requirements | PM doc specifies the two-signal *structure*, not exact numbers — tuning is an implementation task, not a scope change |
 
**OPEN QUESTIONS (don't block — proceed on the assumption, confirm when convenient):**
- **O1 — Team composition/skill split.** Materially changes §17 wall-clock. Assumed A1.
- **O2 — Does the judging rubric require an inspectable public testnet deployment** in addition to the live demo? If yes, add ~1h to §15 (Phase 8) to also deploy the identical bytecode to Base Sepolia. Assumed "local-fork-primary, public deployment optional" — cheap to add later since the contracts don't change.
- **O3 — Exact deviation/slippage thresholds.** Assumed defaults in §9; sanity-check against real seeded-pool depth during Phase 8, not before — this is a 10-minute calibration task, not a design blocker.
 
---
 
## 3. Feature → Architecture Mapping
 
| # | Feature | System Capability | Owning Component | Data | Interface | Depends On | Complexity | Failure Risk |
|---|---|---|---|---|---|---|---|---|
| 1 | Deposit & Vault (ERC-4626) | Yield-bearing custody | `DCAVault` + `IYieldStrategy` | `shares[user]`, strategy balance | ERC-4626 `deposit/withdraw/redeem` | — | 2–4h | **Aave integration instability** — mitigated by swappable strategy (§6.3) |
| 2 | Bounded Constraints | Per-user guardrails | `DCACoordinator` | `Constraints` struct per user | `setConstraints()` | 1 | <1h | Under-scoped params weaken "bounded autonomy" claim — full struct in §8 |
| 3 | Decision Engine | Deterministic 3-way decision | `DecisionEngine` library (pure fn) | none (stateless) | `decide()` | 2 | 1–2h | Over-engineering signal set — **rejected**, TWAP-deviation + urgency only per PM doc |
| 4 | Atomic Coordinator | Withdraw+swap atomicity | `DCACoordinator` | tx-scoped | `unlockCallback()` | 1, 3, 5 | 3–4h | **Revert-semantics bug** — highest silent-bug risk in the build; isolated unit test required (§16) |
| 5 | v4 Hook | Execution-time enforcement | `DCAHook` | reads `Coordinator.getConstraints()` | `beforeSwap`/`afterSwap` | 4 | 2–3h | Hook address mining is fiddly — de-risked via `v4-template` + `HookMiner` (§6.2) |
| 6 | Poke function | Triggers the loop | `DCACoordinator` | none | `poke(address user)` | 2, 3 | <1h | Low — resolved decision, no keeper network |
| 7 | Multi-user demo | Isolation proof | *(no new component — a design rule)* | all mappings keyed by `address` | — | 1–6 | <1h | Low — discipline, not engineering |
| 8 | Before/After comparison | Legibility | Off-chain script/frontend | event logs | `getLogs()` replay | 1–7 | 1–2h | SHOULD HAVE — cut first if behind |
| 9 | Minimal frontend | Narratable demo | Static React page | RPC reads | direct `viem`/`ethers` calls | 1–7 | 2–4h | SHOULD HAVE — CLI fallback rehearsed regardless |
| 10 | User withdrawal | Custody hygiene | `DCAVault` | — | ERC-4626 `withdraw()` | 1 | <30min | COULD HAVE — near-free once Vault exists |
 
**CRITICAL:** 1, 2, 3, 4, 5, 6 — nothing demoable without all six.
**IMPORTANT:** 7 (multi-user is a PM non-negotiable, but it's near-zero marginal engineering if 1–6 are built correctly).
**OPTIONAL:** 8, 9, 10 — build only after 1–7 are integration-tested end-to-end.
 
---
 
## 4. Architecture Diagram + Critical Demo Path
 
```
                    ┌────────────────────┐
                    │  Frontend (SHOULD)  │   direct RPC reads, no backend
                    │  status view + poke │
                    └──────────┬─────────┘
                               │ read-only calls / poke() tx
                               ▼
        ┌───────────────────────────────────────────────┐
        │              DCACoordinator                    │
        │  Constraints[user] · lastDecision[user]         │
        │  poke(user) → DecisionEngine.decide() (pure)    │
        │       → DELAY: no-op, return                    │
        │       → EXECUTE: unlock() ──────────────┐       │
        └───────────────┬───────────────┬─────────┼───────┘
                         │               │         │
                withdrawForExecution     │   unlockCallback
                         │               │         │
                         ▼               │         ▼
              ┌────────────────┐         │  ┌──────────────────┐
              │   DCAVault      │        │  │  PoolManager (v4) │
              │   (ERC-4626)    │        │  │  singleton, flash  │
              │   shares[user]  │        │  │  accounting        │
              └────────┬────────┘        │  └─────────┬─────────┘
                       │                 │            │ beforeSwap/afterSwap
                       ▼                 │            ▼
              ┌────────────────┐         │  ┌──────────────────┐
              │ IYieldStrategy  │         │  │     DCAHook       │
              │ (Aave v3, real) │◄────────┘  │ reads Coordinator. │
              │ real USDC yield │            │ getConstraints()   │
              └────────────────┘            │ enforces tranche +  │
                                             │ slippage caps       │
                                             │ REVERTS on breach    │
                                             └──────────────────┘
```
 
**Critical Demo Path (must run live, no slides — mirrors PM doc exactly):**
 
```
Deposit (User A, User B, different Constraints)
   → poke(A) in a GOOD market state  → DELAY/PARTIAL/FULL correctly chosen, executed atomically
   → poke(A) in a state that breaches A's slippage bound → Hook REVERTS, vault position unchanged
   → poke(B) with a different Constraints set, same market snapshot → different logged outcome than A
   → [if time: show $ delta vs. naive scheduled bot from event logs]
```
 
---
 
## 5. System Components
 
| Component | Purpose | Input | Output | Dependencies | Failure Behavior |
|---|---|---|---|---|---|
| `DCAVault` | Per-user yield-bearing custody (ERC-4626) | deposit/withdraw calls | shares, `totalAssets()` | `IYieldStrategy` | Reverts whole-tx on strategy failure; no partial state |
| `AaveYieldStrategy` | Real yield via Aave v3 | `supply`/`withdraw` | interest-bearing balance | Aave v3 `Pool` (forked) | Reverts propagate to Vault; swappable behind interface |
| `MockYieldStrategy` | Fallback linear accrual | time elapsed | simulated yield | none | Always succeeds; used only if Aave proves unstable |
| `DCACoordinator` | Constraints storage, decision trigger, atomic execution | `poke(user)`, `setConstraints()` | state change + events | `DCAVault`, `PoolManager`, `DecisionEngine` | `nonReentrant`; no-ops cleanly if ineligible; never holds user funds outside a single tx |
| `DecisionEngine` | Pure deterministic rule | deviationBps, daysUntilDeadline, Constraints | Action + trancheBps | none (stateless library) | Cannot fail except on malformed input (validated upstream) |
| `DCAHook` | Last-line execution enforcement | swap params + hookData(user) | allow or revert | `DCACoordinator` (read-only) | Reverts the *entire* atomic tx, not just the swap — vault state is untouched |
| Frontend (SHOULD) | Narratable status view | RPC reads | balances, constraints, history | none (no backend) | Falls back to `cast`/Foundry console script (rehearsed) |
 
**No components built:** API Gateway, Authentication service, Authorization service, Cache, Message queue, Search, general-purpose database, background worker. None are justified — see §20.
 
---
 
## 6. Key Architectural Decisions
 
### 6.1 — No backend, no database
**REQUIREMENT:** Serve per-user state and business logic for a wallet-based, on-chain protocol.
**CHOSEN:** All state on-chain; frontend (if built) talks directly to contracts via RPC.
**WHY:** Every piece of state the product needs (shares, constraints, decisions) is already a contract's job to hold reliably and auditably — a database would be a second, unsynchronized source of truth for no benefit.
**ALTERNATIVE CONSIDERED:** Indexer/subgraph + Postgres for "decision history." Rejected — events + `getLogs()` cover the SHOULD-HAVE frontend need with zero extra infrastructure.
**RISK:** None material. **VERDICT: PROCEED.**
 
### 6.2 — Local Anvil fork of Base mainnet for dev *and* demo
**REQUIREMENT:** Real Aave yield + real Uniswap v4 PoolManager, with zero live-network dependency during the actual judged demo.
**CHOSEN:** `anvil --fork-url $BASE_RPC --fork-block-number <pinned> --code-size-limit 40000`, run once, then treated as a fully local chain for the rest of the hackathon (Anvil caches fetched state; no further calls to the RPC provider are needed after the fork).
**WHY:** Gets audited, already-deployed Aave v3 `Pool` and Uniswap v4 `PoolManager` "for free" (confirmed deployed on Base) instead of redeploying/mocking them, while `anvil_impersonateAccount` + `anvil_setBalance` give the team unlimited test USDC and ETH, and `evm_snapshot`/`evm_revert` make the demo **repeatable to a known-good state between runs.**
**ALTERNATIVE:** Fully local deploy-from-scratch (no fork) — deploy your own `PoolManager` + a hand-rolled mock lending pool. Rejected as primary: throws away real, audited Aave logic for no time savings (existing ERC-4626-Aave wrappers already exist — see 6.3) and weakens the "real yield" claim the PM doc explicitly prefers.
**RISK:** Needs one RPC provider API key (Alchemy/Infura/QuickNode free tier) at fork time only. **MITIGATION:** fork early (Phase 1), keep the same Anvil process alive for the rest of the event; `anvil --dump-state` as a belt-and-suspenders snapshot.
**VERDICT: PROCEED.**
 
### 6.3 — Yield strategy is a swappable interface, not a hardcoded Aave call
**REQUIREMENT:** PM doc Feature 1 explicitly flags Aave-integration timing risk and mandates a fallback that is "visibly real, not hardcoded."
**CHOSEN:** `IYieldStrategy{deposit, withdraw, totalAssets, asset}`; `DCAVault.totalAssets()` delegates to the active strategy. Ship `AaveYieldStrategy` first (real yield, adapted from an existing audited pattern — Aave's own `aave/aave-vault`, or BGD Labs' `static-a-token-v3`, or the lighter `AaveV3ERC4626` reference in the `yield-daddy` repo — do **not** write an Aave integration from scratch). Build `MockYieldStrategy` (linear time-based accrual, funded from a small reserve) **in parallel**, not as a rushed afterthought, so a swap is a config change, not a rewrite.
**WHY:** De-risks the single feature the PM doc itself names as highest-risk, at near-zero extra cost (the interface is trivial; the parallel build uses otherwise-idle capacity in Track B).
**KNOWN RISK (from the reference implementations):** aToken donation / share-price-inflation attack on rebasing-balance-based accounting. **MITIGATION:** use OpenZeppelin's `ERC4626` (has built-in decimals-offset inflation protection) rather than a minimal hand-rolled implementation, and seed a small dead-shares first deposit.
**VERDICT: PROCEED — build both strategies in Phase 3, not sequentially.**
 
### 6.4 — Decision engine is a pure, stateless library
**REQUIREMENT:** PM doc Feature 3: "same inputs → same output every time (auditability)."
**CHOSEN:** `DecisionEngine.decide(deviationBps, daysUntilDeadline, Constraints) → (Action, trancheBps)` as an internal pure function in a library, called by `DCACoordinator`. Not a separate deployed contract, not stateful.
**WHY:** Trivial to unit-test exhaustively (all three branches + urgency override) in isolation with zero mocking; directly answers "how do you guarantee determinism" to a technical judge — it's a pure function, provably so.
**ALTERNATIVE:** Inline the logic directly in `DCACoordinator`. Rejected — harder to isolate in tests, no auditability benefit gained.
**VERDICT: PROCEED.**
 
### 6.5 — No on-chain TWAP oracle hook; lightweight rolling reference price instead
**REQUIREMENT:** Decision engine needs a "TWAP deviation" signal (PM doc, explicitly simplified scope).
**FACT (confirmed):** Uniswap v4 removed the built-in oracle that v3 pools had — v4 core ships **no** TWAP functionality; a real manipulation-resistant TWAP (e.g., Uniswap Labs' "Truncated Oracle" pattern) requires building and attaching a *second* hook that records price observations every swap.
**CHOSEN:** `DCACoordinator` reads the pool's current `sqrtPriceX96` via `StateLibrary.getSlot0()` on each `poke()`, and maintains its own simple checkpointed rolling reference price (updated once per poke, not a full observation array). Deviation = current spot vs. this rolling reference, in bps.
**WHY:** A full truncated-oracle hook is 2–4h of *additional*, non-critical-path engineering (a second hook, a second address-mining exercise) for a manipulation-resistance property that doesn't matter on a single-LP demo pool the team itself controls. The PM doc's own risk note for Feature 3 already says "simplify to TWAP deviation + urgency only."
**RISK:** Not manipulation-resistant — acceptable for a self-owned demo pool with no external traders. **State this limitation explicitly to judges as a named simplification with a clear production path** (swap in the Truncated Oracle Hook pattern), not silently.
**VERDICT: PROCEED — DEFER real TWAP oracle to a stated production note.**
 
### 6.6 — Hook trusts on-chain state, never caller-supplied swap data
**REQUIREMENT:** Feature 5's entire value proposition is that enforcement can't be talked around by whoever calls the pool.
**CHOSEN:** `hookData` carries only a `user` address (an identifier, not a claim). `DCAHook.beforeSwap`/`afterSwap` independently calls `DCACoordinator.getConstraints(user)` (a trusted view call) to get the actual bounds, and separately checks `sender == address(coordinator)` (the `sender` param `PoolManager` passes to the hook is the address that called `unlock()`).
**WHY:** If the hook instead trusted numeric bounds embedded in `hookData`, anyone could call the pool directly with fabricated "bounds" and bypass enforcement entirely — the hook would be decorative. Re-deriving from Coordinator storage costs one extra external view call, not extra engineering time.
**SCOPE BOUNDARY (explicit, matches PM doc "out of scope: MEV-specific hook logic"):** This pool is a fresh, isolated pool the protocol creates and controls (§13) — the hook is not attempting to police a shared public liquidity pool against arbitrary third-party traders. That's a materially harder problem, correctly out of scope.
**VERDICT: PROCEED.**
 
---
 
## 7. Contract Interfaces
 
```solidity
// ---------- IYieldStrategy ----------
interface IYieldStrategy {
    function deposit(uint256 assets) external returns (uint256 deposited);
    function withdraw(uint256 assets, address receiver) external returns (uint256 withdrawn);
    function totalAssets() external view returns (uint256);
    function asset() external view returns (address);
}
 
// ---------- Constraints (Feature 2) ----------
struct Constraints {
    uint64  minFrequencyDays;
    uint64  maxDelayDays;
    uint16  goodDeviationBps;     // decision-engine input band
    uint16  badDeviationBps;      // decision-engine input band
    uint16  trancheFlexMinBps;    // e.g. 5000 = 50% of standardTranche
    uint16  trancheFlexMaxBps;    // e.g. 10000 = 100%
    uint256 standardTrancheAmount;
    uint16  maxSlippageBps;       // HARD cap, enforced by DCAHook, distinct from the bps above
}
 
// ---------- DecisionEngine (pure library, Feature 3) ----------
library DecisionEngine {
    enum Action { DELAY, EXECUTE_PARTIAL, EXECUTE_FULL }
 
    function decide(
        int256 deviationBps,
        int256 daysUntilDeadline,
        Constraints memory c
    ) internal pure returns (Action action, uint16 trancheBps);
}
 
// ---------- IDCACoordinator (Features 2, 4, 6) ----------
interface IDCACoordinator {
    function setConstraints(Constraints calldata c) external;
    function poke(address user) external;                                  // permissionless, Feature 6
    function getConstraints(address user) external view returns (Constraints memory); // trusted read, used by DCAHook
    function lastDecision(address user) external view returns (
        DecisionEngine.Action action, uint256 timestamp, uint256 amountIn, uint256 amountOut
    );
    event DecisionMade(address indexed user, DecisionEngine.Action action, int256 deviationBps, uint256 timestamp);
    event ExecutionCompleted(address indexed user, uint256 amountIn, uint256 amountOut);
    event ExecutionRejectedByHook(address indexed user, string reason);
}
 
// ---------- DCAHook (Feature 5) ----------
// extends BaseHook (v4-periphery). Permissions: beforeSwap = true, afterSwap = true, all else false.
interface IDCAHookView {
    function coordinator() external view returns (address);
}
```
 
### Illustrative pseudocode — the two highest-risk integration points
 
**Coordinator's atomic execute (unlock/callback pattern):**
```solidity
function poke(address user) external nonReentrant {
    require(_isEligible(user), "not eligible");                    // safe no-op, Feature 6 acceptance criterion
    (int256 dev, int256 urgencyDays) = _readMarketSignal(user);
    (DecisionEngine.Action action, uint16 trancheBps) =
        DecisionEngine.decide(dev, urgencyDays, constraints[user]);
    _recordDecision(user, action, dev);
    if (action == DecisionEngine.Action.DELAY) return;              // clean no-op — no swap ever attempted
 
    uint256 amountIn = constraints[user].standardTrancheAmount * trancheBps / 10000;
    poolManager.unlock(abi.encode(user, amountIn));                 // → triggers unlockCallback below
}
 
function unlockCallback(bytes calldata data) external returns (bytes memory) {
    require(msg.sender == address(poolManager), "only pool manager");
    (address user, uint256 amountIn) = abi.decode(data, (address, uint256));
 
    vault.withdrawForExecution(user, amountIn);                     // pulls tokens into this contract
    BalanceDelta delta = poolManager.swap(poolKey, _swapParams(amountIn), abi.encode(user)); // hookData = user only
    _settle(delta);                                                 // pay owed / take owed per flash-accounting rules
    _creditUserOutput(user, delta);
    emit ExecutionCompleted(user, amountIn, _outAmount(delta));
    return "";
}
```
 
**Hook — reads trusted state, not caller-supplied bounds:**
```solidity
function _beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData)
    internal override returns (bytes4, BeforeSwapDelta, uint24)
{
    require(sender == address(coordinator), "untrusted caller");
    address user = abi.decode(hookData, (address));
    Constraints memory c = coordinator.getConstraints(user);        // trusted, not caller-supplied
 
    uint256 amountIn = _abs(params.amountSpecified);
    require(amountIn <= c.standardTrancheAmount * c.trancheFlexMaxBps / 10000, "tranche cap breached");
    return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
}
 
function _afterSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
    internal override returns (bytes4, int128)
{
    address user = abi.decode(hookData, (address));
    Constraints memory c = coordinator.getConstraints(user);
    require(_priceImpactBps(delta) <= c.maxSlippageBps, "slippage cap breached"); // reverts whole tx — vault untouched
    return (BaseHook.afterSwap.selector, 0);
}
```
*(Illustrative — engineers still fill in exact `settle`/`take` calls per the flash-accounting API, `_abs`/`_priceImpactBps` helpers, and error types.)*
 
---
 
## 8. On-Chain Storage Schema
 
| Contract | Mapping / Field | Key | Value | Purpose |
|---|---|---|---|---|
| `DCAVault` | inherited ERC-4626 `balanceOf` | `user` | shares | Per-user vault position (Feature 1) |
| `DCAVault` | `strategy` | — | `IYieldStrategy` | Swappable yield backend (§6.3) |
| `DCACoordinator` | `constraints` | `user` | `Constraints` | Feature 2 |
| `DCACoordinator` | `lastPokeTimestamp` | `user` | `uint256` | Eligibility / frequency check |
| `DCACoordinator` | `lastDecision` | `user` | `(Action, timestamp, amountIn, amountOut)` | Feature 9 status view, no indexer needed |
| `DCACoordinator` | `referencePrice` | `poolId` | `uint160 sqrtPriceX96` | Rolling reference for deviation (§6.5) |
| `DCAHook` | *(none — stateless, reads Coordinator)* | — | — | Trust model (§6.6) |
 
**Rule (this is the entire technical answer to Feature 7):** every piece of mutable per-user state is `mapping(address => X)`. No singleton globals, anywhere. Two users with different `Constraints` and the same market snapshot mechanically produce different `lastDecision` entries — that's the whole "multi-user" proof; it needs no dedicated component.
 
**Full decision history** (not just "last"): emitted via `DecisionMade`/`ExecutionCompleted`/`ExecutionRejectedByHook` events, read back with `getLogs()` — no subgraph, no indexer, matches Role's observability minimum without extra infrastructure.
 
---
 
## 9. Decision Engine Spec
 
Four distinct numbers are in play — keep them separate when explaining to judges:
 
| Signal | Consumed by | Role |
|---|---|---|
| TWAP deviation (bps) | `DecisionEngine.decide()` | *soft* input — should we act at all, and how big |
| Urgency / days-until-maxDelay | `DecisionEngine.decide()` | *soft* input — overrides caution as deadline approaches |
| Tranche cap | `DCAHook.beforeSwap` | *hard* enforcement — was the attempted amount within bounds |
| Slippage / price-impact cap | `DCAHook.afterSwap` | *hard* enforcement — was the actual execution within bounds |
 
**Rule (ASSUMED default thresholds — tune in Phase 8 against the real seeded pool, §2 O3):**
 
```
decide(deviationBps, daysUntilDeadline, c):
    if daysUntilDeadline <= 0:                         # hard bound: never breach user's own max-delay
        return (EXECUTE_FULL, 100%)
    absDev = |deviationBps|
    if absDev <= c.goodDeviationBps (default 100):      # ~1% — favorable/neutral
        return (EXECUTE_FULL, 100%)
    if absDev >= c.badDeviationBps (default 300):        # ~3% — unfavorable
        if daysUntilDeadline <= 1:                        # urgency override, still bounded
            return (EXECUTE_PARTIAL, trancheFlexMinBps)
        return (DELAY, 0%)
    # middle band — linear interpolation
    frac = (absDev - goodDeviationBps) / (badDeviationBps - goodDeviationBps)
    return (EXECUTE_PARTIAL, trancheFlexMaxBps - frac * (trancheFlexMaxBps - trancheFlexMinBps))
```
 
This is deterministic and pure — same inputs always produce the same output (PM doc's explicit auditability requirement), and it directly produces the two demo states Feature 3 requires: a "good" snapshot → `EXECUTE_FULL`; a "bad" snapshot inside the max-delay window → `DELAY`.
 
**AI/ML boundary (per PM doc's conditional handoff — not built in MVP):** if the AI/ML specialist produces a bounded, validated volatility-forecast score, the *only* legitimate integration point is as an **additional optional argument** to `decide()` that nudges `trancheBps` within the already-computed band — it never selects the Action itself and never replaces this function. Not required; not started unless that condition is met.
 
---
 
## 10. Security
 
| Control | Implementation |
|---|---|
| Reentrancy | `nonReentrant` on `poke()` / `unlockCallback` path |
| Hook trust model | §6.6 — re-derives bounds from `Coordinator` state, checks `sender` |
| Permissionless-but-safe poke | `poke()` caller never receives funds; output always credited to the target `user`, never to `msg.sender` |
| Access control | Only position owner can `setConstraints()` or call user-initiated withdraw (Feature 10); `poke()` intentionally open (Feature 6) |
| Input validation | `setConstraints()` rejects `minFrequencyDays == 0`, `maxDelayDays == 0`, `trancheFlexMinBps > trancheFlexMaxBps`, `maxSlippageBps` above a sane ceiling |
| ERC-4626 inflation attack | Use OpenZeppelin's `ERC4626` (built-in decimals-offset protection) + dead-shares seed deposit |
| Aave donation/rebasing risk | Documented in §6.3; mitigated the same way |
| Secrets | `.env` gitignored; fork RPC key + burner deployer key only, never a funded key; no real user funds ever touch these contracts |
| Prompt injection / AI abuse | N/A — no LLM/AI component in this system |
 
---
 
## 11. Reliability & Failure Modes
 
| Failure | Impact | Response | Fallback |
|---|---|---|---|
| Decision engine returns `DELAY` | No execution this poke | Vault unchanged, event logged | **This is a success case, not a failure** |
| Hook reverts at settlement | Withdraw+swap tx reverts | Whole tx reverts, vault position fully unchanged (atomicity) | By design — see §13 for how to demo this reliably |
| Aave `supply`/`withdraw` reverts | Vault op reverts | No partial state | Swap `IYieldStrategy` → `MockYieldStrategy` (§6.3), zero downstream changes |
| Fork RPC unavailable mid-event | Can't re-fork | N/A after initial fork — Anvil is local from then on | Pin fork block in Phase 1; keep the same Anvil process alive; `anvil --dump-state` as backup |
| `poke()` on ineligible user | Would execute early | No-op with clear revert reason, no state change | Covered by unit test |
| Double `poke()` race | Double execution | `nonReentrant` + eligibility re-checked inside the atomic tx | Unit test: rapid double-call |
| Frontend fails live | Can't narrate visually | N/A — CLI fallback | Rehearsed `cast call` / Foundry console script (Phase 9) |
 
---
 
## 12. Performance & Cost
 
**Performance:** Non-issue at this scale (≤2 users, single pool, local chain) — no optimization work is justified; don't spend time here.
**Cost:** Effectively $0. No cloud hosting (no backend). Only cost is one RPC provider free-tier key for the initial fork. If a public testnet deployment is also produced (O2), gas is free testnet ETH from a faucet.
 
---
 
## 13. Deployment & Demo Environment Strategy
 
```
anvil --fork-url $BASE_RPC_URL --fork-block-number <PIN> --code-size-limit 40000
```
- **Chain:** Base mainnet fork (§6.2). `--code-size-limit 40000` is required — Anvil's default size limit is too small for v4 contracts and is a documented, easy-to-lose hour if skipped.
- **Assets:** real USDC (impersonate a whale via `anvil_impersonateAccount` + `anvil_setBalance` to fund two demo wallets) as the vault's deposit/yield asset; a freshly deployed mock ERC-20 as the pool's counter-asset (§2 A3). This gets real Aave yield *and* a pool the team can move the price of cheaply and predictably.
- **Pool:** the team creates its **own, isolated** v4 pool for USDC/mockToken with `DCAHook` attached — not a shared public pool. This is why it's acceptable for the hook to gate every swap through it (§6.6).
- **Demo-critical scripts:**
  - `SeedPool.s.sol` — initializes the pool at a starting price, adds initial liquidity.
  - `MoveMarket.s.sol` — executes swaps against the pool to manufacture a "bad deviation" state on demand, and to move it back for a "good" state — makes both demo branches deterministic and repeatable, not dependent on real market timing.
  - **How to reliably demo the Hook rejection (Feature 5 success metric):** don't try to stage a real race condition. Instead, temporarily configure one user's `maxSlippageBps` tight enough that even a legitimately `EXECUTE_FULL`-decided swap trips the hook's slippage cap at settlement. This is not faking anything — it's exercising the real enforcement path with a real (if strict) user configuration, and it's fully reproducible.
- **Repeatability:** `evm_snapshot` immediately after seeding; `evm_revert` before every rehearsal and before the live run.
- **Open Question O2:** if a public, judge-inspectable deployment is also required, deploy the identical contracts to **Base Sepolia** in Phase 8 — same codebase, no architecture change, budget +1h.
 
---
 
## 14. Repository Structure
 
```
/project
  /src
    /core
      DCAVault.sol
      DCACoordinator.sol
      DCAHook.sol
    /interfaces
      IYieldStrategy.sol
      IDCACoordinator.sol
    /libraries
      DecisionEngine.sol
    /strategies
      AaveYieldStrategy.sol
      MockYieldStrategy.sol
    /mocks
      MockERC20.sol
  /script
    Deploy.s.sol
    SeedPool.s.sol
    MoveMarket.s.sol
  /test
    DCAVault.t.sol
    DCACoordinator.t.sol          # atomicity/revert test lives here
    DCAHook.t.sol
    DecisionEngine.t.sol           # pure-function unit tests, all branches
    Integration.t.sol              # 2-user, end-to-end
  /frontend                        # SHOULD HAVE — independent Track D
    /src
    package.json
  foundry.toml
  .env.example
  README.md
```
Foundry-based, following the `Uniswap/v4-template` layout — the canonical, actively-maintained starting point for v4 hook development (Foundry stable, `HookMiner` + `CREATE2_DEPLOYER` deployment scripts included).
 
---
 
## 15. Implementation Plan (Phases)
 
| Phase | Content | Est. |
|---|---|---|
| 1 — Foundation | `v4-template` clone, deps, `.env`, fork Anvil at pinned block, verify PoolManager + Aave `Pool` respond | 1–1.5h |
| 2 — Interfaces/skeleton | `IYieldStrategy`, `IDCACoordinator`, `Constraints` struct, empty contracts, `MockERC20` — **freeze interfaces here** | ~1h |
| 3 — Vault + Yield (Track B) | `DCAVault` (OZ ERC-4626) + `AaveYieldStrategy` (adapted from an existing reference wrapper) + `MockYieldStrategy` in parallel | 2h |
| 4 — Coordinator + Decision Engine (Track A) | `DecisionEngine` pure lib, `Constraints` storage/validation, `poke()`, `unlockCallback` | 3–4h |
| 5 — Hook (Track C) | `DCAHook` before/afterSwap, `HookMiner` deployment script, pool init | 2–3h |
| 6 — Integration | Wire Vault ↔ Coordinator ↔ Hook end-to-end, 1 user | 1.5h |
| 7 — Testing | Atomicity/revert test, hook-rejection test, decision-engine branch tests, 2-user isolation test | 1.5–2h |
| 8 — Deploy/seed | Run deploy scripts on the fork, fund wallets, seed pool, snapshot, calibrate O3 thresholds | 1h |
| 9 — Harden/rehearse | Force-fail the hook live, verify vault unchanged, rehearse `MoveMarket` + full script twice | 1–1.5h |
| 10 — Frontend + comparison (Track D, runs concurrently with 3–9) | Status view, poke button, before/after delta calc | 2–4h, cut first if behind |
 
Any phase estimated 4+h (none currently are) would need an explicit challenge per Role §21 — none crossed that line once split into parallel tracks.
 
---
 
## 16. Time Budget
 
| Component | Estimate |
|---|---|
| Foundation/env | 1–1.5h |
| Interfaces/skeleton | <1h |
| Vault + yield (both strategies) | 1–2h |
| Coordinator + decision engine | 2–4h |
| Hook + address mining | 2–3h |
| Integration | 1–2h |
| Testing | 1–2h |
| Deploy/seed | <1h |
| Harden/rehearse | 1–2h |
| Frontend + comparison | 2–4h |
 
---
 
## 17. Critical Path
 
```
Fork + Foundation
   ↓
Interfaces frozen  ─────────────────────────────────┐
   ↓                                                  │ (Track D can start
   ├── Track A: Coordinator + Decision Engine ──┐     │  here, converges
   ├── Track B: Vault + Yield strategies ────────┤     │  at Integration)
   └── Track C: Hook + address mining ───────────┘     │
   ↓ (longest of A/B/C — Track A, ~3.5h)               │
Integration (needs A+B+C) ◄─────────────────────────────┘
   ↓
Deploy + Seed
   ↓
Test (atomicity + hook-rejection are CRITICAL PATH; others parallelizable)
   ↓
Harden + Rehearse
   ↓
END-TO-END DEMO
```
 
**With a 3–4 person team (Assumption A1), wall-clock for the core system (Phases 1–9) is ~11–12h**, not the ~16–17h a naive serial sum would suggest — the compression comes entirely from Tracks A/B/C running simultaneously once interfaces are frozen at the end of Phase 2, and Track D (frontend) running the whole time in the background. That leaves real buffer for hardening and rehearsal, which is where hackathon demos actually get won or lost.
 
**Solo/2-person fallback:** if the team is smaller than assumed, the critical path lengthens to ~16–17h serial. In that case: build Phases 1–7 in the exact order shown (skip Track parallelism), and **cut Phase 10 (frontend + comparison) immediately** — the PM doc explicitly allows narrating from Foundry console / block explorer instead.
 
---
 
## 18. Parallel Workstreams
 
| Track | Owner | Deliverable | Depends On | Interface Contract | Start Condition | Done Condition |
|---|---|---|---|---|---|---|
| A — Coordinator + Decision Engine | Solidity eng. | `DCACoordinator`, `DecisionEngine` | Phase 2 interfaces | `IDCACoordinator` | Interfaces frozen | `poke()` correctly atomic + tested |
| B — Vault + Yield | Solidity eng. | `DCAVault`, both strategies | Phase 2 interfaces | `IYieldStrategy` | Interfaces frozen | Deposit/withdraw against real Aave (forked) works |
| C — Hook | Solidity eng. | `DCAHook` + deploy script | Phase 2 interfaces, Track A's `getConstraints()` signature | `beforeSwap`/`afterSwap` | Interfaces frozen | Mined address deploys; rejects a deliberately-bad swap |
| D — Frontend + demo tooling | Frontend/any eng. | Status view, `MoveMarket.s.sol`, comparison calc | Phase 2 interfaces (ABI-level) | read-only RPC calls | Interfaces frozen | Runs the full demo narrative without touching a block explorer |
| E — Environment | Any eng. | Fork setup, deploy scripts, `.env` | none | — | Immediately (Phase 1) | Pinned fork stable, CREATE2 deployer present |
 
---
 
## 19. Red Team
 
| Risk | Impact | Mitigation | Owner | Priority |
|---|---|---|---|---|
| Hook address mining fails / wrong permission bits | Pool can't be initialized with the hook | Use `v4-template`'s `HookMiner` exactly as documented; verify flags with a unit test before touching the pool | Track C | **CRITICAL** |
| Revert semantics wrong in `unlockCallback` (deltas not settled) | Silent fund-stuck bug, or tx never succeeds | Isolated Foundry test asserting vault balance unchanged after a forced-failure swap (PM doc's own named highest risk) | Track A | **CRITICAL** |
| Aave integration unstable close to demo | Feature 1's yield story breaks | `MockYieldStrategy` built in parallel, same interface, swap is a one-line config change | Track B | HIGH |
| Fork RPC key rate-limited/unavailable | Can't fork at all | Fork once, early, in Phase 1; keep the process running; free-tier keys from 2+ providers as backup | Track E | MEDIUM |
| Hook enforces on unintended swaps | Breaks demo pool's own operation | Dedicated, isolated pool — no shared liquidity, no third-party traders (§6.6 scope boundary) | Track C | MEDIUM |
| Decision-engine thresholds don't match seeded pool's realistic price range | Can't manufacture a "bad" state cheaply for the demo | Calibrate O3 thresholds against the actual seeded pool in Phase 8, not before | Track A/E | MEDIUM |
| Frontend eats the schedule | Core loop untested at the deadline | SHOULD HAVE, built on an independent track, cut without affecting 1–7 if behind | Track D | LOW |
 
---
 
## 20. Simplification Pass
 
| Considered | Verdict | Why |
|---|---|---|
| Real on-chain TWAP oracle hook | **DEFER** | v4 ships no built-in oracle; a manipulation-resistant one is a second hook — not needed on a self-owned demo pool (§6.5) |
| Chainlink price feed as deviation source | **REJECT** | Extra live external dependency for a number the pool itself already provides via `StateLibrary` |
| Backend + database for decision history | **REMOVE** | Events + `getLogs()` fully cover it |
| Subgraph/indexer | **REMOVE** | Same — unjustified infra for a 2-user demo |
| Real keeper network (Chainlink Automation/Gelato) | **REJECT** (PM doc, restated) | Permissionless `poke()` already proves the concept; external dependency risk with no demo upside |
| MEV mitigation | **REJECT** (PM doc, restated) | Unprovable live in 18h, explicitly out of scope |
| Separate deployed contract for the decision engine | **SIMPLIFY** | Internal pure library call is sufficient and cheaper to test |
| Hook trusting caller-supplied bounds | **SIMPLIFY → hardened** | Re-deriving from Coordinator state costs one extra view call, closes a real bypass |
 
The architecture is smaller than a naive first draft: **3 contracts + 1 library**, no backend, no database, no indexer, no second hook.
 
---
 
## 21. Definition of Done
 
A component is done only when implemented, integrated, tested, error-handled, and verified in the actual fork environment — not when code merely exists.
 
**MVP end-to-end done when, live on the forked chain:**
- [ ] User A and User B each deposit USDC → both show growing `totalAssets()` via real Aave yield, independently
- [ ] Both have distinct `Constraints` set
- [ ] `poke(A)` in a "good" market snapshot → `EXECUTE_FULL`, atomic withdraw+swap succeeds, vault + event state updated
- [ ] `poke(A)` (or a tightened-constraint variant) against a bound-violating swap → `DCAHook` reverts, vault position provably unchanged (forced-failure test passes)
- [ ] `poke(B)` on the same market snapshot as A, different `Constraints` → a visibly different logged decision than A's
- [ ] All of the above reproducible from a single `evm_revert` to snapshot — the demo can be re-run without redeploying
- [ ] (SHOULD) Frontend narrates balances/constraints/history without a block explorer
- [ ] (SHOULD) $ delta vs. naive scheduled bot computed from real event logs, not fabricated
 
This is the complete, PM-doc-aligned Critical Demo Path (§4) — nothing beyond it is required to prove the core value.
