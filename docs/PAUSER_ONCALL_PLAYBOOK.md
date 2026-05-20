# Pauser On-call Playbook

**Audience:** on-call engineers, security, operations
**Status:** Active
**Owner:** KT (Security Owner)
**Last reviewed:** 2026-05-20

This playbook is the operational manual for Safe 4 (Incident Response) signers. It covers rotation structure, alert tooling, the incident response runbook, drill cadence, and escalation paths. Use alongside [`KEY_MANAGEMENT_POLICY.md`](KEY_MANAGEMENT_POLICY.md) (policy) and [`SAFE_DEPLOYMENT_RUNBOOK.md`](SAFE_DEPLOYMENT_RUNBOOK.md) (Safe deployment).

---

## 1. Mandate

Safe 4 holds `PAUSER_ROLE` on the diamond. Its sole purpose is to halt damage fast when monitoring detects an anomaly. The Safe MUST be able to execute a pause within **60 minutes** of an alert firing, with **2-of-3 hardware signatures**.

Pause is the fastest mitigation available. It does not require root-cause analysis — pause first, investigate after. Unpause is gated separately (see § 6) and requires Safe 1, never Safe 4 alone.

---

## 2. Rotation structure

### Three-person rotation, 8-hour shifts

Each Safe 4 signer covers one fixed 8-hour shift band:

| Shift | UTC window | Recommended timezone for primary |
|---|---|---|
| Asia | 00:00 – 08:00 | UTC+7 (Vietnam) or UTC+8 (Singapore, Hong Kong) |
| EU | 08:00 – 16:00 | UTC±0 (UK) or UTC+1 (Germany, France) |
| Americas | 16:00 – 24:00 | UTC-5 (US East Coast) or UTC-8 (US West Coast) |

With threshold 2-of-3, pause requires **two** signatures. The shift rotation ensures the primary on-call is in awake hours; one of the other two signers will need to wake (acceptable — pause is for emergencies). The 2-of-3 quorum is deliberately tight to enable fast response while still preventing a single-key compromise from pausing the protocol.

### Primary and secondary on-call

Each shift band has:

- **Primary** — the named Safe 4 signer for that timezone, expected response in 15 minutes.
- **Secondary** — a different Safe 4 signer designated as backup if the primary is unreachable for 5 minutes after page.

The secondary rotates weekly: a signer is secondary during the two non-shift bands.

### Coverage SLA

| Milestone | Target |
|---|---|
| Acknowledge alert | < 15 minutes from page fire |
| Initial severity assessment | < 30 minutes |
| Pause decision | < 45 minutes |
| 2-of-3 signatures collected | < 60 minutes |
| Pause executed on-chain | < 90 minutes |

Any milestone missed by > 50% triggers an incident retrospective post-incident.

---

## 3. Alert tooling

### Alert sources

Three independent monitoring sources feed the page pipeline:

**1. Forta bots or OpenZeppelin Defender Sentinels** — on-chain event monitors:

| Event | Severity | Action |
|---|---|---|
| `Paused` / `Unpaused` on diamond, exchange, hook | Inform | Notify war room, no page |
| `MarketEmergencyResolved` (with `EmergencyReason.Reason`) | P1 | Page if reason != `OracleUnreachable`; OracleUnreachable is the routine stall path |
| `EventEmergencyResolved` | P1 | Same logic as above |
| `RoleGranted` / `RoleRevoked` on diamond | P0 | Page immediately — role changes are governance-only and unexpected role grants signal Safe compromise |
| `Hook_DiamondProposed` / `Hook_DiamondRotated` | P0 | Page immediately — diamond rotation is rare and unexpected ones signal Safe 2 compromise |
| `Upgraded` on hook proxy or exchange proxy | P0 | Page immediately — impl changes are governance-only |
| `OldDiamondAllowanceRevoked` | Inform | Expected only during deliberate diamond rotation cleanup |
| `AdminChanged` on any proxy | P0 | Page — proxy admin change is high-risk |
| Trade volume > 5σ above 7-day baseline | P2 | Investigate, no immediate page |

**2. Tenderly Alerts** — transaction-level monitoring:

- Any failed transaction on diamond / exchange / hook / router → P2
- Gas anomaly > 3× expected → P2
- Pending transaction held for > 30 minutes on Safe → P1 (signing infrastructure issue)

**3. Custom watcher cron** — runs every 5 minutes from a dedicated monitoring host:

```bash
# Pseudo-cron
*/5 * * * *  forge script PostDeployVerify --rpc-url $UNICHAIN_RPC_PRIMARY \
               > /var/log/predix/postdeploy.log 2>&1 \
               || /opt/predix/scripts/page-pauser.sh "PostDeployVerify failed"
```

