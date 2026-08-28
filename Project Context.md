# Project Context (v2 — corrected)
 
## CSI ORIGIN 2026 — Problem Statement 12
**Yield-Optimized DCA Engine via Uniswap v4 Hooks**
 
> Read this document as the single source of truth. Every fact below is traceable to the PS. Every unknown is flagged. Do not introduce fiat/off-chain framing, single-user assumptions, or invented mechanisms not listed here.
 
---
 
## 0. One-Sentence Definition
 
Build an **on-chain, multi-user, autonomous capital-management protocol** that keeps each user's committed-but-unexecuted DCA token capital productive in an **ERC-4626 yield vault**, and dynamically controls **when, how much, and whether** to swap that capital via a **Uniswap v4 Hook-based execution layer**, based on market conditions and execution economics — while never exceeding each user's predefined DCA bounds.
 
This is **not** a scheduled DCA bot and **not** a volatility-filtered swap executor. It is a capital-management layer.
 
---
 
## 1. Domain Framing (corrected)
 
Everything is **ERC-20 tokens on-chain**, not fiat/cash.
 
- "Capital" = a token balance (e.g., USDC) held as **ERC-4626 vault shares**, not currency in an account.
- A DCA "execution" = a **token swap** (e.g., USDC → WETH) through a Uniswap v4 pool.
- There is **no backend cron loop by default**. Smart contracts are reactive — code only runs when a transaction calls it. "Continuous monitoring" must be implemented via one of:
  - an external keeper/automation network (e.g., Chainlink Automation, Gelato) that calls a check-and-execute function on a schedule, **or**
  - logic that runs only when triggered — inside the Uniswap v4 hook callback during a swap, or via a permissionless "poke" function anyone can call.
  - **This choice is an open architecture decision (see §7) — resolve it before building.**
 
❌ Do not model this as a fiat SIP with a ₹/$ balance and a background timer. That is the wrong mental model and will misdirect vault and hook design.
 
---
 
## 2. Actors
 
- **Multiple users**, each depositing into the protocol independently (PS: *"allow users to deposit capital"* — plural).
- The protocol must support **per-user**:
  - deposit balance / vault shares
  - DCA schedule (frequency, target allocation)
  - strategy constraint parameters (max delay, min/max tranche size, etc.)
- Vault yield and execution decisions must be computed **per user position**, not pooled as one undifferentiated balance. (ERC-4626 gives you shared pooled yield infrastructure — but DCA eligibility, tranche sizing, and execution timing are user-specific.)
 
❌ Do not design around a single depositor with one global balance.
 
---
 
## 3. Core Problem (unchanged from PS, restated precisely)
 
Two inefficiencies:
1. **Idle capital** — token capital reserved for future DCA purchases earns nothing while it waits.
2. **Rigid schedule** — a fixed-time execution can hit bad market conditions (volatility, poor liquidity, high price impact/slippage).
 
Missing capability: an autonomous system that treats each user's un-deployed DCA capital as an **actively managed resource** — continuously deciding whether it should sit in yield or be withdrawn and swapped, and how much.
 
---
 
## 4. Required Components (all mandatory per PS)
 
| Component | Role | PS status |
|---|---|---|
| ERC-4626 yield vault | Holds unused per-user DCA capital, generates yield while waiting | Required, exact vault/strategy unspecified |
| Uniswap v4 pool + Hook | Execution layer for the actual swap; hook enforces execution conditions | Required, exact hook logic unspecified |
| Decision engine | Evaluates market + yield + DCA rules → chooses action | Required, exact formula unspecified |
| Withdrawal/execution coordinator | Pulls only the needed amount from vault, triggers swap, returns remainder to vault | Required, atomicity where applicable |
| Trigger/automation mechanism | Causes evaluation to happen on a cadence | **Required but unspecified — must be designed** (see §7) |
 
---
 
## 5. Hook Semantics (corrected — important)
 
Uniswap v4 hooks are **callbacks that fire at defined points inside a swap transaction** (e.g., `beforeSwap`, `afterSwap`), scoped to a specific pool. A hook **cannot on its own reach into an ERC-4626 vault or initiate a withdrawal** — it only executes in the context of a swap already being called.
 
Correct architecture:
```
Coordinator/Router contract (your custom contract)
   │
   ├── 1. vault.withdraw(requiredAmount, user)   ← ERC-4626 call
   │
   └── 2. poolManager.swap(...)                  ← Uniswap v4 call
             │
             └── Hook.beforeSwap() / afterSwap()  ← enforces conditions:
                    tranche size limits, price/slippage bounds,
                    abort if conditions violated
```
 
