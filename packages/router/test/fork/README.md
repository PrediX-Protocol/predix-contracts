# router/test/fork

## Status: SKIPPED on Unichain Sepolia

The router constructor takes `IV4Quoter` as a required immutable (reverts
`ZeroAddress` on `address(0)`). The canonical Uniswap v4 `V4Quoter`
deployment could not be confirmed for Unichain Sepolia (chain id 1301) at
research time, so the E2E fork test ships as a placeholder
(`RouterE2EForkTest.t.sol.requires-v4-quoter`) that forge ignores at compile
time.

Once a confirmed V4Quoter address is available:

1. Add `V4_QUOTER_ADDRESS=0x...` to your local `.env`.
2. Rename the placeholder to `RouterE2EForkTest.t.sol`.
3. Fill in the deployment stack per the checklist inside the placeholder.

## Why not a partial test

Deploying a local `MockV4Quoter` inside the fork would produce "mock on top
of real chain" coverage that is strictly worse than the existing unit suite
(which already uses `MockV4Quoter` and `MockPoolManager`). The point of a
fork test is to catch gaps between mocks and real contracts; a test that
still uses one mock cannot catch a gap in the other.

The Permit2 end-to-end flow (canonical address + allowance lifecycle)
already lives in `packages/shared/test/fork/Permit2IntegrationForkTest.t.sol`
and does not need a router-specific copy to validate Permit2 itself.

## Required env (once enabled)

```
UNICHAIN_RPC_PRIMARY=https://...
USDC_ADDRESS=...
POOL_MANAGER_ADDRESS=...
V4_QUOTER_ADDRESS=...
PERMIT2_ADDRESS=0x000000000022D473030F116dDEE9F6B43aC78BA3
```
