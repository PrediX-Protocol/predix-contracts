# Safe Deployment Runbook

**Audience:** operators, security
**Status:** Active
**Owner:** KT (Security Owner)
**Last reviewed:** 2026-05-20

This runbook is the step-by-step procedure for the four-Safe key ceremony required by [`KEY_MANAGEMENT_POLICY.md`](KEY_MANAGEMENT_POLICY.md) v2.0. Complete this runbook before binding production `.env` addresses to the deploy scripts.

The runbook splits into three phases. Each phase has a hard time gate — do **not** start Phase B until Phase A is fully closed.

---

## Overview

| Phase | Window | Outcome |
|---|---|---|
| A — Preparation | T-2 weeks | Signers identified, hardware kits delivered, Safe contracts verified on Unichain |
| B — Key generation | T-1 week | Every signer holds a verified hardware wallet with backed-up seed |
| C — Ceremony | T-3 days | 4 Safes deployed, owners + thresholds confirmed on-chain, no-op test transactions executed |

Four Safes per `KEY_MANAGEMENT_POLICY.md` § 3:

| Safe | Threshold | Signer count | Key type |
|---|---|---|---|
| 1. Protocol Governance | 3-of-5 | 5 | Hardware only |
| 2. Upgrade Governance | 3-of-5 | 5 (no signer overlap with Safe 1) | Hardware only |
| 3. Operations | 2-of-4 | 4 | Hardware or KMS-backed |
| 4. Incident Response | 2-of-3 | 3 | Hardware, on-call rotation |

Total: 17 signer slots. Overlap policy (max 2 Safes per person, Safe 1 ↔ Safe 2 strictly disjoint) requires at least 9–10 distinct individuals.

---

## Phase A — Preparation (T-2 weeks)

### A1. Signer roster

- [ ] Identify 9–10 individuals. Per person record: legal name, contact (Signal/phone), timezone, primary location.
- [ ] Confirm timezone coverage:
      - At least 2 signers each on Safe 1 and Safe 2 in distinct timezones (24h Upgrade Governance coverage).
      - Safe 4 (Pauser) signers span Asia + Europe + Americas so each 8h on-call window has a primary in awake hours.
- [ ] Confirm overlap policy:
      - No individual on both Safe 1 and Safe 2 (hard rule — single key compromise must not grant both role-management and impl-replacement authority).
      - Maximum 2 Safe memberships per individual.
- [ ] Capture the full mapping in the private off-repo roster (vault entry with controlled access — security team only).

### A2. Hardware wallet procurement

- [ ] Order one of: Ledger Nano X / S Plus or Trezor Model T / Safe 3. No software wallets, no mobile hot wallets.
- [ ] Order one device per signer per Safe membership. If a signer sits on two Safes, that signer gets two distinct devices. No key reuse across Safes.
- [ ] Order directly from the vendor (`ledger.com`, `trezor.io`). Do not buy via Amazon / third-party sellers — supply-chain tamper risk is well-documented for hardware wallets sold via resellers.
- [ ] Inspect packaging seal on receipt. If the seal shows any tamper sign — perforation, restickering, mismatched holographic — refuse the unit and request replacement.

### A3. Hardware kit per signer

Each signer receives:

- [ ] Hardware wallet, factory-sealed, firmware verified by Ledger Live / Trezor Suite after first boot.
- [ ] Metal seed backup card (Cryptosteel, Billfodl, or equivalent). Paper backups are not acceptable.
- [ ] Faraday bag for device transport / storage when not actively signing.
- [ ] Dedicated signing laptop. Requirements:
      - Fresh OS install (macOS or Ubuntu) within the last 30 days.
      - Disk encryption enabled (FileVault / LUKS).
      - Only the following software installed: browser (Brave or Firefox), Ledger Live / Trezor Suite, Safe-cli (optional), the team password manager, and `forge` / `cast` (for deploy verification).
      - No other crypto wallets, no Telegram, no Discord, no DeFi browsing. This laptop is single-purpose.

### A4. Safe contract verification on Unichain mainnet

Before running the ceremony, confirm Safe contracts are deployed on chainId 130 at the canonical addresses:

```bash
# Safe singleton v1.4.1
cast code 0x41675C099F32341bf84BFc5382aF534df5C7461a \
  --rpc-url $UNICHAIN_RPC_PRIMARY | head -c 30

# SafeProxyFactory
cast code 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67 \
  --rpc-url $UNICHAIN_RPC_PRIMARY | head -c 30

# MultiSendCallOnly
cast code 0x9641d764fc13c8B624c04430C7356C1C7C8102e2 \
  --rpc-url $UNICHAIN_RPC_PRIMARY | head -c 30

# CompatibilityFallbackHandler
cast code 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99 \
  --rpc-url $UNICHAIN_RPC_PRIMARY | head -c 30
```

