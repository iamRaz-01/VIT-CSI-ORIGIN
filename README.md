# HookDCA

> **CSI ORIGIN 2026 · Problem Statement 12**

An on-chain, multi-user Dollar-Cost Averaging protocol that keeps committed capital earning yield in an ERC-4626 vault between execution intervals, and uses a deterministic decision engine to decide — on each permissionless trigger — whether to execute a full tranche, a partial tranche, or delay based on TWAP deviation and urgency.

---

## What This Is

Most DCA protocols execute blindly on a fixed schedule: capital sits idle between intervals, and swaps execute regardless of market conditions. ORIGIN solves both problems:

1. **Idle capital earns yield.** User deposits are held in an ERC-4626 vault backed by either Aave v3 (production) or a linear-APR mock (demo/test). Capital works until it is needed for a swap.

2. **Execution is market-aware.** A deterministic three-way decision engine evaluates TWAP deviation against each user's personal bounds and outputs one of: `EXECUTE_FULL`, `EXECUTE_PARTIAL`, or `DELAY`. Bad market conditions are skipped; urgency overrides prevent indefinite deferral.

3. **Atomicity is enforced by design.** The Uniswap v4 hook layer (Track C — pending) enforces tranche size and slippage bounds at swap time. A hook rejection reverts the entire transaction, leaving the vault untouched.

---

## Implementation Status

| Component | Status | Tests |
|-----------|--------|-------|
| `DCAVault` — ERC-4626 per-user vault | ✅ Implemented | 22 pass |
| `IYieldStrategy` — yield backend interface | ✅ Implemented | — |
| `MockYieldStrategy` — linear APR fallback | ✅ Implemented | covered by vault tests |
| `AaveYieldStrategy` — live Aave v3 wrapper | ✅ Implemented | fork-compatible |
| `DecisionEngine` — deterministic decision library | ✅ Implemented | 12 pass (incl. 2 fuzz) |
| `DCACoordinator` — constraints + poke engine | ✅ Implemented | 35 pass |
| `DCAHook` — Uniswap v4 enforcement hook | 🔲 Not yet implemented | 8 skeleton tests |
| Deploy scripts | ⚠️ Skeleton with placeholder stubs | — |
| Full integration test bodies | ⚠️ Skeleton (descriptions present, logic pending) | 12 skeleton tests |

**Total test suite: 89 tests, 89 passing, 0 failing.**

---

## Architecture

```
User
 │
 ├─ deposit(USDC)──────────────────────────────► DCAVault (ERC-4626)
 │                                                    │
 │                                              forwards all assets
 │                                                    │
 │                                                    ▼
 │                                           IYieldStrategy
 │                                      ┌────────────┴────────────┐
 │                                      ▼                         ▼
 │                             AaveYieldStrategy         MockYieldStrategy
 │                             (Aave v3 supply)          (linear APR accrual)
 │
 ├─ setConstraints(c)──────────────────────────► DCACoordinator
 │   - minFrequencyDays                               │
 │   - maxDelayDays                            stores per-user params
 │   - goodDeviationBps / badDeviationBps             │
 │   - trancheFlexMinBps / trancheFlexMaxBps           │
 │   - standardTrancheAmount                           │
 │   - maxSlippageBps                                  │
 │                                                     │
 └─ [anyone] poke(user)─────────────────────────┤
                                                      │
                              _isEligible(user)?      │
                              (frequency gate)        │
                                    │                 │
                                  yes                 │
                                    │                 │
                              DecisionEngine.decide() │
                              (deviationBps,           │
                               daysUntilDeadline, c)  │
                                    │                 │
                         ┌──────────┼──────────┐      │
                         ▼          ▼          ▼      │
                       DELAY    EXECUTE_   EXECUTE_   │
                      (stop)    PARTIAL     FULL      │
                                    │          │      │
                              compute tranche amount   │
                                    │                 │
                              vault.withdrawForExecution(user, amount)
                                    │
                              [Track C — pending]
                              PoolManager.unlock()
                                → unlockCallback()
                                → swap via DCAHook
                                → beforeSwap: check tranche cap
                                → afterSwap:  check slippage cap
                                → settle flash accounting
```

---

## Core Contracts

### `src/core/DCAVault.sol`

Extends OpenZeppelin's `ERC4626`. Key behaviors:

