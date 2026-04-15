#!/usr/bin/env bash
# Shared helpers for PrediX V2 Phase 2 testnet test scripts.
# Sourced by every test group script.
#
# Provides:
#   - env loading (SC/.env)
#   - role + module hash constants
#   - test wallet loader
#   - structured results emitter to /tmp/predix_phase2_results.jsonl
#   - rolling log to /tmp/predix_phase2_log.txt
#   - tx send + receipt + gas extraction helpers

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SC_ROOT="$REPO_ROOT"

# Load env (keys + addresses)
set -a
# shellcheck disable=SC1091
source "$SC_ROOT/.env"
set +a

: "${UNICHAIN_RPC_PRIMARY:?required}"
: "${DEPLOYER_PRIVATE_KEY:?required}"
: "${OPERATOR_PRIVATE_KEY:?required}"
: "${DIAMOND_ADDRESS:?required}"
: "${USDC_ADDRESS:?required}"
: "${MANUAL_ORACLE_ADDRESS:?required}"
: "${EXCHANGE_ADDRESS:?required}"

RPC="$UNICHAIN_RPC_PRIMARY"
DEPLOYER_ADDR="$DEPLOYER_ADDRESS"
OPERATOR_ADDR="0x0eC2bFb36BB59C736d7b770eacaFAa43a184De34"

# Role hashes (computed once, exported)
DEFAULT_ADMIN_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"
ADMIN_ROLE="0x84a7a283e0c6a5fad33db915b75d08b15ef8d1518fee8b50b4ed333b61701db5"
OPERATOR_ROLE="0xe81e16170e914df00b4921384b536d80fbd9ecbb45168271c3c7a7300164495e"
PAUSER_ROLE="0xbdb3c7a71aef31ac80b6d5cbd6dded192c9bd509932fe946063b93812daab3d8"
CUT_EXECUTOR_ROLE="0x79e1e3d3e3de70c699cf722e12669b68c6abfc6638926a4cd2453da145dfef87"
REPORTER_ROLE="0x0983a4a225ad19343fb4e37e3e27b5dbb3d58cb6ff14e959ffea1be784e109d0"

# Module ids
MODULE_MARKET="0xebe5e1b4e81c19df2eae56464f20c171ff4cc84e0e7a45fb50315f3ef189da73"

# Test wallet file
WALLETS_FILE="/tmp/predix_test_wallets.json"

# Output sinks
LOG_FILE="/tmp/predix_phase2_log.txt"
RESULTS_FILE="/tmp/predix_phase2_results.jsonl"

# Initialize sinks (touch only)
touch "$LOG_FILE" "$RESULTS_FILE"

log() {
    local msg="[$(date +%H:%M:%S)] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

# Load wallet address by name (alice/bob/carol)
wallet_addr() {
    jq -r ".$1.address" "$WALLETS_FILE"
}
wallet_key() {
    jq -r ".$1.private_key" "$WALLETS_FILE"
}

# Send tx and return tx hash. Args: <pk> <to> <sig> [args...]
send_tx() {
    local pk="$1"; shift
    local to="$1"; shift
    local sig="$1"; shift
    cast send "$to" "$sig" "$@" --private-key "$pk" --rpc-url "$RPC" --json \
        | jq -r '.transactionHash'
}

# Send tx with --value. Args: <pk> <to> <value-eth>
send_eth() {
    local pk="$1"; shift
    local to="$1"; shift
    local value="$1"; shift
    cast send "$to" --value "$value" --private-key "$pk" --rpc-url "$RPC" --json \
        | jq -r '.transactionHash'
}

# Get gas used from a receipt
gas_of() {
    cast receipt "$1" --rpc-url "$RPC" --json 2>/dev/null | jq -r '.gasUsed' \
        | python3 -c 'import sys; v=sys.stdin.read().strip(); print(int(v,16) if v.startswith("0x") else int(v))'
}

# Append a result record. Args: <id> <category> <description> <result> <gas> <tx_hashes_csv> [extra json]
record_result() {
    local id="$1" category="$2" desc="$3" result="$4" gas="${5:-0}" tx_csv="${6:-}" extra="${7:-{\}}"
    local now=$(date +%s)
    local txs_json="[]"
    if [ -n "$tx_csv" ]; then
        txs_json=$(echo "$tx_csv" | python3 -c 'import sys,json; print(json.dumps([t.strip() for t in sys.stdin.read().split(",") if t.strip()]))')
    fi
    jq -nc \
        --arg id "$id" \
        --arg cat "$category" \
        --arg desc "$desc" \
        --arg result "$result" \
        --argjson gas "$gas" \
        --argjson txs "$txs_json" \
        --argjson finished "$now" \
        --argjson extra "$extra" \
        '{id:$id, category:$cat, description:$desc, result:$result, gas_used_total:$gas, tx_hashes:$txs, finished_at:$finished, extra:$extra}' \
        >> "$RESULTS_FILE"
    log "result: $id $result gas=$gas"
}

# Run a cast send and capture failure for "expected revert" tests.
# Returns 0 if it reverted, 1 if it succeeded. Echoes the revert reason.
expect_revert() {
    local pk="$1"; shift
    local to="$1"; shift
    local sig="$1"; shift
    local out
    if out=$(cast send "$to" "$sig" "$@" --private-key "$pk" --rpc-url "$RPC" 2>&1); then
        echo "UNEXPECTED_SUCCESS"
        return 1
    fi
    # Try parameterized error name first (e.g. ERC20InsufficientAllowance(...)),
    # then fall back to bare error name on the trailing line (e.g. Market_AlreadyResolved).
    local match
    match=$(echo "$out" | grep -oE '[A-Za-z_][A-Za-z0-9_]*\([^)]*\)' | tail -1 || true)
    if [ -z "$match" ]; then
        match=$(echo "$out" | grep -oE '[A-Z][A-Za-z0-9_]*_[A-Za-z0-9_]+' | tail -1 || true)
    fi
    [ -n "$match" ] && echo "$match" || echo "REVERT_NO_REASON"
    return 0
}

# Read marketCount
market_count() {
    cast call "$DIAMOND_ADDRESS" "marketCount()(uint256)" --rpc-url "$RPC" \
        | awk '{print $1}'
}

# Read USDC balance
usdc_balance() {
    cast call "$USDC_ADDRESS" "balanceOf(address)(uint256)" "$1" --rpc-url "$RPC" \
        | awk '{print $1}'
}

# Read ERC20 balance
erc20_balance() {
    cast call "$1" "balanceOf(address)(uint256)" "$2" --rpc-url "$RPC" \
        | awk '{print $1}'
}

# Read market YES/NO + endTime + isResolved + refundMode
market_status() {
    cast call "$DIAMOND_ADDRESS" "getMarketStatus(uint256)(address,address,uint256,bool,bool)" "$1" --rpc-url "$RPC"
}

# hasRole helper
has_role() {
    cast call "$DIAMOND_ADDRESS" "hasRole(bytes32,address)(bool)" "$1" "$2" --rpc-url "$RPC"
}
