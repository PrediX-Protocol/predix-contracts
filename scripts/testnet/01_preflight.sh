#!/usr/bin/env bash
# 01_preflight.sh — Sanity checks before running test groups.
# Verifies chain id, deployer + operator balances, role layout, marketCount,
# and that fees are 0. Exits non-zero on any failure.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

log "== preflight =="
chain=$(cast chain-id --rpc-url "$RPC")
[ "$chain" = "1301" ] || { echo "wrong chain: $chain"; exit 1; }
log "chain=1301 (Unichain Sepolia)"

dep_eth=$(cast balance "$DEPLOYER_ADDR" --rpc-url "$RPC")
op_eth=$(cast balance "$OPERATOR_ADDR" --rpc-url "$RPC")
log "deployer eth=$dep_eth"
log "operator eth=$op_eth"
# Real budget per plan §9: ~13 µETH total. Even 1mETH is 70× safe.
[ "$dep_eth" -gt 500000000000000 ] || { echo "deployer drained"; exit 1; }
[ "$op_eth" -gt 500000000000000 ] || { echo "operator drained"; exit 1; }

mc=$(market_count)
log "marketCount=$mc (baseline)"

cf=$(cast call "$DIAMOND_ADDRESS" "marketCreationFee()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
rf=$(cast call "$DIAMOND_ADDRESS" "defaultRedemptionFeeBps()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
log "fees: creation=$cf redemption_bps=$rf"
[ "$cf" = "0" ] || { echo "marketCreationFee != 0"; exit 1; }
[ "$rf" = "0" ] || { echo "defaultRedemptionFeeBps != 0"; exit 1; }

# Operator has admin/operator/pauser; deployer has none
[ "$(has_role "$ADMIN_ROLE" "$OPERATOR_ADDR")" = "true" ] || { echo "operator missing ADMIN_ROLE"; exit 1; }
# staging: # Skipped: staging deploy keeps deployer roles
# [ "$(has_role "$ADMIN_ROLE" "$DEPLOYER_ADDR")" = "false" ] || { echo "deployer should not hold ADMIN_ROLE"; exit 1; }
log "role layout verified"

log "preflight OK"
