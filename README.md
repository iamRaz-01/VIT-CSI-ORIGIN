# DCA Vault Protocol — CSI ORIGIN 2026, PS-12

**Yield-Optimized DCA Engine via Uniswap v4 Hooks**

An on-chain, multi-user, autonomous capital-management protocol that keeps
each user's committed-but-unexecuted DCA capital productive in an ERC-4626
yield vault and dynamically controls when, how much, and whether to swap that
capital via a Uniswap v4 Hook-based execution layer.

---

## Quick Start (every worktree runs these)

### 1. Prerequisites

```bash
# Foundry (forge, anvil, cast) — v1.8.0+
# Windows: download from https://github.com/foundry-rs/foundry/releases
# Linux/macOS: curl -L https://foundry.paradigm.xyz | bash && foundryup
forge --version   # should print forge 1.8.0 or newer

# Git (for submodule dependencies)
git --version
```

### 2. Clone & Install Dependencies

```bash
git clone <repo-url>
cd VIT-CSI-ORIGIN

# Install Solidity dependencies as git submodules
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts
forge install Uniswap/v4-core
forge install Uniswap/v4-periphery
forge install aave/aave-v3-core
```

### 3. Configure Environment

```bash
cp .env.example .env
# Edit .env:
#   BASE_RPC_URL=<your Alchemy/Infura/QuickNode Base endpoint>
#   FORK_BLOCK_NUMBER=<current Base block — run: cast block-number --rpc-url $BASE_RPC_URL>
#   DEPLOYER_PRIVATE_KEY=<burner key — run: cast wallet new>
```

### 4. Start the Anvil Fork (Terminal 1 — keep alive all hackathon)

```bash
bash script/start-fork.sh
```

> **Required:** `--code-size-limit 40000` is set in the script.
> Omitting it silently fails v4 contract deployment.

### 5. Compile

```bash
forge build
```

### 6. Run Tests

```bash
# All tests (unit + integration, fork required):
forge test -vvv

# Pure unit tests only (no fork, fast):
forge test --match-contract DecisionEngineTest -vvv

# Single test file:
forge test --match-contract DCACoordinatorTest -vvv

# Specific test (e.g., the critical atomicity test):
forge test --match-test test_poke_hookRejects_noStateChange -vvvv
```

### 7. Deploy to Local Fork

```bash
# Step 1: ensure Anvil is running (Terminal 1)

# Step 2: deploy all contracts in order
forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key $DEPLOYER_PRIVATE_KEY \
  -vvvv

# Step 3: fund demo wallets (replace with actual addresses)
bash script/fund-demo-wallets.sh <USER_A_ADDR> <USER_B_ADDR>

# Step 4: initialize pool + set constraints + seed liquidity
forge script script/SeedPool.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key $DEPLOYER_PRIVATE_KEY \
  -vvvv

# Step 5: snapshot for repeatable demo
SNAPSHOT_ID=$(cast rpc evm_snapshot --rpc-url http://127.0.0.1:8545)
echo "Snapshot: $SNAPSHOT_ID"
```

### 8. Demo Commands

```bash
# Drive market to "good" state → poke returns EXECUTE_FULL
forge script script/MoveMarket.s.sol --sig "moveGood()" \
  --rpc-url http://127.0.0.1:8545 --broadcast --private-key $DEPLOYER_PRIVATE_KEY

# Drive market to "bad" state → poke returns DELAY or hook rejects
forge script script/MoveMarket.s.sol --sig "moveBad()" \
  --rpc-url http://127.0.0.1:8545 --broadcast --private-key $DEPLOYER_PRIVATE_KEY

# Trigger evaluation for a user
cast send $COORDINATOR_ADDR "poke(address)" $USER_A_ADDR \
  --rpc-url http://127.0.0.1:8545 --private-key $DEPLOYER_PRIVATE_KEY

# Read latest decision
cast call $COORDINATOR_ADDR "lastDecision(address)" $USER_A_ADDR \
  --rpc-url http://127.0.0.1:8545

# Read vault balance
cast call $VAULT_ADDR "balanceOf(address)" $USER_A_ADDR \
  --rpc-url http://127.0.0.1:8545

# Reset demo to snapshot
cast rpc evm_revert $SNAPSHOT_ID --rpc-url http://127.0.0.1:8545
```

---

## Repository Structure

