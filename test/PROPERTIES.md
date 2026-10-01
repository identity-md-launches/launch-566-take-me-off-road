# Additional adversarial properties

These tests run offline with the vendored dependencies. They do not fork a network or change environment variables. Fixed mainnet addresses are populated with `vm.etch` fixtures.

| Suite | Properties checked |
| --- | --- |
| `FareTokenProperties.t.sol` | Four actors' balances and allowances match an independent action model. Every initial token is either held or burned. Failed spending preserves balances, supply and approval; transfers and burns share the same allowance budget. |
| `MedallionLifecycleInvariant.t.sol` | Random real PoolManager swaps, donations, retirement attempts, burns, anchor pokes and rejected calls conserve ETH claims. Creator payment occurs exactly once with NFT retirement; the sink receives all IMD output; every unlock settles all currency deltas. |
| `BurnGuards.t.sol` | Oracle selectors require canonical ABI words. Availability and budget checks precede pool reads. Failed fills and slippage roll back anchor changes. Block-start references and independently calculated quote boundaries constrain burns. |
| `RetirementSecurity.t.sol` | Malformed NFT responses and transfer/payment failures roll back retirement. Cross-entry reentrancy fails. Unlock requests cannot be skipped, altered or replayed to authorize payment. |
| `Pool4Route.t.sol` | The POOL4 route on a real PoolManager: a v4-callable stand-in is etched at `POOL4_HOOK` (its address carries flags 0x2840, so the manager drives beforeInitialize, beforeAddLiquidity and afterSwap) and the fixed (ETH, IMD, 10000, 60, POOL4_HOOK) pool is initialized and funded. Burns settle through the exact key, the POOL4 hook's own revert aborts a burn atomically, an uninitialized burn pool fails before any unlock, closed and malformed oracles leave only the plain fallback. Real price moves on both IMD pools exercise the one-sided guard at 150 and 300 ticks, the once-per-block 200-tick fallback step and its 1000-tick band, the stale-then-poke recovery, and the slippage floor against thin liquidity and caller minimums. |
| `BurnReferenceInvariant.t.sol` | Random sequences on a real PoolManager with both fixed IMD pools: fee accrual, price moves on either pool, five oracle states (open, closed, reverting views, short return words, open but refusing swaps), block gaps including 50,401 idle blocks, burns through both routes with and without an unreachable caller minimum, and pokes. A ghost model of spec section 7 predicts for every burn which guard refuses it (TooSoon, Pool4Unavailable, NothingToBurn, PriceOffReference) or that it reaches the swap; a swap that fails must fail only with Slippage or the POOL4 hook's wrapped revert. After every call the hook's anchor, last reference, anchor block, start-of-block anchor, reference block, burn block and ledger equal the model, so every rollback is checked too. The anchor never leaves lastRef ± FALLBACK_BAND and never steps more than ANCHOR_STEP. |

Both lifecycle-style invariant campaigns use 256 sequences of 64 actions with unexpected handler reverts treated as failures; the reference campaign uses 160 sequences of 48 actions. Expected failures are checked explicitly. The lifecycle suite also includes a deterministic sequence that reaches successful burns before retirement, successful retirement, a stale fallback burn, a live poke that restores the normal batch, and failed operations followed by retries. The reference suite's deterministic witness reaches every outcome its model distinguishes.

The lifecycle handler's freshness model measures staleness from the later of the last burn and the last live POOL4 seed (constructor, normal-mode burn, or a poke while the market is open), matching the accepted stale-recovery revision in `docs/security-review.md`. An earlier version measured it from the last burn only, which the campaign eventually falsified with the sequence burn, 50,401 idle blocks, poke, burn.

The lifecycle fee model uses raw PoolManager swap events and checks the fee against the router's settled ETH delta. Burn output is checked against both the raw pool output and the sink's actual token balance. Donations are tracked separately and cannot increase either fee entitlement or burn budget.

The real-manager campaign exercises the fixed plain IMD pool with deep liquidity. The focused mock suites cover adversarial oracle/NFT behavior, both fixed burn routes, and callback transport faults. They do not establish the availability or behavior of deployed mainnet dependencies.

Run all checks without writing build artifacts outside the test tree:

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```
