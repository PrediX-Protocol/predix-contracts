# oracle/test/fork

## Status: SKIPPED on Unichain Sepolia

Oracle fork testing requires live Chainlink price feeds. As of the date of
this directory's creation, Chainlink has not deployed feeds on Unichain
Sepolia (chain id 1301), so `ChainlinkOracleForkTest.t.sol` is intentionally
shipped with the suffix `.no-chainlink-on-sepolia` — forge ignores it at
compile time.

`ManualOracle` has no external-chain dependency (it only interacts with a
`IMarketFacet`-compatible contract passed at construction), so it is fully
covered by unit tests in `test/unit/ManualOracle.t.sol`. No fork test is
needed for that adapter.

## Re-enabling the Chainlink fork test

1. Verify a real feed exists on the target chain (see the checklist inside
   the placeholder file).
2. Rename the placeholder to `ChainlinkOracleForkTest.t.sol`.
3. Add `CHAINLINK_FEED_ADDRESS=` to `.env.example` and populate in your
   local `.env`.
4. Run `cd packages/oracle && forge test --match-path 'test/fork/*'`.

The unit test at `test/unit/ChainlinkOracle.t.sol` stays the primary source
of coverage regardless.
