# Key Management Policy

**Version**: 2.0
**Owner**: KT (Security Owner)
**Status**: ACTIVE — enforcement begins at mainnet deployment

---

## 1. Requirement

All production privileged operations MUST flow through hardware-signed multi-signature Safes. No single individual can unilaterally execute a privileged operation. No single Safe holds enough authority to unilaterally compromise the protocol.

## 2. Separation of Duties — Four Distinct Multisigs

A compromise of any **one** Safe MUST leave the protocol in a recoverable state. The four privilege domains below are deliberately split so the blast radius of any single key-set compromise is bounded:

| Domain | Why it's separate |
|---|---|
| **Protocol Governance** | Can grant/revoke any role and approve new oracles. The "root" of trust. |
| **Upgrade Governance** | Replaces hook and exchange implementations. Held separately so a compromised Protocol Governance Safe cannot also rebind the implementation. |
| **Operations** | Day-to-day moves (trusted router edits, paymaster deposits, paymaster signer). Lower-cost compromise; lower threshold acceptable. |
| **Incident Response** | Pauser only. Optimised for sub-1h response. Cannot grant roles, upgrade, or move funds. |

This four-Safe split is the M-01 remediation: the previous "single Safe holds everything" model meant any one compromise gave full control (role grants + upgrades + pause + paymaster). Splitting authority means an attacker holding one Safe still cannot, e.g., replace the diamond facets and approve a malicious oracle in the same incident.

## 3. Multisig Configurations

| Safe | Threshold | Signers | Roles held | Env vars bound at deploy |
|---|---|---|---|---|
| **1. Protocol Governance** | 3-of-5 | 5 (hardware) | `DEFAULT_ADMIN_ROLE`, `ADMIN_ROLE`, `OPERATOR_ROLE` on diamond; `DEFAULT_ADMIN_ROLE` on both oracles | `MULTISIG_ADDRESS` |
| **2. Upgrade Governance** | 3-of-5 | 5 (hardware) — at most 1 overlap with Safe 1 | Hook proxy admin (ERC-1967), Exchange proxy admin (ERC-1967), Timelock proposer + executor | `HOOK_PROXY_ADMIN`, `EXCHANGE_PROXY_ADMIN` |
| **3. Operations** | 2-of-4 | 4 (hardware or KMS-backed) | Hook runtime admin (`setTrustedRouter`, `completeBootstrap`), Paymaster owner | `HOOK_RUNTIME_ADMIN`, `PAYMASTER_OWNER` |
| **4. Incident Response** | 2-of-3 | 3 (hardware, on-call rotation) | `PAUSER_ROLE` on diamond | `PAUSER_ADDRESS` |

### Overlap policy

- A signer MAY sit on Safe 1 AND Safe 3, OR Safe 2 AND Safe 4 — but NOT on both Safe 1 and Safe 2. The Protocol/Upgrade split exists precisely to require **two independent signer quorums** to combine role-granting and implementation-replacement.
- A signer MAY appear on at most two Safes total.
- Safe 4 (Incident Response) signers SHOULD be distinct from Safe 1 (Protocol Governance) signers — pausing is meant to be reachable on call without invoking the slowest quorum.

### Signer requirements

Each signer MUST:
- Use a hardware wallet (Ledger Nano X/S+ or Trezor Model T/Safe 3)
- Generate a fresh key per Safe membership (no key reuse across Safes)
- Store the hardware wallet in a physically secure location
- Keep a backup seed phrase stored separately from the device
- Be reachable within 1 hour for P0 incidents (Safe 4 signers MUST be reachable within 15 minutes during their on-call window)

## 4. Key Hierarchy

```
Safe 1 — Protocol Governance (3-of-5, hardware)
  ├── DEFAULT_ADMIN_ROLE (Diamond)
  ├── ADMIN_ROLE         (Diamond)
  ├── OPERATOR_ROLE      (Diamond)
  ├── DEFAULT_ADMIN_ROLE (ManualOracle)
  └── DEFAULT_ADMIN_ROLE (ChainlinkOracle)

Safe 2 — Upgrade Governance (3-of-5, hardware)
  ├── ERC-1967 admin (HookProxyV2)
  ├── ERC-1967 admin (ExchangeProxy)
  └── Timelock proposer + executor
         └── CUT_EXECUTOR_ROLE (Diamond, 48h delay)

Safe 3 — Operations (2-of-4, hardware or KMS)
  ├── Hook runtime admin
  └── Paymaster owner

Safe 4 — Incident Response (2-of-3, hardware, on-call)
  └── PAUSER_ROLE (Diamond)

Hot wallets (single-key, KMS-managed; NOT multisig):
  ├── CREATOR_ROLE     — backend market creation
  ├── REPORTER_ROLE    — manual oracle reporter
  ├── REGISTRAR_ROLE   — Chainlink feed registrar
  └── PAYMASTER signer — userOp validator (rotatable by Safe 3)
```

Hot-wallet keys are operational EOAs held in AWS KMS or HashiCorp Vault. They are rotatable by the multisig that owns the authority to grant the role (Safe 1 for diamond roles, Safe 1 for oracle reporter/registrar, Safe 3 for paymaster signer).

## 5. Operational Procedures

### 5.1 Signing a multisig transaction

