# Trading Flow & Quoting — PrediX Router

**Audience:** frontend / integration engineers, and anyone reasoning about how a
user's funds move through a trade.
**Scope:** the four router trade primitives, how routing picks the cheapest
venue, the YES-vs-NO differences, and how to estimate the amount a user will
receive (and which price to show in the UI).

---

## 1. Core model

- **One pool only:** a single YES/USDC Uniswap v4 pool per market. There is **no
  NO/USDC pool** — NO is synthesised ("virtual") via the diamond's
  `splitPosition` / `mergePositions`.
- **Router = stateless aggregator:** holds no funds between calls
  (`balanceOf(router) == 0` asserted on every exit). Funds flow through
  atomically in one transaction.
- **Two venues, aggregated:** the on-chain CLOB (resting limit orders) and the
  AMM (the v4 pool). Every trade routes across both: CLOB first (waterfall),
  AMM for the remainder.

---

## 2. User money flow (the four actions)

All four take `minOut` (slippage floor) and `deadline`. If the result is worse
than `minOut`, the tx **reverts** and funds stay in the user's wallet (only gas
lost). Any leftover/dust is auto-refunded.

| Action | Wallet sends | Wallet receives | Mechanism |
|---|---|---|---|
| **BUY_YES** | USDC | YES | Direct swap on pool (CLOB + AMM) |
| **SELL_YES** | YES | USDC | Direct swap (CLOB + AMM) |
| **BUY_NO** | USDC | NO | **Virtual:** flash-sell YES → combine with usdcIn → `splitPosition` mints YES+NO → keep NO, repay YES |
| **SELL_NO** | NO | USDC | **Virtual:** flash-buy YES (exact-out) → `mergePositions` burns YES+NO → USDC → pay cost, keep remainder |

The virtual steps for NO are **invisible to the user** — they just send one token
and receive another. The flash-borrow/split/merge all settle inside the same
transaction.

---

## 3. How routing picks the cheapest venue

**Principle: the AMM price is the benchmark; the CLOB only wins if it beats it.**

1. **Quote the AMM** (V4Quoter, simulate-and-revert) for the *effective* price at
   the actual trade size, fee-included. This becomes the **cap**:
   - BUY: max price willing to pay
   - SELL: min price willing to accept
2. **CLOB fills what beats the cap**, best price first, via a 4-way waterfall:
   - *Direct*: match the opposite resting order
   - *Synthetic*: pair two same-side orders via mint/merge
   At each step it takes the cheaper of direct vs synthetic.
3. **AMM takes the remainder** the CLOB did not fill.

→ Any CLOB order cheaper than the AMM is taken; any order more expensive is
skipped and the AMM is used instead. The user always pays ≤ the AMM price.

### Level-2 convergence (the cap self-tightens)

As the CLOB consumes the cheap orders, the AMM remainder shrinks → the AMM gets
cheaper (less slippage) → the cap should tighten. `_convergeCap` walks the cap
from the spot-sized effective toward the fixed point where the marginal CLOB
order equals the AMM effective for the leftover size — the **optimal CLOB/AMM
split**. This avoids over-taking a CLOB order that is cheaper than full-size-AMM
but more expensive than the now-smaller AMM remainder.

The convergence is **gated**: it runs only when there is a genuine CLOB+AMM
split. Pure-AMM and CLOB-only trades use the Level-1 cap directly (no extra
quotes). It only produces the cap NUMBER; the execution path is unchanged, so it
adds no settlement risk. Bounded by `CLOB_CAP_CONVERGE_ROUNDS = 3`.

**Worked example (buy $100 YES, thin pool):**
- AMM effective for $100 = $0.55/YES. CLOB: $0.40 (50), $0.52 (50), $0.54 (lots).
- Convergence: take $0.40 + $0.52 ($50 spent), remainder $50 → AMM effective at
  $50 = $0.52. The $0.54 order (> $0.52) is excluded; $50 routes to the AMM.
- Result: more YES than naively taking the $0.54 CLOB tail.

---

## 4. YES vs NO — differences

| Aspect | YES (direct) | NO (virtual) |
|---|---|---|
| Pool interaction | trade directly | synthesise via flash + split/merge |
| Quoter calls | 1 (cap) | BUY_NO: 3–7 (Path-D sizing); SELL_NO: ~2 |
| Internal cushion | 0 | 0.5% (absorbs quoter-vs-actual drift) |
| Hidden cost | 0 (only hook dynamic fee) | ~50 bps per leg |
| Gas | 1× (baseline) | ~3× |
| Extra invariant | — | BUY_NO: `proceeds + usdcIn ≥ mintAmount` |

