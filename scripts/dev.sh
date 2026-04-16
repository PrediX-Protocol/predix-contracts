#!/usr/bin/env bash
# Start SC dev environment — build + watch for changes.
# Log file: /tmp/predix-sc-dev.log
#
# Usage: bash scripts/dev.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

LOG=/tmp/predix-sc-dev.log

echo "🚀 Starting SC dev (Foundry build + watch)..."
echo "   Log: $LOG"
echo "   Packages: shared, oracle, diamond, hook, exchange, router"
echo ""
echo "Running: make build (all packages)"

script -q "$LOG" make build
