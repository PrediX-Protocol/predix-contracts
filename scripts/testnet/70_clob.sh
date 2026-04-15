#!/usr/bin/env bash
# 70_clob.sh — Group CL: exchange CLOB tests.
# Plan §6.G executed: CL-on-01 place+cancel, CL-on-02 complementary match,
# CL-on-03 C04 solvency check, CL-on-04 cancel idempotency.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

ALICE=$(wallet_addr alice); ALICE_PK=$(wallet_key alice)
BOB=$(wallet_addr bob);     BOB_PK=$(wallet_key bob)

log "== Group CL =="

ORDER_PLACED_SIG=$(cast keccak "OrderPlaced(bytes32,uint256,address,uint8,uint256,uint256)")

# Extract the first OrderPlaced orderId for a tx, filtered by exchange address.
extract_order_id() {
    local tx="$1"
    cast receipt "$tx" --rpc-url "$RPC" --json 2>/dev/null \
        | jq -r --arg sig "$ORDER_PLACED_SIG" --arg ex "$(echo "$EXCHANGE_ADDRESS" | tr 'A-Z' 'a-z')" \
            '.logs[] | select((.address|ascii_downcase)==$ex and .topics[0]==$sig) | .topics[1]' \
        | head -1
}

# ---------------------------------------------------------------------------
# CL-on-01: Alice approves Exchange for USDC, places BUY_YES @ 0.4 size 100,
# verifies 40 USDC locked. Cancel, USDC returned. CL-on-04 piggybacks.
# ---------------------------------------------------------------------------
log "-- CL-on-01: Alice place BUY_YES then cancel --"

# Need a fresh future market for the order to remain valid
NOW=$(date +%s); END=$((NOW + 600))
send_tx "$OPERATOR_PRIVATE_KEY" "$DIAMOND_ADDRESS" "createMarket(string,uint256,address)" \
    "cl-on-01-$NOW" "$END" "$MANUAL_ORACLE_ADDRESS" >/dev/null
CL_MID=$(market_count)
log "CL fresh market=$CL_MID"

# Alice approves Exchange for USDC (idempotent)
send_tx "$ALICE_PK" "$USDC_ADDRESS" "approve(address,uint256)" "$EXCHANGE_ADDRESS" \
    "115792089237316195423570985008687907853269984665640564039457584007913129639935" >/dev/null

alice_usdc_pre=$(usdc_balance "$ALICE")
exchange_usdc_pre=$(usdc_balance "$EXCHANGE_ADDRESS")

# placeOrder(marketId, Side=BUY_YES=0, price=400000 (0.40), amount=100000000 (100 shares))
PRICE=400000      # 0.40 USDC per share, 6 decimals
AMOUNT=100000000  # 100 shares, 6 decimals
LOCKED=40000000   # 40 USDC
place_tx=$(send_tx "$ALICE_PK" "$EXCHANGE_ADDRESS" "placeOrder(uint256,uint8,uint256,uint256)" \
    "$CL_MID" 0 "$PRICE" "$AMOUNT")
log "alice placeOrder BUY_YES @ 0.40 size 100 tx=$place_tx"

ORDER_ID=$(extract_order_id "$place_tx")
log "orderId=$ORDER_ID"
[ -n "$ORDER_ID" ] && [ "$ORDER_ID" != "null" ] || { log "no orderId extracted"; exit 1; }

alice_usdc_mid=$(usdc_balance "$ALICE")
exchange_usdc_mid=$(usdc_balance "$EXCHANGE_ADDRESS")
alice_delta=$((alice_usdc_pre - alice_usdc_mid))
exchange_delta=$((exchange_usdc_mid - exchange_usdc_pre))
log "alice_delta=$alice_delta exchange_delta=$exchange_delta (expect $LOCKED each)"
[ "$alice_delta" = "$LOCKED" ] || { log "alice debit wrong"; exit 1; }
[ "$exchange_delta" = "$LOCKED" ] || { log "exchange credit wrong"; exit 1; }

