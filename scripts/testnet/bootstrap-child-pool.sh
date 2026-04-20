#!/usr/bin/env bash
# bootstrap-child-pool.sh — add full-range LP to an existing market that was
# created CLOB-only (e.g. a child of an event whose BOOTSTRAP_POOL_COUNT
# stopped short, or a binary market seeded without a pool).
#
# Wraps packages/diamond/script/Phase7BootstrapChildPool.s.sol. Uses the
# same 10k USDC / 20k YES at p=0.5 preset as create-market.sh.
#
# The underlying script is idempotent on `registerMarketPool` (hook guards
# the binding) and on `poolManager.initialize` (wrapped in try/catch) — so
# running this twice just appends liquidity at the existing price.
#
# Usage:
#   ./bootstrap-child-pool.sh 42
#
# Args:
#   $1  MARKET_ID  (required, uint — the market to seed LP for)
#
# Overrides (env vars):
#   LP_USDC_AMOUNT, LP_LIQUIDITY_DELTA, LP_FULL_RANGE, LP_TICK_RANGE
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

set -a
# shellcheck disable=SC1091
source "$SC_ROOT/.env"
set +a

: "${UNICHAIN_RPC_PRIMARY:?UNICHAIN_RPC_PRIMARY required}"
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY required}"
: "${DIAMOND_ADDRESS:?DIAMOND_ADDRESS required}"
: "${HOOK_PROXY_ADDRESS:?HOOK_PROXY_ADDRESS required}"
: "${POOL_MANAGER_ADDRESS:?POOL_MANAGER_ADDRESS required}"
: "${USDC_ADDRESS:?USDC_ADDRESS required}"

export NEW_DIAMOND="$DIAMOND_ADDRESS"
export NEW_HOOK_PROXY="$HOOK_PROXY_ADDRESS"

export LP_FULL_RANGE="${LP_FULL_RANGE:-true}"
export LP_USDC_AMOUNT="${LP_USDC_AMOUNT:-10000000000}"
export LP_LIQUIDITY_DELTA="${LP_LIQUIDITY_DELTA:-14142135624}"

MARKET_ID="${1:?usage: bootstrap-child-pool.sh <market_id>}"
export MARKET_ID

echo "== bootstrap-child-pool.sh =="
echo "market id:       $MARKET_ID"
echo "LP full-range:   $LP_FULL_RANGE"
echo "LP USDC amount:  $LP_USDC_AMOUNT raw (≈ $((LP_USDC_AMOUNT / 1000000)) USDC)"
echo "LP liquidity:    $LP_LIQUIDITY_DELTA"
echo

cd "$SC_ROOT/packages/diamond"
forge script script/Phase7BootstrapChildPool.s.sol:Phase7BootstrapChildPool \
    --rpc-url "$UNICHAIN_RPC_PRIMARY" \
    --broadcast \
    -vv
