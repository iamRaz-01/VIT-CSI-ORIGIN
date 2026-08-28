#!/usr/bin/env bash
# =============================================================================
# start-fork.sh — Start the Anvil Base mainnet fork
# CSI ORIGIN 2026, PS-12
#
# Run this ONCE at the start of the hackathon (Phase 1).
# Keep this terminal/process alive for the entire event.
# Anvil caches all fetched state locally — no further RPC calls after startup.
#
# USAGE:
#   bash script/start-fork.sh
#
# PREREQUISITES:
#   - Anvil installed (part of Foundry: https://getfoundry.sh)
#   - .env populated with BASE_RPC_URL and FORK_BLOCK_NUMBER
#   - Or: export BASE_RPC_URL=<url> FORK_BLOCK_NUMBER=<block> before calling
#
# Technical Architecture §6.2, §13
# INTERFACE_CONTRACTS.md §13.3
# =============================================================================
set -euo pipefail

# Load .env if it exists
if [ -f .env ]; then
  # shellcheck source=/dev/null
  source .env
fi

: "${BASE_RPC_URL:?BASE_RPC_URL must be set in .env or shell}"
: "${FORK_BLOCK_NUMBER:?FORK_BLOCK_NUMBER must be set in .env or shell}"

echo "=========================================="
echo "  Starting Anvil — Base mainnet fork"
echo "  Block: $FORK_BLOCK_NUMBER"
echo "  RPC:   $BASE_RPC_URL"
echo "=========================================="

# --code-size-limit 40000 is REQUIRED — Uniswap v4 contracts exceed the
# default 24576 byte limit. Omitting this flag is a documented hour-loss risk.
# Technical Architecture §13.
exec anvil \
  --fork-url "$BASE_RPC_URL" \
  --fork-block-number "$FORK_BLOCK_NUMBER" \
  --code-size-limit 40000 \
  --host 127.0.0.1 \
  --port 8545 \
  --accounts 10 \
  --balance 10000 \
  --chain-id 31337