Each MUST return non-empty bytecode. If any returns `0x`, escalate to the Safe team (`safe.global/contact`) or self-deploy the missing contracts before proceeding.

- [ ] Confirm `app.safe.global` lists Unichain mainnet in its chain selector. If not, plan to use the self-hosted IPFS-pinned Safe UI or `safe-cli` directly.

### Phase A exit gate

All checkboxes above must be ticked before starting Phase B. If any item is incomplete, do not proceed.

---

## Phase B — Key generation (T-1 week)

### B1. Per-signer key generation procedure

Run this procedure for each device, with the signer physically present:

- [ ] **Factory reset.** Even on a brand-new device, run Settings → Reset device first. This invalidates any pre-loaded seed from the supply chain.
- [ ] **Generate fresh seed.** Choose "Set up as new device" → "Generate 24-word recovery seed". Do **not** choose "Restore from existing seed".
- [ ] **Write the seed to the metal card.** 24 words, written by hand, no phone camera in the room. Verify each word by pressing it back on the device.
- [ ] **Verify the seed.** Device walks through the verify-seed flow. Confirm every word matches the metal card.
- [ ] **Two-location storage.** Store the metal card in two physically separate secure locations (e.g., one in a bank safe deposit box, one in a fireproof safe at a residence). The two locations must not share a single point of failure (same building, same building's vault, etc.).
- [ ] **Set device PIN.** 8+ digits, not a birthday or phone number, not the same PIN used for other devices.
- [ ] **Test recovery.** Factory-reset the device. Restore from the metal-card seed. Confirm the same address appears as before. Repeat once more to confirm the seed is recorded correctly. Factory-reset again and set a fresh PIN — this leaves no PIN imprint in muscle memory of the people present.
- [ ] **Connect to ceremony laptop.** Open Ledger Live / Trezor Suite. Confirm the address shown on the laptop matches the address shown on the device screen. **The on-device screen is the source of truth.**
- [ ] **Record the address** in the off-repo private roster, with the signer's name and Safe assignment.

### B2. Cross-verification

For each address recorded in B1:

- [ ] The signer reads the address aloud from the device screen.
- [ ] Two other team members independently verify the address against the roster entry.
- [ ] All three sign off in writing.

This blocks the Bybit / Radiant class attack where a compromised laptop displays a different address than the device shows. The hardware screen is trusted; the laptop is not.

### Phase B exit gate

- [ ] All 17 signer slots have a verified address recorded.
- [ ] All metal-card seeds are stored in two distinct physical locations.
- [ ] No two Safes share an owner where the policy forbids it (Safe 1 ↔ Safe 2 disjoint, no individual on more than 2 Safes).

---

## Phase C — Safe deployment ceremony (T-3 days)

### C1. Location and observer setup

- [ ] Dedicated room, soundproofed if possible.
- [ ] All personal phones outside the room or in a Faraday bag.
- [ ] Ceremony laptop on wired Ethernet (no public Wi-Fi, no VPN).
- [ ] Two independent observers present, not part of the on-call rotation (legal / compliance, external advisor, or similar). Observers document the timeline and sign off on each step.

### C2. Deploy each Safe

Run this loop four times, once per Safe. Order: Safe 1 → Safe 2 → Safe 3 → Safe 4.

For Safe N:

- [ ] Open `app.safe.global` (or the self-hosted IPFS build).
- [ ] Connect the ceremony wallet (one of the N signers' hardware devices) to pay gas.
- [ ] Click "New Safe" → select **Unichain mainnet** (chainId 130).
- [ ] Add the N owners. Paste each address from the roster. Each signer present verifies that the address shown on their own device matches the address being added.
- [ ] Set the threshold per the policy (3 for Safe 1, Safe 2; 2 for Safe 3, Safe 4).
- [ ] Click Deploy. The gas-paying signer confirms the transaction on their hardware screen, verifies the transaction data byte-by-byte, then signs.
- [ ] Once mined, record the deployed Safe address in the roster.
- [ ] Open Unichain block explorer for the deploy transaction. Confirm:
      - `setup()` parameters match expected owners + threshold.
      - Fallback handler is `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99`.
      - Singleton master copy is `0x41675C099F32341bf84BFc5382aF534df5C7461a` (Safe v1.4.1).
- [ ] Read back owners + threshold via `cast call`:
      ```bash
      cast call $SAFE_ADDRESS "getOwners()(address[])" --rpc-url $UNICHAIN_RPC_PRIMARY
      cast call $SAFE_ADDRESS "getThreshold()(uint256)" --rpc-url $UNICHAIN_RPC_PRIMARY
      ```
      The result must match the roster.

### C3. No-op test transaction per Safe

Once a Safe is deployed, before binding it to production env:

- [ ] Send 0.001 ETH to the Safe address (gas reserve).
- [ ] Propose a no-op transaction: send 0 ETH from the Safe back to itself.
- [ ] Collect quorum signatures:
      - Safe 1, Safe 2: 3 distinct signers each sign on their hardware device, verifying the tx hash on-device matches the one shown in the UI.
      - Safe 3: 2 distinct signers.
      - Safe 4: 2 distinct signers.
- [ ] Execute the transaction.
- [ ] Verify the on-chain receipt via block explorer.

This proves the Safe can move funds with the expected quorum and the signing UX works end-to-end.

### C4. Cross-Safe disjoint check

- [ ] Run for each pair (Safe i, Safe j) where i ≠ j:
      ```bash
      diff <(cast call $SAFE_I "getOwners()(address[])" --rpc-url $UNICHAIN_RPC_PRIMARY | tr ',' '\n' | sort) \
           <(cast call $SAFE_J "getOwners()(address[])" --rpc-url $UNICHAIN_RPC_PRIMARY | tr ',' '\n' | sort)
      ```
- [ ] Safe 1 vs Safe 2: there MUST be zero overlap. Any shared owner is a policy violation; abort and rotate the duplicated owner on one of the two Safes.
- [ ] Other pairs: overlap permitted up to the policy's 2-Safe-per-individual cap.

### C5. Independent verification (post-ceremony, T-2 days)

A team member who was **not** present at the ceremony performs:

- [ ] Block explorer audit of each Safe deploy transaction. Confirm owners, threshold, fallback handler, singleton.
- [ ] Re-runs the `cast call getOwners() / getThreshold()` checks.
- [ ] Confirms the no-op test transaction succeeded for each Safe.
- [ ] Confirms the off-repo roster matches the on-chain owner list.
- [ ] Signs off in writing. This signature gates Phase C exit.

### C6. Bind to deploy env

Once all checks in C5 pass:

- [ ] Update `.env` (production) with the four Safe addresses:
      ```bash
      MULTISIG_ADDRESS=0x<safe1_address>
      HOOK_PROXY_ADMIN=0x<safe2_address>
      EXCHANGE_PROXY_ADMIN=0x<safe2_address>
      HOOK_RUNTIME_ADMIN=0x<safe3_address>
      PAYMASTER_OWNER=0x<safe3_address>
      PAUSER_ADDRESS=0x<safe4_address>
      ```
- [ ] Run the env pre-flight:
      ```bash
      forge script VerifyDeployEnv --rpc-url $UNICHAIN_RPC_PRIMARY
      ```
      Expected output: `VerifyDeployEnv: OK`. A revert here means canonical Permit2 or sequencer feed env entries drifted; do not deploy until clean.
- [ ] Commit the env file to the operator's vault (not the repo). The repo retains only `.env.example` and `.env.beta.example`.

### Phase C exit gate

- [ ] All four Safes deployed and verified on-chain.
- [ ] No-op test transactions executed for all four Safes.
- [ ] Disjoint owner check passed for Safe 1 ↔ Safe 2.
- [ ] Independent verifier sign-off recorded.
- [ ] `.env` updated and `VerifyDeployEnv` passes.

---

## Post-deployment maintenance

### Quarterly review

- [ ] Confirm all 17 signers are still active in their roles.
- [ ] Confirm hardware wallets are physically accounted for.
- [ ] Confirm all seed backups remain in their two storage locations.
- [ ] Re-run no-op test transactions on Safe 4 (most active for incident response).

### Signer rotation procedure

When a signer leaves or a key is compromised:

- [ ] Remaining signers on the affected Safe propose `swapOwner(prevOwner, oldOwner, newOwner)` (or `removeOwner` + `addOwner` if changing threshold).
- [ ] The new signer follows Phase B to generate a fresh hardware wallet and seed.
- [ ] Cross-verify the new address per B2.
- [ ] Existing quorum signs the swap transaction.
- [ ] No-op test transaction with the new signer participating.
- [ ] Update the off-repo roster.

The `KEY_MANAGEMENT_POLICY.md` § 5.2 covers rotation policy; this runbook covers the mechanical execution.

### Safe loss recovery

See `KEY_MANAGEMENT_POLICY.md` § 5.4 for the recovery matrix — each Safe has at least one independent recovery path through another Safe. The system has no single Safe whose loss is unrecoverable.

---

## Reference

- `docs/KEY_MANAGEMENT_POLICY.md` — policy and four-Safe structure
- `docs/MAINNET_DEPLOY_REHEARSAL.md` — full T-48h deploy checklist this runbook feeds into
- `docs/PAUSER_ONCALL_PLAYBOOK.md` — Safe 4 on-call rotation and incident response
- Safe canonical addresses: <https://docs.safe.global/advanced/smart-account-supported-networks>
- Hardware wallet supply chain guidance: <https://support.ledger.com/article/360011239759-zd>
