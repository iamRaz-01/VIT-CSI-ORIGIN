#!/usr/bin/env bash
# =============================================================================
# fund-demo-wallets.sh — Fund demo wallets with test ETH and USDC
# CSI ORIGIN 2026, PS-12
# =============================================================================
set -euo pipefail

# Add Foundry to PATH for Linux, WSL2, Git Bash, and Windows PATHs
for bin_dir in \
  "$HOME/.foundry/bin" \
  "/mnt/c/Users/admin/.foundry/bin" \
  "/mnt/c/Users/${USER:-admin}/.foundry/bin" \
  "/c/Users/admin/.foundry/bin"; do
  if [ -d "$bin_dir" ]; then
    export PATH="$bin_dir:$PATH"
  fi
done

CAST_CMD="cast"
if ! command -v cast &> /dev/null; then
  if command -v cast.exe &> /dev/null; then
    CAST_CMD="cast.exe"
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$ROOT_DIR/.env" ]; then
  set -o allexport
  eval "$(tr -d '\r' < "$ROOT_DIR/.env")"
  set +o allexport
fi

ANVIL_URL="${ANVIL_URL:-http://127.0.0.1:8545}"
USDC="${USDC_ADDRESS:-0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913}"
USDC_WHALE="0x0B0A5886664376F59C351ba3f598C8A8B4D0A6f3"
DEMO_AMOUNT_ETH="0x56BC75E2D63100000"      # 100 ETH in wei (hex)
DEMO_AMOUNT_USDC="1000000000000"           # 1,000,000 USDC (6 decimals)

USER_A="${1:?Usage: fund-demo-wallets.sh <USER_A_ADDR> <USER_B_ADDR>}"
USER_B="${2:?Usage: fund-demo-wallets.sh <USER_A_ADDR> <USER_B_ADDR>}"

fund_wallet() {
  local addr="$1"
  echo "Funding $addr with ETH..."
  "$CAST_CMD" rpc anvil_setBalance "$addr" "$DEMO_AMOUNT_ETH" --rpc-url "$ANVIL_URL" > /dev/null

  echo "Impersonating USDC whale to fund $addr with USDC..."
  "$CAST_CMD" rpc anvil_impersonateAccount "$USDC_WHALE" --rpc-url "$ANVIL_URL" > /dev/null
  "$CAST_CMD" send "$USDC" \
    "transfer(address,uint256)" \
    "$addr" \
    "$DEMO_AMOUNT_USDC" \
    --from "$USDC_WHALE" \
    --unlocked \
    --rpc-url "$ANVIL_URL" > /dev/null
  "$CAST_CMD" rpc anvil_stopImpersonatingAccount "$USDC_WHALE" --rpc-url "$ANVIL_URL" > /dev/null

  local usdc_bal
  usdc_bal=$("$CAST_CMD" call "$USDC" "balanceOf(address)(uint256)" "$addr" --rpc-url "$ANVIL_URL")
  echo "  USDC balance: $usdc_bal"
}

echo "=== Funding Demo Wallets ==="
fund_wallet "$USER_A"
fund_wallet "$USER_B"
echo "=== Done ==="