- **Atomicity** (PS requirement) comes from steps 1–2 happening in **one transaction** in the coordinator contract — not from the hook itself. If the swap fails validation inside the hook, the whole transaction (including the withdrawal) must revert, so the vault position is never left in an inconsistent state.
- The hook's job: enforce **execution-time conditions** (e.g., reject/adjust if price deviation, slippage, or price impact exceed bounds) at the moment of the swap.
- The **decision** of whether to execute at all, how much, or to delay, can be computed **before** calling the coordinator (off-chain/keeper-side) or partially on-chain — this is a design choice, not dictated by the PS.
 
---
 
## 6. Market Signals to Evaluate (from PS, unchanged)
 
- TWAP / historical price
- Short-term price deviation from reference
- Volatility
- Liquidity depth
- Price impact
- Slippage
- Execution urgency (how overdue is this DCA interval)
 
**Added, not explicit in PS text but required by "execution costs" + on-chain reality:**
- **MEV / sandwich-attack exposure** — a recurring, semi-predictable on-chain swap is a natural MEV target. Must be considered under "execution costs" (PS §Economic Viability) even though not named explicitly. Mitigations (private mempool / commit-reveal / TWAP-based limits) are a design decision, not a PS mandate.
 
---
 
## 7. Decision Space (unchanged from PS)
 
For each eligible DCA interval, per user, the engine chooses one of:
- Execute normally (full planned tranche)
- Execute a smaller tranche
- Delay execution (accumulate, remain in yield)
- (Implicit) accelerate/execute early is **not** granted by the PS — bounded autonomy governs deviations, and the PS frames delay/reduction as the primary lever, not early execution. Treat "execute early" as out-of-scope unless explicitly justified.
 
Decision inputs:
```
Available capital (per user)
+ Yield earned/forgone by waiting
+ Market signals (§6)
+ Execution costs (fees, slippage, price impact, MEV exposure)
+ DCA urgency (how close to violating schedule bounds)
+ User-defined strategy constraints (§8)
→ Action
```
 
---
 
## 8. Bounded Autonomy — Required Per-User Parameters
 
The PS requires "predefined strategy constraints" but does not give values. These must exist as **explicit, user-set parameters** (inferred requirement, not invented feature):
 
- DCA frequency (e.g., every N days)
- Target allocation per interval
- Max allowed delay (hard cap — cannot be skipped indefinitely)
- Max/min tranche adjustment range (how much execution size can flex)
- (Optional, still bounded-autonomy-consistent) volatility/slippage thresholds beyond which the system must delay rather than execute
 
The system **must never**:
- freely time the market outside these bounds
- delay indefinitely
- deviate from the user's overall target allocation trajectory
 
---
 
## 9. Continuous Loop (from PS, annotated with on-chain reality)
 
```
Monitor Capital        → read per-user vault position
Generate Yield          → passive, handled by ERC-4626 vault/strategy
Monitor Market          → read price/TWAP/liquidity — via oracle or pool state,
                           triggered by keeper or on-demand call, NOT a background thread
Evaluate Execution       → decision engine (on-chain view function or off-chain keeper logic)
Determine Optimal Tranche → sizing logic within §8 bounds
Execute / Delay          → coordinator contract: withdraw + swap (atomic), or no-op
Return Remaining Capital → capital not withdrawn stays as vault shares, keeps earning
Repeat                   → next trigger (keeper cadence or user-eligible-interval check)
```
 
---
 
## 10. Explicit Scope
 
**In scope:** per-user DCA capital management, ERC-4626 yield-while-waiting, market-aware execution via Uniswap v4 hooks, dynamic tranche sizing, bounded delay, atomic withdraw+swap, execution-cost accounting (incl. MEV), a defined trigger/automation mechanism.
 
**Out of scope:** unrestricted market timing, general-purpose trading, pure yield maximization (parking forever), a plain scheduled DCA bot, unbounded delay, single-user-only design, fiat/off-chain balance modeling.
 
---
 
## 11. Facts vs. Unknowns (updated)
 
**Facts (from PS, non-negotiable):**
- Multi-user deposits
- ERC-4626 vault mandatory
- Uniswap v4 Hooks mandatory for execution
- Dynamic tranche sizing mandatory
- Only required-for-execution capital withdrawn; rest keeps earning
- Atomic withdraw+swap where applicable
- Bounded autonomy — schedule/allocation preserved
- Execution costs (fees, slippage, price impact, opportunity cost of yield) must factor into the decision
 
**Unknowns (must be decided by the team, not the PS):**
- Exact vault/underlying yield strategy
- Exact token pair / pool
- Exact hook logic and thresholds
- Exact decision formula/weighting
- **Trigger mechanism (keeper vs. reactive) — resolve first, it's architecturally load-bearing**
- Exact per-user constraint defaults/UI
- MEV mitigation approach
 
---
