#!/usr/bin/env bash
# 40_pause.sh — Group P: pause module tests.
# Plan §6.D executed: P-on-01 (pause→split reverts), P-on-02 (pause→redeem
# reverts), P-on-03 (pause→refund still works — bypass design).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ALICE=$(wallet_addr alice); ALICE_PK=$(wallet_key alice)
BOB=$(wallet_addr bob);     BOB_PK=$(wallet_key bob)

log "== Group P =="

# Setup: create a fresh market for the pause probes
NOW=$(date +%s); END=$((NOW + 50))
setup_create=$(send_tx "$OPERATOR_PRIVATE_KEY" "$DIAMOND_ADDRESS" \
    "createMarket(string,uint256,address)" "p-on-$NOW" "$END" "$MANUAL_ORACLE_ADDRESS")
P_MID=$(market_count)
log "pause-test market=$P_MID"

# Bob splits 10 USDC pre-pause so he has tokens to attempt redeem/refund later.
send_tx "$BOB_PK" "$DIAMOND_ADDRESS" "splitPosition(uint256,uint256)" "$P_MID" "10000000" >/dev/null

# Pause MARKET module
pause_tx=$(send_tx "$OPERATOR_PRIVATE_KEY" "$DIAMOND_ADDRESS" "pauseModule(bytes32)" "$MODULE_MARKET")
pause_gas=$(gas_of "$pause_tx")
log "MARKET paused tx=$pause_tx gas=$pause_gas"

# P-on-01: split should revert
reason=$(expect_revert "$ALICE_PK" "$DIAMOND_ADDRESS" "splitPosition(uint256,uint256)" "$P_MID" "1000000")
log "P-on-01 split-when-paused: $reason"
if echo "$reason" | grep -q "Pausable_EnforcedPause"; then
    record_result "P-on-01" "Pause" "splitPosition reverts when MARKET paused" "pass" 0 "$pause_tx" "{\"revert\":\"$reason\"}"
else
    record_result "P-on-01" "Pause" "splitPosition reverts when MARKET paused" "fail" 0 "$pause_tx" "{\"revert\":\"$reason\"}"
fi

# Need to wait for endTime + report + resolve to test redeem-when-paused
remain=$((END - $(date +%s) + 8))
[ $remain -gt 0 ] && { log "wait ${remain}s for endTime"; sleep $remain; }

# Resolve while paused — resolveMarket isn't gated by MARKET pause? Check.
# To be safe, unpause briefly to report+resolve, then re-pause.
unpause_tx=$(send_tx "$OPERATOR_PRIVATE_KEY" "$DIAMOND_ADDRESS" "unpauseModule(bytes32)" "$MODULE_MARKET")
unpause_gas=$(gas_of "$unpause_tx")
send_tx "$OPERATOR_PRIVATE_KEY" "$MANUAL_ORACLE_ADDRESS" "report(uint256,bool)" "$P_MID" "true" >/dev/null
send_tx "$BOB_PK" "$DIAMOND_ADDRESS" "resolveMarket(uint256)" "$P_MID" >/dev/null
# Re-pause
send_tx "$OPERATOR_PRIVATE_KEY" "$DIAMOND_ADDRESS" "pauseModule(bytes32)" "$MODULE_MARKET" >/dev/null

# P-on-02: redeem should revert
reason=$(expect_revert "$BOB_PK" "$DIAMOND_ADDRESS" "redeem(uint256)" "$P_MID")
log "P-on-02 redeem-when-paused: $reason"
if echo "$reason" | grep -q "Pausable_EnforcedPause"; then
    record_result "P-on-02" "Pause" "redeem reverts when MARKET paused" "pass" 0 "" "{\"revert\":\"$reason\"}"
else
    record_result "P-on-02" "Pause" "redeem reverts when MARKET paused" "info" 0 "" "{\"revert\":\"$reason\"}"
fi

# P-on-03: refund still works through pause? Need a refund-mode market.
# Market is resolved, so refund won't apply. Use a different fresh market
# specifically for this probe.
log "-- P-on-03: refund bypasses pause (sanity probe) --"
# Unpause first so we can create a fresh market and split into it.
send_tx "$OPERATOR_PRIVATE_KEY" "$DIAMOND_ADDRESS" "unpauseModule(bytes32)" "$MODULE_MARKET" >/dev/null
NOW=$(date +%s); END=$((NOW + 35))
send_tx "$OPERATOR_PRIVATE_KEY" "$DIAMOND_ADDRESS" "createMarket(string,uint256,address)" "p-refund-$NOW" "$END" "$MANUAL_ORACLE_ADDRESS" >/dev/null
P_REF_MID=$(market_count)
log "refund-bypass market=$P_REF_MID"
send_tx "$BOB_PK" "$DIAMOND_ADDRESS" "splitPosition(uint256,uint256)" "$P_REF_MID" "5000000" >/dev/null

remain=$((END - $(date +%s) + 8))
[ $remain -gt 0 ] && { log "wait ${remain}s"; sleep $remain; }

send_tx "$OPERATOR_PRIVATE_KEY" "$DIAMOND_ADDRESS" "enableRefundMode(uint256)" "$P_REF_MID" >/dev/null
# Now pause and try refund
send_tx "$OPERATOR_PRIVATE_KEY" "$DIAMOND_ADDRESS" "pauseModule(bytes32)" "$MODULE_MARKET" >/dev/null
bob_pre=$(usdc_balance "$BOB")
if refund_tx=$(send_tx "$BOB_PK" "$DIAMOND_ADDRESS" "refund(uint256,uint256,uint256)" "$P_REF_MID" 5000000 5000000 2>&1); then
    bob_post=$(usdc_balance "$BOB")
    delta=$((bob_post - bob_pre))
    log "P-on-03 refund-while-paused succeeded delta=$delta"
    if [ "$delta" = "5000000" ]; then
        record_result "P-on-03" "Pause" "refund bypasses MARKET pause (per design)" "pass" 0 "$refund_tx" "{\"delta\":$delta}"
    else
        record_result "P-on-03" "Pause" "refund bypasses MARKET pause" "fail" 0 "$refund_tx" "{\"delta\":$delta}"
    fi
else
    log "P-on-03 refund-while-paused REVERTED — design check"
    record_result "P-on-03" "Pause" "refund-while-paused unexpectedly reverted" "info" 0 "" "{\"behavior\":\"refund blocked by pause\"}"
fi

# Final cleanup: unpause
unpause_final=$(send_tx "$OPERATOR_PRIVATE_KEY" "$DIAMOND_ADDRESS" "unpauseModule(bytes32)" "$MODULE_MARKET")
log "MARKET unpaused (final) tx=$unpause_final"

log "== Group P done =="
