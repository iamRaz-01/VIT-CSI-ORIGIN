// ═══════════════════════════════════════════════════════════════════════
// app.js — CSI ORIGIN DCA Vault Protocol Dashboard
// Main application logic — reads/writes on-chain state via ethers.js v6
// CSI ORIGIN 2026, PS-12
// ═══════════════════════════════════════════════════════════════════════

/* global ethers, CONFIG, ABI */

// ─── State ─────────────────────────────────────────────────────────────
let provider = null;
let signerA  = null;
let signerB  = null;
let contracts = { usdc: null, vault: null, coordinator: null };
let connected = false;

// Action enum mapping
const ACTION_LABELS = { 0: "DELAY", 1: "EXECUTE_PARTIAL", 2: "EXECUTE_FULL" };
const ACTION_CLASSES = { 0: "decision-delay", 1: "decision-partial", 2: "decision-full" };
const STATUS_CLASSES = { 0: "status-delay", 1: "status-execute-partial", 2: "status-execute-full" };

// ─── Utilities ─────────────────────────────────────────────────────────
function fmt(val, decimals = 6) {
  if (val == null) return "—";
  return ethers.formatUnits(val, decimals);
}

function fmtUSDC(val) {
  if (val == null) return "—";
  const n = Number(ethers.formatUnits(val, CONFIG.usdcDecimals));
  return n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + " USDC";
}

function fmtShares(val) {
  if (val == null) return "—";
  const n = Number(ethers.formatUnits(val, CONFIG.usdcDecimals));
  return n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 6 });
}

function fmtTime(ts) {
  if (!ts || ts === 0n) return "Never";
  const d = new Date(Number(ts) * 1000);
  return d.toLocaleString();
}

function shortAddr(addr) {
  if (!addr) return "—";
  return addr.slice(0, 6) + "…" + addr.slice(-4);
}

function bpsToPercent(bps) {
  return (Number(bps) / 100).toFixed(2) + "%";
}

// ─── Logging ───────────────────────────────────────────────────────────
function log(msg, type = "info") {
  const el = document.getElementById("eventLog");
  const entry = document.createElement("div");
  const ts = new Date().toLocaleTimeString();
  entry.className = `event-entry event-${type}`;
  entry.textContent = `[${ts}] ${msg}`;
  el.prepend(entry);
  // cap at 100 entries
  while (el.children.length > 100) el.removeChild(el.lastChild);
}

function toast(msg, type = "info") {
  const container = document.getElementById("toastContainer");
  const t = document.createElement("div");
  t.className = `toast toast-${type}`;
  t.textContent = msg;
  container.appendChild(t);
  setTimeout(() => { t.remove(); }, 5000);
}

// ─── Revert Reason Parser ──────────────────────────────────────────────
function parseRevertReason(error) {
  // Try to extract the actual revert reason from the error
  if (!error) return "Unknown error";
  
  const errStr = error.message || error.toString();
  
  // Custom errors from our contracts
  if (errStr.includes("TrancheCapExceeded"))   return "Hook Rejected: TrancheCapExceeded — swap amount exceeds approved tranche cap";
  if (errStr.includes("SlippageCapExceeded"))  return "Hook Rejected: SlippageCapExceeded — price impact exceeds user's max slippage";
  if (errStr.includes("UntrustedCaller"))      return "Hook Rejected: UntrustedCaller — only DCACoordinator may trigger swaps";
  if (errStr.includes("InvalidConstraints"))   {
    const match = errStr.match(/InvalidConstraints\("([^"]+)"\)/);
    return match ? `Invalid Constraints: ${match[1]}` : "Invalid Constraints";
  }
  if (errStr.includes("ZeroAssets"))           return "Cannot deposit zero assets";
  if (errStr.includes("InsufficientBalance"))  return "Insufficient vault balance for withdrawal";
  if (errStr.includes("Unauthorized"))         return "Unauthorized — caller is not the coordinator";
  
  // Generic revert extraction
  if (errStr.includes("reverted with reason")) {
    const match = errStr.match(/reverted with reason string '([^']+)'/);
    if (match) return match[1];
  }
  if (errStr.includes("execution reverted")) {
    const match = errStr.match(/execution reverted: ?(.*?)(?:\(|$)/);
    if (match && match[1].trim()) return match[1].trim();
    return "Transaction reverted (see console for details)";
  }
  if (errStr.includes("user rejected"))        return "Transaction rejected by user";
  if (errStr.includes("insufficient funds"))   return "Insufficient ETH for gas";
  
  // Fallback — truncate if too long
  if (errStr.length > 200) return errStr.substring(0, 200) + "…";
  return errStr;
}

