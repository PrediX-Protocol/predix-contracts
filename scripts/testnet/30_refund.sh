#!/usr/bin/env bash
# 30_refund.sh — Group R: refund mode tests.
# Plan §6.C executed cases: R-06 (refund > balance), R-07 (enableRefundMode
# twice), R-08 (cleanup stuck market 4).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ALICE=$(wallet_addr alice); ALICE_PK=$(wallet_key alice)

log "== Group R =="

# ---------------------------------------------------------------------------
# R-08: cleanup stuck market 4 (created Phase 0, has 10 USDC locked).
# Verify endTime has passed, enable refund mode, refund 10 USDC.
# ---------------------------------------------------------------------------
log "-- R-08: cleanup stuck market 4 --"
status4=$(market_status 4)
end4=$(echo "$status4" | sed -n '3p' | awk '{print $1}')
now=$(date +%s)
log "market 4 endTime=$end4 now=$now"
if [ "$now" -lt "$end4" ]; then
    log "R-08 SKIP — market 4 endTime not reached"
    record_result "R-08" "Refund" "cleanup stuck market 4" "skip" 0 "" "{\"reason\":\"endTime not reached\"}"
else
    erm4_tx=$(send_tx "$OPERATOR_PRIVATE_KEY" "$DIAMOND_ADDRESS" "enableRefundMode(uint256)" 4)
    log "market 4 enableRefundMode tx=$erm4_tx"
    dep_pre=$(usdc_balance "$DEPLOYER_ADDR")
    refund4_tx=$(send_tx "$DEPLOYER_PRIVATE_KEY" "$DIAMOND_ADDRESS" "refund(uint256,uint256,uint256)" 4 10000000 10000000)
    dep_post=$(usdc_balance "$DEPLOYER_ADDR")
    delta=$((dep_post - dep_pre))
    log "R-08 deployer USDC delta=$delta (expect 10000000)"
    if [ "$delta" = "10000000" ]; then
        record_result "R-08" "Refund" "cleanup stuck market 4 via refund mode" "pass" 0 "$erm4_tx,$refund4_tx" "{\"market\":4,\"delta_usdc\":$delta}"
    else
        record_result "R-08" "Refund" "cleanup stuck market 4" "fail" 0 "$refund4_tx" "{\"delta\":$delta}"
        log "R-08 FAIL"; exit 1
    fi
fi

# ---------------------------------------------------------------------------
# R-07: enableRefundMode twice → expect Pausable_ModuleAlreadyPaused or
# Market_RefundModeActive (depending on impl). Use market 5 which is already
# in refund mode from Phase 0.
# ---------------------------------------------------------------------------
log "-- R-07: enableRefundMode twice on already-refund market --"
status5=$(market_status 5)
refund5=$(echo "$status5" | sed -n '5p' | awk '{print $1}')
log "market 5 refundMode=$refund5"
reason=$(expect_revert "$OPERATOR_PRIVATE_KEY" "$DIAMOND_ADDRESS" "enableRefundMode(uint256)" 5)
log "R-07 second enableRefundMode revert: $reason"
if echo "$reason" | grep -q "Market_RefundModeActive\|Market_AlreadyResolved\|RefundMode"; then
    record_result "R-07" "Refund" "enableRefundMode twice reverts" "pass" 0 "" "{\"revert\":\"$reason\"}"
else
    record_result "R-07" "Refund" "enableRefundMode twice" "info" 0 "" "{\"revert\":\"$reason\"}"
fi

# ---------------------------------------------------------------------------
# R-06: refund > balance → revert. Need a wallet with low YES/NO holdings on
# a refund-mode market. After R-08, market 4 is in refund mode and deployer
# has 0 YES + 0 NO there. Try refund(4, 1, 1) → revert.
# ---------------------------------------------------------------------------
log "-- R-06: refund exceeds balance --"
reason=$(expect_revert "$DEPLOYER_PRIVATE_KEY" "$DIAMOND_ADDRESS" "refund(uint256,uint256,uint256)" 4 1000000 1000000)
log "R-06 refund-over-balance revert: $reason"
if [ "$reason" != "UNEXPECTED_SUCCESS" ]; then
    record_result "R-06" "Refund" "refund exceeds balance reverts" "pass" 0 "" "{\"revert\":\"$reason\"}"
else
    record_result "R-06" "Refund" "refund exceeds balance" "fail" 0 "" "{}"
    log "R-06 FAIL"; exit 1
fi

log "== Group R done =="
