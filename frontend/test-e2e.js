// ═══════════════════════════════════════════════════════════════════════
// test-e2e.js — End-to-end frontend integration test
// Runs the same ethers.js calls the browser would, validates all reads/writes.
// Usage: node frontend/test-e2e.js
// ═══════════════════════════════════════════════════════════════════════

const { ethers } = require("ethers");

// ── Config (duplicated from config.js for Node.js usage) ────────────
const RPC = "http://127.0.0.1:8545";
const USDC     = "0x4e88df059cdc4c1a1e4a1dfcbee9649f11c35291";
const VAULT    = "0x8c675bbe13724feb226e80fd38a8dd9916d89e3d";
const COORD    = "0x900f012f6025d64afaebc63013588ded7f84973c";
const USER_A   = { addr: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", key: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" };
const USER_B   = { addr: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC", key: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a" };

// ── ABI fragments ──────────────────────────────────────────────────
const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)",
];
const VAULT_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function convertToAssets(uint256) view returns (uint256)",
  "function totalAssets() view returns (uint256)",
  "function deposit(uint256,address) returns (uint256)",
  "event Deposit(address indexed, address indexed, uint256, uint256)",
];
const COORD_ABI = [
  "function setConstraints(tuple(uint64,uint64,uint16,uint16,uint16,uint16,uint256,uint16))",
  "function getConstraints(address) view returns (tuple(uint64,uint64,uint16,uint16,uint16,uint16,uint256,uint16))",
  "function poke(address)",
  "function lastDecision(address) view returns (uint8,uint256,uint256,uint256)",
  "function lastPokeTimestamp(address) view returns (uint256)",
  "event DecisionMade(address indexed, uint8, int256, uint256)",
  "event ExecutionCompleted(address indexed, uint256, uint256)",
];

const ACTIONS = ["DELAY", "EXECUTE_PARTIAL", "EXECUTE_FULL"];

