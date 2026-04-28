#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# PrediX V2 — Full E2E Test on Unichain Sepolia
# ============================================================================

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
POS_MGR="$POSITION_MANAGER_ADDRESS"

MAX="115792089237316195423570985008687907853269984665640564039457584007913129639935"
pass=0; fail=0

log()  { printf "\n\033[1;34m[%s]\033[0m %s\n" "$1" "$2"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$1"; ((pass++)); }
err()  { printf "  \033[1;31m✗\033[0m %s\n" "$1"; ((fail++)); }

tx() { cast send "$@" --rpc-url "$RPC" > /dev/null 2>&1; }
q()  { cast call "$@" --rpc-url "$RPC" 2>/dev/null | head -1 | sed 's/ \[.*//'; }

tokens() {
    local out
    out=$(cast call "$DIAMOND" "getMarketStatus(uint256)(address,address,uint256,bool,bool)" "$1" --rpc-url "$RPC" 2>/dev/null)
    echo "$out" | sed -n '1p' | tr -d ' '
    echo "$out" | sed -n '2p' | tr -d ' '
}

# ============================================================================
log "SETUP" "Pre-flight"
# ============================================================================
log "INFO" "Deployer USDC = $(q $USDC 'balanceOf(address)(uint256)' $DEPLOYER)"
log "INFO" "Operator USDC = $(q $USDC 'balanceOf(address)(uint256)' $OPERATOR)"
tx "$USDC" "transfer(address,uint256)" "$OPERATOR" 500000000 --private-key "$DK" && ok "Fund operator 500 USDC" || err "Fund operator"

# ============================================================================
log "PHASE 1" "Create Market A (6 min) + Market B (7 day)"
# ============================================================================

END_A=$(($(date +%s) + 360))
tx "$DIAMOND" "createMarket(string,uint256,address)" "E2E:BTC>200k" "$END_A" "$ORACLE" --private-key "$DK" && ok "Market A created" || err "Market A create"
MARKET_A=$(q "$DIAMOND" "marketCount()(uint256)")
read YES_A NO_A <<< "$(tokens $MARKET_A | tr '\n' ' ')"
log "INFO" "A=$MARKET_A YES=$YES_A NO=$NO_A end=$END_A"

END_B=$(($(date +%s) + 604800))
tx "$DIAMOND" "createMarket(string,uint256,address)" "E2E:ETH>5k" "$END_B" "$ORACLE" --private-key "$DK" && ok "Market B created" || err "Market B create"
MARKET_B=$(q "$DIAMOND" "marketCount()(uint256)")
read YES_B NO_B <<< "$(tokens $MARKET_B | tr '\n' ' ')"
log "INFO" "B=$MARKET_B YES=$YES_B NO=$NO_B end=$END_B"

# Split
tx "$USDC" "approve(address,uint256)" "$DIAMOND" "$MAX" --private-key "$DK"
tx "$DIAMOND" "splitPosition(uint256,uint256)" "$MARKET_A" 1000000000 --private-key "$DK" && ok "Split 1000 USDC on A" || err "Split A"
tx "$DIAMOND" "splitPosition(uint256,uint256)" "$MARKET_B" 2000000000 --private-key "$DK" && ok "Split 2000 USDC on B" || err "Split B"

# Fund operator with YES_A for sell orders
tx "$YES_A" "transfer(address,uint256)" "$OPERATOR" 200000000 --private-key "$DK" && ok "Operator got 200 YES_A" || err "Transfer YES_A"

# ============================================================================
log "PHASE 2" "CLOB Trading on Market A"
# ============================================================================

tx "$USDC" "approve(address,uint256)" "$EXCHANGE" "$MAX" --private-key "$DK"
tx "$EXCHANGE" "placeOrder(uint256,uint8,uint256,uint256)" "$MARKET_A" 0 600000 100000000 --private-key "$DK" \
    && ok "BUY YES @0.60 x100" || err "BUY YES"

tx "$YES_A" "approve(address,uint256)" "$EXCHANGE" "$MAX" --private-key "$OK"
tx "$EXCHANGE" "placeOrder(uint256,uint8,uint256,uint256)" "$MARKET_A" 1 600000 50000000 --private-key "$OK" \
    && ok "SELL YES @0.60 x50 (matched)" || err "SELL YES"

# Place + cancel
USDC_PRE=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
tx "$EXCHANGE" "placeOrder(uint256,uint8,uint256,uint256)" "$MARKET_A" 0 550000 100000000 --private-key "$DK"
# Read the orderId of the latest order by nonce: exchange._orderNonce gives the last nonce used
# orderId = keccak256(abi.encode(nonce, placer)). Nonce for this order = current _orderNonce value.
# Since _orderNonce is private, we get orderId from getOrder by trying. Simpler: just read from tx receipt.
CANCEL_TX_HASH=$(cast send "$EXCHANGE" "placeOrder(uint256,uint8,uint256,uint256)" "$MARKET_A" 0 500000 50000000 \
    --private-key "$DK" --rpc-url "$RPC" --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['transactionHash'])" 2>/dev/null || echo "")
if [ -n "$CANCEL_TX_HASH" ]; then
    ORDER_CANCEL=$(cast receipt "$CANCEL_TX_HASH" --rpc-url "$RPC" --json 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d['logs'][0]['topics'][1])" 2>/dev/null || echo "")
    if [ -n "$ORDER_CANCEL" ]; then
        tx "$EXCHANGE" "cancelOrder(bytes32)" "$ORDER_CANCEL" --private-key "$DK" && ok "Cancel order + refund" || err "Cancel"
        USDC_POST=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
        log "INFO" "USDC refund delta = $((USDC_POST - USDC_PRE))"
    else
        err "Could not parse orderId for cancel"
    fi
else
    err "Could not get tx hash for cancel test"
fi

# ============================================================================
log "PHASE 3" "AMM Setup + Router on Market B"
# ============================================================================

QUOTE="$USDC"
if [[ "$(echo $YES_B | tr '[:upper:]' '[:lower:]')" < "$(echo $QUOTE | tr '[:upper:]' '[:lower:]')" ]]; then
    C0="$YES_B"; C1="$QUOTE"
else
    C0="$QUOTE"; C1="$YES_B"
fi
log "INFO" "Pool c0=$C0 c1=$C1"

tx "$HOOK" "registerMarketPool(uint256,(address,address,uint24,int24,address))" \
    "$MARKET_B" "($C0,$C1,8388608,60,$HOOK)" --private-key "$DK" && ok "Pool registered" || err "Register pool"

# Init pool
if [[ "$(echo $YES_B | tr '[:upper:]' '[:lower:]')" < "$(echo $QUOTE | tr '[:upper:]' '[:lower:]')" ]]; then
    INIT_TICK=-6960
else
    INIT_TICK=6960
fi
SQRT_P=$(python3 -c "import math; print(int(math.sqrt(1.0001**$INIT_TICK)*(2**96)))")
tx "$POS_MGR" "initializePool((address,address,uint24,int24,address),uint160)" \
    "($C0,$C1,8388608,60,$HOOK)" "$SQRT_P" --private-key "$DK" && ok "Pool initialized tick=$INIT_TICK" || err "Init pool"

# Add liquidity via forge script
log "PHASE 3" "Adding liquidity (forge script)..."
cd /Users/keyti/Sources/Final_Predix_V2/SC/packages/diamond

cat > /tmp/e2e_liq.sol << 'SOLEOF'
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

contract E2ELiq is Script {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    function run() external {
        address yes = vm.envAddress("E2E_YES");
        address usdc_ = vm.envAddress("USDC_ADDRESS");
        address hook_ = vm.envAddress("HOOK_PROXY_ADDRESS");
        address pm = vm.envAddress("POOL_MANAGER_ADDRESS");
        address posMgr = vm.envAddress("POSITION_MANAGER_ADDRESS");
        address permit2 = vm.envAddress("PERMIT2_ADDRESS");
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        (address c0, address c1) = yes < usdc_ ? (yes, usdc_) : (usdc_, yes);
        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), LPFeeLibrary.DYNAMIC_FEE_FLAG, int24(60), IHooks(hook_));
        (uint160 sqrtP,,,) = IPoolManager(pm).getSlot0(key.toId());
        require(sqrtP != 0, "not init");

        uint256 a0 = yes < usdc_ ? 200e6 : 100e6;
        uint256 a1 = yes < usdc_ ? 100e6 : 200e6;
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(sqrtP, TickMath.getSqrtPriceAtTick(-887220), TickMath.getSqrtPriceAtTick(887220), a0, a1);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        IERC20(yes).forceApprove(permit2, type(uint256).max);
        IERC20(usdc_).forceApprove(permit2, type(uint256).max);
        IAllowanceTransfer(permit2).approve(yes, posMgr, type(uint160).max, type(uint48).max);
        IAllowanceTransfer(permit2).approve(usdc_, posMgr, type(uint160).max, type(uint48).max);

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, int24(-887220), int24(887220), uint256(liq), uint128(a0), uint128(a1), deployer, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        IPositionManager(posMgr).modifyLiquidities(abi.encode(actions, params), block.timestamp + 300);
        vm.stopBroadcast();
    }
}
SOLEOF

