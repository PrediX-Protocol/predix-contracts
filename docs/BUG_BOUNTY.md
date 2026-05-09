# PrediX Bug Bounty Program

## Scope

All smart contracts in `packages/`:
- **diamond** — Market engine (EIP-2535 proxy, MarketFacet, EventFacet, AccessControl, Pausable)
- **hook** — Uniswap v4 hook (PrediXHookV2 + PrediXHookProxyV2)
- **exchange** — On-chain CLOB (PrediXExchange + PrediXExchangeProxy)
- **router** — Stateless aggregator (PrediXRouter, PrediXMarketFactory)
- **oracle** — ManualOracle, ChainlinkOracle
- **shared** — OutcomeToken, TransientReentrancyGuard, constants, interfaces

Deployed contract addresses are listed in [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md).

## Severity & Rewards

| Severity | Description | Reward |
|---|---|---|
| Critical | Direct fund loss, protocol bricking, oracle manipulation, unauthorized minting/burning of outcome tokens | $10,000 - $50,000 |
| High | Unauthorized access to admin functions, DoS on critical exit paths (redeem/refund/cancel), incorrect market resolution | $5,000 - $10,000 |
| Medium | Gas griefing, minor access control gaps, incorrect event emission, orderbook manipulation without fund loss | $1,000 - $5,000 |
| Low | Best practice violations, gas optimizations, informational findings | $100 - $1,000 |

Rewards are denominated in USDC and paid upon fix verification.

## Out of Scope

- Issues already documented in `SC/audits/`
- Frontend, backend, indexer, or paymaster issues
- Social engineering or phishing attacks
- Issues requiring compromised admin/operator private keys (threat model excludes key compromise)
- Theoretical attacks requiring > $10M capital or > 50% network hash power
- Gas inefficiencies that do not constitute a DoS vector
- Issues in vendored dependencies (`lib/`) unless exploitable through PrediX contracts

## Reporting Process

1. **Email**: security@predixprotocol.com
2. **Encrypt**: Use PGP key (available at predixprotocol.com/.well-known/pgp-key.asc)
3. **Include**: Detailed description, affected contracts/functions, proof of concept (Foundry test preferred), estimated severity
4. **Do NOT**: Disclose publicly, test on mainnet, exploit for personal gain

## Response Timeline

| Action | Timeline |
|---|---|
| Acknowledgement | Within 48 hours |
| Severity assessment | Within 5 business days |
| Fix for Critical | Within 24 hours of confirmation |
| Fix for High | Within 72 hours |
| Fix for Medium | Within 1 week |
| Fix for Low | Next release cycle |
| Reward payment | Within 30 days of fix deployment |

## Rules

- First valid reporter receives the reward (no duplicates)
- Public disclosure allowed 30 days after fix is deployed on all affected chains
- Testing must be performed on testnets only (Unichain Sepolia)
- Researchers must not interact with accounts they do not own
- Researchers must make a good-faith effort to avoid privacy violations and data destruction
- Severity is determined by the PrediX security team based on impact and likelihood

## Safe Harbor

PrediX will not pursue legal action against researchers who:
- Comply with the rules above
- Report vulnerabilities through the designated channel
- Do not exploit vulnerabilities beyond proof of concept
- Do not access or modify data belonging to other users

## Platform

Self-hosted program. Immunefi integration planned for mainnet launch.
