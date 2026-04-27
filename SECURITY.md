# Security Policy

## Reporting a Vulnerability

The PrediX team takes security seriously. We appreciate responsible disclosure from security researchers and the broader community.

### Where to report

| Severity | Channel | Response SLA |
|---|---|---|
| **Critical / High** (fund loss, protocol brick, admin compromise) | **security@predix.markets** | 24 hours acknowledgment, 72 hours initial assessment |
| **Medium / Low** (DoS, gas griefing, cosmetic, theoretical) | **security@predix.markets** or GitHub Security Advisories | 48 hours acknowledgment |
| **Bug bounty** | [Immunefi program — link TBD] | Per Immunefi SLA |

### What to include

- Description of the vulnerability
- Affected contract(s) and function(s) — file path and line number if possible
- Step-by-step reproduction (ideally a Foundry test or cast commands)
- Impact assessment (what can an attacker do? how much value at risk?)
- Suggested fix if you have one

### What NOT to do

- **Do not** open a public GitHub issue for security vulnerabilities
- **Do not** exploit the vulnerability on mainnet or testnet beyond minimal proof-of-concept
- **Do not** access or modify other users' funds or data
- **Do not** perform denial-of-service attacks
- **Do not** social-engineer or phish team members or users

## Bug Bounty Program

We plan to launch a bug bounty program on Immunefi before mainnet deployment. Bounty ranges (subject to program terms):

| Severity | Bounty range |
|---|---|
| Critical (direct fund loss) | $25,000 — $100,000 |
| High (significant vulnerability) | $5,000 — $25,000 |
| Medium (limited impact) | $1,000 — $5,000 |
| Low (minor / theoretical) | $250 — $1,000 |

Bounties are paid in USDC. Final amounts determined by impact, quality of report, and whether the vulnerability was previously known.

## Scope

### In scope

All smart contracts in `packages/*/src/`:

- `packages/diamond/src/` — Diamond proxy, Market/Event/Access/Pausable/Cut facets, init contracts, storage libraries
- `packages/hook/src/` — PrediXHookV2 (impl), PrediXHookProxyV2 (proxy), interfaces, constants
- `packages/exchange/src/` — PrediXExchange, MakerPath, TakerPath, Views, MatchMath, PriceBitmap
- `packages/router/src/` — PrediXRouter, interfaces
- `packages/oracle/src/` — ManualOracle, ChainlinkOracle, interfaces
- `packages/paymaster/src/` — PrediXPaymaster, interfaces
- `packages/shared/src/` — OutcomeToken, TransientReentrancyGuard, Roles, Modules, shared interfaces

### Out of scope

- Test files (`packages/*/test/`)
- Deploy scripts (`scripts/`)
- Vendored dependencies (`lib/`) — report upstream
- Frontend, backend, indexer, bot (separate repos)
- Issues in third-party contracts (Uniswap v4, OpenZeppelin, Chainlink) — report upstream
- Issues already documented in `audits/` directory
- Gas optimizations without security impact
- Cosmetic / documentation issues

## Safe Harbor

We will not pursue legal action against security researchers who:
- Report vulnerabilities in good faith following this policy
- Do not exploit vulnerabilities beyond minimal proof-of-concept
- Do not access or modify other users' data
- Allow reasonable time for remediation before disclosure

## Acknowledgments

We maintain a Hall of Fame for researchers who responsibly disclose vulnerabilities. With your permission, we will publicly credit you in our security advisories and this file.

## Contact

- **Email**: security@predix.markets
- **PGP key**: [TBD — will be published at predix.markets/.well-known/security.txt]

## Supported Versions

| Version | Supported |
|---|---|
| `upgrade_v2` (current) | ✅ |
| `develop` (pre-Bundle-A) | ❌ (upgrade to `upgrade_v2`) |
| V1 (legacy) | ❌ (deprecated) |
