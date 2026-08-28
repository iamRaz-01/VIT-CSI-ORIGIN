#!/usr/bin/env bash
# =============================================================================
# fund-demo-wallets.sh — Fund demo wallets with test ETH and USDC
# CSI ORIGIN 2026, PS-12
#
# Uses Anvil's `anvil_impersonateAccount` + `anvil_setBalance` cheatcodes to
# give demo wallets unlimited test ETH and USDC without touching any live network.
#
# Technical Architecture §13: "anvil_impersonateAccount + anvil_setBalance
# give the team unlimited test USDC and ETH"
#
# USAGE (after Anvil fork is running):
#   bash script/fund-demo-wallets.sh <USER_A_ADDRESS> <USER_B_ADDRESS>
#
# The USDC whale address is the Coinbase/Circle reserve wallet on Base mainnet,
# which holds enough USDC to fund any demo. Impersonation works on a local fork.
# =============================================================================
set -euo pipefail

ANVIL_URL="${ANVIL_URL:-http://127.0.0.1:8545}"
USDC="${USDC_ADDRESS:-0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913}"
# A known large USDC holder on Base mainnet (impersonatable on the fork)
USDC_WHALE="0x0B0A5886664376F59C351ba3f598C8A8B4D0A6f3"
DEMO_AMOUNT_ETH="0x56BC75E2D63100000"      # 100 ETH in wei (hex)
DEMO_AMOUNT_USDC="1000000000000"           # 1,000,000 USDC (6 decimals)

USER_A="${1:?Usage: fund-demo-wallets.sh <USER_A_ADDR> <USER_B_ADDR>}"
USER_B="${2:?Usage: fund-demo-wallets.sh <USER_A_ADDR> <USER_B_ADDR>}"

fund_wallet() {
  local addr="$1"
  echo "Funding $addr with ETH..."
  cast rpc anvil_setBalance "$addr" "$DEMO_AMOUNT_ETH" --rpc-url "$ANVIL_URL" > /dev/null

  echo "Impersonating USDC whale to fund $addr with USDC..."
  cast rpc anvil_impersonateAccount "$USDC_WHALE" --rpc-url "$ANVIL_URL" > /dev/null
  cast send "$USDC" \
    "transfer(address,uint256)" \
    "$addr" \
    "$DEMO_AMOUNT_USDC" \
    --from "$USDC_WHALE" \
    --unlocked \
    --rpc-url "$ANVIL_URL" > /dev/null
  cast rpc anvil_stopImpersonatingAccount "$USDC_WHALE" --rpc-url "$ANVIL_URL" > /dev/null

  local usdc_bal
  usdc_bal=$(cast call "$USDC" "balanceOf(address)(uint256)" "$addr" --rpc-url "$ANVIL_URL")
  echo "  USDC balance: $usdc_bal"
}

echo "=== Funding Demo Wallets ==="
fund_wallet "$USER_A"
fund_wallet "$USER_B"
echo "=== Done ==="
