# Security Team

## Security Owner

**KT (SP Labs)** — Protocol Lead & Security Owner

Responsible for:
- Smart contract security review and sign-off on all code changes
- Incident response command (Incident Commander per `docs/INCIDENT_RESPONSE_PLAN.md`)
- Audit firm engagement and remediation oversight
- Access control and key management policy
- Vulnerability triage (reports via `SECURITY.md`)

## Security Practices

- All smart contract changes require security review per `SC/CLAUDE.md §6` (mandatory, non-negotiable)
- SWC Registry checklist verified on every commit
- 16 invariant tests + 22 fuzz tests + 11 attack scenario tests run in CI
- 25+ security findings identified, fixed, and regression-locked across 3+ audit passes
- Formal incident response plan with quarterly drill schedule

## Contact

- Security reports: security@predix.markets
- Emergency: KT directly (see internal contact sheet)
