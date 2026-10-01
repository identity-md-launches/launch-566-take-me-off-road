# Local review record

This records implementation review and offline verification, not a production audit or a mainnet deployment rehearsal.

| Area | Reviewed behavior and evidence |
| --- | --- |
| Permissions | Constructor validates `0x10CC`; every enabled callback checks the immutable PoolManager. Unauthorized callbacks and wrong address bits are tested. |
| Fee deltas | All four swap modes run against an upstream PoolManager. Positive hook deltas offset minted ETH claims; before-swap fee modes reject partial execution. Unspecified fees use actual gross ETH movement. |
| Solvency | Stateful randomized real swaps and claim donations check claims against the ledger. Retirement and burn tests check conservation before and after spending, including failed transactions. |
| Retirement | Low-level ownership reads validate return size and address range. Transfer success alone is insufficient: ownership must become DEAD. Real-manager recipient failure rolls back the NFT, claims and payout state. |
| Unlock access | The transient slot-1 lock covers retirement, burning and anchor maintenance. The unlock callback also requires PoolManager identity and the exact pending operation hash, consumed once. Nested external unlocks and callback reentrancy are tested. |
| Burn destination | Only the two fixed PoolKeys can be selected. Claim redemption settles exactly the ETH input; all IMD goes to DEAD. Real-manager tests assert no outstanding currency deltas and no caller proceeds. |
| Price protection | Oracle results are length/range checked. Tests cover one-sided tolerance boundaries, independent caller minimums, no LP-fee discount, zero and partial fills, cooldown, stale mode and unavailable references. |
| Fallback anchor | Fallback uses the block's saved anchor, moves at most once per block, and stays within the last reference band. Tests include poking before burning, long inactivity, both band limits and normal recovery. |
| Stale recovery revision | Reproduced a live POOL4 lockout after a burn, 50,401 idle blocks and a -1500 tick move: fallback stopped at -1000 and both routes reverted. `pokeAnchor()` now accepts validated open POOL4 data regardless of burn history, records a separate reference block and restores normal mode. It does not change the burn cooldown or depend on the plain pool. Closed/malformed responses and fallback steps cannot refresh this timestamp. |
| First reference | Review reproduced an uninitialized snapshot when the first valid POOL4 reading arrived after deployment. Initial seeding now initializes the block snapshot as well; subsequent updates preserve the existing start-of-block snapshot. Regression tests cover both the price guard and minimum output. |
| Bytecode | PUSH-aware scans of creation and runtime bytecode reject CALLCODE, DELEGATECALL and SELFDESTRUCT. Runtime size remains below EIP-170. The compiler omits CBOR metadata. |
| Manifest | The installed IdentityMD `LaunchManifest` schema accepts the manifest, including `kind: univ4_hook`, bare contract names and the five-name permission array. |

The chosen initial price is `sqrtPriceX96 = 2**96`, meaning parity of raw ETH/FARE447 units; both currencies have 18 decimals. The fixed IMD decimal assumption is also 18. Neither price nor external token behavior is inferred from live RPC data by the offline suite.

Remaining operational dependencies are the correct PoolManager, immutable mainnet addresses, sufficient market liquidity, NFT approval and CREATOR's ability to receive ETH. The deployer must atomically initialize the intended launch pool. An adversary can affect market spot prices within the specified guards; the fallback policy is not an independent price oracle. Voluntary keepers pay gas and receive no reward. The immutable design intentionally provides no administrator or asset-rescue function.

The advisory reproductions confirmed the reference-only floor, the earlier same-block snapshot after a live re-seed, closed-oracle constructor/first-poke asymmetry, first-native-pool binding and unavailable-NFT reserve lock. These are retained as explicit specification choices, with their limits documented in `operations.md` and individual dispositions in `.imd-responses.json`. In particular, a 4% reference-relative output allowance does not cap loss against a higher market price; a fresh re-seed does not replace an existing block's fallback reference; and destroying the NFT does not release the creator reserve.

Foundry's built-in linter reports conservative warnings around narrowing casts, default-initialized locals, low-level interactions and events after external calls. Narrowing values are bounded before conversion; retirement requires the NFT interaction before marking success and uses the transient lock; events follow verified operations and roll back with failures. Tests exercise these failure and reentry paths. Slither, Mythril, live forks and external audits were not performed.