set -a && source /Users/keyti/Sources/Final_Predix_V2/SC/testenv.local && set +a
LIQ_RESULT=$(E2E_YES="$YES_B" forge script /tmp/e2e_liq.sol:E2ELiq --rpc-url "$RPC" --broadcast 2>&1)
if echo "$LIQ_RESULT" | grep -q "ONCHAIN EXECUTION COMPLETE"; then
    ok "Liquidity added"
else
    err "Liquidity add failed"
    echo "$LIQ_RESULT" | tail -5
fi

# Router trades
cd /Users/keyti/Sources/Final_Predix_V2/SC
DL=$(($(date +%s) + 600))

log "PHASE 3" "Router.buyYes 50 USDC"
tx "$USDC" "approve(address,uint256)" "$ROUTER" "$MAX" --private-key "$DK"
PRE=$(q "$YES_B" "balanceOf(address)(uint256)" "$DEPLOYER")
tx "$ROUTER" "buyYes(uint256,uint256,uint256,address,uint256,uint256)" "$MARKET_B" 50000000 1 "$DEPLOYER" 10 "$DL" --private-key "$DK"
POST=$(q "$YES_B" "balanceOf(address)(uint256)" "$DEPLOYER")
[ "$((POST - PRE))" -gt 0 ] 2>/dev/null && ok "buyYes: +$((POST-PRE)) YES" || err "buyYes: no YES received"

