# PolicyEnvelopeHook

Prepared by Midas

Source: `src/PolicyEnvelopeHook.sol`. Tests: `test/PolicyEnvelopeHook.t.sol`.

## 1. What it does

PolicyEnvelopeHook is a reusable Uniswap v4 block for launches that want a fee somebody can still steer without asking anyone to trust that person. The swap fee of each pool floats, but only inside an envelope fixed at deployment: a floor, a ceiling, the largest single step, and the minimum time between steps. Those four numbers are constructor immutables, checked in the constructor against hardcoded absolute limits, and there is no function anywhere in the contract that can move them afterwards.

The fee itself is moved per pool by whoever holds that pool's policy capsule. The capsule is recorded when the pool is initialized, is handed over in two steps (propose, then accept), and can be renounced, which freezes the pool's fee at its last value permanently. This is the split the whole design turns on: the capsule holder decides when to move the fee; the envelope decides what a move is allowed to be. An agent, a DAO, or a script can hold the capsule and still be unable to redefine its own authority.

Whatever the current total fee is, it divides by constant fractions on every swap: 70% to concentrated liquidity providers, applied as the native v4 LP fee override; 25% to the pool's deployer, the address that called `initialize`; 5% to an immutable royalty recipient. The deployer and royalty shares are taken on the specified currency inside `beforeSwap` as a BeforeSwapDelta and held as ERC-6909 claims on the PoolManager until pulled. The LP share never touches the hook.

What it deliberately does not do: it never blocks a liquidity add or remove, it never halts a swap, it holds no owner, it has no upgrade path, and it has no function that can redirect where either the deployer share or the royalty lands.

## 2. Hook permission flags

`getHookPermissions()` returns `beforeInitialize`, `beforeSwap` and `beforeSwapReturnDelta` set; every other flag false. In `Hooks.*_FLAG` terms that is `BEFORE_INITIALIZE_FLAG | BEFORE_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG`, which is `(1 << 13) | (1 << 7) | (1 << 3)` = `0x2000 | 0x0080 | 0x0008` = **0x2088**. The test file mines the deployment address with exactly this constant (`flags` in `PolicyEnvelopeHook.t.sol`), and it is the same mask the deployed MidasRWAHook and the proposed MarketHoursGuardHook use. The return-delta flag is load bearing here: without it the hook could not take the deployer and royalty shares in kind.

## 3. Authority surface

| Function | Who may call | What it can move | What it cannot move |
|---|---|---|---|
| `setFee(key, newFee)` | The pool's capsule holder | The pool's total fee, inside `[MIN_FEE, MAX_FEE]`, by at most `MAX_STEP`, at most once per `MIN_INTERVAL` | The envelope, the split, the royalty recipient, the deployer, any other pool |
| `transferCapsule(key, to)` | The pool's capsule holder | Records a pending capsule holder; passing `address(0)` cancels a pending offer | Nothing until the offer is accepted; the current holder keeps every right |
| `acceptCapsule(key)` | Only the pending capsule holder | Moves the capsule to the caller and clears the pending slot | The deployer share, which does not follow the capsule |
| `renounceCapsule(key)` | The pool's capsule holder | Sets the capsule to `address(0)`, freezing the fee forever, and clears the pending slot | Nothing else; irreversible, with no recovery path |
| `claimDeployer(id, c)` | Only the pool's deployer | Drains `deployerBucket[id][c]` to the caller | Any other pool's bucket, the royalty bucket |
| `claimRoyalty(c)` | Anyone | Drains `royaltyBucket[c]` to `ROYALTY_RECIPIENT` | The destination; the caller receives nothing |
| `unlockCallback(data)` | PoolManager only | Settles claims and takes tokens to the recipient encoded by `_payout` | Reverts with `OnlyPoolManager` for any other caller |
| `beforeInitialize` (via PoolManager) | Whoever initializes a dynamic-fee pool | Records that sender as both deployer and first capsule holder; sets the fee to `DEFAULT_FEE` | Reverts with `NotDynamicFee` on static-fee pools and `AlreadyInitialized` on re-initialization |
| `beforeSwap` (via PoolManager) | PoolManager | Mints the hook-share claim, accrues it, returns the LP fee override and the BeforeSwapDelta | Cannot charge outside the pool's current fee, which is already inside the envelope |

There is no setter for `MIN_FEE`, `MAX_FEE`, `MAX_STEP`, `MIN_INTERVAL`, `DEFAULT_FEE`, `ROYALTY_RECIPIENT`, `LP_SHARE`, `DEPLOYER_SHARE` or `ROYALTY_SHARE`, there is no owner, no ownership transfer, no proxy, and no fallback function. `test_I10_noSetterSelectorsExist` calls nine plausible setter and upgrade signatures against the hook instance and asserts every one of them reverts and leaves the envelope byte-identical.

## 4. Parameters and ceilings