A `PostDeployVerify` failure means the on-chain wiring drifted from the expected state. This is a P0 page.

### Notification pipeline

```
Forta/Defender/Tenderly/Cron alert
    |
    v
Webhook to PagerDuty (or Opsgenie / VictorOps)
    |
    v
Page primary on-call (SMS + phone call + push notification)
    |
    v  (no ack in 5 min)
Page secondary on-call
    |
    v  (no ack in 5 min)
Escalate to all 3 Safe 4 signers + 2 Safe 1 signers
    |
    v  (no ack in 15 min)
Escalate to engineering lead + security lead
```

### Communication channels

- **War room** (private Signal group OR a dedicated Slack channel) — 4 Safe 4 signers + 2 engineering leads + security lead. Quiet by default; activates when alert fires. Used for real-time coordination during an incident.
- **Status page** (`status.predix.xxx`) — public, updated by the security lead during P0/P1 incidents. Sets user expectations.
- **Incident document** (Notion / Linear / Confluence) — opened at the start of every incident. Records timeline, decisions, signature collection, on-chain tx hashes, post-mortem actions.

---

## 4. Incident response runbook

### Minute 0 – 5: Acknowledge

Primary on-call:

- [ ] Click "Acknowledge" in PagerDuty (stops further pages to others).
- [ ] Post in war room: "ACK by [name] @ [time UTC], assessing [alert ID]"
- [ ] Open the three tabs that will be needed:
      - Safe UI for Safe 4 (pre-loaded to the propose-tx page)
      - Tenderly dashboard for the affected contract
      - Unichain block explorer

### Minute 5 – 15: Assessment

- [ ] Read the alert payload. Identify:
      - Contract address involved
      - Event name
      - Transaction hash that triggered the event
      - Timestamp
      - msg.sender of the triggering transaction
- [ ] Determine severity:

| Severity | Definition | Action |
|---|---|---|
| **P0** | Active exploit confirmed OR funds at risk OR unexpected role/admin change OR unexpected upgrade | Pause immediately, ask questions after |
| **P1** | Suspicious but unclear whether exploit OR governance event with no advance notice | Pull second Safe 4 signer onto war room, investigate before pausing |
| **P2** | Likely false positive OR informational event | Document, downgrade page, no action |

- [ ] Post the severity decision in war room with reasoning.

### Minute 15 – 30: Decision

For P0:

- [ ] In Safe 4 UI, propose the appropriate pause transaction. The four pause surfaces:

| Surface | Function | When to use |
|---|---|---|
| Diamond MARKET module | `diamond.pause(Modules.MARKET)` | Market manipulation, oracle exploit on regular markets |
| Diamond EVENT module | `diamond.pause(Modules.EVENT)` | Event-resolution exploit, child-market manipulation |
| Exchange | `exchange.pause()` | CLOB exploit, fill solvency violation |
| Hook | `hook.setPaused(true)` | Anti-sandwich bypass, AMM-layer exploit |

When in doubt, pause the broadest surface that contains the suspect contract. Pausing more than necessary is recoverable; pausing too narrow leaves the exploit running.

- [ ] Notify the secondary on-call in war room: "Need countersignature on Safe 4 tx [hash]."
- [ ] Notify Safe 1 and Safe 2 signers (passive awareness — no action expected from them yet).

For P1:

- [ ] Pull secondary on-call into war room.
- [ ] Together, decide: more data needed (P2 downgrade), or pause warranted (P0 promotion).
- [ ] If unclear after 15 minutes, default to pause. The cost of an unnecessary pause is hours of downtime; the cost of a missed exploit is funds.

### Minute 30 – 60: Execute

- [ ] Secondary signer opens Safe UI, finds the proposed transaction.
- [ ] Both signers verify on their hardware device:
      - Target contract address matches
      - Function selector decodes to the expected pause function
      - Parameter (module enum for diamond, `true` for hook) is correct
- [ ] Both signers sign. Threshold 2-of-3 reached.
- [ ] Primary executes the transaction.
- [ ] Verify on-chain via Tenderly that the `Paused` event emitted.
- [ ] Update status page: "Protocol paused at [time UTC] pending investigation. User funds remain on-chain and recoverable; trading halted."

### Minute 60+: Investigation

- [ ] Spawn dedicated incident channel (e.g., `#incident-2026-05-20`).
- [ ] Engineering lead and security lead join.
- [ ] Begin root cause analysis:
      - Reproduce the triggering transaction in Tenderly fork simulation
      - Read the touched contracts' state at the failing block
      - Identify whether this is an exploit, an oracle anomaly, a misconfigured operator action, or a false-positive alert
- [ ] Decide:
      - Short-term mitigation: keep paused, or unpause subset of modules
      - Long-term fix: contract change required, governance change required, or config change
      - Unpause criteria (see § 6)
