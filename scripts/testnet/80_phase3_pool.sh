#!/usr/bin/env bash
# 80_phase3_pool.sh — Phase 3 pool init + liquidity seed + router trust wiring.
#
# Reproduces the Phase 3 on-chain setup exactly as executed on 2026-04-16 and
# documented in SC/audits/TEST_REPORT_PHASE3_POOL_AMM_20260416.md.
#
# RUN ORDER (per Phase 3 execution log):
#   1. setTrustedRouter(router)   — escape #5, operator signs, idempotent
#   2. setTrustedRouter(V4Quoter) — escape #6, operator signs, idempotent
#   3. Create market 19 (AMM smoke test) — deployer signs
#   4. hook.registerMarketPool(19, poolKey) — deployer signs, permissionless
#   5. PoolManager.initialize(poolKey, sqrtPriceX96) — deployer signs
#   6. Split 200 USDC on market 19 — deployer signs
#   7. approve YES + USDC → PoolModifyLiquidityTest — deployer signs
#   8. PoolModifyLiquidityTest.modifyLiquidity — deployer signs
#
# Phase 3 halted at RT-on-02 due to Finding #2 (router spot-price helpers
# call V4Quoter without pre-committing identity, which fails the hook's
# FINAL-H06 commit gate on the real-swap path). See report §Finding #2.
# RT-on-* execution is therefore OUT OF SCOPE for this script until a
# router source patch lands in Phase 4.
#
# Idempotency: every step no-ops if the target state is already reached.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

V4_QUOTER=0x56dcd40a3f2d466f48e7f48bdbe5cc9b92ae4472
POOL_MANAGER="${POOL_MANAGER_ADDRESS:?}"
STATE_VIEW=0xc199f1072a74d4e905aba1a84d9a45e2546b6222
MOD_LIQ=0x5fa728c0a5cfd51bee4b060773f50554c0c8a7ab
HOOK="$HOOK_PROXY_ADDRESS"
ROUTER="$PREDIX_ROUTER_ADDRESS"
LP_FEE_FLAG=8388608
TICK_SPACING=60

log "== Phase 3: pool init + wiring =="

# ---------------------------------------------------------------------------
# Step 1 + 2: trust router + quoter on hook (idempotent via isTrustedRouter)
# ---------------------------------------------------------------------------
trust_if_needed() {
    local addr="$1" label="$2"
    local current
    current=$(cast call "$HOOK" "isTrustedRouter(address)(bool)" "$addr" --rpc-url "$RPC")
    if [ "$current" = "true" ]; then
        log "$label already trusted ($addr)"
        return
    fi
    log "trusting $label ($addr)"
    send_tx "$OPERATOR_PRIVATE_KEY" "$HOOK" "setTrustedRouter(address,bool)" "$addr" true >/dev/null
    [ "$(cast call "$HOOK" "isTrustedRouter(address)(bool)" "$addr" --rpc-url "$RPC")" = "true" ] \
        || { log "trust verification FAILED for $label"; exit 1; }
}
trust_if_needed "$ROUTER" "router (escape #5)"
trust_if_needed "$V4_QUOTER" "V4Quoter (escape #6)"

# ---------------------------------------------------------------------------
# Step 3: create market 19 (or reuse if the marker file already has it)
# ---------------------------------------------------------------------------
STATE_FILE=/tmp/predix_phase3_state.json
MID=$(jq -r '.marketId // empty' "$STATE_FILE" 2>/dev/null || echo "")
if [ -z "$MID" ]; then
    NOW=$(date +%s)
    END=$((NOW + 86400))
    send_tx "$DEPLOYER_PRIVATE_KEY" "$DIAMOND_ADDRESS" \
        "createMarket(string,uint256,address)" \
        "AMM smoke test — YES if PrediX v4 pool init succeeds" \
        "$END" "$MANUAL_ORACLE_ADDRESS" >/dev/null
    MID=$(market_count)
    log "created market $MID"
else
    log "reusing market $MID from $STATE_FILE"
fi
STATUS=$(market_status "$MID")
YES_TOKEN=$(echo "$STATUS" | sed -n '1p')
log "market $MID yesToken=$YES_TOKEN"

