# PrediX V2 — Incident Response Plan

**Version**: 1.0
**Date**: 2026-04-27
**Owner**: SP Labs Security Team
**Review cadence**: Quarterly (next review: 2026-07-27)

---

## 1. Purpose

This document defines the procedures for detecting, triaging, containing, and recovering from security incidents affecting the PrediX V2 protocol. It applies to all on-chain contracts, off-chain services, and operational infrastructure.

## 2. Scope

| Component | Chain | Contracts |
|---|---|---|
| Diamond proxy | Unichain | MarketFacet, EventFacet, AccessControlFacet, PausableFacet, DiamondCutFacet |
| Hook proxy + impl | Unichain | PrediXHookProxyV2, PrediXHookV2 |
| Exchange | Unichain | PrediXExchange |
| Router | Unichain | PrediXRouter |
| Oracles | Unichain | ManualOracle, ChainlinkOracle |
| Paymaster | Unichain | PrediXPaymaster |
| Off-chain | Cloud | BE API, Indexer (Ponder), Frontend, Bot |

## 3. Severity Levels

| Level | Definition | Response time | Examples |
|---|---|---|---|
| **P0 — Critical** | Active fund drain or protocol brick. User collateral at immediate risk. | **15 min** triage, **1 hour** containment | Reentrancy exploit, diamond storage corruption, oracle manipulation draining collateral |
| **P1 — High** | Exploitable vulnerability identified but not yet exploited. Significant fund risk. | **1 hour** triage, **4 hours** containment | Admin key compromise, CLOB accounting bug, hook bypass |
| **P2 — Medium** | Limited impact vulnerability or degraded service. No immediate fund risk. | **4 hours** triage, **24 hours** remediation | DoS on CLOB taker path, gas griefing, price manipulation limited by anti-sandwich |
| **P3 — Low** | Minor bug, cosmetic issue, or theoretical vulnerability. | **24 hours** triage, **1 week** remediation | Rounding dust, documentation gap, gas optimization |

## 4. Incident Response Team

| Role | Responsibility | Primary | Backup |
|---|---|---|---|
| **Incident Commander (IC)** | Overall coordination, severity assessment, external communication authorization | CTO / KT | Senior Engineer |
| **Technical Lead** | Root cause analysis, containment execution, fix development | Lead SC Engineer | SC Engineer #2 |
| **Communications Lead** | User notification, Discord/Twitter updates, exchange liaisons | COO / Community Lead | Marketing Lead |
| **Legal Lead** | Regulatory implications, law enforcement coordination, insurance claims | Legal Counsel | External Legal Firm |
| **On-call Engineer** | First responder, initial triage, 24/7 availability | Rotating weekly | — |

## 5. Detection Sources

| Source | What it detects | Owner |
|---|---|---|
| **On-chain monitoring** (Forta / OZ Defender) | Unusual token transfers, governance proposals, pause events, large swaps | Technical Lead |
| **Indexer alerts** (Ponder) | Failed transactions, revert spikes, volume anomalies | Backend Team |
| **External reports** (bug bounty, security researchers) | Vulnerability disclosures via SECURITY.md | IC |
| **Dependency monitoring** (GitHub Dependabot) | Vulnerabilities in vendored libraries | Technical Lead |
| **Social media / community** | User reports of unexpected behavior, rumors of exploits | Communications Lead |
| **Peer protocol monitoring** | Exploits on similar protocols (via BlockThreat, rekt.news) | On-call Engineer |

## 6. Response Procedures

### 6.1 Phase 1 — Detection & Triage (0-15 min)

1. **Receive alert** from any detection source
2. **On-call engineer** performs initial assessment:
   - Is this a real incident or false positive?
   - What is the blast radius? (which contracts, which markets, how much TVL at risk?)
   - Assign severity level (P0-P3)
3. **If P0/P1**: immediately activate Incident Commander + Technical Lead
4. **Create incident channel** in team Slack/Discord (private, restricted access)
5. **Log**: timestamp, detection source, initial assessment, severity

