#!/usr/bin/env bash
# 00_wallets.sh — Generate Alice/Bob/Carol test wallets, fund each with
# 0.005 ETH + 1000 TestUSDC. Idempotent: skips funding if balances already met.
# Wallet file: /tmp/predix_test_wallets.json (process-local, never committed).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

if [ ! -f "$WALLETS_FILE" ]; then
    log "generating fresh test wallets at $WALLETS_FILE"
    ALICE_JSON=$(cast wallet new --json)
    BOB_JSON=$(cast wallet new --json)
    CAROL_JSON=$(cast wallet new --json)
    jq -n \
        --argjson alice "$ALICE_JSON" \
        --argjson bob "$BOB_JSON" \
        --argjson carol "$CAROL_JSON" \
        '{alice: $alice[0], bob: $bob[0], carol: $carol[0]}' \
        > "$WALLETS_FILE"
    chmod 600 "$WALLETS_FILE"
else
    log "reusing existing $WALLETS_FILE"
fi

MIN_ETH_WEI=5000000000000000   # 0.005 ETH
MIN_USDC=1000000000            # 1000 USDC raw (6 decimals)

for who in alice bob carol; do
    addr=$(wallet_addr "$who")
    bal=$(cast balance "$addr" --rpc-url "$RPC")
    if [ "$bal" -lt "$MIN_ETH_WEI" ]; then
        log "funding $who ($addr) with 0.005 ETH (current: $bal)"
        send_eth "$DEPLOYER_PRIVATE_KEY" "$addr" "0.005ether" >/dev/null
    fi
    usdc=$(usdc_balance "$addr")
    if [ "$usdc" -lt "$MIN_USDC" ]; then
        log "minting 1000 TestUSDC to $who ($addr)"
        send_tx "$DEPLOYER_PRIVATE_KEY" "$USDC_ADDRESS" "mint(address,uint256)" "$addr" "1000000000" >/dev/null
    fi
    log "wallet $who $addr eth=$(cast balance "$addr" --rpc-url "$RPC") usdc=$(usdc_balance "$addr")"
done

log "wallet setup complete"