log "PHASE 3" "Router.sellYes 20 YES"
tx "$YES_B" "approve(address,uint256)" "$ROUTER" "$MAX" --private-key "$DK"
PRE=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
tx "$ROUTER" "sellYes(uint256,uint256,uint256,address,uint256,uint256)" "$MARKET_B" 20000000 1 "$DEPLOYER" 10 "$DL" --private-key "$DK"
POST=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
[ "$((POST - PRE))" -gt 0 ] 2>/dev/null && ok "sellYes: +$((POST-PRE)) USDC" || err "sellYes: no USDC received"

log "PHASE 3" "Router.buyNo 50 USDC (virtual-NO)"
PRE=$(q "$NO_B" "balanceOf(address)(uint256)" "$DEPLOYER")
tx "$ROUTER" "buyNo(uint256,uint256,uint256,address,uint256,uint256)" "$MARKET_B" 50000000 1 "$DEPLOYER" 10 "$DL" --private-key "$DK"
POST=$(q "$NO_B" "balanceOf(address)(uint256)" "$DEPLOYER")
[ "$((POST - PRE))" -gt 0 ] 2>/dev/null && ok "buyNo: +$((POST-PRE)) NO (virtual)" || err "buyNo: no NO received"

log "PHASE 3" "Router.sellNo 20 NO (virtual-NO)"
tx "$NO_B" "approve(address,uint256)" "$ROUTER" "$MAX" --private-key "$DK"
PRE=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
tx "$ROUTER" "sellNo(uint256,uint256,uint256,address,uint256,uint256)" "$MARKET_B" 20000000 1 "$DEPLOYER" 10 "$DL" --private-key "$DK"
POST=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
[ "$((POST - PRE))" -gt 0 ] 2>/dev/null && ok "sellNo: +$((POST-PRE)) USDC (virtual)" || err "sellNo: no USDC received"

# ============================================================================
log "PHASE 4" "Waiting for Market A to expire..."
# ============================================================================
NOW=$(date +%s); WAIT=$((END_A - NOW + 10))
[ "$WAIT" -gt 0 ] && { log "INFO" "Sleeping ${WAIT}s..."; sleep "$WAIT"; }

# ============================================================================
log "PHASE 5" "Oracle + Resolve + Redeem"
# ============================================================================

tx "$ORACLE" "report(uint256,bool)" "$MARKET_A" true --private-key "$OK" && ok "Oracle reported YES" || err "Oracle report"
tx "$DIAMOND" "resolveMarket(uint256)" "$MARKET_A" --private-key "$DK" && ok "Market A resolved" || err "Resolve"

RESOLVED=$(cast call "$DIAMOND" "getMarketStatus(uint256)(address,address,uint256,bool,bool)" "$MARKET_A" --rpc-url "$RPC" 2>/dev/null | sed -n '4p' | tr -d ' ')
[ "$RESOLVED" = "true" ] && ok "isResolved=true" || err "isResolved=$RESOLVED"

PRE=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
tx "$DIAMOND" "redeem(uint256)" "$MARKET_A" --private-key "$DK" && ok "Redeem tx sent" || err "Redeem"
POST=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
PAYOUT=$((POST - PRE))
[ "$PAYOUT" -gt 0 ] 2>/dev/null && ok "Redeem payout: $PAYOUT USDC" || err "Redeem: no payout"