# ---------------------------------------------------------------------------
# Step 4: derive PoolKey ordering + sqrtPriceX96 for YES/USDC 0.5:0.5
# ---------------------------------------------------------------------------
ORDER=$(python3 -c "
y=int('$YES_TOKEN'.lower(),16); u=int('$USDC_ADDRESS'.lower(),16)
import math
if y < u:
    c0, c1 = '$YES_TOKEN', '$USDC_ADDRESS'
    ratio = 0.5
else:
    c0, c1 = '$USDC_ADDRESS', '$YES_TOKEN'
    ratio = 2.0
sqrtPriceX96 = int(math.sqrt(ratio) * (2**96))
print(c0)
print(c1)
print(sqrtPriceX96)
")
CURRENCY0=$(echo "$ORDER" | sed -n '1p')
CURRENCY1=$(echo "$ORDER" | sed -n '2p')
SQRT=$(echo "$ORDER" | sed -n '3p')
POOL_KEY="($CURRENCY0,$CURRENCY1,$LP_FEE_FLAG,$TICK_SPACING,$HOOK)"
log "poolKey=$POOL_KEY sqrtPriceX96=$SQRT"

# ---------------------------------------------------------------------------
# Step 5 + 6: hook.registerMarketPool + PoolManager.initialize (idempotent)
# ---------------------------------------------------------------------------
POOL_ID=$(cast keccak "$(cast abi-encode 'f(address,address,uint24,int24,address)' \
    "$CURRENCY0" "$CURRENCY1" "$LP_FEE_FLAG" "$TICK_SPACING" "$HOOK")")
log "poolId=$POOL_ID"

BOUND=$(cast call "$HOOK" "poolMarketId(bytes32)(uint256)" "$POOL_ID" --rpc-url "$RPC" | awk '{print $1}')
if [ "$BOUND" = "0" ]; then
    log "registering pool with hook"
    send_tx "$DEPLOYER_PRIVATE_KEY" "$HOOK" \
        "registerMarketPool(uint256,(address,address,uint24,int24,address))" \
        "$MID" "$POOL_KEY" >/dev/null
else
    log "pool already registered to market $BOUND"
fi

SLOT0_SQRT=$(cast call "$STATE_VIEW" "getSlot0(bytes32)(uint160,int24,uint24,uint24)" "$POOL_ID" --rpc-url "$RPC" | sed -n '1p' | awk '{print $1}')
if [ "$SLOT0_SQRT" = "0" ]; then
    log "initializing pool on PoolManager"
    send_tx "$DEPLOYER_PRIVATE_KEY" "$POOL_MANAGER" \
        "initialize((address,address,uint24,int24,address),uint160)" \
        "$POOL_KEY" "$SQRT" >/dev/null
else
    log "pool already initialized sqrtPriceX96=$SLOT0_SQRT"
fi

# ---------------------------------------------------------------------------
# Step 7 + 8: seed liquidity via PoolModifyLiquidityTest
# ---------------------------------------------------------------------------
CURRENT_LIQ=$(cast call "$STATE_VIEW" "getLiquidity(bytes32)(uint128)" "$POOL_ID" --rpc-url "$RPC" | awk '{print $1}')
if [ "$CURRENT_LIQ" = "0" ]; then
    log "splitting 200 USDC on market $MID for seed liquidity"
    send_tx "$DEPLOYER_PRIVATE_KEY" "$USDC_ADDRESS" "approve(address,uint256)" "$DIAMOND_ADDRESS" "200000000" >/dev/null
    send_tx "$DEPLOYER_PRIVATE_KEY" "$DIAMOND_ADDRESS" "splitPosition(uint256,uint256)" "$MID" "200000000" >/dev/null

    log "approving PoolModifyLiquidityTest"
    send_tx "$DEPLOYER_PRIVATE_KEY" "$YES_TOKEN" "approve(address,uint256)" "$MOD_LIQ" "200000000" >/dev/null
    send_tx "$DEPLOYER_PRIVATE_KEY" "$USDC_ADDRESS" "approve(address,uint256)" "$MOD_LIQ" "200000000" >/dev/null

    log "modifyLiquidity L=18_700_000_000 over [-7080, -6780]"
    L=18700000000
    PARAMS="(-7080,-6780,$L,0x0000000000000000000000000000000000000000000000000000000000000000)"
    send_tx "$DEPLOYER_PRIVATE_KEY" "$MOD_LIQ" \
        "modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)" \
        "$POOL_KEY" "$PARAMS" "0x" >/dev/null
else
    log "pool already seeded liquidity=$CURRENT_LIQ"
fi

# ---------------------------------------------------------------------------
# Persist marker
# ---------------------------------------------------------------------------
jq -n \
    --arg mid "$MID" \
    --arg poolId "$POOL_ID" \
    --arg yesToken "$YES_TOKEN" \
    --arg currency0 "$CURRENCY0" \
    --arg currency1 "$CURRENCY1" \
    --arg sqrt "$SQRT" \
    '{marketId: ($mid|tonumber), poolId: $poolId, yesToken: $yesToken, currency0: $currency0, currency1: $currency1, sqrtPriceX96: $sqrt}' \
    > "$STATE_FILE"
log "wrote $STATE_FILE"

log "== Phase 3 pool setup complete =="
log "RT-on-* execution SKIPPED — see report Finding #2 (Phase 4 blocker)"
