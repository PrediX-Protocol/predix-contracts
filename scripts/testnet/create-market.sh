#!/usr/bin/env bash
# create-market.sh — one-shot binary market bootstrap on Unichain Sepolia.
#
# Wraps packages/diamond/script/Phase7CreateMarketFull.s.sol with full-range
# LP defaults aligned to the staging requirement:
#   10_000 USDC + 20_000 YES at initial yesPrice = 0.5 USDC/YES.
#
# Usage:
#   ./create-market.sh "Will BTC close above 100k on 2026-04-20?" 86400
#
# Args:
#   $1  MARKET_QUESTION            (required)
#   $2  MARKET_END_OFFSET_SECONDS  (optional, default: 86400 = 1 day from now)
#
# Overrides (env vars, same names as the underlying forge script):
#   LP_USDC_AMOUNT, LP_LIQUIDITY_DELTA, LP_FULL_RANGE, MARKET_ORACLE
#
# Deployer must hold ≥ 3×LP_USDC_AMOUNT USDC. TestUSDC has an open
# `mint(address,uint256)` if you need to top up.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load env. `.env` is a symlink to testenv.local per root CLAUDE.md convention.
set -a
# shellcheck disable=SC1091
source "$SC_ROOT/.env"
set +a

: "${UNICHAIN_RPC_PRIMARY:?UNICHAIN_RPC_PRIMARY required}"
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY required}"
: "${DIAMOND_ADDRESS:?DIAMOND_ADDRESS required}"
: "${HOOK_PROXY_ADDRESS:?HOOK_PROXY_ADDRESS required}"
: "${MANUAL_ORACLE_ADDRESS:?MANUAL_ORACLE_ADDRESS required}"
: "${POOL_MANAGER_ADDRESS:?POOL_MANAGER_ADDRESS required}"
: "${USDC_ADDRESS:?USDC_ADDRESS required}"

# Map project-level env names → names the forge script reads.
export NEW_DIAMOND="$DIAMOND_ADDRESS"
export NEW_HOOK_PROXY="$HOOK_PROXY_ADDRESS"
export NEW_MANUAL_ORACLE="$MANUAL_ORACLE_ADDRESS"

# Full-range LP defaults — 10k USDC + 20k YES at p = 0.5 USDC/YES.
#   amount_USDC = L × √P, amount_YES = L / √P (full range, P = 0.5)
#   L ≈ √(10_000 × 20_000) × 1e6 = √2 × 1e10 ≈ 14_142_135_624
export LP_FULL_RANGE="${LP_FULL_RANGE:-true}"
export LP_USDC_AMOUNT="${LP_USDC_AMOUNT:-10000000000}"           # 10k USDC raw (6 dec)
export LP_LIQUIDITY_DELTA="${LP_LIQUIDITY_DELTA:-14142135624}"    # ≈ √2 × 10^10

# Args
MARKET_QUESTION="${1:?usage: create-market.sh <question> [end_offset_seconds]}"
MARKET_END_OFFSET_SECONDS="${2:-86400}"
export MARKET_QUESTION MARKET_END_OFFSET_SECONDS

echo "== create-market.sh =="
echo "question:        $MARKET_QUESTION"
echo "end offset:      ${MARKET_END_OFFSET_SECONDS}s"
echo "oracle:          $NEW_MANUAL_ORACLE"
echo "diamond:         $NEW_DIAMOND"
echo "LP full-range:   $LP_FULL_RANGE"
echo "LP USDC amount:  $LP_USDC_AMOUNT raw (≈ $((LP_USDC_AMOUNT / 1000000)) USDC)"
echo "LP liquidity:    $LP_LIQUIDITY_DELTA"
echo

cd "$SC_ROOT/packages/diamond"
forge script script/Phase7CreateMarketFull.s.sol:Phase7CreateMarketFull \
    --rpc-url "$UNICHAIN_RPC_PRIMARY" \
    --broadcast \
    -vv
