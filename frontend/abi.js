// ═══════════════════════════════════════════════════════════════════════
// abi.js — Contract ABIs (minimal, only the functions the UI calls)
// CSI ORIGIN 2026, PS-12
// ═══════════════════════════════════════════════════════════════════════

const ABI = {
  // ── ERC-20 (USDC) ───────────────────────────────────────────────────
  erc20: [
    "function balanceOf(address account) view returns (uint256)",
    "function approve(address spender, uint256 amount) returns (bool)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
  ],

  // ── DCAVault (ERC-4626) ─────────────────────────────────────────────
  vault: [
    "function balanceOf(address account) view returns (uint256)",
    "function convertToAssets(uint256 shares) view returns (uint256)",
    "function totalAssets() view returns (uint256)",
    "function asset() view returns (address)",
    "function deposit(uint256 assets, address receiver) returns (uint256)",
    "function withdraw(uint256 assets, address receiver, address owner) returns (uint256)",
    "function coordinator() view returns (address)",
    "function strategy() view returns (address)",
    "function symbol() view returns (string)",
    "function name() view returns (string)",
    "function decimals() view returns (uint8)",
    "event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)",
    "event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares)",
    "event ExecutionWithdrawal(address indexed user, uint256 assets, uint256 shares)",
  ],

  // ── DCACoordinator ──────────────────────────────────────────────────
  coordinator: [
    // Structs as tuples
    "function setConstraints(tuple(uint64 minFrequencyDays, uint64 maxDelayDays, uint16 goodDeviationBps, uint16 badDeviationBps, uint16 trancheFlexMinBps, uint16 trancheFlexMaxBps, uint256 standardTrancheAmount, uint16 maxSlippageBps) c)",
    "function getConstraints(address user) view returns (tuple(uint64 minFrequencyDays, uint64 maxDelayDays, uint16 goodDeviationBps, uint16 badDeviationBps, uint16 trancheFlexMinBps, uint16 trancheFlexMaxBps, uint256 standardTrancheAmount, uint16 maxSlippageBps))",
    "function poke(address user)",
    "function lastDecision(address user) view returns (uint8 action, uint256 timestamp, uint256 amountIn, uint256 amountOut)",
    "function lastPokeTimestamp(address user) view returns (uint256)",
    "function vault() view returns (address)",
    "function poolKeySet() view returns (bool)",
    "event DecisionMade(address indexed user, uint8 action, int256 deviationBps, uint256 timestamp)",
    "event ExecutionCompleted(address indexed user, uint256 amountIn, uint256 amountOut)",
    "event ConstraintsSet(address indexed user, tuple(uint64 minFrequencyDays, uint64 maxDelayDays, uint16 goodDeviationBps, uint16 badDeviationBps, uint16 trancheFlexMinBps, uint16 trancheFlexMaxBps, uint256 standardTrancheAmount, uint16 maxSlippageBps) c)",
    "error InvalidConstraints(string reason)",
  ],
};