**Why NO costs more:** the single-pool design forces NO to be a two-leg
synthetic (flash swap + split/merge). BUY_NO must solve for `mintAmount`
iteratively (Path D) so the flash proceeds plus the user's USDC exactly fund the
mint. The 0.5% cushion covers V4Quoter simulate-vs-actual precision drift.

**Fairness:** cushion is symmetric (BUY_NO = SELL_NO = 0.5%); NO hidden cost is
~50 bps/leg, YES is 0. This is the theoretical minimum for the single-pool
design. Round-trip NO loss ≈ 1.0%. Gas asymmetry (NO ~3× YES) is inherent and
accepted.

---

## 5. Estimating the amount received

### Method ranking (most accurate → fastest)

1. **Router quote functions (recommended).** Run the *exact* execute code path
   (same cap convergence, CLOB preview, Path D, exact-out):
   ```
   quoteBuyYes(marketId, usdcIn, maxFills)  → (expectedYesOut, clobPortion, ammPortion)
   quoteSellYes(marketId, yesIn, maxFills)  → (expectedUsdcOut, clobPortion, ammPortion)
   quoteBuyNo(marketId, usdcIn, maxFills)   → (expectedNoOut,  clobPortion, ammPortion)
   quoteSellNo(marketId, noIn, maxFills)    → (expectedUsdcOut, clobPortion, ammPortion)
   ```
   - **Not `view`** (they call V4Quoter simulate-and-revert + a transient
     commit), but **callable via `eth_call`** off-chain (viem `readContract`,
     ethers `callStatic`). eth_call simulates without persisting → no gas, no
     real execution.
   - **Practical:** set `from` ≠ `address(0)` in the eth_call (the hook commit
     requires `user != 0`). Returns `(0,0,0)` when the market is
     paused/resolved/expired/not-found → UI detects "not tradeable".
   - `quoteBuyNo` is the heaviest (Path D + convergence) → **debounce** while the
     user types.

2. **Full-tx simulation.** `eth_call` the actual `buyXxx(...)` with state
   overrides (balance + allowance), or Tenderly / Foundry fork. Includes the
   `minOut` check and refunds — exact to the wei. Heavier; rarely needed because
   the quote functions are already faithful.

3. **Indexer (display only).** Ponder indexes orderbook depth + pool state. Use
   for spot price, depth, charts, recent trades, and fast pre-estimates. It lags
   real-time by a few blocks → **not** the final number before signing.

4. **Client-side replication (avoid).** Re-implementing the routing math in TS is
   fragile (drifts when the contract changes). Pre-estimate only.

### Quote ≈ execute, but not identical

Quote runs at block N; execution lands at block N+k. Pool/orderbook state can
move between them, and NO paths carry ~0.5% quoter drift (cushion-absorbed).
**Always set `minOut = expectedOut × (1 − slippageTolerance)` plus a `deadline`.**
The quote is the *estimate*; `minOut` is the *guarantee*.

---

## 6. Which price to display in the UI

Show the **effective (blended average) price** — `amountIn / amountOut` — not the
spot. Spot is the $1-size price and ignores slippage; the quote already returns
the size-aware effective.

| UI element | Source | Example |
|---|---|---|
| Amount received | `expectedOut` | "~230 YES" |
| Average price | `usdcIn / expectedYesOut` | "$0.4348 / YES" |
| Venue breakdown | `clobPortion` / `ammPortion` | "150 from CLOB, 80 from AMM" |
| Price impact | effective vs spot | "+2.1% vs spot $0.4258" |
| Min received | `expectedOut × (1 − tolerance)` | "min 227.7 YES (1%)" |
| Fees | already baked into effective (hook fee + 0.5% NO cushion) | optional, for transparency |

### Recommended UI flow

```
user types amount
  → debounce ~300ms
  → eth_call quoteXxx(...) at latest block
  → show expectedOut, avg price, breakdown, impact, minOut
  → on submit: buyXxx(..., minOut, deadline)
```

Use the quote function for the primary number, the indexer for auxiliary display,
and always attach `minOut` + `deadline`.

---

## 7. Quick reference

| Need | Use |
|---|---|
| Accurate pre-trade amount | `quoteXxx` via `eth_call` (latest block) |
| Absolute verification | full-tx `eth_call` / Tenderly |
| Charts, depth, history, fast preview | indexer |
| UI price | effective = `amountIn / expectedOut` (never spot) |
| Execution guarantee | `minOut` + `deadline` |