- **`deposit(assets, receiver)`** — pulls USDC from `msg.sender`, transfers all assets to the active `IYieldStrategy` immediately (vault holds zero idle balance), mints proportional shares to `receiver`. Reverts `ZeroAssets()` on zero-amount deposit.
- **`withdrawForExecution(user, assets)`** — callable only by `DCACoordinator`. Burns exactly the shares corresponding to `assets` from `user`'s balance and sends USDC directly to the coordinator. Reverts `Unauthorized()` if caller is not coordinator; reverts `InsufficientBalance()` if `assets` exceeds user's convertible balance.
- **`totalAssets()`** — delegates entirely to `strategy.totalAssets()`. Vault holds no independent underlying balance.
- **`withdraw` / `redeem`** — standard ERC-4626 user-initiated exits; route through `strategy.withdraw()`.
- **`setCoordinator(address)` / `setStrategy(address)`** — deployer-called configuration used in the two-step deployment sequence.

**Invariants enforced by tests:**
- Vault holds zero USDC after deposit (all forwarded to strategy)
- Per-user share balances are fully isolated
- One user's execution withdrawal does not affect another's shares

---

### `src/libraries/DecisionEngine.sol`

A pure Solidity `library` — no storage, no external calls, always deterministic. The `decide()` function implements the following four-branch formula:

```
decide(deviationBps, daysUntilDeadline, Constraints c):

  if daysUntilDeadline <= 0:
      → EXECUTE_FULL, 10000 bps          // deadline passed, no further delay allowed

  absDev = |deviationBps|

  if absDev <= c.goodDeviationBps:
      → EXECUTE_FULL, 10000 bps          // conditions are favourable

  if absDev >= c.badDeviationBps:
      if daysUntilDeadline <= 1:
          → EXECUTE_PARTIAL, trancheFlexMinBps  // urgency override
      → DELAY, 0                                // conditions are bad, not yet urgent

  // middle band: linear interpolation
  frac = (absDev - goodDev) / (badDev - goodDev)
  trancheBps = trancheFlexMaxBps - frac * (trancheFlexMaxBps - trancheFlexMinBps)
  → EXECUTE_PARTIAL, trancheBps
```

The formula is fully auditable from source. Identical inputs always produce identical outputs. No external oracles, no ML, no randomness.

---

### `src/core/DCACoordinator.sol`

Owns the evaluate-and-act loop. Key behaviors:

- **`setConstraints(Constraints c)`** — validates and stores per-user DCA parameters. Storage is keyed exclusively to `msg.sender`. Validates: non-zero frequency, non-zero max delay, flex min ≤ flex max, slippage ≤ 2000 bps ceiling, good deviation ≤ bad deviation, non-zero tranche amount.
- **`poke(user)`** — permissionless; callable by anyone. If the user is ineligible (no constraints set, or `minFrequencyDays` has not elapsed since last poke), the function returns silently — no revert, no state change, no event. When eligible: computes deviation (currently a stub returning `0`), computes urgency, invokes `DecisionEngine.decide()`, records the decision, emits `DecisionMade`, then conditionally calls `vault.withdrawForExecution()` on the execute path. Protected by `ReentrancyGuard`.
- **`lastDecision(user)`** — returns `(action, timestamp, amountIn, amountOut)` for the last recorded decision.
- **`lastPokeTimestamp(user)`** — returns the timestamp of the last eligible poke.
- **`unlockCallback(bytes data)`** — stub for Track C (Hook). Validates `msg.sender == poolManager`. The actual `PoolManager.swap()` and flash-accounting settlement will be wired by the Hook workstream.

**Current limitation:** `_computeDeviationBps()` returns `0` (neutral). Live TWAP deviation requires `StateLibrary.getSlot0()` wiring from Track C.

---

### `src/strategies/AaveYieldStrategy.sol`

Wraps Aave v3 on Base mainnet (forked). On `deposit()`, calls `IPool.supply(asset, amount, address(this), 0)`. USDC is sent to this contract by `DCAVault` before `deposit()` is called. On `withdraw()`, calls `IPool.withdraw(asset, amount, receiver)`, routing USDC directly to the target. `totalAssets()` returns `aToken.balanceOf(address(this))` — Aave's rebasing aToken naturally reflects accrued interest.