Compile-time absolutes, in pips (1,000,000 = 100%): `ABS_MIN_FEE = 100` (0.01%) and `ABS_MAX_FEE = 60_000` (6.00%). No envelope, on any deployment, can reach below the first or above the second. The split is in basis points of the fee: `LP_SHARE = 7_000`, `DEPLOYER_SHARE = 2_500`, `ROYALTY_SHARE = 500`, and the constructor asserts they sum to `BPS = 10_000`.

Constructor immutables and the checks applied to them: `_minFee >= ABS_MIN_FEE`; `_maxFee <= ABS_MAX_FEE`; `_minFee <= _maxFee`; `_maxStep != 0`; `_defaultFee` inside `[_minFee, _maxFee]`; `_royaltyRecipient != address(0)`. `_minInterval` is unchecked and may legally be zero. The test suite deploys with `MIN = 500` (0.05%), `MAX = 6_000` (0.60%), `STEP = 1_000` (0.10%), `INTERVAL = 3600` seconds, `DEFAULT = 3_000` (0.30%), which is the pitch configuration a launch would plausibly use.

The split arithmetic is deliberate about rounding. `_splitPips` gives the LP the floor of 70% of the fee and gives the hook the exact remainder, so lp plus hook equals the total to the pip. `_accrue` gives the deployer the floor of 25/30 of the hook share and gives the royalty the remainder, so deployer plus royalty equals the amount taken to the wei. At the test default of 3,000 pips that is 2,100 to LPs, 900 to the hook, of which 750 to the deployer and 150 to the royalty.

## 5. Invariants and the tests that prove them

| Invariant | Test | What would fail if broken |
|---|---|---|
| Fee never leaves `[MIN_FEE, MAX_FEE]`, whatever sequence of calls | `test_I1_setFee_rejectsOutsideEnvelope`, `testFuzz_I1_feeStaysInEnvelope` | A target below the floor or above the ceiling being accepted, or a random walk of 40 signed steps landing outside |
| A single move is bounded by `MAX_STEP`, inclusive | `test_I2_stepBounded` | A step of `MAX_STEP + 1` succeeding, or a step of exactly `MAX_STEP` being refused |
| Two moves on one pool are at least `MIN_INTERVAL` apart, and the first move is not gated | `test_I3_rateLimited`, `test_init_recordsDeployerCapsuleAndDefaultFee` | A move one second early succeeding, or the pool's first move being blocked |
| Only the capsule holder may move the fee | `test_I4_onlyCapsuleCanSetFee` | A stranger, the royalty recipient, or the hook's own address moving it |
| Renouncing is permanent and freezes the fee | `test_I5_renounceFreezesForever`, `test_I5_renounceClearsPendingTransfer`, `test_I5_onlyCapsuleCanRenounce` | Any path back to a live capsule after a year, a pending offer surviving the renounce, or a stranger renouncing |
| The hand-off is two steps and single use | `test_I6_twoStepTransfer`, `test_I6_proposeZeroCancelsOffer` | The proposed holder gaining rights before accepting, a third party accepting, the offerer accepting for them, or accept working twice |
| The split conserves exactly, in pips and in wei, at every fee level | `test_I7_splitConservesAtSeveralFeeLevels`, `testFuzz_I7_splitPipsConserve` | Any fee where lp plus deployer plus royalty is not the total, or where the amount taken is not the deployer-plus-royalty pips of the input |
| The LP share actually reaches the pool through the override | `test_I7_lpShareAppliedViaOverride` | The same input yielding the same output at the envelope floor and at the ceiling |
| The royalty always pays `ROYALTY_RECIPIENT` and nobody else | `test_I8_royaltyAlwaysPaysFixedRecipient` | A stranger caller receiving funds, the recipient being short-paid, or the bucket not draining |
| The deployer share is deployer-only and does not follow the capsule | `test_I8_claimDeployer_onlyDeployerAndFullAmount` | A stranger, the royalty recipient, or the new capsule holder claiming it |
| The hook retains nothing after both claims | `test_I8_claimsDrainHookCompletely` | A residual ERC-6909 claim or ERC-20 balance in either currency |
| The constructor refuses every envelope outside the absolutes | `test_I9_constructorRejectsBadEnvelopes`, `testFuzz_I9_constructorNeverAcceptsEnvelopeOutsideCeilings` | An out-of-range deployment succeeding, or a legal boundary deployment being refused |
| The envelope is immutable and no setter exists | `test_I10_envelopeReadsBackAndIsImmutable`, `test_I10_noSetterSelectorsExist` | The envelope hash changing after every mutating path is exercised, or any setter selector landing |
| Pools are fully independent | `test_poolsHaveIndependentCapsulesAndFees`, `test_uninitializedPoolHasNoCapsule` | One capsule reaching another pool, one pool's cooldown affecting another, or an uninitialized pool having a holder |
| Static-fee pools are refused; `unlockCallback` is manager-only | `test_init_revertsOnStaticFeePool`, `test_unlockCallback_onlyPoolManager` | A static-fee pool initializing, or a stranger entering the settlement path |

