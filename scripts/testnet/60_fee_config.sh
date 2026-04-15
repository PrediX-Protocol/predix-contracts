#!/usr/bin/env bash
# 60_fee_config.sh — Group FC: live fee accrual round trip.
# RUNS LAST per Phase 2 prompt §Q4 — mutates global state then resets via trap.
#
# TESTNET ONLY. DO NOT RUN ON MAINNET.
# Sets marketCreationFee = 1 USDC + defaultRedemptionFeeBps = 500 (5%),
# runs an end-to-end create→split→resolve→redeem flow that exercises both
# fees, then resets BOTH back to 0. Trap handler enforces the reset on every
# exit path (success, failure, SIGINT, SIGTERM).
#
# If the reset fails (post-test invariant), downstream BE/FE tests are
# blocked until manual operator cleanup via:
#   cast send $DIAMOND_ADDRESS "setMarketCreationFee(uint256)" 0 \
#     --private-key $OPERATOR_PRIVATE_KEY --rpc-url $UNICHAIN_RPC_PRIMARY
#   cast send $DIAMOND_ADDRESS "setDefaultRedemptionFeeBps(uint256)" 0 \
#     --private-key $OPERATOR_PRIVATE_KEY --rpc-url $UNICHAIN_RPC_PRIMARY
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ALICE=$(wallet_addr alice); ALICE_PK=$(wallet_key alice)

log "== Group FC =="

# Trap handler — resets fees on any exit path
cleanup_fc01() {
    log "[FC cleanup] resetting fees to 0"
    cast send "$DIAMOND_ADDRESS" "setMarketCreationFee(uint256)" 0 \
        --private-key "$OPERATOR_PRIVATE_KEY" --rpc-url "$RPC" >/dev/null 2>&1 || true
    cast send "$DIAMOND_ADDRESS" "setDefaultRedemptionFeeBps(uint256)" 0 \
        --private-key "$OPERATOR_PRIVATE_KEY" --rpc-url "$RPC" >/dev/null 2>&1 || true
}
trap cleanup_fc01 EXIT INT TERM

# Snapshot fee recipient balance for delta tracking
fee_rcpt_pre=$(usdc_balance "$OPERATOR_ADDR")

# Step 1: enable fees
log "-- FC-on-01 step 1: setMarketCreationFee=1e6, setDefaultRedemptionFeeBps=500 --"
fee1_tx=$(send_tx "$OPERATOR_PRIVATE_KEY" "$DIAMOND_ADDRESS" "setMarketCreationFee(uint256)" "1000000")
fee2_tx=$(send_tx "$OPERATOR_PRIVATE_KEY" "$DIAMOND_ADDRESS" "setDefaultRedemptionFeeBps(uint256)" "500")
log "fees set (creation=1 USDC, redemption=500 bps)"

# Verify
[ "$(cast call "$DIAMOND_ADDRESS" "marketCreationFee()(uint256)" --rpc-url "$RPC" | awk '{print $1}')" = "1000000" ] || { log "creation fee not set"; exit 1; }
[ "$(cast call "$DIAMOND_ADDRESS" "defaultRedemptionFeeBps()(uint256)" --rpc-url "$RPC" | awk '{print $1}')" = "500" ] || { log "redemption bps not set"; exit 1; }

# Step 2: alice creates market — should be charged 1 USDC
# Alice already has USDC approved to diamond from Group ML
NOW=$(date +%s); END=$((NOW + 35))
alice_pre=$(usdc_balance "$ALICE")
fc_create_tx=$(send_tx "$ALICE_PK" "$DIAMOND_ADDRESS" "createMarket(string,uint256,address)" \
    "fc-on-01-$NOW" "$END" "$MANUAL_ORACLE_ADDRESS")
FC_MID=$(market_count)
alice_post_create=$(usdc_balance "$ALICE")
create_fee_paid=$((alice_pre - alice_post_create))
log "FC-on-01 alice -USDC=$create_fee_paid (expect 1000000)"

