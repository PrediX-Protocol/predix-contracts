#!/usr/bin/env bash
# bump-pin-block.sh
# ----------------------------------------------------------------------------
# Bumps UNICHAIN_MAINNET_PIN_BLOCK to (current block - 100) in .env.example.
# A 100-block buffer protects against reorgs while keeping tests recent.
#
# Run quarterly OR before each mainnet release. Commits the bump in a PR so
# all CI runs (current branch + nightly) pick up the new pin atomically.
#
# Usage:
#   UNICHAIN_RPC_PRIMARY=https://mainnet.unichain.org ./scripts/bump-pin-block.sh
#
# Exit codes:
#   0 — bumped successfully (or no change needed)
#   1 — RPC error or env var missing
#   2 — pin block is already at-or-newer than (current - 100), no bump needed
# ----------------------------------------------------------------------------
set -euo pipefail

RPC="${UNICHAIN_RPC_PRIMARY:-https://mainnet.unichain.org}"
ENV_FILE="$(git rev-parse --show-toplevel)/.env.example"
BUFFER=100

if ! command -v cast >/dev/null 2>&1; then
    echo "Error: 'cast' not found in PATH. Install Foundry: https://book.getfoundry.sh/getting-started/installation"
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: $ENV_FILE not found"
    exit 1
fi

echo "Querying current block on $RPC..."
CURRENT=$(cast block-number --rpc-url "$RPC" 2>/dev/null) || {
    echo "Error: RPC call failed. Check UNICHAIN_RPC_PRIMARY."
    exit 1
}

TARGET=$((CURRENT - BUFFER))

CURRENT_PIN=$(grep -E "^UNICHAIN_MAINNET_PIN_BLOCK=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d ' "' || echo "")
if [[ -z "$CURRENT_PIN" ]]; then
    CURRENT_PIN=0
fi

echo "Current block:    $CURRENT"
echo "Target pin block: $TARGET (current - $BUFFER)"
echo "Existing pin:     $CURRENT_PIN"

if [[ "$CURRENT_PIN" -ge "$TARGET" ]]; then
    echo "No bump needed: existing pin $CURRENT_PIN is at-or-newer than target $TARGET."
    exit 2
fi

# Idempotent update: replace existing line OR append new line if missing.
# Use a portable sed invocation. Backup file via .bak suffix for both BSD + GNU sed.
if grep -qE "^UNICHAIN_MAINNET_PIN_BLOCK=" "$ENV_FILE" 2>/dev/null; then
    sed -i.bak "s/^UNICHAIN_MAINNET_PIN_BLOCK=.*/UNICHAIN_MAINNET_PIN_BLOCK=$TARGET/" "$ENV_FILE"
    rm "$ENV_FILE.bak"
    echo "Replaced UNICHAIN_MAINNET_PIN_BLOCK in $ENV_FILE"
else
    echo "" >> "$ENV_FILE"
    echo "# Pin block for fork test reproducibility. Bump quarterly via scripts/bump-pin-block.sh" >> "$ENV_FILE"
    echo "UNICHAIN_MAINNET_PIN_BLOCK=$TARGET" >> "$ENV_FILE"
    echo "Appended UNICHAIN_MAINNET_PIN_BLOCK to $ENV_FILE"
fi
echo "Now set to: UNICHAIN_MAINNET_PIN_BLOCK=$TARGET"
echo
echo "Next steps:"
echo "  1. Run fork tests to verify: 'make test-fork' or per-package 'forge test --match-path test/fork/*'"
echo "  2. Commit the change with message: 'chore(test): bump pin block to $TARGET'"
echo "  3. Open PR — CI will run fork tests against the new pin block."
