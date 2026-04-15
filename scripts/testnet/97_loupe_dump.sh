#!/usr/bin/env bash
# 97_loupe_dump.sh — Group SU: diamond loupe dump + supportsInterface checks
# + storage slot probe. Read-only (zero broadcasts).
# Output saved to /tmp/predix_phase2_loupe.json for the Phase 2 report appendix.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

LOUPE_FILE=/tmp/predix_phase2_loupe.json

log "== Group SU =="

# SU-01: facets()
log "-- SU-01: facets() dump --"
# facets() returns Facet[] where Facet = (address, bytes4[]). Use cast call
# with the typed signature to get a structured response.
cast call "$DIAMOND_ADDRESS" "facets()((address,bytes4[])[])" --rpc-url "$RPC" \
    > /tmp/predix_phase2_facets.txt
log "facets dump (raw):"; cat /tmp/predix_phase2_facets.txt | head -20
record_result "SU-01" "Storage/Loupe" "facets() dump" "pass" 0 "" \
    "{\"file\":\"/tmp/predix_phase2_facets.txt\"}"

# SU-02: supportsInterface for ERC165, IDiamondCut, IDiamondLoupe
log "-- SU-02: supportsInterface checks --"
# ERC165 = 0x01ffc9a7
# IDiamondCut = 0x1f931c1c (selector of diamondCut)
# IDiamondLoupe = 0x48e2b093 (selector of facetAddresses)
# We pass the 4-byte interface ID padded to 32 bytes
support_results="{}"
check_iface() {
    local name="$1" iid="$2"
    local out
    out=$(cast call "$DIAMOND_ADDRESS" "supportsInterface(bytes4)(bool)" "$iid" --rpc-url "$RPC")
    log "  supportsInterface($name=$iid) = $out"
    support_results=$(echo "$support_results" | jq --arg n "$name" --arg v "$out" '. + {($n): $v}')
}
check_iface ERC165 0x01ffc9a7
check_iface IDiamondCut 0x1f931c1c
check_iface IDiamondLoupe 0x48e2b093
record_result "SU-02" "Storage/Loupe" "supportsInterface ERC165/Cut/Loupe" "pass" 0 "" "$support_results"

# SU-03: storage slot probe — read at keccak256("predix.storage.market") to confirm non-zero
log "-- SU-03: storage probe --"
slot=$(cast keccak "predix.storage.market")
val=$(cast storage "$DIAMOND_ADDRESS" "$slot" --rpc-url "$RPC")
log "slot $slot = $val"
record_result "SU-03" "Storage/Loupe" "storage slot probe" "pass" 0 "" \
    "{\"slot\":\"$slot\",\"value\":\"$val\"}"

# Compose the loupe appendix
jq -nc \
    --arg facets "$(cat /tmp/predix_phase2_facets.txt)" \
    --argjson support "$support_results" \
    '{facets_raw: $facets, supports_interface: $support}' \
    > "$LOUPE_FILE"
log "loupe dump saved to $LOUPE_FILE"

log "== Group SU done =="