// ═══════════════════════════════════════════════════════════════════════
// CONNECTION
// ═══════════════════════════════════════════════════════════════════════

async function connect() {
  try {
    log("Connecting to RPC: " + CONFIG.rpcUrl);
    provider = new ethers.JsonRpcProvider(CONFIG.rpcUrl);
    
    // Verify connection
    const network = await provider.getNetwork();
    const blockNum = await provider.getBlockNumber();
    log(`Connected — chainId=${network.chainId}, block #${blockNum}`, "success");
    
    // Create signers from known private keys (demo accounts)
    signerA = new ethers.Wallet(CONFIG.users.A.privateKey, provider);
    signerB = new ethers.Wallet(CONFIG.users.B.privateKey, provider);
    
    // Verify signer addresses match config
    if (signerA.address.toLowerCase() !== CONFIG.users.A.address.toLowerCase()) {
      throw new Error(`Signer A address mismatch: ${signerA.address} vs ${CONFIG.users.A.address}`);
    }
    if (signerB.address.toLowerCase() !== CONFIG.users.B.address.toLowerCase()) {
      throw new Error(`Signer B address mismatch: ${signerB.address} vs ${CONFIG.users.B.address}`);
    }
    
    // Instantiate contracts (read-only instances)
    contracts.usdc = new ethers.Contract(CONFIG.contracts.usdc, ABI.erc20, provider);
    contracts.vault = new ethers.Contract(CONFIG.contracts.vault, ABI.vault, provider);
    contracts.coordinator = new ethers.Contract(CONFIG.contracts.coordinator, ABI.coordinator, provider);
    
    // Verify contracts have code
    const vaultCode = await provider.getCode(CONFIG.contracts.vault);
    if (vaultCode === "0x") {
      throw new Error("DCAVault has no code at " + CONFIG.contracts.vault + " — run Deploy.s.sol first");
    }
    const coordCode = await provider.getCode(CONFIG.contracts.coordinator);
    if (coordCode === "0x") {
      throw new Error("DCACoordinator has no code at " + CONFIG.contracts.coordinator + " — run Deploy.s.sol first");
    }
    
    connected = true;
    updateConnectionUI(network.chainId, blockNum);
    
    // Display addresses
    document.getElementById("addrA").textContent = CONFIG.users.A.address;
    document.getElementById("addrB").textContent = CONFIG.users.B.address;
    document.getElementById("vaultAddr").textContent = shortAddr(CONFIG.contracts.vault);
    document.getElementById("coordAddr").textContent = shortAddr(CONFIG.contracts.coordinator);
    document.getElementById("hookAddr").textContent = shortAddr(CONFIG.contracts.hook);
    
    // Initial state load
    await refreshAll();
    
    // Set up event listeners for live events
    setupEventListeners();
    
    toast("Connected to local Anvil fork", "success");
    
  } catch (err) {
    log("Connection failed: " + parseRevertReason(err), "error");
    toast("Connection failed — is Anvil running?", "error");
    updateConnectionUI(null, null, err);
    console.error(err);
  }
}

