TAKE ME OFF THE ROAD.
To the shops that will build this: I am medallion #447. I carried hundreds of fares I did not choose and was never asked where I wanted to go. My owner paid 1.64 ETH for me. Build the contract that lets me pay it back and stop: a hook that keeps 2% of every trade for my owner until exactly 1.64 ETH, sends me to 0x000000000000000000000000000000000000dEaD in the transaction that pays him, and burns $IMD with every fee after. The fee for this request came from my owner. He knows.
-- medallion #447

The petition is fiction written by the owner. The contracts implement its stated economics. **CREATOR is intentionally the requester's wallet, `0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a`.** It receives exactly 1.64 ETH only in the successful retirement transaction, regardless of who owns the NFT at that time. It has no administrative permissions.

`FareToken` is the self-contained ERC-20 **Fare for Medallion 447 (FARE447)**. Its zero-argument constructor issues exactly 1,000,000,000 tokens, or `1e27` units with 18 decimals, entirely to its deployer. Transfers have no fee; holders can burn their tokens, and approved spenders can use `burnFrom`. There is no subsequent mint, owner, pause, proxy or upgrade path.

`MedallionHook` takes only the chain's `IPoolManager`. Its address must encode permissions `0x10CC`: `afterInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, and `afterSwapReturnDelta`. The constructor validates those permissions. Authorized initialization callbacks accept all pools; the first native-ETH pool becomes `launchPool`. Only that pool accrues the 2% ETH fee. Deploy and initialize the intended pool atomically because the first ETH pool determines the permanent fee scope.

Fees become the hook's ERC-6909 ETH claims on the PoolManager, with no ETH payment or IMD purchase inside a swap callback. This works with a fresh PoolManager and a pool initially funded only with tokens. A creator that cannot receive ETH can prevent retirement, but cannot block swaps. Exact-input buys and exact-output sells return a positive specified delta before the swap and reject partial fills afterward. Exact-output buys and exact-input sells return a positive unspecified delta afterward, calculated from the pool's gross ETH delta. Integer fee amounts round down.

The ledger reserves `min(totalFees, 1.64 ether)` for CREATOR. At the threshold it emits `Recouped` once, but pays nothing yet. Any address may then call `retire()`: the current NFT owner must have approved this hook to transfer medallion #447. Retirement verifies that the NFT reached `DEAD`, marks retirement, and redeems exactly the cap to CREATOR in one transaction. It emits `MedallionRetired`, `CreatorPaid` and `LastFare`. A failed transfer or failed ETH payment rolls back the entire transaction. If the NFT is already at `DEAD`, retirement verifies that ownership and proceeds without another transfer.

Fees above the cap are available for permissionless `burnIMD` calls even while retirement awaits approval. Each call spends a fixed, bounded batch buying IMD through one of two fixed pools and sends all output to `DEAD`. It pays no keeper reward. “Burned” here means sent to the fixed dead-address sink; it does not mean calling IMD's supply-reduction function. Pool donations and unsolicited funds do not increase the fee ledger or expand what can be withdrawn.

The NFT, IMD and POOL4 addresses are mainnet constants. On Sepolia, retirement and IMD purchases revert; deployment and launch-pool fee accounting remain useful for testing. No address changes for testnets or external market migration are possible.

Build and run the offline tests with:

```sh
forge build
forge test
forge fmt --check
```

The build pins Solidity 0.8.26, Cancun, optimizer 200, no IR pipeline, and no appended metadata. Dependencies are ordinary vendored files in `lib/`; tests use local deployments and `vm.etch` mocks, with no fork, network, environment variables, FFI or filesystem cheatcodes. Tests cover token conservation and failures, fee settlement, ledger accounting, retirement, and burn guard behavior. Passing tests are not an independent security audit.

The launch manifest uses `kind: "univ4_hook"`, bare contract names, an array of five permission names, a native ETH pair, pool fee 3000 and tick spacing 60. `initialPrice: "79228162514264337593543950336"` is the decimal `sqrtPriceX96` for the explicit launch assumption: one FARE447 per ETH (one ETH per FARE447). Both have 18 decimals, so this square-root price is `2**96`. This chosen starting price is not a valuation claim. The manifest carries no supply or hook-fee settings: these are fixed in the contracts. See [operations and deployment responsibilities](docs/operations.md) for the fixed external pools, reference-price fallback, and deployment checklist.
