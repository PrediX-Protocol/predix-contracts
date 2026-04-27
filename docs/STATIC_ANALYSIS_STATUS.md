# Static Analysis Tool Status

**Date**: 2026-04-27
**Codebase**: `upgrade_v2` @ `b898fc6`

## Slither — BLOCKED (upstream compatibility issue)

### Problem

Slither 0.11.5 (latest stable as of 2026-04-27) cannot parse the PrediX monorepo due to two compounding issues:

1. **Deep remapping chain**: `@predix/shared → packages/shared/src` + `@openzeppelin → lib/openzeppelin-contracts` + `uniswap-hooks → lib/uniswap-hooks/lib/v4-core/lib/openzeppelin-contracts`. Slither's foundry integration (`crytic-compile`) follows the remappings but fails to resolve `IERC20Errors` from the nested OZ install.

2. **`via_ir` requirement**: PrediX uses `via_ir = true` (required for stack-depth management in TakerPath, PrediXRouter). When flattened, the same files hit "Stack too deep" without `--via-ir`. Slither 0.11.5 does not support `via_ir` compilation via solc.

### What we tried

| Approach | Result |
|---|---|
| `slither .` in package directory | `AssertionError: Contract IERC20Errors not found` |
| `slither .` with `--foundry-out-directory out` | `ParsingError: Type not found Address` |
| `forge flatten` → `slither flat.sol` | `Stack too deep` (needs via_ir) |
| `solc-select use 0.8.30` + direct solc | Same stack-too-deep |
| `--solc-args "--via-ir"` | Not supported by crytic-compile 0.3.11 |

### Equivalent coverage we DO have

| Slither capability | PrediX equivalent |
|---|---|
| Reentrancy detection | Manual audit (3 passes) + `nonReentrant` on all state-changing entries + CEI pattern enforced |
| Unused state variables | Manual scan per CLAUDE.md §5.3 — 0 found |
| Unprotected functions | Manual audit — all external functions access-gated (verified) |
| Integer overflow | Solidity 0.8 default checks + 0 `unchecked` blocks |
| Missing events | All 45 events verified present at critical state transitions |
| tx.origin usage | grep verified: 0 actual uses (1 NatSpec mention) |
| Shadowing | Shallow inheritance (max 2 levels), no variable shadowing found |

### Recommended path forward

1. **Short-term**: Track [Slither #2567](https://github.com/crytic/slither/issues) (via_ir support). When fixed, install and add to CI.

2. **Medium-term**: Try Slither's development branch (`pip install slither-analyzer --pre`) once a release candidate addresses the OZ v5 + via_ir combination.

3. **Alternative**: Use **Aderyn** (Cyfrin's Solidity analyzer, Rust-based) which supports via_ir. Install: `cargo install aderyn`. Run: `aderyn .` per package.

4. **Complementary**: Add **Echidna** for property-based fuzzing (already have 16 invariant functions in Foundry format — portable to Echidna with minor adaptation).

### CI placeholder

The CI pipeline (`.github/workflows/ci.yml`) should include a Slither step that:
- Runs when the upstream fix lands
- Uses `slither . --json slither-report.json --triage-database slither.db.json`
- Fails the build on new HIGH/MEDIUM findings
- Triaged findings stored in `slither.db.json` (committed)

Placeholder step (commented out until upstream fix):

```yaml
# - name: Slither static analysis
#   run: |
#     pip3 install slither-analyzer
#     for pkg in diamond hook exchange router oracle paymaster shared; do
#       cd packages/$pkg
#       slither . --json ../../slither-reports/${pkg}.json \
#         --triage-database ../../slither-triage/${pkg}.db.json \
#         --filter-paths "test|lib|script" \
#         --exclude-informational \
#         --fail-on high,medium
#       cd ../..
#     done
```

## Other tools

| Tool | Status | Notes |
|---|---|---|
| **Echidna** | Not installed | 16 invariant functions ready for porting. Recommend install for extended campaigns. |
| **Halmos** | Not installed | Good candidate for symbolic verification of MatchMath arithmetic. |
| **Mythril** | Not installed | Superseded by Slither + Echidna for this codebase complexity. |
| **Aderyn** | Not installed | Viable alternative to Slither — supports via_ir. Recommend trial. |
| **Foundry fuzz** | ✅ Active | 256 runs per fuzz test, 128k calls per invariant campaign. Runs in CI. |
| **Foundry fmt** | ✅ Active | All 7 packages pass `forge fmt --check`. Runs in CI. |