The aToken address is resolved once at construction via a low-level `staticcall` on `getReserveData()` (avoiding the stack-too-deep error from its 15-element return tuple).

---

### `src/strategies/MockYieldStrategy.sol`

Deterministic linear APR yield accrual for testing without a live fork. Formula: `yield = principal × annualYieldBps × elapsed / (365 days × 10000)`. Default rate: 500 bps (5% APR), configurable at construction. Yield is snapshotted on each `deposit()` or `withdraw()` call.

---

## User Constraints (`Constraints` struct)

Each user independently configures their DCA behaviour:

| Parameter | Type | Purpose |
|-----------|------|---------|
| `minFrequencyDays` | `uint64` | Minimum interval between poke executions |
| `maxDelayDays` | `uint64` | Hard ceiling — system must execute before this elapses |
| `goodDeviationBps` | `uint16` | Deviation ≤ this → EXECUTE_FULL |
| `badDeviationBps` | `uint16` | Deviation ≥ this → DELAY (unless urgency override fires) |
| `trancheFlexMinBps` | `uint16` | Minimum execution size as fraction of standard tranche (bps) |
| `trancheFlexMaxBps` | `uint16` | Maximum execution size as fraction of standard tranche (bps) |
| `standardTrancheAmount` | `uint256` | Full tranche in USDC (6 decimal units) |
| `maxSlippageBps` | `uint16` | Slippage cap enforced by DCAHook at swap time (max 2000 bps) |

Constraints are stored per `msg.sender`. No user can modify another user's parameters. Validation reverts with `InvalidConstraints(string reason)` on any structural violation.

---

## Test Suite

All tests run with `forge test`. No network connection required for unit tests.

```bash
forge test                                       # all suites
forge test --match-contract DCAVaultTest         # 22 vault unit tests
forge test --match-contract DCACoordinatorTest   # 35 coordinator + decision tests
forge test --match-contract DecisionEngineTest   # 12 pure library tests (no fork)
```

| Suite | Tests | Fork | Description |
|-------|-------|------|-------------|
| `DCAVaultTest` | 22 | No | ERC-4626 deposit/withdraw/yield/multi-user isolation |
| `DCACoordinatorTest` | 35 | No | Constraints validation, eligibility, all decision branches, vault integration, multi-user |
| `DecisionEngineTest` | 12 | No | All formula branches + 2 fuzz runs (256 iterations each) |
| `DCAHookTest` | 8 | Yes | Skeleton — test bodies pending Hook implementation |
| `IntegrationTest` | 12 | Yes | Skeleton — test bodies pending full stack merge |
| **Total** | **89** | — | **89 passing, 0 failing** |

### What the passing tests verify

**DCAVault (22 tests):**
- Deposit mints non-zero shares; zero-deposit reverts `ZeroAssets()`
- All deposited assets are forwarded to strategy immediately (vault holds zero idle USDC)
- Two users' share balances are independent; one user's withdrawal does not affect the other
- `withdrawForExecution` reverts `Unauthorized()` from non-coordinator, `InsufficientBalance()` on over-withdrawal
- Coordinator receives exact requested amount; remaining shares continue accruing yield
- `totalAssets()` grows over time (MockYieldStrategy accrual verified at 5% APR over 365 days)
- Share price initially 1:1; `previewDeposit` matches actual shares minted

**DCACoordinator + DecisionEngine (35 tests):**
- All 6 constraint validation rules fire individually
- `setConstraints` writes only `msg.sender`'s storage; USER_A cannot overwrite USER_B
- DecisionEngine: EXECUTE_FULL on good band and deadline override; EXECUTE_PARTIAL at midpoint (7500 bps verified for 50/50 deviation midpoint); DELAY on bad band when not urgent; urgency override fires at 1 day remaining; negative deviation uses absolute value; deterministic across identical inputs (256 fuzz runs)
- Ineligible `poke` is a clean no-op: no state change, no revert, no event (verified for "no constraints" and "too early")
- Eligible `poke` records `lastPokeTimestamp`, records `lastDecision`, emits `DecisionMade`
- Execute path reduces vault shares, emits `ExecutionCompleted`, delivers USDC to coordinator address
- Permissionless: any caller can trigger poke; output is always credited to the user, not the caller
- Multi-user: independent constraint sets produce different share deltas; User A's poke does not mutate User B
- Deadline override: poke after `maxDelayDays` forces EXECUTE_FULL