YES_AFTER=$(q "$YES_A" "balanceOf(address)(uint256)" "$DEPLOYER")
[ "$YES_AFTER" = "0" ] && ok "YES_A burned to 0" || err "YES_A not burned ($YES_AFTER)"

# ============================================================================
log "PHASE 6" "Event create + resolve"
# ============================================================================

END_EV=$(($(date +%s) + 180))
tx "$DIAMOND" "createEvent(string,string[],uint256)" "E2E Election" '["A wins?","B wins?"]' "$END_EV" --private-key "$DK" \
    && ok "Event created" || err "Event create"

EV_ID=$(q "$DIAMOND" "eventCount()(uint256)")
MC=$(q "$DIAMOND" "marketCount()(uint256)")
C1=$((MC - 1)); C2="$MC"
log "INFO" "Event=$EV_ID children=[$C1,$C2]"

tx "$USDC" "approve(address,uint256)" "$DIAMOND" "$MAX" --private-key "$DK"
tx "$DIAMOND" "splitPosition(uint256,uint256)" "$C1" 100000000 --private-key "$DK" && ok "Split child 1" || err "Split child 1"
tx "$DIAMOND" "splitPosition(uint256,uint256)" "$C2" 100000000 --private-key "$DK" && ok "Split child 2" || err "Split child 2"

log "PHASE 6" "Waiting for event to expire..."
NOW=$(date +%s); WAIT=$((END_EV - NOW + 10))
[ "$WAIT" -gt 0 ] && { log "INFO" "Sleeping ${WAIT}s..."; sleep "$WAIT"; }

tx "$DIAMOND" "resolveEvent(uint256,uint256)" "$EV_ID" 0 --private-key "$OK" && ok "Event resolved (A wins)" || err "Event resolve"

PRE=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
tx "$DIAMOND" "redeem(uint256)" "$C1" --private-key "$DK"
POST=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
[ "$((POST - PRE))" -gt 0 ] 2>/dev/null && ok "Event redeem: +$((POST-PRE)) USDC" || err "Event redeem"

# ============================================================================
log "PHASE 7" "Pause + bypass"
# ============================================================================

MKT_MOD=$(cast keccak "predix.module.market")
tx "$DIAMOND" "pauseModule(bytes32)" "$MKT_MOD" --private-key "$OK" && ok "Paused" || err "Pause"

# Split should fail
cast send "$DIAMOND" "splitPosition(uint256,uint256)" "$MARKET_B" 10000000 \
    --private-key "$DK" --rpc-url "$RPC" > /dev/null 2>&1
[ $? -ne 0 ] && ok "Split reverted when paused" || err "Split should revert"

tx "$DIAMOND" "unpauseModule(bytes32)" "$MKT_MOD" --private-key "$OK" && ok "Unpaused" || err "Unpause"

# ============================================================================
log "PHASE 8" "Refund mode"
# ============================================================================

END_R=$(($(date +%s) + 120))
tx "$DIAMOND" "createMarket(string,uint256,address)" "E2E Refund" "$END_R" "$ORACLE" --private-key "$DK"
MKT_R=$(q "$DIAMOND" "marketCount()(uint256)")
log "INFO" "Refund market=$MKT_R"

tx "$USDC" "approve(address,uint256)" "$DIAMOND" "$MAX" --private-key "$DK"
tx "$DIAMOND" "splitPosition(uint256,uint256)" "$MKT_R" 100000000 --private-key "$DK" && ok "Split refund market" || err "Split refund"

log "PHASE 8" "Waiting for refund market to expire..."
NOW=$(date +%s); WAIT=$((END_R - NOW + 10))
[ "$WAIT" -gt 0 ] && { log "INFO" "Sleeping ${WAIT}s..."; sleep "$WAIT"; }

tx "$DIAMOND" "enableRefundMode(uint256)" "$MKT_R" --private-key "$OK" && ok "Refund mode ON" || err "Enable refund"

PRE=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
tx "$DIAMOND" "refund(uint256,uint256,uint256)" "$MKT_R" 100000000 100000000 --private-key "$DK"
POST=$(q "$USDC" "balanceOf(address)(uint256)" "$DEPLOYER")
[ "$((POST - PRE))" -gt 0 ] 2>/dev/null && ok "Refund: +$((POST-PRE)) USDC" || err "Refund: no USDC"

# ============================================================================
echo ""
echo "============================================================"
echo "  PASSED: $pass"
echo "  FAILED: $fail"
echo "============================================================"
[ "$fail" -gt 0 ] && echo "  SOME TESTS FAILED" || echo "  ALL TESTS PASSED"