- [ ] Publish a preliminary post-mortem within 48h, final within 7 days.

---

## 5. Unpause procedure

Unpause is **not** a Safe 4 action. Pause is fast; unpause must be deliberate.

Unpause requirements:

- [ ] Engineering sign-off — root cause documented and understood.
- [ ] Security sign-off — mitigation is tested and reviewed. If a contract change is required, it has gone through the existing 48h timelock with `PostDeployVerify` confirmation.
- [ ] Minimum 24h cooldown from the moment of pause (gives community time to react and external observers time to audit).
- [ ] Safe 1 (Protocol Governance) signs the unpause transaction with the full 3-of-5 quorum.

Safe 4 cannot self-unpause. This separation prevents a compromised Safe 4 from waving the protocol back on after a malicious pause.

---

## 6. Drill cadence

Drills keep the rotation sharp and catch tooling rot before a real incident.

### Monthly tabletop exercise (30 minutes)

- Security lead presents a scenario verbally. Examples:
  - "Forta alerted that the diamond's USDC balance dropped 40% in one block. What do?"
  - "The ETH/USD Chainlink feed just emitted a price 50% below the previous round. What do?"
  - "An unexpected `RoleGranted` event on diamond just fired, granting OPERATOR_ROLE to a new EOA. What do?"
- On-call team walks through the decision tree out loud.
- No actual signing, no on-chain action.
- Document any gap in the runbook, alert tooling, or escalation path. File issues against this playbook.

### Quarterly real pause test on testnet

- Deploy a fresh stack on Unichain Sepolia (or replay the latest mainnet snapshot in a fork test environment).
- Trigger a synthetic alert.
- Run the full pipeline: alert → page → ack → assess → propose → countersign → execute.
- Measure each milestone against the SLA in § 2.
- Verify the alert pipelines fire correctly. Verify war room comms work.
- Post-drill retro within 24h.

### Annual end-to-end incident drill

- Surprise simulation. No prior notice to on-call beyond the existing rotation.
- Security lead works with one external observer to design the scenario.
- Full flow: alert → page → ack → assess → pause → status page update → public comms → investigation → mitigation → unpause via Safe 1.
- External observer audits each step against this playbook.
- Results feed the annual rotation review and any necessary policy updates.

---

## 7. Escalation matrix

| Level | Trigger | Responder | Authority |
|---|---|---|---|
| **L1** | Single alert fires, primary acknowledges within SLA | Primary on-call | Assess + propose |
| **L2** | No ack in 5 minutes OR P0 severity declared | Secondary on-call + all Safe 4 signers | Sign + execute pause |
| **L3** | Pause executed OR active exploit confirmed | Engineering lead + Security lead + Safe 1 signers (passive awareness) | Investigation + mitigation planning |
| **L4** | Loss > $100k OR sustained attack OR Safe compromise suspected | External: audit firm partners, Chainalysis (if funds moved), law enforcement / regulators per jurisdiction | External coordination |

Each level is additive — L4 escalation does not replace L1-L3; all parties remain engaged.

---

## 8. On-call hygiene

### Daily

- [ ] Primary on-call confirms PagerDuty subscription is active and the device receives test pages.
- [ ] Confirm hardware wallet is physically present, charged, and accessible within 5 minutes of where the signer will be during the shift.

### Weekly

- [ ] Run a synthetic alert through PagerDuty → page test channel. Confirm primary + secondary receive within 30 seconds.
- [ ] Confirm war room access for all participants (Signal group membership, Slack channel access).

### Monthly

- [ ] Tabletop exercise per § 6.
- [ ] Review and close any open action items from the previous month's incidents.

### Pre-vacation

When a Safe 4 signer takes leave > 24h:

- [ ] Notify the other two Safe 4 signers and the security lead.
- [ ] Confirm one of the other two signers will cover the affected shift.
- [ ] Update the public on-call schedule (private OPS doc).

---

## 9. Reference

- `docs/KEY_MANAGEMENT_POLICY.md` — Safe 4 mandate and signer requirements
- `docs/SAFE_DEPLOYMENT_RUNBOOK.md` — how the four Safes were deployed
- `docs/MAINNET_DEPLOY_REHEARSAL.md` — broader rehearsal that includes monitoring setup
- `docs/INCIDENT_RESPONSE_PLAN.md` — protocol-wide incident response (this playbook is the Safe 4 subset)
- Pausable interface: `packages/shared/src/interfaces/IPausableFacet.sol`
- Emergency event signatures: `packages/shared/src/interfaces/IMarketFacet.sol` (`MarketEmergencyResolved`) and `IEventFacet.sol` (`EventEmergencyResolved`), both with `EmergencyReason.Reason` field for off-chain classification