---

## Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh/) v1.8.0 or newer (`forge`, `anvil`, `cast`)
- Git

### Install

```bash
git clone <repo-url>
cd VIT-CSI-ORIGIN

# Install Solidity library dependencies
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts
forge install Uniswap/v4-core
forge install Uniswap/v4-periphery
forge install aave/aave-v3-core
```

> **Note:** Currently only `forge-std` and `openzeppelin-contracts` are present in `lib/`. Install `v4-core`, `v4-periphery`, and `aave-v3-core` before running fork-dependent tests.

### Configure Environment

```bash
cp .env.example .env
```

Edit `.env`:

| Variable | Description |
|----------|-------------|
| `BASE_RPC_URL` | Base mainnet RPC endpoint |
| `FORK_BLOCK_NUMBER` | `cast block-number --rpc-url $BASE_RPC_URL` |
| `DEPLOYER_PRIVATE_KEY` | Burner key only — `cast wallet new` |
| `USDC_ADDRESS` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (pre-filled) |
| `AAVE_POOL_ADDRESS` | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` (pre-filled) |
| `POOL_MANAGER_ADDRESS` | `0x498581ff718922c3f8e6a244956af099b2652b2b` (pre-filled) |

### Compile

```bash
forge build
```

### Run Tests

```bash
# Unit tests (no network required)
forge test --match-contract DCAVaultTest -vvv
forge test --match-contract DCACoordinatorTest -vvv
forge test --match-contract DecisionEngineTest -vvv

# All tests (fork-based suites require BASE_RPC_URL in .env)
forge test -vvv
```

### Start Anvil Fork

```bash
bash script/start-fork.sh
```

Starts Anvil at `127.0.0.1:8545` with `--code-size-limit 40000` (required for Uniswap v4 contracts). Reads `BASE_RPC_URL` and `FORK_BLOCK_NUMBER` from `.env` automatically. WSL2 and Windows compatible.

### Deploy to Local Fork

```bash
# Ensure Anvil is running first
forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key $DEPLOYER_PRIVATE_KEY \
  -vvvv
```

> `Deploy.s.sol` is a skeleton — each step currently prints a `[PLACEHOLDER]` log. The full deployment activates once `DCAHook` is implemented.

---

## Deployment Order

| Step | Contract | Depends On |
|------|----------|------------|
| 1 | `MockERC20` (demo counter-asset) | — |
| 2 | `DCAVault` | `USDC_ADDRESS` |
| 3 | `AaveYieldStrategy` or `MockYieldStrategy` | `DCAVault`, `AAVE_POOL_ADDRESS` |
| 4 | `DCACoordinator` | `DCAVault`, `POOL_MANAGER_ADDRESS` |
| 5 | `DCAHook` (mined `CREATE2` address) | `DCACoordinator`, `POOL_MANAGER_ADDRESS` |
| 6 | Pool init via `SeedPool.s.sol` | `DCAHook`, `MockERC20`, `USDC_ADDRESS` |

After steps 2–4, call:
- `vault.setStrategy(yieldStrategy)` — wires the yield backend
- `vault.setCoordinator(coordinator)` — authorizes `withdrawForExecution`

---

## Demo Commands (after deploy)

```bash
# Trigger evaluation for User A
cast send $COORDINATOR_ADDR "poke(address)" $USER_A_ADDR \
  --rpc-url http://127.0.0.1:8545 --private-key $DEPLOYER_PRIVATE_KEY

# Read the last decision
cast call $COORDINATOR_ADDR "lastDecision(address)" $USER_A_ADDR \
  --rpc-url http://127.0.0.1:8545

# Read vault balance
cast call $VAULT_ADDR "balanceOf(address)" $USER_A_ADDR \
  --rpc-url http://127.0.0.1:8545

# Drive market to good/bad state for demo
forge script script/MoveMarket.s.sol --sig "moveGood()" \
  --rpc-url http://127.0.0.1:8545 --broadcast --private-key $DEPLOYER_PRIVATE_KEY
forge script script/MoveMarket.s.sol --sig "moveBad()" \
  --rpc-url http://127.0.0.1:8545 --broadcast --private-key $DEPLOYER_PRIVATE_KEY

