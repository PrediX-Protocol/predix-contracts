# Security Policy

## Reporting a Vulnerability

The PrediX team takes security seriously. We appreciate responsible disclosure from security researchers and the broader community.

### Where to report

| Severity | Channel | Response SLA |
|---|---|---|
| **Critical / High** (fund loss, protocol brick, admin compromise) | **keyti@predixpro.io** | 24 hours acknowledgment, 72 hours initial assessment |
| **Medium / Low** (DoS, gas griefing, cosmetic, theoretical) | **keyti@predixpro.io** or GitHub Security Advisories | 48 hours acknowledgment |
| **Bug bounty** | Contact keyti@predixpro.io | Per Immunefi SLA |

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
| Critical (direct fund loss) | $5,000 — $20,000 |
| High (significant vulnerability) | $1,000 — $5,000 |
| Medium (limited impact) | $200 — $1,000 |
| Low (minor / theoretical) | $50 — $200 |

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

## Trust Model & Centralization

PrediX holds user collateral in its own contracts and releases it only by the rules
described here. Before depositing, users should understand the following trust
assumptions. Privileged roles are intended to be held by multisig / timelock
governance in production; consult the on-chain role configuration for current holders.

### Privileged roles

Governance is role-based (EIP-2535 access control). The hierarchy is deliberately
split: `DEFAULT_ADMIN_ROLE` administers the operational roles below but **cannot**
administer `CUT_EXECUTOR_ROLE`, so the keys that can upgrade code are separated from
the keys that run day-to-day operations.

| Role | Power | Bound by |
|---|---|---|
| `ADMIN_ROLE` | protocol config, redemption fee (capped on-chain), enable refund mode, sweep unclaimed / surplus | fee ceilings enforced on-chain; cannot seize collateral backing live claims |
| `OPERATOR_ROLE` | emergency-resolve a stalled market (see below) | `endTime + 7 days` wait; fair refund alternative always available |
| `PAUSER_ROLE` | pause market entry and trading | **cannot** block exits (see Pause) |
| `CUT_EXECUTOR_ROLE` | upgrade Diamond facets | intended to be an external TimelockController with a **48-hour** delay; not administered by the admin role |

### Oracle resolution

Each market resolves through an admin-approved oracle — a Chainlink price feed or a
manual reporter. Users trust the approved oracle to report the correct outcome. The
manual reporter writes through a challenge window before an outcome finalizes.

### Emergency resolution (operator-trusted)

If an approved oracle never produces an answer, a stalled market has two recovery
paths after it ends:

- **Refund mode** (`ADMIN_ROLE`) — voids the market; holders reclaim collateral by
  redeeming matched YES + NO at par. No winner is chosen. This is the fair default.
- **Emergency resolve** (`OPERATOR_ROLE`, only after `endTime + 7 days`) — settles the
  market to an **operator-asserted** outcome. The outcome is chosen by the operator,
  not derived from the oracle (the oracle is consulted only to confirm it has not
  answered). This exists so a market whose real-world result is known can be settled
  to the truth when its oracle is dead, rather than only voided.

Emergency resolve is a trusted action. It is bounded by the 7-day delay, the operator
being a multisig in production, and the always-available fair refund alternative — but
within those bounds the operator is trusted to assert the correct outcome. Every
emergency resolution emits a `MarketEmergencyResolved` event with a machine-readable
reason, which the protocol monitors off-chain.

### Pause

`PAUSER_ROLE` can freeze market entry and trading (mint / merge, AMM swaps, liquidity
adds). It **cannot** freeze exits: redeeming a resolved position, refunding a voided
market, and removing liquidity always succeed regardless of pause state. A pause can
slow the protocol; it cannot trap user funds.

### Upgradeability

The Diamond (EIP-2535) and the Uniswap v4 hook are upgradeable. Facet cuts run only
through `CUT_EXECUTOR_ROLE` (an external TimelockController, 48-hour delay); the hook
upgrades through a proxy with its own 48-hour timelock whose delay is monotonic and
self-gated (it cannot be shortened to bypass the wait). Storage layouts are
append-only. Every sensitive governance action (diamond / hook upgrade, admin
rotation, trusted-router changes, oracle / diamond rotation) follows a two-step
propose → delay → execute flow with a cancellation window.

### Collateral

The protocol uses USDC as collateral and assumes standard 6-decimal, non-fee-on-
transfer behavior.

## Safe Harbor

We will not pursue legal action against security researchers who:
- Report vulnerabilities in good faith following this policy
- Do not exploit vulnerabilities beyond minimal proof-of-concept
- Do not access or modify other users' data
- Allow reasonable time for remediation before disclosure

## Acknowledgments

We maintain a Hall of Fame for researchers who responsibly disclose vulnerabilities. With your permission, we will publicly credit you in our security advisories and this file.

## Contact

- **Email**: keyti@predixpro.io
— Telegram: @keyti_0

## Supported Versions

| Version | Supported |
|---|---|
| `upgrade_v2` (current) | ✅ |
| `develop` (pre-Bundle-A) | ❌ (upgrade to `upgrade_v2`) |
| V1 (legacy) | ❌ (deprecated) |
