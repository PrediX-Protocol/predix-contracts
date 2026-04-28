# Key Management Policy

**Version**: 1.0
**Owner**: KT (Security Owner)
**Status**: ACTIVE — enforcement begins at mainnet deployment

---

## 1. Requirement

All production systems MUST use hardware security keys and multi-signature controls. No single individual can unilaterally execute privileged operations.

## 2. Multisig Configuration

| Parameter | Value |
|---|---|
| **Wallet** | Safe (formerly Gnosis Safe) |
| **Threshold** | 3-of-5 |
| **Chain** | Unichain (chainId 130) |
| **Signers** | 5 individuals with hardware wallets |

### Signer requirements

Each signer MUST:
- Use a hardware wallet (Ledger Nano X/S+ or Trezor Model T/Safe 3)
- Generate a FRESH key specifically for this multisig (not reuse existing keys)
- Store the hardware wallet in a physically secure location
- Have a backup seed phrase stored separately from the device (e.g., bank safe deposit box)
- Be reachable within 1 hour for P0 incidents

### Signer composition (recommended)

| Slot | Role | Location | Notes |
|---|---|---|---|
| 1 | Protocol Lead (KT) | Primary | Always available |
| 2 | Senior Engineer | Primary | Technical operations |
| 3 | Operations Lead | Primary | Day-to-day management |
| 4 | External Advisor | Advisory | Independent oversight |
| 5 | Legal/Compliance | Advisory | Regulatory awareness |

Geographic distribution: at least 2 signers in different timezones to ensure 24h coverage.

## 3. Key Hierarchy

```
Hardware Wallet (Ledger/Trezor)
  └── EOA key
        └── Safe 3-of-5 Multisig
              ├── Holds: DEFAULT_ADMIN_ROLE (Diamond)
              ├── Holds: ADMIN_ROLE (Diamond)
              ├── Holds: OPERATOR_ROLE (Diamond)
              ├── Holds: Hook admin
              ├── Holds: Hook proxy admin
              ├── Holds: Exchange proxy admin
              ├── Holds: Oracle admin
              ├── Holds: Paymaster owner
              └── Executor OF: TimelockController
                    └── Holds: CUT_EXECUTOR_ROLE (48h delay)

Separate hot wallets (KMS-managed, NOT hardware):
  ├── PAUSER_ROLE — fast incident response
  ├── CREATOR_ROLE — backend market creation
  ├── REPORTER_ROLE — manual oracle reporter
  └── REGISTRAR_ROLE — Chainlink feed registrar
```

## 4. Operational Procedures

### 4.1 Signing a multisig transaction

1. Proposer submits tx via Safe UI (app.safe.global)
2. 2 additional signers review the tx details on their hardware wallet screen
3. Each signer verifies: target contract, function selector, parameters
4. Each signer signs on hardware wallet (physical button press required)
5. Once 3/5 signed, any signer can execute

### 4.2 Key rotation

If a signer's key is compromised or a signer leaves the team:
1. Remaining 3 signers approve `removeOwner(compromised)` + `addOwnerWithThreshold(new, 3)`
2. New signer generates fresh hardware wallet key
3. Verify new signer can connect and sign test tx
4. Update this document with new signer roster

### 4.3 Emergency scenarios

| Scenario | Action | Min signers needed |
|---|---|---|
| 1 signer compromised | Rotate via removeOwner + addOwner | 3 of remaining 4 |
| 2 signers compromised | Rotate both in 1 batch tx | 3 of remaining 3 |
| 3+ signers compromised | Multisig lost. Deploy new Safe + new diamond. | N/A — recovery mode |
| Hardware wallet lost (not compromised) | Signer recovers from seed phrase on new device | 0 (self-recovery) |
| Seed phrase lost + device OK | Generate new key, rotate via multisig | 3 |

### 4.4 Hot wallet (operational keys) management

| Key | Storage | Rotation | Monitoring |
|---|---|---|---|
| PAUSER | AWS KMS or HashiCorp Vault | Quarterly | Alert on any pause event |
| CREATOR | AWS KMS | Per-deployment | Alert on creation spike |
| REPORTER | AWS KMS | Per-oracle | Alert on unusual report |
| REGISTRAR | AWS KMS | Per-oracle | Alert on register/unregister |

Hot wallet keys are rotated by the multisig via `grantRole(newKey)` + `revokeRole(oldKey)`.

## 5. Pre-mainnet Checklist

- [ ] 5 signers identified and confirmed
- [ ] 5 hardware wallets purchased and distributed
- [ ] 5 fresh keys generated (1 per signer)
- [ ] Safe deployed on Unichain mainnet (3-of-5 threshold)
- [ ] Test transaction signed and executed successfully
- [ ] Hot wallets provisioned in KMS
- [ ] All roles transferred from deployer EOA to multisig (per `DeployAll.s.sol`)
- [ ] Deployer EOA key destroyed or moved to cold storage
- [ ] This document updated with signer roster (PRIVATE — not in repo)

## 6. Audit Trail

All multisig transactions are on-chain and publicly verifiable:
- Safe transaction history: `https://app.safe.global/transactions/queue?safe=uni:<SAFE_ADDRESS>`
- On-chain events: `RoleGranted`, `RoleRevoked`, `AdminChanged`, `Upgraded`, etc.

---

*This policy is reviewed quarterly and updated after any key rotation event.*