### 6.2 Phase 2 — Containment (15 min - 4 hours)

**Goal**: Stop the bleeding. Prevent further damage.

**On-chain containment actions** (by severity):

| Action | Who can execute | Timelock | P0 | P1 | P2 |
|---|---|---|---|---|---|
| **Pause MARKET module** (blocks split/merge/resolve) | PAUSER_ROLE (multisig) | Instant | ✅ First action | ✅ If exploited | Case-by-case |
| **Pause Exchange** | PAUSER_ROLE via diamond | Instant | ✅ | ✅ If CLOB affected | No |
| **Pause Hook** (`setPaused(true)`) | Hook admin (multisig) | Instant | ✅ | ✅ If AMM affected | No |
| **Revoke oracle** (`revokeOracle`) | ADMIN_ROLE | Instant | ✅ If oracle compromised | ✅ | No |
| **Enable refund mode** per market | ADMIN_ROLE | Instant | ✅ If resolution corrupted | Case-by-case | No |
| **Cancel pending governance** (diamond rotation, upgrade, etc.) | Respective admin | Instant | ✅ If governance compromised | ✅ | No |

**Off-chain containment**:
- Disable frontend trading UI (deploy maintenance page)
- Pause bot trading
- Notify exchange partners if token listed

**Note**: `redeem` and `refund` deliberately bypass MARKET pause — users can ALWAYS exit post-finality. This is by design.

### 6.3 Phase 3 — Investigation (1-24 hours)

1. **Root cause analysis**:
   - Identify the vulnerable code path (file:line)
   - Determine if exploit is reproducible
   - Assess total funds at risk vs. funds actually lost
   - Check if similar vulnerabilities exist in related code paths

2. **Transaction forensics**:
   - Trace attacker transactions (`cast run <txhash>`)
   - Identify attacker address(es)
   - Determine if attacker is known entity
   - Estimate total value extracted

3. **Impact assessment**:
   - How many markets affected?
   - How many users affected?
   - What is the total collateral at risk?
   - Is the protocol invariant (`YES.supply == NO.supply == collateral`) broken?

### 6.4 Phase 4 — Remediation (4 hours - 1 week)

1. **Develop fix** in isolated branch
2. **Audit fix** — minimum 2 engineers review; for P0/P1 at least 1 external reviewer
3. **Write regression test** — test must fail on vulnerable code, pass on fixed code
4. **Deploy fix**:
   - Diamond facets: `diamondCut` via Timelock (48h delay — may need emergency governance acceleration)
   - Hook impl: `proposeUpgrade` + 48h + `executeUpgrade`
   - Exchange/Router: redeploy + admin update references
5. **Verify fix** on testnet first, then mainnet
6. **Unpause** affected modules after fix verified

**Emergency governance acceleration**: If 48h timelock is too slow for P0, options:
- Deploy fresh diamond with fixed facets at new address (requires user migration)
- Use `enableRefundMode` on affected markets (users get collateral back)
- Contact Unichain sequencer team for transaction prioritization

### 6.5 Phase 5 — Recovery & Post-mortem (1-2 weeks)

1. **User compensation plan** (if funds lost):
   - Calculate per-user loss from on-chain data
   - Determine compensation source (protocol treasury, insurance fund)
   - Publish compensation plan for community review
   - Execute airdrop or claim contract

2. **Post-mortem report** (public):
   - Timeline of events
   - Root cause
   - Impact ($ amount, users affected)
   - Response actions taken
   - Lessons learned
   - Prevention measures

3. **Process improvements**:
   - Update this incident response plan
   - Add new monitoring rules
   - Update threat model
   - Schedule additional audit if needed

## 7. Communication Templates

### 7.1 Initial acknowledgment (within 1 hour of P0/P1)

```
🚨 [PrediX Security Notice]

We are investigating a potential security issue affecting [component].
Trading has been paused as a precaution while we investigate.

Your funds are safe — redeem and refund functions remain operational.

We will provide updates every [30 min / 1 hour].

— PrediX Security Team
```