# Step 3: alice splits 100 USDC
fc_split_tx=$(send_tx "$ALICE_PK" "$DIAMOND_ADDRESS" "splitPosition(uint256,uint256)" "$FC_MID" "100000000")
log "alice split 100"

# Wait for endTime
remain=$((END - $(date +%s) + 8))
[ $remain -gt 0 ] && { log "wait ${remain}s"; sleep $remain; }

fc_report_tx=$(send_tx "$OPERATOR_PRIVATE_KEY" "$MANUAL_ORACLE_ADDRESS" "report(uint256,bool)" "$FC_MID" "true")
fc_resolve_tx=$(send_tx "$ALICE_PK" "$DIAMOND_ADDRESS" "resolveMarket(uint256)" "$FC_MID")

# Step 4: alice redeems 100 YES — expect 100 USDC - 5% fee = 95 USDC
alice_pre_redeem=$(usdc_balance "$ALICE")
fc_redeem_tx=$(send_tx "$ALICE_PK" "$DIAMOND_ADDRESS" "redeem(uint256)" "$FC_MID")
alice_post_redeem=$(usdc_balance "$ALICE")
redeem_payout=$((alice_post_redeem - alice_pre_redeem))
log "FC-on-01 alice redeem payout=$redeem_payout (expect 95000000 = 100 - 5%)"

# Step 5: verify fee recipient (operator) accrued 1 + 5 = 6 USDC
fee_rcpt_post=$(usdc_balance "$OPERATOR_ADDR")
fee_rcpt_delta=$((fee_rcpt_post - fee_rcpt_pre))
log "FC-on-01 fee recipient delta=$fee_rcpt_delta (expect 6000000)"

# Verify all expectations
if [ "$create_fee_paid" = "1000000" ] && [ "$redeem_payout" = "95000000" ] && [ "$fee_rcpt_delta" = "6000000" ]; then
    record_result "FC-on-01" "Fee config" "live fee accrual round-trip" "pass" 0 \
        "$fee1_tx,$fee2_tx,$fc_create_tx,$fc_split_tx,$fc_report_tx,$fc_resolve_tx,$fc_redeem_tx" \
        "{\"market\":$FC_MID,\"creation_fee_paid\":$create_fee_paid,\"redeem_payout\":$redeem_payout,\"fee_recipient_delta\":$fee_rcpt_delta}"
else
    record_result "FC-on-01" "Fee config" "live fee accrual" "fail" 0 "$fc_redeem_tx" \
        "{\"creation_fee_paid\":$create_fee_paid,\"redeem_payout\":$redeem_payout,\"fee_recipient_delta\":$fee_rcpt_delta}"
fi

# Step 6: explicit reset (also the trap handler runs on exit, double-safety)
log "-- FC reset --"
creation_reset_tx=$(cast send "$DIAMOND_ADDRESS" "setMarketCreationFee(uint256)" 0 \
    --private-key "$OPERATOR_PRIVATE_KEY" --rpc-url "$RPC" --json | jq -r '.transactionHash')
log "creation fee reset tx=$creation_reset_tx"
redemption_reset_tx=$(cast send "$DIAMOND_ADDRESS" "setDefaultRedemptionFeeBps(uint256)" 0 \
    --private-key "$OPERATOR_PRIVATE_KEY" --rpc-url "$RPC" --json | jq -r '.transactionHash')
log "redemption bps reset tx=$redemption_reset_tx"

# Step 7: post-test invariant
cf=$(cast call "$DIAMOND_ADDRESS" "marketCreationFee()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
rf=$(cast call "$DIAMOND_ADDRESS" "defaultRedemptionFeeBps()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
log "post-FC fees: creation=$cf redemption=$rf"
[ "$cf" = "0" ] || { echo "🚨 marketCreationFee not reset: $cf"; exit 1; }
[ "$rf" = "0" ] || { echo "🚨 defaultRedemptionFeeBps not reset: $rf"; exit 1; }

trap - EXIT INT TERM
log "== Group FC done =="