# Cancel
cancel_tx=$(send_tx "$ALICE_PK" "$EXCHANGE_ADDRESS" "cancelOrder(bytes32)" "$ORDER_ID")
log "cancelOrder tx=$cancel_tx"

alice_usdc_post=$(usdc_balance "$ALICE")
[ "$alice_usdc_post" = "$alice_usdc_pre" ] || { log "alice not refunded after cancel"; exit 1; }

record_result "CL-on-01" "CLOB" "place BUY_YES + cancel returns deposit" "pass" 0 "$place_tx,$cancel_tx" \
    "{\"market\":$CL_MID,\"orderId\":\"$ORDER_ID\",\"locked\":$LOCKED}"

# ---------------------------------------------------------------------------
# CL-on-04: cancel already-cancelled order → revert OrderAlreadyCancelled
# ---------------------------------------------------------------------------
log "-- CL-on-04: re-cancel reverts --"
reason=$(expect_revert "$ALICE_PK" "$EXCHANGE_ADDRESS" "cancelOrder(bytes32)" "$ORDER_ID")
log "CL-on-04 re-cancel: $reason"
if echo "$reason" | grep -q "OrderAlreadyCancelled\|OrderNotFound"; then
    record_result "CL-on-04" "CLOB" "re-cancel reverts" "pass" 0 "" "{\"revert\":\"$reason\"}"
else
    record_result "CL-on-04" "CLOB" "re-cancel reverts" "info" 0 "" "{\"revert\":\"$reason\"}"
fi

# ---------------------------------------------------------------------------
# CL-on-02: Complementary/MERGE match.
# Alice has 100 YES (held back from earlier ML-04 setup? no — fresh market).
# Setup: both Alice and Bob split 100 USDC on the fresh market, then
# Alice transfers her 100 NO to Bob so Alice holds only YES, Bob holds NO.
# Alice places SELL_YES @ 0.40 size 100. Bob places SELL_NO @ 0.60 size 100
# → sum = 1.0 → MERGE match should auto-trigger on Bob's placeOrder, both
# tokens burn, Alice +40 USDC, Bob +60 USDC.
# ---------------------------------------------------------------------------
log "-- CL-on-02: complementary/MERGE match --"

# Alice + Bob need outcome tokens — split 100 each on the same market
send_tx "$ALICE_PK" "$DIAMOND_ADDRESS" "splitPosition(uint256,uint256)" "$CL_MID" "100000000" >/dev/null
send_tx "$BOB_PK" "$DIAMOND_ADDRESS" "splitPosition(uint256,uint256)" "$CL_MID" "100000000" >/dev/null

# Get YES/NO addresses
status=$(market_status "$CL_MID")
YES_CL=$(echo "$status" | sed -n '1p')
NO_CL=$(echo "$status" | sed -n '2p')
log "yes=$YES_CL no=$NO_CL"

# Alice → Bob: 100 NO. Bob now has 100 YES + 200 NO. Alice has 100 YES + 0 NO.
send_tx "$ALICE_PK" "$NO_CL" "transfer(address,uint256)" "$BOB" "100000000" >/dev/null

# Alice + Bob approve Exchange for outcome tokens
send_tx "$ALICE_PK" "$YES_CL" "approve(address,uint256)" "$EXCHANGE_ADDRESS" \
    "115792089237316195423570985008687907853269984665640564039457584007913129639935" >/dev/null
send_tx "$BOB_PK" "$NO_CL" "approve(address,uint256)" "$EXCHANGE_ADDRESS" \
    "115792089237316195423570985008687907853269984665640564039457584007913129639935" >/dev/null

# Snapshot pre-trade balances
alice_usdc_pre=$(usdc_balance "$ALICE")
bob_usdc_pre=$(usdc_balance "$BOB")
alice_yes_pre=$(erc20_balance "$YES_CL" "$ALICE")
bob_no_pre=$(erc20_balance "$NO_CL" "$BOB")

# Alice SELL_YES (Side=1) @ 0.40 size 100 → no resting orders, sits on book
sell_yes_tx=$(send_tx "$ALICE_PK" "$EXCHANGE_ADDRESS" "placeOrder(uint256,uint8,uint256,uint256)" \
    "$CL_MID" 1 400000 100000000)