### 7.2 Status update

```
🔄 [PrediX Security Update — HH:MM UTC]

Status: [Investigating / Contained / Remediating]
Impact: [X markets / $Y TVL / Z users affected]
Action: [What we've done]
Next: [What we're doing next]
ETA: [When we expect resolution]

— PrediX Security Team
```

### 7.3 Resolution

```
✅ [PrediX Security Resolution]

The issue identified on [date] has been fully resolved.

Root cause: [brief]
Impact: [$ amount, users affected]
Resolution: [what was fixed]
Compensation: [plan if applicable]

Full post-mortem: [link]

Trading has resumed. Thank you for your patience.

— PrediX Security Team
```

## 8. Contact Information

| Contact | Channel | Response time |
|---|---|---|
| Security email | keyti@predixpro.io | 24h |
| Bug bounty | Contact keyti@predixpro.io | 48h |
| Discord #security | Contact @keyti_0 on Telegram | 4h during business hours |
| Emergency hotline | Telegram @keyti_0 | 15 min (P0 only) |

## 9. Runbook Quick Reference

### Pause everything (P0 nuclear option)

```bash
# 1. Pause Diamond MARKET module
cast send $DIAMOND "pauseModule(bytes32)" $(cast keccak "predix.module.market") --private-key $PAUSER_KEY

# 2. Pause Exchange
cast send $EXCHANGE "pause()" --private-key $PAUSER_KEY

# 3. Pause Hook
cast send $HOOK_PROXY "setPaused(bool)" true --private-key $HOOK_ADMIN_KEY

# 4. Verify paused
cast call $DIAMOND "isModulePaused(bytes32)" $(cast keccak "predix.module.market")
cast call $EXCHANGE "paused()"
cast call $HOOK_PROXY "paused()"
```

### Revoke compromised oracle

```bash
cast send $DIAMOND "revokeOracle(address)" $COMPROMISED_ORACLE --private-key $ADMIN_KEY
```

### Enable refund mode on affected market

```bash
cast send $DIAMOND "enableRefundMode(uint256)" $MARKET_ID --private-key $ADMIN_KEY
```

### Cancel pending governance proposal

```bash
# Cancel pending diamond rotation
cast send $HOOK_PROXY "cancelDiamondRotation()" --private-key $HOOK_ADMIN_KEY

# Cancel pending upgrade
cast send $HOOK_PROXY "cancelUpgrade()" --private-key $PROXY_ADMIN_KEY

# Cancel pending admin rotation
cast send $HOOK_PROXY "cancelAdminRotation()" --private-key $HOOK_ADMIN_KEY
```

## 10. Drill Schedule

| Drill | Frequency | Last run | Next scheduled |
|---|---|---|---|
| **Tabletop exercise** (simulate P0 scenario) | Quarterly | — | Before mainnet launch |
| **Pause drill** (actually pause on testnet) | Monthly | 2026-04-17 (Sepolia) | 2026-05-17 |
| **Key rotation drill** (rotate a signer in multisig) | Quarterly | — | Before mainnet launch |
| **Communication drill** (send test alert through all channels) | Quarterly | — | Before mainnet launch |

## 11. Dependencies & External Contacts

| Dependency | Security contact | Notification channel |
|---|---|---|
| Uniswap v4 (PoolManager) | security@uniswap.org | Discord #security |
| OpenZeppelin Contracts | security@openzeppelin.com | GitHub advisories |
| Chainlink (price feeds) | N/A (monitoring via feed health checks) | — |
| Circle (USDC) | N/A (USDC blacklist = circle.com/contact) | — |
| Unichain (sequencer) | Contact via Uniswap Discord | — |
| Permit2 | (part of Uniswap) | — |

## 12. Revision History

| Version | Date | Author | Changes |
|---|---|---|---|
| 1.0 | 2026-04-27 | SP Labs | Initial version |

---

*This plan must be reviewed and updated quarterly, after every incident, and after every major protocol upgrade.*
