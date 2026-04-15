#!/usr/bin/env bash
# 50_access.sh — Group AC: access control sweep.
# Plan §6.E AC-on-01 (10-revert sweep) + AC-on-02 (grant rotation) + AC-on-03
# (operator self-role invariant during rotation).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ALICE=$(wallet_addr alice); ALICE_PK=$(wallet_key alice)

log "== Group AC =="

# ---------------------------------------------------------------------------
# AC-on-01: 10-revert sweep — deployer (no roles) tries every admin setter.
# Each must revert with AccessControl_MissingRole.
# ---------------------------------------------------------------------------
log "-- AC-on-01: 10-revert admin sweep (deployer signs) --"

declare -a SWEEP_RESULTS
sweep_idx=0
sweep() {
    local label="$1"; shift
    local sig="$1"; shift
    local reason
    reason=$(expect_revert "$DEPLOYER_PRIVATE_KEY" "$DIAMOND_ADDRESS" "$sig" "$@" || echo "")
    sweep_idx=$((sweep_idx + 1))
    if echo "$reason" | grep -q "AccessControl_MissingRole"; then
        log "  $sweep_idx. $label -> AccessControl_MissingRole ✓"
        SWEEP_RESULTS+=("{\"call\":\"$label\",\"revert\":\"AccessControl_MissingRole\"}")
        return 0
    else
        log "  $sweep_idx. $label -> UNEXPECTED: $reason"
        SWEEP_RESULTS+=("{\"call\":\"$label\",\"revert\":\"$reason\"}")
        return 1
    fi
}

# Use a probe address that doesn't matter
PROBE=0x000000000000000000000000000000000000bEEF
ok_count=0
sweep "setFeeRecipient" "setFeeRecipient(address)" "$PROBE" && ok_count=$((ok_count+1)) || true
sweep "setMarketCreationFee" "setMarketCreationFee(uint256)" "1" && ok_count=$((ok_count+1)) || true
sweep "setDefaultPerMarketCap" "setDefaultPerMarketCap(uint256)" "1" && ok_count=$((ok_count+1)) || true
sweep "setDefaultRedemptionFeeBps" "setDefaultRedemptionFeeBps(uint256)" "10" && ok_count=$((ok_count+1)) || true
sweep "setPerMarketCap" "setPerMarketCap(uint256,uint256)" "1" "1" && ok_count=$((ok_count+1)) || true
sweep "setPerMarketRedemptionFeeBps" "setPerMarketRedemptionFeeBps(uint256,uint16)" "1" "10" && ok_count=$((ok_count+1)) || true
sweep "approveOracle" "approveOracle(address)" "$PROBE" && ok_count=$((ok_count+1)) || true
sweep "revokeOracle" "revokeOracle(address)" "$MANUAL_ORACLE_ADDRESS" && ok_count=$((ok_count+1)) || true
sweep "pauseModule" "pauseModule(bytes32)" "$MODULE_MARKET" && ok_count=$((ok_count+1)) || true
sweep "enableRefundMode" "enableRefundMode(uint256)" "1" && ok_count=$((ok_count+1)) || true

extra=$(printf '%s\n' "${SWEEP_RESULTS[@]}" | jq -sc '{sweep:., ok:'$ok_count'}')
if [ "$ok_count" = "10" ]; then
    record_result "AC-on-01" "Access control" "deployer reverts on all 10 admin setters" "pass" 0 "" "$extra"
else
    record_result "AC-on-01" "Access control" "deployer admin sweep" "fail" 0 "" "$extra"
    log "AC-on-01 partial: $ok_count/10"
fi

# ---------------------------------------------------------------------------
# AC-on-02 + AC-on-03: grant ADMIN_ROLE to Alice → Alice calls setFeeRecipient
# → operator revokes → Alice's next call reverts. Continuous C05 invariant
# check: operator never loses ADMIN_ROLE during rotation.
# ---------------------------------------------------------------------------
log "-- AC-on-02 + AC-on-03: grant rotation + C05 --"

# Pre-condition: Alice has no ADMIN_ROLE; operator has ADMIN_ROLE
[ "$(has_role "$ADMIN_ROLE" "$ALICE")" = "false" ] || { log "Alice already admin"; exit 1; }
[ "$(has_role "$ADMIN_ROLE" "$OPERATOR_ADDR")" = "true" ] || { log "operator missing admin"; exit 1; }

# Snapshot current feeRecipient so we can restore it
FEE_RECIPIENT_PRE=$(cast call "$DIAMOND_ADDRESS" "feeRecipient()(address)" --rpc-url "$RPC")