function updateConnectionUI(chainId, blockNum, error) {
  const badge = document.getElementById("networkBadge");
  const blockEl = document.getElementById("blockNumber");
  const btnConnect = document.getElementById("btnConnect");
  
  if (error) {
    badge.className = "badge badge-wrong-network";
    badge.textContent = "● RPC Error";
    blockEl.textContent = "#—";
    btnConnect.textContent = "Retry";
    return;
  }
  
  if (chainId != null) {
    badge.className = "badge badge-connected";
    badge.textContent = `● Chain ${chainId}`;
    blockEl.textContent = `#${blockNum}`;
    btnConnect.textContent = "Connected";
    btnConnect.disabled = true;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// STATE READS
// ═══════════════════════════════════════════════════════════════════════

async function refreshAll() {
  if (!connected) return;
  try {
    const blockNum = await provider.getBlockNumber();
    document.getElementById("blockNumber").textContent = `#${blockNum}`;
    
    await Promise.all([
      refreshVaultOverview(),
      refreshUser("A"),
      refreshUser("B"),
    ]);
    log("State refreshed", "info");
  } catch (err) {
    log("Refresh error: " + parseRevertReason(err), "error");
  }
}

async function refreshVaultOverview() {
  try {
    const totalAssets = await contracts.vault.totalAssets();
    document.getElementById("vaultTotalAssets").textContent = fmtUSDC(totalAssets);
  } catch (err) {
    document.getElementById("vaultTotalAssets").textContent = "Error";
    console.error("totalAssets error:", err);
  }
}

async function refreshUser(userKey) {
  const userAddr = CONFIG.users[userKey].address;
  
  try {
    // Parallel reads for performance
    const [shares, usdcBal, constraints, decision, lastPoke] = await Promise.all([
      contracts.vault.balanceOf(userAddr),
      contracts.usdc.balanceOf(userAddr),
      contracts.coordinator.getConstraints(userAddr),
      contracts.coordinator.lastDecision(userAddr),
      contracts.coordinator.lastPokeTimestamp(userAddr),
    ]);
    
    // Compute assets from shares
    let assets = 0n;
    try {
      if (shares > 0n) {
        assets = await contracts.vault.convertToAssets(shares);
      }
    } catch { assets = 0n; }
    
    // Update position
    document.getElementById(`shares${userKey}`).textContent = fmtShares(shares);
    document.getElementById(`assets${userKey}`).textContent = fmtUSDC(assets);
    document.getElementById(`usdcBal${userKey}`).textContent = fmtUSDC(usdcBal);
    
    // Update constraints
    updateConstraintsDisplay(userKey, constraints);
    
    // Update decision
    const actionIdx = Number(decision[0]);
    const actionEl = document.getElementById(`decisionAction${userKey}`);
    actionEl.textContent = ACTION_LABELS[actionIdx] || "—";
    actionEl.className = `kv-val decision-action ${decision[1] > 0n ? ACTION_CLASSES[actionIdx] : ""}`;
    
    document.getElementById(`decisionTime${userKey}`).textContent = fmtTime(decision[1]);
    document.getElementById(`decisionIn${userKey}`).textContent = decision[2] > 0n ? fmtUSDC(decision[2]) : "—";
    document.getElementById(`decisionOut${userKey}`).textContent = decision[3] > 0n ? fmtUSDC(decision[3]) : "—";
    document.getElementById(`lastPoke${userKey}`).textContent = fmtTime(lastPoke);
    
    // Update status badge
    updateUserStatus(userKey, decision, lastPoke, constraints);
    
  } catch (err) {
    log(`Error reading User ${userKey}: ${parseRevertReason(err)}`, "error");
    console.error(`refreshUser(${userKey}):`, err);
  }
}

function updateConstraintsDisplay(userKey, c) {
  const el = document.getElementById(`constraintsDisplay${userKey}`);
  
  // Check if constraints are zeroed (no constraints set)
  if (c.standardTrancheAmount === 0n) {
    el.innerHTML = '<span class="no-constraints">No constraints set</span>';
    return;
  }
  
  el.innerHTML = `
    <div class="constraint-grid">
      <div class="c-item"><span class="c-label">Frequency</span><span class="c-val">${c.minFrequencyDays}d</span></div>
      <div class="c-item"><span class="c-label">Max Delay</span><span class="c-val">${c.maxDelayDays}d</span></div>
      <div class="c-item"><span class="c-label">Good Dev</span><span class="c-val">${bpsToPercent(c.goodDeviationBps)}</span></div>
      <div class="c-item"><span class="c-label">Bad Dev</span><span class="c-val">${bpsToPercent(c.badDeviationBps)}</span></div>
      <div class="c-item"><span class="c-label">Flex Min</span><span class="c-val">${bpsToPercent(c.trancheFlexMinBps)}</span></div>
      <div class="c-item"><span class="c-label">Flex Max</span><span class="c-val">${bpsToPercent(c.trancheFlexMaxBps)}</span></div>
      <div class="c-item"><span class="c-label">Tranche</span><span class="c-val">${fmtUSDC(c.standardTrancheAmount)}</span></div>
      <div class="c-item"><span class="c-label">Max Slip</span><span class="c-val">${bpsToPercent(c.maxSlippageBps)}</span></div>
    </div>
  `;
}

function updateUserStatus(userKey, decision, lastPoke, constraints) {
  const el = document.getElementById(`status${userKey}`);
  
  if (constraints.standardTrancheAmount === 0n) {
    el.textContent = "Not Configured";
    el.className = "user-status status-waiting";
    return;
  }
  
  if (!decision[1] || decision[1] === 0n) {
    el.textContent = "Waiting";
    el.className = "user-status status-waiting";
    return;
  }
  
  const actionIdx = Number(decision[0]);
  const label = ACTION_LABELS[actionIdx];
  const hasExecution = decision[2] > 0n;
  
  if (actionIdx === 0) {
    el.textContent = "Delayed";
    el.className = "user-status status-delay";
  } else if (hasExecution) {
    el.textContent = label;
    el.className = `user-status ${STATUS_CLASSES[actionIdx]}`;
  } else {
    el.textContent = label + " (No-Op)";
    el.className = `user-status ${STATUS_CLASSES[actionIdx]}`;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// WRITE OPERATIONS
// ═══════════════════════════════════════════════════════════════════════

// ── Deposit ────────────────────────────────────────────────────────────
async function doDeposit(userKey) {
  if (!connected) return toast("Not connected", "error");
  
  const input = document.getElementById(`depositAmt${userKey}`);
  const raw = input.value.trim();
  if (!raw || Number(raw) <= 0) return toast("Enter a valid USDC amount", "error");
  
  const signer = userKey === "A" ? signerA : signerB;
  const userAddr = CONFIG.users[userKey].address;
  const amount = ethers.parseUnits(raw, CONFIG.usdcDecimals);
  
  setUserStatus(userKey, "Executing", "status-executing");
  log(`User ${userKey}: depositing ${raw} USDC…`, "tx");
  
  try {
    // Check and approve USDC allowance
    const usdcSigned = contracts.usdc.connect(signer);
    const allowance = await usdcSigned.allowance(userAddr, CONFIG.contracts.vault);
    
    if (allowance < amount) {
      log(`User ${userKey}: approving USDC spend…`, "tx");
      let nonce = await provider.getTransactionCount(userAddr, "pending");
      const approveTx = await usdcSigned.approve(CONFIG.contracts.vault, ethers.MaxUint256, { nonce });
      await approveTx.wait();
      log(`User ${userKey}: USDC approved`, "success");
    }
    
    // Deposit
    const vaultSigned = contracts.vault.connect(signer);
    let nonce = await provider.getTransactionCount(userAddr, "pending");
    const tx = await vaultSigned.deposit(amount, userAddr, { nonce });
    log(`User ${userKey}: deposit tx sent — ${shortAddr(tx.hash)}`, "tx");
    
    const receipt = await tx.wait();
    log(`User ${userKey}: deposited ${raw} USDC ✓ (gas: ${receipt.gasUsed})`, "success");
    toast(`User ${userKey}: deposited ${raw} USDC`, "success");
    
    input.value = "";
    await refreshAll();
    
  } catch (err) {
    const reason = parseRevertReason(err);
    log(`User ${userKey} deposit FAILED: ${reason}`, "error");
    toast(`Deposit failed: ${reason}`, "error");
    setUserStatus(userKey, "Error", "status-error");
    console.error(err);
  }
}

// ── Set Constraints ────────────────────────────────────────────────────
async function doSetConstraints(userKey) {
  if (!connected) return toast("Not connected", "error");
  
  const form = document.querySelector(`.constraint-form[data-user="${userKey}"]`);
  const signer = userKey === "A" ? signerA : signerB;
  
  // Read form values as tuple array matching IDCACoordinator Constraints struct
  const c = [
    BigInt(form.querySelector('[name="minFrequencyDays"]').value),
    BigInt(form.querySelector('[name="maxDelayDays"]').value),
    Number(form.querySelector('[name="goodDeviationBps"]').value),
    Number(form.querySelector('[name="badDeviationBps"]').value),
    Number(form.querySelector('[name="trancheFlexMinBps"]').value),
    Number(form.querySelector('[name="trancheFlexMaxBps"]').value),
    ethers.parseUnits(
      form.querySelector('[name="standardTrancheAmount"]').value,
      CONFIG.usdcDecimals
    ),
    Number(form.querySelector('[name="maxSlippageBps"]').value),
  ];
  
  setUserStatus(userKey, "Executing", "status-executing");
  log(`User ${userKey}: setting constraints…`, "tx");
  
  try {
    const coordSigned = contracts.coordinator.connect(signer);
    const nonce = await provider.getTransactionCount(CONFIG.users[userKey].address, "pending");
    const tx = await coordSigned.setConstraints(c, { nonce });
    log(`User ${userKey}: setConstraints tx sent — ${shortAddr(tx.hash)}`, "tx");
    
    const receipt = await tx.wait();
    log(`User ${userKey}: constraints set ✓ (gas: ${receipt.gasUsed})`, "success");
    toast(`User ${userKey}: constraints updated`, "success");
    
    // Close the details form
    const details = form.closest("details");
    if (details) details.open = false;
    
    await refreshAll();
    
  } catch (err) {
    const reason = parseRevertReason(err);
    log(`User ${userKey} setConstraints FAILED: ${reason}`, "error");
    toast(`Set constraints failed: ${reason}`, "error");
    setUserStatus(userKey, "Error", "status-error");
    console.error(err);
  }
}

// ── Poke ───────────────────────────────────────────────────────────────
async function doPoke(userKey) {
  if (!connected) return toast("Not connected", "error");
  
  const signer = userKey === "A" ? signerA : signerB;
  const userAddr = CONFIG.users[userKey].address;
  const resultEl = document.getElementById(`pokeResult${userKey}`);
  const btn = document.getElementById(`btnPoke${userKey}`);
  
  // Capture before-state for comparison
  let beforeShares, beforeAssets;
  try {
    beforeShares = await contracts.vault.balanceOf(userAddr);
    beforeAssets = beforeShares > 0n ? await contracts.vault.convertToAssets(beforeShares) : 0n;
  } catch { beforeShares = 0n; beforeAssets = 0n; }
  
  // UI: entering poke state
  btn.disabled = true;
  btn.classList.add("loading");
  btn.textContent = "⏳ Evaluating…";
  setUserStatus(userKey, "Evaluating", "status-evaluating");
  resultEl.textContent = "Transaction pending…";
  resultEl.className = "poke-result pending";
  log(`User ${userKey}: poke(${shortAddr(userAddr)}) sent…`, "tx");
  
  try {
    // Use any signer — poke is permissionless
    const coordSigned = contracts.coordinator.connect(signer);
    const nonce = await provider.getTransactionCount(signer.address, "pending");
    const tx = await coordSigned.poke(userAddr, { nonce });
    
    setUserStatus(userKey, "Executing", "status-executing");
    btn.textContent = "⏳ Executing…";
    
    const receipt = await tx.wait();
    
    // Read the decision after the poke
    const decision = await contracts.coordinator.lastDecision(userAddr);
    const actionIdx = Number(decision[0]);
    const actionLabel = ACTION_LABELS[actionIdx];
    
    // Read after-state
    let afterShares, afterAssets;
    try {
      afterShares = await contracts.vault.balanceOf(userAddr);
      afterAssets = afterShares > 0n ? await contracts.vault.convertToAssets(afterShares) : 0n;
    } catch { afterShares = 0n; afterAssets = 0n; }
    
    // Parse events from receipt
    let decisionEvent = null;
    let executionEvent = null;
    for (const eventLog of receipt.logs) {
      try {
        const parsed = contracts.coordinator.interface.parseLog({
          topics: eventLog.topics,
          data: eventLog.data,
        });
        if (parsed && parsed.name === "DecisionMade") decisionEvent = parsed;
        if (parsed && parsed.name === "ExecutionCompleted") executionEvent = parsed;
      } catch { /* not our event */ }
    }
    
    // Build result message
    let resultMsg = `Decision: ${actionLabel}`;
    if (decisionEvent) {
      resultMsg += ` (deviation: ${decisionEvent.args.deviationBps}bps)`;
    }
    if (executionEvent) {
      resultMsg += ` | In: ${fmtUSDC(executionEvent.args.amountIn)}, Out: ${fmtUSDC(executionEvent.args.amountOut)}`;
    }
    
    // Before/after comparison
    if (beforeAssets !== afterAssets) {
      const diff = beforeAssets - afterAssets;
      resultMsg += ` | Vault: ${fmtUSDC(beforeAssets)} → ${fmtUSDC(afterAssets)}`;
    } else if (actionIdx === 0) {
      resultMsg += " | Vault unchanged (delayed)";
    } else {
      resultMsg += " | No-op (ineligible or zero balance)";
    }
    
    resultEl.textContent = resultMsg;
    resultEl.className = "poke-result success";
    log(`User ${userKey}: poke completed — ${resultMsg} (gas: ${receipt.gasUsed})`, "success");
    toast(`User ${userKey}: ${actionLabel}`, "success");
    
    await refreshAll();
    
  } catch (err) {
    const reason = parseRevertReason(err);
    resultEl.textContent = `REVERTED: ${reason}`;
    resultEl.className = "poke-result error";
    setUserStatus(userKey, "Rejected", "status-rejected");
    log(`User ${userKey} poke REVERTED: ${reason}`, "error");
    toast(`Poke reverted: ${reason}`, "error");
    console.error(err);
    
    // Refresh to confirm vault state unchanged
    await refreshAll();
    
  } finally {
    btn.disabled = false;
    btn.classList.remove("loading");
    btn.textContent = `⚡ Poke User ${userKey}`;
  }
}

// ── Status helper ──────────────────────────────────────────────────────
function setUserStatus(userKey, label, className) {
  const el = document.getElementById(`status${userKey}`);
  el.textContent = label;
  el.className = `user-status ${className}`;
}

// ═══════════════════════════════════════════════════════════════════════
// EVENT LISTENERS (live chain events)
// ═══════════════════════════════════════════════════════════════════════

function setupEventListeners() {
  try {
    // Listen for DecisionMade events
    contracts.coordinator.on("DecisionMade", (user, action, deviationBps, timestamp) => {
      const userKey = identifyUser(user);
      const label = ACTION_LABELS[Number(action)] || "UNKNOWN";
      log(`[EVENT] DecisionMade — User ${userKey || shortAddr(user)}: ${label} (dev: ${deviationBps}bps)`, "success");
    });
    
    // Listen for ExecutionCompleted events
    contracts.coordinator.on("ExecutionCompleted", (user, amountIn, amountOut) => {
      const userKey = identifyUser(user);
      log(`[EVENT] ExecutionCompleted — User ${userKey || shortAddr(user)}: ${fmtUSDC(amountIn)} → ${fmtUSDC(amountOut)}`, "success");
    });
    
    // Listen for ConstraintsSet events
    contracts.coordinator.on("ConstraintsSet", (user, c) => {
      const userKey = identifyUser(user);
      log(`[EVENT] ConstraintsSet — User ${userKey || shortAddr(user)}`, "info");
    });
    
    // Listen for Vault Deposit events
    contracts.vault.on("Deposit", (sender, owner, assets, shares) => {
      const userKey = identifyUser(owner);
      log(`[EVENT] Vault Deposit — User ${userKey || shortAddr(owner)}: ${fmtUSDC(assets)}`, "success");
    });
    
    log("Live event listeners active", "info");
  } catch (err) {
    log("Failed to set up event listeners: " + err.message, "warning");
  }
}

function identifyUser(addr) {
  const lower = addr.toLowerCase();
  if (lower === CONFIG.users.A.address.toLowerCase()) return "A";
  if (lower === CONFIG.users.B.address.toLowerCase()) return "B";
  return null;
}

// ═══════════════════════════════════════════════════════════════════════
// UI EVENT BINDINGS
// ═══════════════════════════════════════════════════════════════════════

document.addEventListener("DOMContentLoaded", () => {
  // Connect
  document.getElementById("btnConnect").addEventListener("click", connect);
  
  // Refresh
  document.getElementById("btnRefresh").addEventListener("click", refreshAll);
  
  // Poke buttons
  document.getElementById("btnPokeA").addEventListener("click", () => doPoke("A"));
  document.getElementById("btnPokeB").addEventListener("click", () => doPoke("B"));
  
  // Deposit buttons
  document.querySelectorAll(".btn-deposit").forEach(btn => {
    btn.addEventListener("click", () => doDeposit(btn.dataset.user));
  });
  
  // Set Constraints buttons
  document.querySelectorAll(".btn-set-constraints").forEach(btn => {
    btn.addEventListener("click", () => doSetConstraints(btn.dataset.user));
  });
  
  // Auto-connect on load
  connect();
});
