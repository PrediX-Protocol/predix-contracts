#!/usr/bin/env bash
# create-event.sh — one-shot event + N children bootstrap on Unichain Sepolia.
#
# Wraps packages/diamond/script/Phase7CreateEventFull.s.sol. Each child that
# gets a pool (up to BOOTSTRAP_POOL_COUNT, default: all) is seeded with a
# full-range LP of 10_000 USDC + 20_000 YES at yesPrice = 0.5.
#
# Usage:
#   ./create-event.sh "US President 2028" \
#       "Will Trump win?,Will Harris win?,Other candidate?" \
#       86400 3
#
# Args:
#   $1  EVENT_NAME                  (required)
#   $2  CANDIDATE_QUESTIONS         (required, comma-delimited, ≥2 entries)
#   $3  EVENT_END_OFFSET_SECONDS    (optional, default: 86400)
#   $4  BOOTSTRAP_POOL_COUNT        (optional, default: N children; set to 0
#                                    for CLOB-only)
#
# Cost: 30_000 USDC per bootstrapped child (2× split + 1× LP). Preflight in
# the forge script fails loud if deployer is underfunded. TestUSDC has open
# `mint(address,uint256)` — top up first if needed.
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

EVENT_NAME="${1:?usage: create-event.sh <name> <candidates_csv> [end_offset_seconds] [bootstrap_pool_count]}"
CANDIDATE_QUESTIONS="${2:?candidates required, comma-delimited}"
EVENT_END_OFFSET_SECONDS="${3:-86400}"

# If BOOTSTRAP_POOL_COUNT unset, default to candidate count so every child
# gets a pool. User can pass 0 explicitly to stay CLOB-only.
if [[ $# -ge 4 ]]; then
    BOOTSTRAP_POOL_COUNT="$4"
else
    # shellcheck disable=SC2034
    BOOTSTRAP_POOL_COUNT="$(awk -F',' '{print NF}' <<<"$CANDIDATE_QUESTIONS")"
fi

export EVENT_NAME CANDIDATE_QUESTIONS EVENT_END_OFFSET_SECONDS BOOTSTRAP_POOL_COUNT

echo "== create-event.sh =="
echo "name:            $EVENT_NAME"
echo "candidates:      $CANDIDATE_QUESTIONS"
echo "end offset:      ${EVENT_END_OFFSET_SECONDS}s"
echo "pools to seed:   $BOOTSTRAP_POOL_COUNT"
echo "LP full-range:   $LP_FULL_RANGE"
echo "LP USDC / pool:  $LP_USDC_AMOUNT raw (≈ $((LP_USDC_AMOUNT / 1000000)) USDC)"
echo "LP liquidity:    $LP_LIQUIDITY_DELTA"
echo

cd "$SC_ROOT/packages/diamond"
forge script script/Phase7CreateEventFull.s.sol:Phase7CreateEventFull \
    --rpc-url "$UNICHAIN_RPC_PRIMARY" \
    --broadcast \
    -vv
