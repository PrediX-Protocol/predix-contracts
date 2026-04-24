# PrediX V2 SC — Spec vs Code matrix

**Purpose**: pre-audit source-of-truth matrix mapping each spec section to
its implementing code. When spec and code drift, this matrix records which
side is authoritative and when the drift was reconciled.

**Audience**: external audit firm + internal engineering. Read alongside
`GITBOOK/vi_v4/design-docs/` (design spec) and `packages/*/` (implementation).

**Convention**:
- Status `✅ aligned` — spec matches current implementation at given commit.
- Status `⚠️ drift` — spec says X, code does Y; row notes which is authoritative and remediation.
- Status `⏭ deferred` — gap is known, remediation scheduled post-launch.

Rows are appended as Bundle A items ship. Existing rows are updated (not
rewritten) when later changes affect the same symbol.

---

## 1 · Hook package

| ID | Symbol | Spec source | Code location | Status | Notes |
|---|---|---|---|---|---|
| SPEC-01 | `PrediXHookV2.getHookPermissions` | `GITBOOK/vi_v4/design-docs/01-smart-contract-spec.md §5.1` | `packages/hook/src/hooks/PrediXHookV2.sol:419` | ✅ aligned (2026-04-24) | Code enables 6 callbacks (beforeInit, beforeAddLiq, beforeRemoveLiq, beforeSwap, afterSwap, beforeDonate). Earlier spec draft listed only 4 — spec updated to match code on 2026-04-24. PoolManager authoritative on salt-mined flag bits: hook address must carry the correct flag bits or `initialize` reverts. Defense-in-depth: `beforeAddLiquidity` blocks JIT liquidity into resolved / refunded / expired markets, `beforeRemoveLiquidity` tracks pool registration (LP exit is never blocked), `beforeDonate` blocks donate after `endTime` / resolved / refund to prevent sneak-in value transfers. |

## 2 · Diamond package

(rows appended per Bundle A items)

## 3 · Exchange package

(rows appended per Bundle A items)

## 4 · Router package

(rows appended per Bundle A items)

## 5 · Oracle package

(rows appended per Bundle A items)

## 6 · Paymaster package

(rows appended per Bundle A items)

---

## Changelog

- **2026-04-24** — Initial matrix seeded with SPEC-01 (hook permissions). File created as part of Bundle A §S1.
