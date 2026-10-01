# Deployment and operation

## Fixed deployment parameters

Deploy `src/FareToken.sol:FareToken` without constructor arguments. Deploy `src/MedallionHook.sol:MedallionHook` with only the intended chain's PoolManager, supplied through the manifest's literal `$poolManager` placeholder. Neither contract creates an owner or administrator. The immutable contract logic has no setters, pause, sweep or upgrade facility.

Mine a CREATE2 salt using the exact hook creation bytecode, deployer and encoded manager argument so that `uint160(hook) & 0x3fff == 0x10cc`. Changing the PoolManager or bytecode changes the predicted address and requires mining again. The five enabled permissions are `afterInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, and `afterSwapReturnDelta`; `beforeInitialize` is disabled. The constructor validates the address bits. All enabled callbacks accept only the configured PoolManager.

Deploy and initialize the intended native-ETH/FARE447 pool in one transaction. The first native-ETH pool initialized through this hook permanently becomes the fee-bearing launch pool; ERC-20/ERC-20 initialization does not select it, and later pools remain fee-free. The manifest specifies fee 3000, tick spacing 60, and an initial 1:1 price (`sqrtPriceX96 = 79228162514264337593543950336`). Initial liquidity size and distribution belong to the deploying launch process and are not contract settings.

Solidity settings are 0.8.26, Cancun EVM, optimizer enabled with 200 runs, `via_ir = false`, `bytecode_hash = "none"`, and `cbor_metadata = false`. Ethereum Cancun transient storage is required. The transient reentrancy guard uses literal slot 1. Build dependencies are vendored as ordinary files; no dependency fetch is required for the verifier.

## Addresses and disclosed beneficiary

CREATOR is **intentionally the requester's wallet**, `0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a`. The owner funded the request and authored the fictional petition. CREATOR is a fixed beneficiary, not a role, and the hook never derives a beneficiary from the caller or NFT ownership. If the NFT changes hands, the beneficiary remains CREATOR.

| Constant | Value |
| --- | --- |
| MEDALLION_NFT | `0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03` |
| MEDALLION_ID | `447` |
| DEAD / IMD_SINK | `0x000000000000000000000000000000000000dEaD` |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| POOL4_HOOK | `0xc6C965Bd164c483e87d0B550671798e9A3602840` |

The two burn routes are fixed PoolKeys with currency0 native ETH and currency1 IMD:

| Route | LP fee | Tick spacing | Hook |
| --- | --- | --- | --- |
| POOL4 | `10000` | `60` | `POOL4_HOOK` |
| Plain | `10000` | `200` | Zero address |

These external contracts and markets exist only on mainnet. The constants are preserved on every chain; `retire()` and `burnIMD()` revert on Sepolia. Local tests replace mainnet dependencies with mocks; they do not establish current mainnet balances, liquidity, NFT ownership or approval. The deployer must verify these operational facts separately before launch. No transaction is broadcast by this project.

## Fees and accounting

Both buy and sell hook fees are 200 basis points, entirely in ETH. CREATOR_SHARE_BPS is 10000, with a total cap of 1.64 ETH. The pool's ordinary LP fee remains separate.

| Trade | Hook accounting |
| --- | --- |
| Exact-input buy | Before swap, claim 2% of specified ETH input; require full remaining input execution |
| Exact-output sell | Before swap, claim 2% of requested ETH output; require requested output plus fee from pool |
| Exact-output buy | After swap, claim 2% of pool's gross ETH input |
| Exact-input sell | After swap, claim 2% of pool's gross ETH output |

The before-swap modes enforce raw pool ETH delta equal to `amountSpecified + fee`; price-limit partial execution reverts. Fee calculations round down to wei. Swaps only accrue `totalFees`, minting PoolManager claims rather than making ETH transfers or calling external NFT/market contracts.

The ledger is:

```text
creatorEntitlement = min(totalFees, CREATOR_CAP)
burnable = totalFees - creatorEntitlement - burnSpent
PoolManager.balanceOf(hook, 0) >= totalFees - creatorPaid - burnSpent
creatorPaid is either 0 or CREATOR_CAP
```

Donated claims or forced ETH do not count as fees; there is no donation recovery or sweep function. A swap can cross the cap: only 1.64 ETH is reserved, and its excess becomes burnable. Accrued burnable fees can be spent before NFT retirement without consuming the creator reserve.

## Retirement responsibilities

Once fee accrual reaches the cap, anyone can call `retire()`. Before that it reverts `NotRecouped`; after success it reverts `AlreadyRetired`. Unless medallion #447 is already at `DEAD`, its current owner must approve the hook for that token or as operator. Prefer a token-specific approval. Owner information is read by low-level `staticcall`; missing code or malformed responses fail closed. A refused transfer reports `RetireRefused`, and ownership is checked again after the call.

On success the transaction transfers the NFT, marks retirement, burns 1.64 ETH of the hook's claims in its own PoolManager unlock and takes exactly that ETH to CREATOR. All state, NFT and payment changes are atomic. The caller gets nothing. A beneficiary unable to receive ETH prevents retirement until receipt becomes possible; its reserved amount cannot be redirected. The immutable final-fare text is 1126 bytes and its hash is `0x0d095dc39a486d88dd13cac371e1aefd8e9c5f9315fdbeba70a10371604762f2`.

## Permissionless burn maintenance

Call `burnIMD(viaPool4, callerMinOut)` from outside an existing PoolManager unlock. The hook opens its own unlock; callers choose only between the two fixed routes and an optional stricter minimum output. They cannot choose batch size, destination, arbitrary calldata, or a tip. Calls are non-reentrant and separated by at least five blocks; deployment sets `lastBurnBlock` to its current block.

Normal mode requires valid, open POOL4 views and either no prior burn or a burn within 50,400 blocks. It spends the smaller of burnable and 0.05 ETH. The validated POOL4 `refTick()` supplies the reference, anchor and last reference. Staticcall return lengths and value ranges are checked. A failed or closed market, or a stale burn history, permits fallback only after a valid reference has previously seeded the anchor. The constructor can seed from valid POOL4 answers even while its market is closed; after deployment, a successful normal-mode `pokeAnchor()` or burn can establish the first seed. That first seed initializes both the anchor and the current block's reference snapshot, because no valid fallback reference existed before it. Subsequent seeds preserve the existing start-of-block snapshot. A newly readable but still closed market cannot establish that first seed after deployment.

Fallback uses the plain pool only and caps batches at 0.01 ETH. Its guard reference is the anchor as it stood at the start of the block. Then the anchor moves toward plain spot by at most 200 ticks, clamped inside the last valid POOL4 reference plus or minus 1000 ticks. Only one such step is available per block, even after long idle periods. Multiple calls in a block cannot ratchet the guard reference. `pokeAnchor()` lets anyone maintain the same process without spending burnable fees; valid normal-mode data re-seeds from POOL4, and an anchor cannot be invented before a valid POOL4 reading.

Guard evaluation starts with `TooSoon`, then POOL4 availability/routing eligibility, then the fixed batch and `NothingToBurn` for less than 0.002 ETH. Price protection is one-sided: reject only a spot tick below reference minus tolerance. Normal plain-pool tolerance is 300 ticks; POOL4 and fallback tolerance is 150 ticks. A higher tick means more IMD per ETH and is favorable to the burn.

Minimum output is at least 96% of `amount * 1.0001^referenceTick`, without subtracting the pool LP fee, and at least `callerMinOut`. The hook checks actual output against that bound and rejects zero or partial input execution with `PartialFill`. Burns send IMD directly to the fixed sink and account for ETH spent and IMD received. A successful purchase updates the burn block; failed burns revert all accounting and anchor changes.

Keeper work is voluntary: there is no incentive payment, and fees can accumulate indefinitely without callers. Missing liquidity, adverse prices, an unavailable POOL4 before the first valid read, market contract failure or NFT approval refusal can stop the associated maintenance action. None adds an administrator who can bypass the constraints. Spot-price manipulation and transaction ordering remain relevant within the specified tolerance and slippage bounds; the fallback anchor is a bounded reference mechanism, not an independent oracle.

## Validation and release responsibilities

Run `forge build`, `forge test`, and `forge fmt --check` using the pinned compiler. The local suite uses a real local PoolManager where applicable plus `vm.etch` mocks for fixed external addresses. Token tests check exact initial issuance, transfers, burns, approval failures, fuzzed conservation and the forbidden runtime opcodes. Hook tests exercise success and failure accounting, fixed routes and retirement. The opcode walk skips PUSH data and checks for CALLCODE, DELEGATECALL and SELFDESTRUCT. The manifest passed the installed IdentityMD worker's actual `LaunchManifest` schema: it requires bare contract names, a permission-name array, and an unsigned decimal integer string for the price. The price's Q96 interpretation and 1:1 launch choice are explicit deployment assumptions; schema validation alone does not choose or validate economic pricing.

Before production use, an independent contributor should review the final bytecode and accounting; the deployer should verify runtime code, external addresses, permissions, market liquidity, initial price, the NFT approval, and beneficiary ETH receipt. The repository's offline mocks do not replace that review or a mainnet rehearsal. Static analyzers and a live mainnet fork are not claimed by the offline test suite. Source verification and funded deployment are operational responsibilities outside this assignment.