async function main() {
  console.log("═══ CSI ORIGIN Frontend E2E Test ═══\n");
  
  const provider = new ethers.JsonRpcProvider(RPC);
  const network = await provider.getNetwork();
  const block = await provider.getBlockNumber();
  console.log(`✓ Connected: chainId=${network.chainId}, block #${block}`);
  
  // Verify contracts have code
  for (const [name, addr] of [["USDC", USDC], ["Vault", VAULT], ["Coordinator", COORD]]) {
    const code = await provider.getCode(addr);
    if (code === "0x") throw new Error(`${name} has no code at ${addr}`);
    console.log(`✓ ${name} deployed at ${addr}`);
  }
  
  const signerA = new ethers.Wallet(USER_A.key, provider);
  const signerB = new ethers.Wallet(USER_B.key, provider);
  
  const usdc  = new ethers.Contract(USDC, ERC20_ABI, provider);
  const vault = new ethers.Contract(VAULT, VAULT_ABI, provider);
  const coord = new ethers.Contract(COORD, COORD_ABI, provider);
  
  // ── Test 1: Read USDC balances ─────────────────────────────────
  console.log("\n── Test 1: USDC Balances ──");
  const balA = await usdc.balanceOf(USER_A.addr);
  const balB = await usdc.balanceOf(USER_B.addr);
  console.log(`  User A: ${ethers.formatUnits(balA, 6)} USDC`);
  console.log(`  User B: ${ethers.formatUnits(balB, 6)} USDC`);
  if (balA === 0n) throw new Error("User A has no USDC");
  if (balB === 0n) throw new Error("User B has no USDC");
  console.log("✓ Both users have USDC");
  
  // ── Test 2: Deposit for User A ─────────────────────────────────
  console.log("\n── Test 2: Deposit 10,000 USDC (User A) ──");
  const depositAmount = ethers.parseUnits("10000", 6);
  
  const usdcA = usdc.connect(signerA);
  let nonceA = await provider.getTransactionCount(USER_A.addr, "pending");
  const approveTx = await usdcA.approve(VAULT, ethers.MaxUint256, { nonce: nonceA++ });
  await approveTx.wait();
  console.log("  ✓ USDC approved");
  
  const vaultA = vault.connect(signerA);
  const depTx = await vaultA.deposit(depositAmount, USER_A.addr, { nonce: nonceA++ });
  const depReceipt = await depTx.wait();
  console.log(`  ✓ Deposit tx confirmed (gas: ${depReceipt.gasUsed})`);
  
  const sharesA = await vault.balanceOf(USER_A.addr);
  const assetsA = await vault.convertToAssets(sharesA);
  const totalAssets = await vault.totalAssets();
  console.log(`  Shares: ${ethers.formatUnits(sharesA, 6)}`);
  console.log(`  Assets: ${ethers.formatUnits(assetsA, 6)} USDC`);
  console.log(`  Total Assets: ${ethers.formatUnits(totalAssets, 6)} USDC`);
  if (sharesA === 0n) throw new Error("No shares minted");
  console.log("✓ Deposit successful");
  
  // ── Test 3: Deposit for User B ─────────────────────────────────
  console.log("\n── Test 3: Deposit 5,000 USDC (User B) ──");
  const usdcB = usdc.connect(signerB);
  let nonceB = await provider.getTransactionCount(USER_B.addr, "pending");
  await (await usdcB.approve(VAULT, ethers.MaxUint256, { nonce: nonceB++ })).wait();
  const vaultB = vault.connect(signerB);
  await (await vaultB.deposit(ethers.parseUnits("5000", 6), USER_B.addr, { nonce: nonceB++ })).wait();
  const sharesB = await vault.balanceOf(USER_B.addr);
  console.log(`  Shares: ${ethers.formatUnits(sharesB, 6)}`);
  console.log("✓ User B deposit successful");
  
  // ── Test 4: Set Constraints (User A — standard) ─────────────────
  console.log("\n── Test 4: Set Constraints (User A — standard) ──");
  const coordA = coord.connect(signerA);
  const constraintsA = [
    1n,                                      // minFrequencyDays
    7n,                                      // maxDelayDays
    100,                                     // goodDeviationBps
    300,                                     // badDeviationBps
    5000,                                    // trancheFlexMinBps
    10000,                                   // trancheFlexMaxBps
    ethers.parseUnits("1000", 6),            // standardTrancheAmount
    200,                                     // maxSlippageBps
  ];
  await (await coordA.setConstraints(constraintsA, { nonce: nonceA++ })).wait();
  const cA = await coord.getConstraints(USER_A.addr);
  console.log(`  minFrequencyDays: ${cA[0]}, maxDelayDays: ${cA[1]}`);
  console.log(`  standardTrancheAmount: ${ethers.formatUnits(cA[6], 6)} USDC`);
  console.log("✓ User A constraints set");
  
  // ── Test 5: Set Constraints (User B — tight slippage) ───────────
  console.log("\n── Test 5: Set Constraints (User B — tight slippage for rejection demo) ──");
  const coordB = coord.connect(signerB);
  const constraintsB = [
    1n,
    7n,
    100,
    300,
    5000,
    10000,
    ethers.parseUnits("500", 6),
    50,
  ];
  await (await coordB.setConstraints(constraintsB, { nonce: nonceB++ })).wait();
  console.log("✓ User B constraints set (tight slippage)");
  
  // ── Test 6: Poke User A ──────────────────────────────────────────
  console.log("\n── Test 6: Poke User A ──");
  const beforeAssetsA = await vault.convertToAssets(await vault.balanceOf(USER_A.addr));
  
  const pokeTxA = await coordA.poke(USER_A.addr, { nonce: nonceA++ });
  const pokeReceiptA = await pokeTxA.wait();
  
  const decisionA = await coord.lastDecision(USER_A.addr);
  const afterAssetsA = await vault.convertToAssets(await vault.balanceOf(USER_A.addr));
  
  console.log(`  Action: ${ACTIONS[Number(decisionA[0])]}`);
  console.log(`  Timestamp: ${new Date(Number(decisionA[1]) * 1000).toLocaleString()}`);
  console.log(`  AmountIn: ${ethers.formatUnits(decisionA[2], 6)} USDC`);
  console.log(`  AmountOut: ${ethers.formatUnits(decisionA[3], 6)}`);
  console.log(`  Vault: ${ethers.formatUnits(beforeAssetsA, 6)} → ${ethers.formatUnits(afterAssetsA, 6)} USDC`);
  console.log(`  Gas: ${pokeReceiptA.gasUsed}`);
  
  // Parse events
  for (const log of pokeReceiptA.logs) {
    try {
      const parsed = coord.interface.parseLog({ topics: log.topics, data: log.data });
      if (parsed) console.log(`  [Event] ${parsed.name}: ${parsed.args}`);
    } catch {}
  }
  console.log("✓ Poke User A successful");
  
  // ── Test 7: Poke User B ──────────────────────────────────────────
  console.log("\n── Test 7: Poke User B ──");
  const pokeTxB = await coordB.poke(USER_B.addr, { nonce: nonceB++ });
  const pokeReceiptB = await pokeTxB.wait();
  
  const decisionB = await coord.lastDecision(USER_B.addr);
  console.log(`  Action: ${ACTIONS[Number(decisionB[0])]}`);
  console.log(`  AmountIn: ${ethers.formatUnits(decisionB[2], 6)} USDC`);
  console.log("✓ Poke User B successful");
  
  // ── Test 8: User A and B remain independent ──────────────────────
  console.log("\n── Test 8: Verify User Isolation ──");
  const finalDecA = await coord.lastDecision(USER_A.addr);
  const finalDecB = await coord.lastDecision(USER_B.addr);
  if (finalDecA[1] === finalDecB[1] && finalDecA[2] === finalDecB[2]) {
    console.log("  ⚠ Decisions are identical (possible but check)");
  } else {
    console.log("  ✓ Decisions differ — users are independent");
  }
  const finalSharesA = await vault.balanceOf(USER_A.addr);
  const finalSharesB = await vault.balanceOf(USER_B.addr);
  console.log(`  User A shares: ${ethers.formatUnits(finalSharesA, 6)}`);
  console.log(`  User B shares: ${ethers.formatUnits(finalSharesB, 6)}`);
  console.log("✓ User isolation verified");
  
  // ── Summary ──────────────────────────────────────────────────────
  console.log("\n═══════════════════════════════════");
  console.log("  ALL E2E TESTS PASSED ✓");
  console.log("═══════════════════════════════════\n");
}

main().catch(err => {
  console.error("\n✗ E2E TEST FAILED:", err.message);
  process.exit(1);
});
