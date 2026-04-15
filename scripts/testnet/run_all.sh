#!/usr/bin/env bash
# run_all.sh — Phase 2 orchestrator. Runs every test group in the order
# specified by Plan §7 / Phase 2 prompt §C.
#
# Usage:
#   bash scripts/testnet/run_all.sh
#
# FC group is intentionally LAST per the Phase 2 prompt (§Q4 trap-handler
# safety). Group RT is deferred to Phase 3 and not invoked here.
set -euo pipefail

cd "$(dirname "$0")/../.."

bash scripts/testnet/00_wallets.sh
bash scripts/testnet/01_preflight.sh
bash scripts/testnet/10_market.sh
bash scripts/testnet/30_refund.sh
bash scripts/testnet/40_pause.sh
bash scripts/testnet/50_access.sh
bash scripts/testnet/70_clob.sh
bash scripts/testnet/97_loupe_dump.sh
bash scripts/testnet/60_fee_config.sh    # MUST be last (mutates fees, trap resets)

echo "== run_all.sh complete =="
echo "results: /tmp/predix_phase2_results.jsonl"
echo "log:     /tmp/predix_phase2_log.txt"
echo "loupe:   /tmp/predix_phase2_loupe.json"
