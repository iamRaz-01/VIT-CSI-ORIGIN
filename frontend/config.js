// ═══════════════════════════════════════════════════════════════════════
// config.js — Contract addresses & demo accounts
// CSI ORIGIN 2026, PS-12
//
// These addresses come from the DeployFrontend.s.sol broadcast output.
// Update them after each fresh deployment.
// ═══════════════════════════════════════════════════════════════════════

const CONFIG = {
  // ── RPC ──────────────────────────────────────────────────────────────
  rpcUrl: "http://127.0.0.1:8545",
  chainId: 8453,                    // Base Mainnet chain ID (Anvil fork preserves it)

  // ── Deployed Contract Addresses ─────────────────────────────────────
  // From broadcast/DeployFrontend.s.sol/8453/run-latest.json
  contracts: {
    usdc:         "0x4e88df059cdc4c1a1e4a1dfcbee9649f11c35291",
    vault:        "0x8c675bbe13724feb226e80fd38a8dd9916d89e3d",
    coordinator:  "0x900f012f6025d64afaebc63013588ded7f84973c",
    hook:         "0x0000000000000000000000000000000000000000",  // Not deployed in stub mode
  },

  // ── Demo Accounts ───────────────────────────────────────────────────
  // Anvil pre-funded accounts with known private keys
  users: {
    A: {
      address:    "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",  // Anvil Account 1
      privateKey: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
      label:      "User A",
    },
    B: {
      address:    "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",  // Anvil Account 2
      privateKey: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
      label:      "User B",
    },
  },

  // ── USDC Decimals ───────────────────────────────────────────────────
  usdcDecimals: 6,
};