# Cleanup handler: ensure Alice never retains ADMIN_ROLE on exit
cleanup_ac02() {
    log "[AC-on-02 cleanup] revoking ADMIN_ROLE from $ALICE if held"
    if [ "$(has_role "$ADMIN_ROLE" "$ALICE")" = "true" ]; then
        cast send "$DIAMOND_ADDRESS" "revokeRole(bytes32,address)" "$ADMIN_ROLE" "$ALICE" \
            --private-key "$OPERATOR_PRIVATE_KEY" --rpc-url "$RPC" >/dev/null || true
    fi
    if [ "$(cast call "$DIAMOND_ADDRESS" "feeRecipient()(address)" --rpc-url "$RPC")" != "$FEE_RECIPIENT_PRE" ]; then
        cast send "$DIAMOND_ADDRESS" "setFeeRecipient(address)" "$FEE_RECIPIENT_PRE" \
            --private-key "$OPERATOR_PRIVATE_KEY" --rpc-url "$RPC" >/dev/null || true
    fi
}
trap cleanup_ac02 EXIT INT TERM

# Step 1: operator grants ADMIN_ROLE to Alice
grant_tx=$(send_tx "$OPERATOR_PRIVATE_KEY" "$DIAMOND_ADDRESS" "grantRole(bytes32,address)" "$ADMIN_ROLE" "$ALICE")
log "operator → grant ADMIN_ROLE to alice tx=$grant_tx"
[ "$(has_role "$ADMIN_ROLE" "$ALICE")" = "true" ] || { log "grant failed"; exit 1; }
# C05 invariant: operator still admin
[ "$(has_role "$ADMIN_ROLE" "$OPERATOR_ADDR")" = "true" ] || { log "C05 violated: operator lost ADMIN"; exit 1; }

# Step 2: Alice calls setFeeRecipient (must succeed)
new_fee_recipient=0x000000000000000000000000000000000000DEAD
alice_set_tx=$(send_tx "$ALICE_PK" "$DIAMOND_ADDRESS" "setFeeRecipient(address)" "$new_fee_recipient")
log "alice → setFeeRecipient($new_fee_recipient) tx=$alice_set_tx"
current=$(cast call "$DIAMOND_ADDRESS" "feeRecipient()(address)" --rpc-url "$RPC")
[ "$(echo "$current" | tr 'A-Z' 'a-z')" = "$(echo "$new_fee_recipient" | tr 'A-Z' 'a-z')" ] || { log "feeRecipient not updated"; exit 1; }

# Step 3: operator revokes Alice's ADMIN_ROLE
revoke_tx=$(send_tx "$OPERATOR_PRIVATE_KEY" "$DIAMOND_ADDRESS" "revokeRole(bytes32,address)" "$ADMIN_ROLE" "$ALICE")
log "operator → revoke ADMIN_ROLE from alice tx=$revoke_tx"
[ "$(has_role "$ADMIN_ROLE" "$ALICE")" = "false" ] || { log "revoke failed"; exit 1; }
[ "$(has_role "$ADMIN_ROLE" "$OPERATOR_ADDR")" = "true" ] || { log "C05 violated post-revoke"; exit 1; }

# Step 4: Alice's next admin call reverts
reason=$(expect_revert "$ALICE_PK" "$DIAMOND_ADDRESS" "setFeeRecipient(address)" "$FEE_RECIPIENT_PRE")
log "alice → setFeeRecipient post-revoke: $reason"
if echo "$reason" | grep -q "AccessControl_MissingRole"; then
    record_result "AC-on-02" "Access control" "grant→use→revoke→denied rotation" "pass" 0 "$grant_tx,$alice_set_tx,$revoke_tx" "{\"final_revert\":\"AccessControl_MissingRole\"}"
    record_result "AC-on-03" "Access control" "C05 operator retains ADMIN throughout rotation" "pass" 0 "" "{\"invariant\":\"C05\"}"
else
    record_result "AC-on-02" "Access control" "grant→use→revoke→denied rotation" "fail" 0 "" "{\"revert\":\"$reason\"}"
fi

# Restore feeRecipient (cleanup_ac02 also handles this on exit)
cast send "$DIAMOND_ADDRESS" "setFeeRecipient(address)" "$FEE_RECIPIENT_PRE" \
    --private-key "$OPERATOR_PRIVATE_KEY" --rpc-url "$RPC" >/dev/null
log "feeRecipient restored to $FEE_RECIPIENT_PRE"

trap - EXIT INT TERM
log "== Group AC done =="
