# PrediX Documentation Index

This directory contains all engineering and operational documentation for the
PrediX V2 protocol. Each document declares its audience and lifecycle status
in a header block; the table below is the canonical entry point.

## Conventions

- Filename: `SCREAMING_SNAKE_CASE.md`
- Each document starts with a header block stating audience, status, and the
  date it was last reviewed.
- Status values: **Active** (kept current), **Reference** (timeless),
  **Archived** (preserved for context, not maintained), **Draft** (work in
  progress).
- Audience values: **engineers**, **operators**, **security**, **auditors**,
  **users**.

## Documents

### Reference — protocol architecture and conventions

| Document | Audience | Status | Purpose |
|---|---|---|---|
| [`TEST_TAXONOMY.md`](TEST_TAXONOMY.md) | engineers, auditors | Reference | The 5-layer test strategy (unit, integration, fork, staging smoke, mainnet smoke). What lives where and how each layer is run. |
| [`STATIC_ANALYSIS_STATUS.md`](STATIC_ANALYSIS_STATUS.md) | engineers, auditors | Active | Current state of static-analysis tooling integration (Slither, Aderyn) and known limitations. |
| [`DEVELOPER_GUIDE.md`](DEVELOPER_GUIDE.md) | engineers | Active | Local development setup, build/test commands, contribution flow. |

### Operations — runbooks for deploy and incident response

| Document | Audience | Status | Purpose |
|---|---|---|---|
| [`MAINNET_DEPLOY_REHEARSAL.md`](MAINNET_DEPLOY_REHEARSAL.md) | operators, security | Active | T-48h checklist before mainnet deploy: pin block freeze, fork-test consistency, key ceremony, monitoring readiness, sign-off matrix. |
| [`KEY_MANAGEMENT_POLICY.md`](KEY_MANAGEMENT_POLICY.md) | operators, security | Active | Four-Safe separation, signer overlap rules, role-to-env binding, Safe-loss recovery matrix. |
| [`SAFE_DEPLOYMENT_RUNBOOK.md`](SAFE_DEPLOYMENT_RUNBOOK.md) | operators, security | Active | Step-by-step procedure for the four-Safe key ceremony: preparation, key generation, on-chain deployment, verification. |
| [`PAUSER_ONCALL_PLAYBOOK.md`](PAUSER_ONCALL_PLAYBOOK.md) | operators, security | Active | Safe 4 on-call rotation structure, alert tooling, incident response runbook, drill cadence. |
| [`INCIDENT_RESPONSE_PLAN.md`](INCIDENT_RESPONSE_PLAN.md) | operators, security | Active | Protocol-wide incident response: roles, escalation paths, step-by-step procedures. |
| [`BUNDLE_C_CHECKLIST.md`](BUNDLE_C_CHECKLIST.md) | operators | Active | Pre-deploy verification checklist (complements `MAINNET_DEPLOY_REHEARSAL.md`). |

### Policy — rules of engagement

| Document | Audience | Status | Purpose |
|---|---|---|---|
| [`BUG_BOUNTY.md`](BUG_BOUNTY.md) | security, users | Active | Bug-bounty scope, reward bands, and disclosure timeline. |
| [`SECURITY_TEAM.md`](SECURITY_TEAM.md) | security, users | Active | Contact channels and responsibilities for security disclosures. |

### Tracking — mutable state

| Document | Audience | Status | Purpose |
|---|---|---|---|
| [`DEFERRED_FINDINGS.md`](DEFERRED_FINDINGS.md) | engineers, security | Active | Audit findings not remediated yet. Sprint roadmap, assignees, sign-off tracking. |
| [`AUDIT_RFP_PACKAGE.md`](AUDIT_RFP_PACKAGE.md) | auditors | Reference | External audit engagement package — scope, invariants, trust model, known issues. |

## Cross-document map

```
                       SECURITY.md (root)
                            │
                            ▼
                       SECURITY_TEAM.md
                            │
                            ▼
                       BUG_BOUNTY.md
                            │
                            ▼
                    AUDIT_RFP_PACKAGE.md  ◄────┐
                            │                  │
                ┌───────────┼───────────┐      │
                ▼           ▼           ▼      │
         TEST_TAXONOMY  STATIC_ANALYSIS  AUDIT_REPORT_*
                │                              │
                ▼                              │
          (test layers)                        │
                │                              │
                ▼                              │
         DEFERRED_FINDINGS ◄───────────────────┘
                │
                ▼
         (sprint roadmap)

  Deploy lifecycle
       │
       ▼
  BUNDLE_C_CHECKLIST  →  MAINNET_DEPLOY_REHEARSAL  →  Deploy  →  INCIDENT_RESPONSE_PLAN
                                     │                                  │
                                     ▼                                  ▼
                          KEY_MANAGEMENT_POLICY               PAUSER_ONCALL_PLAYBOOK
                                     │
                                     ▼
                          SAFE_DEPLOYMENT_RUNBOOK
```

## Adding a new document

1. Pick a filename in `SCREAMING_SNAKE_CASE.md` aligned with one of the four
   categories above (Reference / Operations / Policy / Tracking).
2. Open with the standard header block:
   ```
   # <Document title>

   **Audience:** <one or more from the list above>
   **Status:** <one of: Active / Reference / Archived / Draft>
   **Last reviewed:** YYYY-MM-DD
   ```
3. Add the document to the table in the right section of this index.
4. Cross-link related documents at the bottom of the new file.

## Document review cadence

| Category | Review cadence |
|---|---|
| Reference | Annually or when underlying code changes substantively. |
| Operations | Quarterly. Also before each mainnet release. |
| Policy | Annually. Also after each external audit. |
| Tracking | Continuously — these are living documents. |

The status field of each document doubles as a freshness gate: if the
"Last reviewed" date is older than the cadence above, the document needs a
re-read.