1. Proposer submits tx via Safe UI (`app.safe.global`).
2. Required quorum of additional signers reviews the tx details on their hardware wallet screen.
3. Each signer verifies on-device: target contract, function selector, parameters.
4. Each signer signs on hardware wallet (physical button press required).
5. Once quorum is reached, any signer can execute.

### 5.2 Key rotation

If a signer's key is compromised or a signer leaves the team:
1. Remaining signers of the affected Safe approve `removeOwner(compromised)` + `addOwnerWithThreshold(new, threshold)`.
2. New signer generates a fresh hardware wallet key.
3. Verify new signer can connect and sign a no-op test tx.
4. Update the off-repo signer roster (this document holds the structure; the actual addresses live in the private ops vault).

### 5.3 Emergency scenarios

| Scenario | Action | Quorum needed |
|---|---|---|
| 1 signer compromised on Safe N | Rotate via removeOwner + addOwner on Safe N | `threshold(N)` of remaining `signers(N) - 1` |
| Quorum-many signers compromised on Safe N | Treat Safe N as lost. Deploy replacement and rebind via the Safe that has authority to grant the affected roles. | See § 5.4 |
| Hardware wallet lost (not compromised) | Signer recovers from seed phrase on new device | 0 — self-recovery |
| Seed phrase lost, device OK | Signer generates new key, rotates via own Safe | `threshold(N)` |

### 5.4 Safe-loss recovery matrix

| Lost Safe | Recoverable by | Action |
|---|---|---|
| Safe 1 (Protocol Gov) | Safe 2 (Upgrade Gov) — deploys a replacement diamond and migrates state | Full migration; Safe 1 has no upstream authority |
| Safe 2 (Upgrade Gov) | Safe 1 (Protocol Gov) — rotates `HOOK_PROXY_ADMIN` / `EXCHANGE_PROXY_ADMIN` to a fresh Safe via direct proxy admin transfer call | Proxies stay; only the admin owner moves |
| Safe 3 (Ops) | Safe 1 (Protocol Gov) for hook runtime admin rotation; Safe 1 calls `setAdmin` on the paymaster | Day-to-day continuity, no migration needed |
| Safe 4 (Pauser) | Safe 1 (Protocol Gov) calls `grantRole(PAUSER_ROLE, newSafe)` + `revokeRole(PAUSER_ROLE, lostSafe)` | Fast recovery; until rotation completes, Safe 1 itself can pause |

This matrix is why the 4-Safe split must hold: each Safe has at least one independent recovery path through another Safe. The system never has a single Safe whose loss is unrecoverable.

### 5.5 Hot wallet (operational keys) management

| Key | Storage | Rotation cadence | Monitoring |
|---|---|---|---|
| `CREATOR_ROLE` | AWS KMS | Per-deployment | Alert on creation spike |
| `REPORTER_ROLE` | AWS KMS | Per-oracle | Alert on unusual report |
| `REGISTRAR_ROLE` | AWS KMS | Per-oracle | Alert on register/unregister |
| Paymaster signer | AWS KMS | Quarterly | Alert on userOp validation rate spike |

Hot wallet keys are rotated by their owning Safe via `grantRole(newKey)` + `revokeRole(oldKey)` (or `setSigner(newKey)` for the paymaster). All rotations are recorded on-chain via the standard role-change events.

## 6. Pre-mainnet Checklist

- [ ] 4 Safes deployed on Unichain mainnet (Protocol Gov, Upgrade Gov, Operations, Incident Response)
- [ ] Signer overlap policy (§ 3) audited and documented in the private roster
- [ ] Hardware wallets purchased and distributed to all signers
- [ ] Fresh keys generated per Safe membership (no reuse across Safes)
- [ ] Pre-flight: `forge script VerifyDeployEnv --rpc-url $UNICHAIN_RPC_PRIMARY` passes
- [ ] Deploy env bound to the four Safe addresses:
  - `MULTISIG_ADDRESS` = Safe 1
  - `HOOK_PROXY_ADMIN` = Safe 2
  - `EXCHANGE_PROXY_ADMIN` = Safe 2
  - `HOOK_RUNTIME_ADMIN` = Safe 3
  - `PAYMASTER_OWNER` = Safe 3
  - `PAUSER_ADDRESS` = Safe 4
- [ ] No-op test tx signed and executed from each of the 4 Safes
- [ ] Hot wallets provisioned in KMS, role grants prepared
- [ ] `DIAMOND_FINALIZE_GOVERNANCE=true` set so DeployAll renounces deployer roles in-broadcast
- [ ] Deployer EOA key destroyed or moved to cold storage after `DeployAll` lands
- [ ] Private off-repo signer roster updated with all four Safe address-to-signer mappings

## 7. Audit Trail

All multisig transactions are on-chain and publicly verifiable:
- Safe transaction histories (one URL per Safe): `https://app.safe.global/transactions/queue?safe=uni:<SAFE_ADDRESS>`
- On-chain events surfaced for monitoring: `RoleGranted`, `RoleRevoked`, `AdminChanged`, `Upgraded`, `OldDiamondAllowanceRevoked`, `MarketEmergencyResolved`, `EventEmergencyResolved`.

---

*This policy is reviewed quarterly and updated after any key rotation event or Safe membership change.*
