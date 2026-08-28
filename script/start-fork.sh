#!/usr/bin/env bash
# =============================================================================
# start-fork.sh — Start the Anvil Base mainnet fork
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

# Resolve project root directory dynamically
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env automatically with export enabled
if [ -f "$ROOT_DIR/.env" ]; then
  set -o allexport
  eval "$(tr -d '\r' < "$ROOT_DIR/.env")"
  set +o allexport
fi

: "${BASE_RPC_URL:?BASE_RPC_URL must be set in .env or shell}"
: "${FORK_BLOCK_NUMBER:?FORK_BLOCK_NUMBER must be set in .env or shell}"

echo "=========================================="
echo "  Starting Anvil — Base mainnet fork"
echo "  Block: $FORK_BLOCK_NUMBER"
echo "  RPC:   $BASE_RPC_URL"
echo "=========================================="

ANVIL_CMD="anvil"
if ! command -v anvil &> /dev/null; then
  if command -v anvil.exe &> /dev/null; then
    ANVIL_CMD="anvil.exe"
  else
    echo "Error: anvil binary not found on PATH."
    exit 1
  fi
fi

exec "$ANVIL_CMD" \
  --fork-url "$BASE_RPC_URL" \
  --fork-block-number "$FORK_BLOCK_NUMBER" \
  --code-size-limit 40000 \
  --host 127.0.0.1 \
  --port 8545 \
  --accounts 10 \
  --balance 10000 \
  --chain-id 31337
