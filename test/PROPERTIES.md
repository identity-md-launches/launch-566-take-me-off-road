# Additional adversarial properties

These tests run offline with the vendored dependencies. They do not fork a network or change environment variables. Fixed mainnet addresses are populated with `vm.etch` fixtures.

| Suite | Properties checked |
| --- | --- |
| `FareTokenProperties.t.sol` | Four actors' balances and allowances match an independent action model. Every initial token is either held or burned. Failed spending preserves balances, supply and approval; transfers and burns share the same allowance budget. |
| `MedallionLifecycleInvariant.t.sol` | Random real PoolManager swaps, donations, retirement attempts, burns, anchor pokes and rejected calls conserve ETH claims. Creator payment occurs exactly once with NFT retirement; the sink receives all IMD output; every unlock settles all currency deltas. |
| `BurnGuards.t.sol` | Oracle selectors require canonical ABI words. Availability and budget checks precede pool reads. Failed fills and slippage roll back anchor changes. Block-start references and independently calculated quote boundaries constrain burns. |
| `RetirementSecurity.t.sol` | Malformed NFT responses and transfer/payment failures roll back retirement. Cross-entry reentrancy fails. Unlock requests cannot be skipped, altered or replayed to authorize payment. |

Both new invariant campaigns use 256 sequences of 64 actions with unexpected handler reverts treated as failures. Expected failures are checked explicitly. The lifecycle suite also includes a deterministic sequence that reaches successful burns before retirement, successful retirement, a stale fallback burn, and failed operations followed by retries.

The lifecycle fee model uses raw PoolManager swap events and checks the fee against the router's settled ETH delta. Burn output is checked against both the raw pool output and the sink's actual token balance. Donations are tracked separately and cannot increase either fee entitlement or burn budget.

The real-manager campaign exercises the fixed plain IMD pool with deep liquidity. The focused mock suites cover adversarial oracle/NFT behavior, both fixed burn routes, and callback transport faults. They do not establish the availability or behavior of deployed mainnet dependencies.

Run all checks without writing build artifacts outside the test tree:

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```