## 6. Failure cases and open problems

The capsule hand-off is two-step precisely because a capsule sent to a dead address cannot be recovered, but the two-step only covers the transfer. A live capsule whose key is simply lost has the same effect as a renounce, except that nobody knows it happened: the fee is stuck at its last value and the pool has no way to say so.

Renouncing is irreversible by construction. `capsule` becomes `address(0)`, which no caller can be, so `setFee`, `transferCapsule`, `acceptCapsule` and `renounceCapsule` all revert forever afterwards. A renounced pool keeps accruing the deployer and royalty shares at the frozen fee indefinitely; renouncing the capsule stops the fee moving, it does not stop the fee.

The deployer is worse off than the capsule holder in one respect that is easy to miss. The deployer address is recorded at `initialize` and there is no transfer, no proposal, and no recovery for it. `test_I8_claimDeployer_onlyDeployerAndFullAmount` proves that handing over the capsule does not hand over the deployer share, which is the intended behaviour; the flip side is that a lost deployer key strands that pool's deployer bucket permanently, in every currency, with the funds sitting as ERC-6909 claims that no one can redeem.

The envelope can be configured to be vacuous. `_minInterval` is not checked at all, so an envelope with no rate limit is a legal deployment, and the test suite deploys exactly that in `test_I9_constructorRejectsBadEnvelopes` when it checks the boundary case. `_maxStep` is only required to be non-zero, so a step limit wider than the envelope itself is also legal and reduces the step wall to nothing. Nothing in the contract stops a deployer from shipping `[ABS_MIN_FEE, ABS_MAX_FEE]` with a step of 60,000 and an interval of zero, which is an envelope in name only. The guarantee this contract makes is that whatever envelope was published at deployment is the one that will hold; it does not make the envelope a good one, and a reviewer must read the constructor arguments, not the contract name.

Rounding is not symmetric. The LP takes the floor of its 70% and the hook takes the remainder, so at fee levels that do not divide cleanly the LPs receive slightly less than 70% and the hook side slightly more. Inside the hook share the deployer takes the floor of 25/30 and the royalty absorbs the remainder, so the royalty receives slightly more than 5% of the fee at the same fee levels. The error is at most one pip and one wei respectively, and it always resolves against the LP and toward the royalty, never the reverse.

The royalty is a real fee interest and the NatSpec discloses it: 5% of every swap fee, on every pool ever opened on this hook, paid to an immutable address that cannot be rotated by anyone including the author. An adopter cannot deploy this contract without paying it.

The hook share is taken on the specified currency, which means it comes from the input on exact-input swaps and from the output on exact-output swaps, following the MidasRWAHook pattern. `setFee` on a pool that was never initialized reverts with `NotCapsule` rather than a distinct error, because an uninitialized pool has `capsule == address(0)` and a zero-address caller is impossible; the behaviour is right and the error message is misleading. The cooldown uses `block.timestamp`, which a proposer can shift by seconds; the contract's own comment argues this is acceptable because the guard is minutes-to-hours scale, and it is, but it is a stated assumption rather than a proof.

## 7. Status

Status: compiles under solc 0.8.26 via_ir, 25/25 Foundry tests passing, bytecode 7,714 bytes runtime. Not deployed. Unaudited.

Initcode is 8,873 bytes.

## 8. Where it fits in the Hookr stack

This is the most reusable of the proposed blocks, because it is the one that answers a question every launch asks: how do you keep a lever without becoming a trusted party. MarketHoursGuardHook already uses a minimal version of the same pattern, a per-pool policy holder moving three parameters inside immutable walls, and PolicyEnvelopeHook is that idea generalized to a single number with an explicit, published envelope and a transferable, renounceable capsule.

It is also the supply side of the fee-stream design in `docs/FEE-STREAM-COLLATERAL.md`, which consumes this hook's 25% deployer bucket directly: the wrapper there initializes the pool itself so that `deployerBucket[poolId][quote]` is its own to claim, then proposes the policy capsule straight back to the creator so the wrapper holds no fee-setting authority of its own. That design depends on nothing more than `claimDeployer` and `deployerBucket` existing, which is why it works against both this hook and the deployed MidasRWAHook.

Against the deployed hooks it is a complement rather than a replacement. GoldStandardHook (PAXG quote, `0xA0E75Ca3470638AF11417e0EAC79a1f50129e0cC`) and MidasRWAHook (stock-token quote, `0xC97C22C241EcD0B9fb5656307e47C8a674ee2088`), both verified on Robinhood Chain and both unaudited, each carry a fixed fee schedule chosen at deployment. PolicyEnvelopeHook is what those hooks would use if their fee needed to respond to conditions without handing anyone an unbounded switch, and it borrows their `beforeSwap` accrual pattern, their `0x2088` permission mask, and their `last != 0` cooldown guard rather than inventing new ones.