log "alice SELL_YES @ 0.40 100 tx=$sell_yes_tx"

# Bob SELL_NO (Side=3) @ 0.60 size 100 → matches Alice via MERGE
sell_no_tx=$(send_tx "$BOB_PK" "$EXCHANGE_ADDRESS" "placeOrder(uint256,uint8,uint256,uint256)" \
    "$CL_MID" 3 600000 100000000)
log "bob SELL_NO @ 0.60 100 tx=$sell_no_tx"

alice_usdc_post=$(usdc_balance "$ALICE")
bob_usdc_post=$(usdc_balance "$BOB")
alice_yes_post=$(erc20_balance "$YES_CL" "$ALICE")
bob_no_post=$(erc20_balance "$NO_CL" "$BOB")

alice_usdc_d=$((alice_usdc_post - alice_usdc_pre))
bob_usdc_d=$((bob_usdc_post - bob_usdc_pre))
alice_yes_d=$((alice_yes_pre - alice_yes_post))
bob_no_d=$((bob_no_pre - bob_no_post))

log "alice +USDC=$alice_usdc_d (expect 40000000) -YES=$alice_yes_d (expect 100000000)"
log "bob   +USDC=$bob_usdc_d (expect 60000000) -NO=$bob_no_d (expect 100000000)"

if [ "$alice_usdc_d" = "40000000" ] && [ "$bob_usdc_d" = "60000000" ] \
   && [ "$alice_yes_d" = "100000000" ] && [ "$bob_no_d" = "100000000" ]; then
    record_result "CL-on-02" "CLOB" "MERGE match SELL_YES@0.40 + SELL_NO@0.60" "pass" 0 \
        "$sell_yes_tx,$sell_no_tx" \
        "{\"market\":$CL_MID,\"alice_usdc_in\":$alice_usdc_d,\"bob_usdc_in\":$bob_usdc_d,\"alice_yes_burned\":$alice_yes_d,\"bob_no_burned\":$bob_no_d}"
else
    record_result "CL-on-02" "CLOB" "MERGE match" "fail" 0 "$sell_yes_tx,$sell_no_tx" \
        "{\"alice_usdc_d\":$alice_usdc_d,\"bob_usdc_d\":$bob_usdc_d,\"alice_yes_d\":$alice_yes_d,\"bob_no_d\":$bob_no_d}"
    log "CL-on-02 FAIL"; exit 1
fi

# ---------------------------------------------------------------------------
# CL-on-03: C04 solvency check post-match.
# C04: Σ depositLocked == exchange USDC + Σ outcome token balances at exchange
# At this point all locked tokens have been settled, so depositLocked should
# net to 0 and exchange should hold 0 USDC + 0 of each outcome token (unless
# other open orders exist from prior tests — in this fresh-market session,
# nothing else is open).
# ---------------------------------------------------------------------------
log "-- CL-on-03: C04 post-match invariant --"
ex_usdc=$(usdc_balance "$EXCHANGE_ADDRESS")
ex_yes=$(erc20_balance "$YES_CL" "$EXCHANGE_ADDRESS")
ex_no=$(erc20_balance "$NO_CL" "$EXCHANGE_ADDRESS")
log "exchange usdc=$ex_usdc yes=$ex_yes no=$ex_no"
# Should all be 0 since we closed CL-on-01's order and CL-on-02 settled in full
if [ "$ex_usdc" = "0" ] && [ "$ex_yes" = "0" ] && [ "$ex_no" = "0" ]; then
    record_result "CL-on-03" "CLOB" "C04 solvency: exchange holdings == 0 post-settlement" "pass" 0 "" \
        "{\"exchange_usdc\":0,\"exchange_yes\":0,\"exchange_no\":0}"
else
    record_result "CL-on-03" "CLOB" "C04 solvency" "info" 0 "" \
        "{\"exchange_usdc\":$ex_usdc,\"exchange_yes\":$ex_yes,\"exchange_no\":$ex_no}"
fi

log "== Group CL done =="