```
/
├── src/
│   ├── core/
│   │   ├── DCAVault.sol          [Vault worktree — Track B]
│   │   ├── DCACoordinator.sol    [Coordinator worktree — Track A]
│   │   └── DCAHook.sol           [Hook worktree — Track C]
│   ├── interfaces/
│   │   ├── IYieldStrategy.sol    [Vault worktree]
│   │   └── IDCACoordinator.sol   [Coordinator worktree]
│   ├── libraries/
│   │   └── DecisionEngine.sol    [Coordinator worktree]
│   ├── strategies/
│   │   ├── AaveYieldStrategy.sol [Vault worktree]
│   │   └── MockYieldStrategy.sol [Vault worktree]
│   └── mocks/
│       └── MockERC20.sol         [Vault worktree]
├── script/
│   ├── Deploy.s.sol              ← Deployment order §13.2 (Environment)
│   ├── SeedPool.s.sol            ← Pool init + demo setup (Environment)
│   ├── MoveMarket.s.sol          ← Demo state control (Environment/Frontend)
│   ├── start-fork.sh             ← Anvil fork startup (Environment)
│   └── fund-demo-wallets.sh      ← Impersonation funding (Environment)
├── test/
│   ├── ForkTestBase.sol          ← Shared fork setup (Environment)
│   ├── DecisionEngine.t.sol      ← Pure unit tests (Coordinator)
│   ├── DCAVault.t.sol            ← Vault unit tests (Vault)
│   ├── DCACoordinator.t.sol      ← ⚠️ CRITICAL atomicity test (Coordinator)
│   ├── DCAHook.t.sol             ← Hook unit tests (Hook)
│   └── Integration.t.sol         ← End-to-end demo path (all tracks)
├── foundry.toml                  ← Compiler settings, remappings, RPC config
├── .env.example                  ← Required env vars (copy to .env)
├── .gitignore
└── docs/
    ├── Project Context.md
    ├── Technical Architecture.md
    ├── Interface Contracts.md
    └── Features of the Product
```

---

## Deployment Order

Per **INTERFACE_CONTRACTS.md §13.2** — hard dependency chain, do not reorder:

| Step | Contract | Depends On |
|------|----------|------------|
| 1 | `MockERC20` | — |
| 2 | `DCAVault` | `USDC_ADDRESS` |
| 3 | `AaveYieldStrategy` / `MockYieldStrategy` | `DCAVault`, `AAVE_POOL_ADDRESS` |
| 4 | `DCACoordinator` | `DCAVault`, `POOL_MANAGER_ADDRESS` |
| 5 | `DCAHook` (mined address) | `DCACoordinator`, `POOL_MANAGER_ADDRESS` |
| 6 | Pool init (`SeedPool.s.sol`) | `DCAHook`, `MockERC20`, `USDC_ADDRESS` |

---

## Key Addresses (Base Mainnet — inherited by fork)

| Contract | Address |
|----------|---------|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Aave v3 Pool | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` |
| Uniswap v4 PoolManager | `0x498581ff718922c3f8e6a244956af099b2652b2b` |

---

## Open Architectural Questions (from INTERFACE_CONTRACTS.md §23)

| # | Question | Status | Affects |
|---|----------|--------|---------|
| §23-E | `poke()` on ineligible user: silent return vs. revert? | **Decide before Coordinator impl** | Coordinator, Frontend |
| §23-F | `ExecutionRejectedByHook` can't fire under hard-revert atomicity | **Decide before Coordinator/Hook impl** | Coordinator, Hook, Frontend |
| §23-D | Exact `_isEligible()` formula | **Decide before Coordinator impl** | Coordinator |
| §23-B | `maxSlippageBps` sane ceiling value | Minor — pick a number (e.g. 2000) | Coordinator |
| §23-G | Strategy swap: redeploy vs. `setStrategy()` function | Low risk — redeploy assumed | Vault |

---

## Worktree Assignment

| Track | Worktree | Owns |
|-------|----------|------|
| A | Coordinator | `DCACoordinator.sol`, `DecisionEngine.sol` |
| B | Vault | `DCAVault.sol`, `IYieldStrategy.sol`, both strategies, `MockERC20` |
| C | Hook | `DCAHook.sol` |
| D | Frontend | `/frontend`, `MoveMarket.s.sol` (demo tooling) |
| E | **Environment** | `Deploy.s.sol`, `SeedPool.s.sol`, `start-fork.sh`, `.env.example`, `foundry.toml`, all `test/` skeletons |

*Interfaces are frozen — see INTERFACE_CONTRACTS.md §19 for mutation rules.*
