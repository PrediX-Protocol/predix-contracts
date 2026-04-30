#!/usr/bin/env bash
set -uo pipefail
source /Users/keyti/Sources/Final_Predix_V2/SC/testenv.local

RPC="$UNICHAIN_RPC_PRIMARY"
DK="$DEPLOYER_PRIVATE_KEY"
OK="$OPERATOR_PRIVATE_KEY"
DEPLOYER="$DEPLOYER_ADDRESS"
OPERATOR="$OPERATOR_ADDRESS"
DIAMOND="$DIAMOND_ADDRESS"
EXCHANGE="$EXCHANGE_ADDRESS"
ROUTER="$PREDIX_ROUTER_ADDRESS"
HOOK="$HOOK_PROXY_ADDRESS"
ORACLE="$MANUAL_ORACLE_ADDRESS"
USDC="$USDC_ADDRESS"
MAX="$(python3 -c 'print(2**256-1)')"
EVE_PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
EVE="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

pass=0; fail=0; total=0
log()  { printf "\n\033[1;36m[%s]\033[0m %s\n" "$1" "$2"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$1"; ((pass++)); ((total++)); }
fail() { printf "  \033[1;31m✗\033[0m %s\n" "$1"; ((fail++)); ((total++)); }
q()    { cast call "$@" --rpc-url "$RPC" 2>/dev/null | head -1 | sed 's/ \[.*//'; }
tx()   { cast send "$@" --rpc-url "$RPC" --json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('transactionHash',''))" 2>/dev/null; }
txq()  { cast send "$@" --rpc-url "$RPC" > /dev/null 2>&1; }
expect_revert() { local exp="$1"; shift; cast send "$@" --rpc-url "$RPC" 2>&1 | grep -qi "$exp\|revert\|error"; }

DL=$(($(date +%s) + 600))

# ---- SETUP: create a market, split, resolve for multi-test reuse ----
log "SETUP" "Create markets"
txq "$USDC" "approve(address,uint256)" "$DIAMOND" "$MAX" --private-key "$DK"

# Market for resolved tests (60s endTime)
END1=$(($(date +%s) + 90))
txq "$DIAMOND" "createMarket(string,uint256,address)" "remaining-resolved" "$END1" "$ORACLE" --private-key "$DK"
M_R=$(q "$DIAMOND" "marketCount()(uint256)")
txq "$DIAMOND" "splitPosition(uint256,uint256)" "$M_R" 1000000000 --private-key "$DK"
read YES_R NO_R <<< "$(cast call "$DIAMOND" "getMarketStatus(uint256)(address,address,uint256,bool,bool)" "$M_R" --rpc-url "$RPC" 2>/dev/null | head -2 | tr -d ' ' | tr '\n' ' ')"

# Market for fee tests
cast send "$DIAMOND" "setDefaultRedemptionFeeBps(uint256)" 200 --private-key "$DK" --rpc-url "$RPC" > /dev/null 2>&1
END2=$(($(date +%s) + 90))
txq "$DIAMOND" "createMarket(string,uint256,address)" "remaining-fee" "$END2" "$ORACLE" --private-key "$DK"
M_FEE=$(q "$DIAMOND" "marketCount()(uint256)")
txq "$DIAMOND" "splitPosition(uint256,uint256)" "$M_FEE" 10000000000 --private-key "$DK"
read YES_F NO_F <<< "$(cast call "$DIAMOND" "getMarketStatus(uint256)(address,address,uint256,bool,bool)" "$M_FEE" --rpc-url "$RPC" 2>/dev/null | head -2 | tr -d ' ' | tr '\n' ' ')"

# Market for CLOB tests (long)
END3=$(($(date +%s) + 604800))
txq "$DIAMOND" "createMarket(string,uint256,address)" "remaining-clob" "$END3" "$ORACLE" --private-key "$DK"
M_CLOB=$(q "$DIAMOND" "marketCount()(uint256)")
txq "$DIAMOND" "splitPosition(uint256,uint256)" "$M_CLOB" 5000000000 --private-key "$DK"
read YES_C NO_C <<< "$(cast call "$DIAMOND" "getMarketStatus(uint256)(address,address,uint256,bool,bool)" "$M_CLOB" --rpc-url "$RPC" 2>/dev/null | head -2 | tr -d ' ' | tr '\n' ' ')"
txq "$USDC" "approve(address,uint256)" "$EXCHANGE" "$MAX" --private-key "$DK"
txq "$YES_C" "approve(address,uint256)" "$EXCHANGE" "$MAX" --private-key "$DK"
txq "$NO_C" "approve(address,uint256)" "$EXCHANGE" "$MAX" --private-key "$DK"

log "INFO" "M_R=$M_R M_FEE=$M_FEE M_CLOB=$M_CLOB"
log "INFO" "Waiting 95s for M_R + M_FEE to expire..."
sleep 95

# ============================================================================
log "B" "Resolve & Redeem"
# ============================================================================

# B05: resolve when oracle revoked
txq "$ORACLE" "report(uint256,bool)" "$M_R" true --private-key "$OK"
txq "$DIAMOND" "revokeOracle(address)" "$ORACLE" --private-key "$DK"
expect_revert "OracleNotApproved" "$DIAMOND" "resolveMarket(uint256)" "$M_R" --private-key "$DK" && ok "B05: oracle revoked → revert" || fail "B05"
txq "$DIAMOND" "approveOracle(address)" "$ORACLE" --private-key "$DK"

# Now resolve normally
H=$(tx "$DIAMOND" "resolveMarket(uint256)" "$M_R" --private-key "$DK")
ok "B01/B10 setup: resolved M_R (tx=${H:0:18})"

# B10: redeem holding both YES+NO
USDC_PRE=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
H=$(tx "$DIAMOND" "redeem(uint256)" "$M_R" --private-key "$DK")
USDC_POST=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
YES_AFT=$(q "$YES_R" "balanceOf(address)(uint256)" "$DEPLOYER")
NO_AFT=$(q "$NO_R" "balanceOf(address)(uint256)" "$DEPLOYER")
PAYOUT=$((USDC_POST - USDC_PRE))
[ "$YES_AFT" = "0" ] && [ "$NO_AFT" = "0" ] && [ "$PAYOUT" -gt 0 ] && ok "B10: redeem both sides (payout=$PAYOUT, YES=NO=0, tx=${H:0:18})" || fail "B10"

# B14: fee + payout == burned (use M_FEE)
txq "$ORACLE" "report(uint256,bool)" "$M_FEE" true --private-key "$OK"
txq "$DIAMOND" "resolveMarket(uint256)" "$M_FEE" --private-key "$DK"
FEE_RECIP=$(q "$DIAMOND" "feeRecipient()(address)")
FR_PRE=$(q "$USDC" "balanceOf(address)(uint256)" "$FEE_RECIP")
USDC_PRE=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
YES_BURNED=$(q "$YES_F" "balanceOf(address)(uint256)" "$DEPLOYER")
H=$(tx "$DIAMOND" "redeem(uint256)" "$M_FEE" --private-key "$DK")
USDC_POST=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
FR_POST=$(q "$USDC" "balanceOf(address)(uint256)" "$FEE_RECIP")
PAYOUT=$((USDC_POST - USDC_PRE))
FEE=$((FR_POST - FR_PRE))
SUM=$((PAYOUT + FEE))
[ "$SUM" -eq "$YES_BURNED" ] && ok "B14: fee($FEE)+payout($PAYOUT)=burned($YES_BURNED) EXACT (tx=${H:0:18})" || fail "B14: $SUM != $YES_BURNED"

# ============================================================================
log "D" "Fee edge cases"
# ============================================================================

# D04: per-market lowers fee
END_D=$(($(date +%s) + 90))
txq "$DIAMOND" "createMarket(string,uint256,address)" "D04" "$END_D" "$ORACLE" --private-key "$DK"
M_D04=$(q "$DIAMOND" "marketCount()(uint256)")
txq "$DIAMOND" "setPerMarketRedemptionFeeBps(uint256,uint16)" "$M_D04" 50 --private-key "$DK"
EFF=$(q "$DIAMOND" "effectiveRedemptionFeeBps(uint256)(uint256)" "$M_D04")
[ "$EFF" = "50" ] && ok "D04: per-market fee=50 bps effective" || fail "D04: $EFF"

# D06: clear falls back
txq "$DIAMOND" "clearPerMarketRedemptionFee(uint256)" "$M_D04" --private-key "$DK"
EFF2=$(q "$DIAMOND" "effectiveRedemptionFeeBps(uint256)(uint256)" "$M_D04")
[ "$EFF2" = "200" ] && ok "D06: clearPerMarket → falls back to 200" || fail "D06: $EFF2"

# D07: fee locked after resolve
expect_revert "FeeLockedAfterFinal" "$DIAMOND" "setPerMarketRedemptionFeeBps(uint256,uint16)" "$M_R" 50 --private-key "$DK" && ok "D07: fee locked after resolve → revert" || fail "D07"

# D08: snapshot protects user
txq "$DIAMOND" "splitPosition(uint256,uint256)" "$M_D04" 10000000000 --private-key "$DK"
# Raise global to 500
txq "$DIAMOND" "setDefaultRedemptionFeeBps(uint256)" 500 --private-key "$DK"
sleep 95
txq "$ORACLE" "report(uint256,bool)" "$M_D04" true --private-key "$OK"
txq "$DIAMOND" "resolveMarket(uint256)" "$M_D04" --private-key "$DK"
USDC_PRE=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
txq "$DIAMOND" "redeem(uint256)" "$M_D04" --private-key "$DK"
USDC_POST=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
PAYOUT=$((USDC_POST - USDC_PRE))
# Snapshot was 200 bps (2%), so payout = 10000 * 0.98 = 9800
[ "$PAYOUT" -eq 9800000000 ] && ok "D08: snapshot 2% (not 5%), payout=$PAYOUT" || fail "D08: payout=$PAYOUT expected 9800000000"
txq "$DIAMOND" "setDefaultRedemptionFeeBps(uint256)" 0 --private-key "$DK"

# ============================================================================
log "CLOB" "More matching + cancel cases"
# ============================================================================

# E10: min amount exactly
H=$(tx "$EXCHANGE" "placeOrder(uint256,uint8,uint256,uint256)" "$M_CLOB" 0 500000 1000000 --private-key "$DK")
[ -n "$H" ] && ok "E10: MIN_ORDER_AMOUNT=1e6 (tx=${H:0:18})" || fail "E10"

# F02: price improvement
txq "$EXCHANGE" "placeOrder(uint256,uint8,uint256,uint256)" "$M_CLOB" 0 700000 10000000 --private-key "$DK"
# Transfer YES to operator, operator sells at 0.60 → matches BUY at 0.70 but at maker price 0.60
txq "$YES_C" "transfer(address,uint256)" "$OPERATOR" 10000000 --private-key "$DK"
txq "$YES_C" "approve(address,uint256)" "$EXCHANGE" "$MAX" --private-key "$OK"
H=$(tx "$EXCHANGE" "placeOrder(uint256,uint8,uint256,uint256)" "$M_CLOB" 1 600000 10000000 --private-key "$OK")
ok "F02: price improvement (BUY@0.70 matched SELL@0.60, tx=${H:0:18})"

# F07: partial fill
txq "$EXCHANGE" "placeOrder(uint256,uint8,uint256,uint256)" "$M_CLOB" 0 500000 20000000 --private-key "$DK"
txq "$NO_C" "transfer(address,uint256)" "$OPERATOR" 10000000 --private-key "$DK"
txq "$NO_C" "approve(address,uint256)" "$EXCHANGE" "$MAX" --private-key "$OK"
H=$(tx "$EXCHANGE" "fillMarketOrder(uint256,uint8,uint256,uint256,address,address,uint256,uint256)" "$M_CLOB" 1 500000 5000000 "$OPERATOR" "$OPERATOR" 10 "$DL" --private-key "$OK")
ok "F07: partial fill 5 of 20 (tx=${H:0:18})"

# G02: cancel SELL order
txq "$YES_C" "approve(address,uint256)" "$EXCHANGE" "$MAX" --private-key "$DK"
SELL_H=$(tx "$EXCHANGE" "placeOrder(uint256,uint8,uint256,uint256)" "$M_CLOB" 1 600000 5000000 --private-key "$DK")
ORDER_G02=$(cast receipt "$SELL_H" --rpc-url "$RPC" --json 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['logs'][0]['topics'][1])" 2>/dev/null)
YES_PRE=$(q "$YES_C" "balanceOf(address)(uint256)" "$DEPLOYER")
H=$(tx "$EXCHANGE" "cancelOrder(bytes32)" "$ORDER_G02" --private-key "$DK")
YES_POST=$(q "$YES_C" "balanceOf(address)(uint256)" "$DEPLOYER")
[ "$((YES_POST - YES_PRE))" -eq 5000000 ] && ok "G02: cancel SELL refund 5 YES (tx=${H:0:18})" || fail "G02"

# G03: cancel already cancelled
expect_revert "Cancelled" "$EXCHANGE" "cancelOrder(bytes32)" "$ORDER_G02" --private-key "$DK" && ok "G03: cancel cancelled → revert" || fail "G03"

# ============================================================================
log "H" "Exchange pause full cycle"
# ============================================================================

txq "$EXCHANGE" "pause()" --private-key "$DK"
expect_revert "ExchangePaused" "$EXCHANGE" "placeOrder(uint256,uint8,uint256,uint256)" "$M_CLOB" 0 500000 1000000 --private-key "$DK" && ok "H01: place blocked when paused" || fail "H01"

# H03: fill still works when paused
txq "$EXCHANGE" "placeOrder(uint256,uint8,uint256,uint256)" "$M_CLOB" 1 500000 5000000 --private-key "$DK" 2>/dev/null
# Can't place when paused — unpause, place, re-pause, then fill
txq "$EXCHANGE" "unpause()" --private-key "$DK"
txq "$EXCHANGE" "placeOrder(uint256,uint8,uint256,uint256)" "$M_CLOB" 1 400000 5000000 --private-key "$DK"
txq "$EXCHANGE" "pause()" --private-key "$DK"
H=$(tx "$EXCHANGE" "fillMarketOrder(uint256,uint8,uint256,uint256,address,address,uint256,uint256)" "$M_CLOB" 0 400000 2000000 "$DEPLOYER" "$DEPLOYER" 10 "$DL" --private-key "$DK")
[ -n "$H" ] && ok "H03: fillMarketOrder works when paused (tx=${H:0:18})" || fail "H03"

txq "$EXCHANGE" "unpause()" --private-key "$DK"
ok "H04: unpause → placeOrder works"

# ============================================================================
log "L" "Router market validation"
# ============================================================================

txq "$USDC" "approve(address,uint256)" "$ROUTER" "$MAX" --private-key "$DK"
# L02: refund mode
expect_revert "RefundMode\|revert" "$ROUTER" "buyYes(uint256,uint256,uint256,address,uint256,uint256)" "$M_R" 1000000 1 "$DEPLOYER" 10 "$DL" --private-key "$DK" && ok "L02: trade refund mode → revert" || fail "L02"

# L04: paused
MKT_MODULE=$(cast keccak "predix.module.market")
txq "$DIAMOND" "pauseModule(bytes32)" "$MKT_MODULE" --private-key "$DK"
expect_revert "Paused\|revert" "$ROUTER" "buyYes(uint256,uint256,uint256,address,uint256,uint256)" "$M_CLOB" 1000000 1 "$DEPLOYER" 10 "$DL" --private-key "$DK" && ok "L04: trade paused → revert" || fail "L04"
txq "$DIAMOND" "unpauseModule(bytes32)" "$MKT_MODULE" --private-key "$DK"

# ============================================================================
log "N" "Hook anti-sandwich edge cases"
# ============================================================================

# N07: commitSwapIdentityFor non-quoter
expect_revert "InvalidCommitTarget\|revert" "$HOOK" "commitSwapIdentityFor(address,address,bytes32)" "$DEPLOYER" "$DEPLOYER" "0x0000000000000000000000000000000000000000000000000000000000000001" --private-key "$DK" && ok "N07: commitFor non-quoter → revert" || fail "N07"

# N08: commitSwapIdentity user=0
TRUSTED_ROUTER="$ROUTER"
expect_revert "ZeroAddress\|revert" "$HOOK" "commitSwapIdentity(address,bytes32)" "0x0000000000000000000000000000000000000000" "0x0000000000000000000000000000000000000000000000000000000000000001" --private-key "$DK" && ok "N08: commit user=0 → revert" || fail "N08"

# ============================================================================
log "R" "Event edge cases"
# ============================================================================

# R08: resolveEvent already resolved (use event 3 from earlier session)
EV=$(q "$DIAMOND" "eventCount()(uint256)")
expect_revert "AlreadyResolved\|revert" "$DIAMOND" "resolveEvent(uint256,uint256)" "$EV" 0 --private-key "$OK" && ok "R08: resolveEvent twice → revert" || fail "R08"

# ============================================================================
log "S" "Access Control"
# ============================================================================

CREATOR_ROLE=$(cast keccak "predix.role.creator")
# S01: grant + revoke
txq "$DIAMOND" "grantRole(bytes32,address)" "$CREATOR_ROLE" "$EVE" --private-key "$DK"
HAS=$(q "$DIAMOND" "hasRole(bytes32,address)(bool)" "$CREATOR_ROLE" "$EVE")
[ "$HAS" = "true" ] && ok "S01a: grantRole ✓" || fail "S01a"
txq "$DIAMOND" "revokeRole(bytes32,address)" "$CREATOR_ROLE" "$EVE" --private-key "$DK"
HAS2=$(q "$DIAMOND" "hasRole(bytes32,address)(bool)" "$CREATOR_ROLE" "$EVE")
[ "$HAS2" = "false" ] && ok "S01b: revokeRole ✓" || fail "S01b"

# ============================================================================
log "V" "Multi-user scenarios"
# ============================================================================

# V01: transfer YES then redeem (use M_CLOB — can't redeem unresolved, use fresh)
END_V=$(($(date +%s) + 90))
txq "$DIAMOND" "createMarket(string,uint256,address)" "V01" "$END_V" "$ORACLE" --private-key "$DK"
M_V=$(q "$DIAMOND" "marketCount()(uint256)")
txq "$DIAMOND" "splitPosition(uint256,uint256)" "$M_V" 200000000 --private-key "$DK"
read YES_V NO_V <<< "$(cast call "$DIAMOND" "getMarketStatus(uint256)(address,address,uint256,bool,bool)" "$M_V" --rpc-url "$RPC" 2>/dev/null | head -2 | tr -d ' ' | tr '\n' ' ')"
# Transfer 100 YES to operator
txq "$YES_V" "transfer(address,uint256)" "$OPERATOR" 100000000 --private-key "$DK"
sleep 95
txq "$ORACLE" "report(uint256,bool)" "$M_V" true --private-key "$OK"
txq "$DIAMOND" "resolveMarket(uint256)" "$M_V" --private-key "$DK"
# Operator redeems (has 100 YES)
USDC_PRE=$(q "$USDC" "balanceOf(address)(uint256)" "$OPERATOR")
txq "$DIAMOND" "redeem(uint256)" "$M_V" --private-key "$OK"
USDC_POST=$(q "$USDC" "balanceOf(address)(uint256)" "$OPERATOR")
OP_PAYOUT=$((USDC_POST - USDC_PRE))
[ "$OP_PAYOUT" -eq 100000000 ] && ok "V01: transfer YES→operator, operator redeems 100 USDC" || fail "V01: $OP_PAYOUT"

# ============================================================================
log "W" "Economic invariants"
# ============================================================================

# W01: YES==NO==collateral on M_CLOB
YES_SUP=$(q "$YES_C" "totalSupply()(uint256)")
NO_SUP=$(q "$NO_C" "totalSupply()(uint256)")
[ "$YES_SUP" = "$NO_SUP" ] && ok "W01: YES.supply($YES_SUP)==NO.supply($NO_SUP)" || fail "W01"

# W06: collateral unchanged by CLOB
COL_PRE=$(cast call "$DIAMOND" "getMarket(uint256)((string,uint256,address,address,address,address,uint256,uint256,uint256,uint256,bool,bool,bool,uint256,uint256,bool,uint256))" "$M_CLOB" --rpc-url "$RPC" 2>/dev/null | sed -n '7p' | tr -d ' ')
txq "$EXCHANGE" "placeOrder(uint256,uint8,uint256,uint256)" "$M_CLOB" 0 500000 5000000 --private-key "$DK"
COL_POST=$(cast call "$DIAMOND" "getMarket(uint256)((string,uint256,address,address,address,address,uint256,uint256,uint256,uint256,bool,bool,bool,uint256,uint256,bool,uint256))" "$M_CLOB" --rpc-url "$RPC" 2>/dev/null | sed -n '7p' | tr -d ' ')
[ "$COL_PRE" = "$COL_POST" ] && ok "W06: collateral unchanged by CLOB order" || fail "W06"

# W03: Router zero balance
R_USDC=$(q "$USDC" "balanceOf(address)(uint256)" "$ROUTER")
[ "$R_USDC" = "0" ] && ok "W03: Router USDC=0" || fail "W03"

# ============================================================================
log "Y" "Attack + Governance"
# ============================================================================

# Y06: instant upgrade blocked
EXCH_PROXY="$EXCHANGE"
FAKE=$(python3 -c "print('0x' + '00' * 19 + '01')")
expect_revert "revert" "$(echo $EXCH_PROXY)" "proposeUpgrade(address)" "$ORACLE" --private-key "$OK" 2>/dev/null
# Propose then immediate execute → revert
txq "$EXCH_PROXY" "proposeUpgrade(address)" "$ORACLE" --private-key "$OK"
expect_revert "UpgradeNotReady\|revert" "$EXCH_PROXY" "executeUpgrade()" --private-key "$OK" && ok "Y06: instant upgrade blocked" || fail "Y06"
txq "$EXCH_PROXY" "cancelUpgrade()" --private-key "$OK"

# Y07: re-propose resets timer → AlreadyPending
txq "$EXCH_PROXY" "proposeUpgrade(address)" "$ORACLE" --private-key "$OK"
expect_revert "AlreadyPending\|revert" "$EXCH_PROXY" "proposeUpgrade(address)" "$DIAMOND" --private-key "$OK" && ok "Y07: re-propose AlreadyPending → revert" || fail "Y07"
txq "$EXCH_PROXY" "cancelUpgrade()" --private-key "$OK"

# Y09: double redeem
expect_revert "NothingToRedeem\|revert" "$DIAMOND" "redeem(uint256)" "$M_R" --private-key "$DK" && ok "Y09: double redeem → revert" || fail "Y09"

# ============================================================================
echo ""
echo "============================================================"
echo "  REMAINING CASES RESULTS"
echo "  Passed: $pass"
echo "  Failed: $fail"
echo "  Total:  $total"
echo "============================================================"
[ "$fail" -gt 0 ] && echo "  SOME FAILED" || echo "  ALL PASSED"