# Snapshot / revert for repeatable demo replay
SNAPSHOT_ID=$(cast rpc evm_snapshot --rpc-url http://127.0.0.1:8545)
cast rpc evm_revert $SNAPSHOT_ID --rpc-url http://127.0.0.1:8545
```

---

## Technology Stack

| Layer | Technology |
|-------|-----------|
| Smart contract language | Solidity `^0.8.26` |
| Development framework | Foundry v1.8.0 |
| ERC-4626 base | OpenZeppelin Contracts v5.7.0 |
| Yield source (production) | Aave v3 on Base mainnet |
| Swap execution layer | Uniswap v4 (PoolManager + hooks) |
| Target chain | Base mainnet (chain ID 8453) |
| Fork testing | Anvil pinned to Base mainnet |

---

## Repository Structure

```
src/
├── core/
│   ├── DCAVault.sol           ← ERC-4626 per-user yield vault          [IMPLEMENTED]
│   └── DCACoordinator.sol     ← Constraints, poke, decision integration [IMPLEMENTED]
├── interfaces/
│   ├── IYieldStrategy.sol     ← Frozen yield backend interface          [IMPLEMENTED]
│   └── IDCACoordinator.sol    ← Frozen coordinator interface + Constraints struct
├── libraries/
│   └── DecisionEngine.sol     ← Pure deterministic decision library     [IMPLEMENTED]
├── strategies/
│   ├── AaveYieldStrategy.sol  ← Aave v3 yield wrapper                  [IMPLEMENTED]
│   └── MockYieldStrategy.sol  ← Linear APR mock (tests/fallback)       [IMPLEMENTED]
└── mocks/
    └── MockERC20.sol          ← Mintable ERC-20 (demo counter-asset)   [IMPLEMENTED]

test/
├── DCAVault.t.sol             ← 22 vault unit tests                    [IMPLEMENTED]
├── DCACoordinator.t.sol       ← 35 coordinator + decision tests        [IMPLEMENTED]
├── DecisionEngine.t.sol       ← Library test skeleton (TODO bodies)    [SKELETON]
├── DCAHook.t.sol              ← 8 hook test skeletons                  [SKELETON]
├── Integration.t.sol          ← 12 integration test skeletons          [SKELETON]
└── ForkTestBase.sol           ← Shared Base fork setup + wallet funding

script/
├── Deploy.s.sol               ← 5-step deployment skeleton             [SKELETON]
├── SeedPool.s.sol             ← Pool initialisation skeleton           [SKELETON]
├── MoveMarket.s.sol           ← Demo state control skeleton            [SKELETON]
├── start-fork.sh              ← Anvil fork startup (WSL2 compatible)   [IMPLEMENTED]
└── fund-demo-wallets.sh       ← Wallet funding via impersonation       [IMPLEMENTED]

docs/
├── Project Context.md
├── Technical Architecture.md
├── Interface Contracts.md
└── Features of the Product
```

---

## Known Limitations

| Item | Status |
|------|--------|
| `DCAHook.sol` — Uniswap v4 enforcement hook | Not yet implemented |
| `_computeDeviationBps()` — live TWAP deviation | Stub returning `0`; requires `StateLibrary.getSlot0()` |
| Deploy scripts (`Deploy.s.sol`, `SeedPool.s.sol`, `MoveMarket.s.sol`) | Skeleton with placeholder stubs |
| Integration and Hook test bodies | Empty; pass by default in Foundry |
| `lib/v4-core`, `lib/v4-periphery`, `lib/aave-v3-core` | Not yet installed (`forge install` needed) |

---

## Design Notes

**Why ERC-4626?** Standardised vault interface allows yield strategies to be swapped without changing the vault's public API or affecting share accounting. The OpenZeppelin implementation provides built-in inflation-attack protection.

**Why a pure `library` for decision logic?** `DecisionEngine` being `internal pure` means it can be unit-tested exhaustively with zero mocking, its output is auditable from source code alone, and it adds no gas overhead from external calls.

**Why a clean no-op for ineligible poke?** Any revert-on-ineligible design forces keepers to pre-check eligibility off-chain before triggering, creating a race condition. A silent no-op makes the function safe to call from any automation without coordination overhead.

**Why is the execution path a stub?** `vault.withdrawForExecution()` is real and fully tested. The swap step requires `DCAHook`. Keeping them separately testable maintains a clean integration seam: vault accounting is verifiable independently of swap mechanics.
