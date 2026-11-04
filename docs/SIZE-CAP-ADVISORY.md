# MidasSizeCapAdvisory

SweepGuard's size cap as a Hook Block for the Hook Blocks Market. It is an `IHookrAdvisory` block, the interface Hookr named for a size cap, and it refuses a swap larger than its pool's cap, except that a swap at or under the pool's always-admitted floor is never refused for impact. It never charges a surcharge and never takes quote. Whether it should also implement `IHookrMarketModule` and call `recordInstall` from `bind`, to be listed in the bonded `HookrModuleMarket` at `0xbAcE47373D6FF5B017e08a3EcA5a93ec49680f15`, is an open question for Hookr; this version does neither.

Author: Midas. Status: unaudited, nothing deployed. Source `hookr-size-cap/src/MidasSizeCapAdvisory.sol`. Tests `hookr-size-cap/test/MidasSizeCapAdvisory.t.sol` (32, the refuse path and the floor on the real fixture), `hookr-size-cap/test/MidasSizeCapMath.t.sol` (7, the arithmetic on arbitrary PoolManager states, with the pre-floor block run beside it) and `hookr-size-cap/test/MidasSizeCapConformance.t.sol` (Hookr's conformance kit, unmodified, driven against the block). Built against github.com/Hookr-fun/hookr-contracts at `5ba9dfc9cc3d1b463315518f17dda8bb07f48d3b`, the interfaces in `hookr-1/src/interfaces` as they stand there, with `lib/forge-std` at `c179529c` and `lib/v4-core` at `46c68346` as its `foundry.lock` records. `hookr-size-cap/pin.sh` checks out exactly those. Every figure below comes from the `-vv` logs of those files.

## What it is

A pool binds five numbers at launch: `maxImpactBps`, `maxQuoteIn`, `maxSubjectIn`, `floorQuoteIn` and `floorSubjectIn`. Before every swap the root asks the block, and the block answers `reject` when the swap is over the smaller of two bounds:

- the direction's ceiling on what one swap pays in, `maxQuoteIn` for a buy and `maxSubjectIn` for a sell, in raw units;
- the larger of the direction's floor (`floorQuoteIn` for a buy, `floorSubjectIn` for a sell, raw units) and the amount whose own move of sqrt price at the pool's active liquidity is `maxImpactBps`.

So a swap at or under its direction's floor is admitted whatever the impact cap says, and the ceiling still bounds it: `bind` refuses a floor above its ceiling. A floor of 0 is the block as it was before the floor, decision for decision (see "The floor" below).

That is `SweepGuard.capIn` with one change: SweepGuard's `maxIn` belongs to a one-way route, and a pool trades both ways in two different tokens, so the ceiling is split by direction. The impact term is the same expression. `test_boundary_impact_exactInput_bothDirections` computes SweepGuard's term independently on the pool's own slot0 and liquidity and checks the block returns the same amount.

Exact input is checked on the specified amount, which is all the swap pays in. The ceiling and the floor are exact for it: a buy of exactly `maxQuoteIn` pays exactly `maxQuoteIn`, and a buy of exactly `floorQuoteIn` is admitted whatever the depth. The fees only make the real move smaller.

Exact output is checked twice: the move the output itself makes at active liquidity against `maxImpactBps`, and the input that output costs at active liquidity, grossed up by the pool's base LP fee and rounded up, against the ceiling. An output over the impact cap is admitted when that same cost is within the floor. The swap context carries the base fee and no other charge, so for exact output the ceiling, the floor and the impact cap are approximate. The Rules' LP surcharge, quote take and dynamic fee are outside the cost, and the root adds the Rules' reservation to the output after the advice (Auto Burn on a buy, the quote take on a sell). Measured on the fixture's Rules: the largest admitted exact-output buy pays 1,030.68e18 against a 1e21 ceiling (+3.07%), and the largest exact-output buy within a 10 bps impact cap moves sqrt price 10.0756 bps. The sell side measures at the ceiling and at the cap.

Active liquidity is the PoolManager's, read at the start of the swap, with one correction. When the price sits exactly on the boundary of the tick a swap moves into, the PoolManager crosses that tick before it trades anything, so the block applies that tick's `liquidityNet` the way the crossing will. A launch whose single-sided range ends at the opening price (the shape of a new-token launch with the subject as currency1) reports zero active liquidity at tick 0, yet a buy trades against the whole range; the block holds that buy to the impact cap at the range's depth. `test_priceOnTickBoundary_readsTheSideTheSwapMovesInto` covers both token orders.

With no active liquidity at the price, a swap moves through empty ticks to the next range before it trades, and its move at zero depth says nothing about what it trades. There the impact cap does not apply. An exact input is bounded by its direction's ceiling alone, which is how a pool whose price has run out of its range trades back in. An exact output cannot be costed at zero depth and is refused. The floor changes neither, since it is never above the ceiling.

The block reads its binding and the PoolManager's storage, and nothing else. It does not read `sqrtPriceLimitX96`.

```solidity
struct Config { uint16 maxImpactBps; uint120 maxQuoteIn; uint120 maxSubjectIn;   // slot 1: the cap
                uint120 floorQuoteIn; uint120 floorSubjectIn; }                // slot 2: the floors, unwritten when both are 0
enum Reason { OK, NO_PRICE, NO_LIQUIDITY, OVER_CEILING, OVER_IMPACT, BAD_FEE }    // NO_LIQUIDITY: exact output at zero depth

function configSchemaHash() external pure returns (bytes32);
function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data) external returns (bytes32);
function beforeAddLiquidity(PoolId, address) external pure returns (bool);                 // always true
function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory);
function afterSwap(HookrTypes.SwapContext calldata, int128, int128) external pure returns (HookrTypes.Advice memory); // never called
function config(address root, PoolId id) external view returns (Config memory);
function explainSwap(address root, HookrTypes.SwapContext calldata x) external view
    returns (bool allowed, Reason reason, uint256 amountIn, uint256 limitIn);
function maxExactInput(address root, PoolId id, bool zeroForOne, bool isBuy) external view returns (uint256);
```

`explainSwap` and `maxExactInput` are for UIs and keepers, as HookrComplianceGuard's `explainSwap` is: what the block would decide, why, and the largest exact input it admits now. `maxExactInput` is now `min(ceiling, max(impact cap, floor))`, the ceiling alone at zero depth. A swap the floor admits over the impact cap explains as `OK`; one over both explains as `OVER_IMPACT`, the reason it had without a floor.

## What it declares

The admission Hookr would queue through the timelock, and what `bind` holds every pool to:

| Admission field | Value | Why |
|---|---|---|
| `kind` | ADVISORY | |
| `schemaHash` | `keccak256("MidasSizeCap(uint16 maxImpactBps,uint120 maxQuoteIn,uint120 maxSubjectIn,uint120 floorQuoteIn,uint120 floorSubjectIn)")` = `0x6ba75614553807c672486e5d3ab356ffab8abc0b60c6e0a86f3dcd0a3647ad59` | `configSchemaHash()` returns it. It changed with the floor (it was `0x0e448ae3...` for the three-word terms), so an admission queued for the earlier version does not fit this one |
| `caps` | `(0, 0, 0)`: LP-fee cap 0, quote-take cap 0, subject-take cap 0 | The block never surcharges and never takes. `bind` refuses an admission with any cap above zero |
| `gasLimit` | `ADVISORY_GAS` = 100,000 | The root forwards it to `bind` as well as to every swap-path call. Cold, `bind` measures 52,069 with floors of 0 and 74,218 with a floor set, and the heaviest `beforeSwap` 23,669 (see Gas), so it covers `bind` and `beforeSwap` with room to spare. `bind` refuses a pool with less |
| `phaseMask` | `PHASES` = BEFORE_SWAP (1) | The cap is decided before the swap. `bind` refuses any other phases, so `afterSwap` is never called |
| `feeOnly` | true | It takes no charge of any kind |
| `failOpen` | false | A block that refuses runs fail-closed. With this admission the root refuses to open a fail-open pool naming the block (`HookrLane.sol` line 944), `test_declaredAdmission_refusesAFailOpenPool` |

`bind` also checks the caller is the pool's hook, the pool names this contract as its advisory, and the root's PoolManager is the block's. It does not check the pool's fail mode itself, as Market Guard, the Buy/Sell Block and the Credential Gate do when their refusing modes are on, because Hookr's conformance kit admits every advisory fail-open and launches a fail-open pool, and that check would stop the kit in setUp. The admission is where fail-closed is held. Every check has its own code in `InvalidPoolConfig(uint8)` and `InvalidTerms(uint8)`, listed in the NatSpec, in the same pattern as HookrComplianceGuard.

## Fail-closed and fail-open

Read from `HookrRoot._advice` and `beforeSwap` at the pinned commit, and asserted with the exact revert data. The fail-open cases run against a second deployment of the same code admitted fail-open, the way the kit admits it, since the declared admission keeps the block out of fail-open slots.

- Fail-closed slot. A refusal reverts the swap with the root's `SwapRejected()` (`HookrRoot.sol` line 432 on the full path, 381 on the fee-only path), wrapped by the PoolManager in `WrappedError(root, beforeSwap, SwapRejected, HookCallFailed)`. `test_failClosed_overCapBuyRefused_atCapBuyFills`, `test_failClosed_overCapSellRefused_atCapSellFills`.
- Fail-open slot. `_advice` refuses `reject` or a take from any fail-open advisory (line 817), so the same refusal reverts the swap as `InvalidModuleResult(advisory)`. The block gives the same advice in both slots. `test_failOpen_refusalRevertsTheSwap`.
- What fail-open changes is a failed call. A revert or an out-of-gas lets the swap through at the admitted LP-fee cap (lines 805 to 811), zero here, so an over-cap swap fills unchecked. A fail-closed pool reverts it with the block's reason inside `ModuleCallReverted`. `test_failOpen_failedCallLetsAnOverCapSwapThrough` shows both with a mocked failure.

The block does not revert on a bound pool and answers within its gas limit. `MidasSizeCapMath.t.sol` writes the PoolManager's storage directly and fuzzes any price, prices exactly on a tick boundary from either side, the price extremes, any active liquidity, any `liquidityNet` on the boundary tick, any amount (the int256 extremes included), any base fee and any terms, through a staticcall with exactly `ADVISORY_GAS`. On the real fixture, `testFuzz_neverRevertsOnABoundPool` does the same at depths from the whole launch position down to none and at any price one swap can push the pool to, out of range included. Every answer is four clean words with no surcharge, no take and no recipient.

## Parameters and ceilings

`bind` takes `abi.encode(maxImpactBps, maxQuoteIn, maxSubjectIn, floorQuoteIn, floorSubjectIn)`, exactly five words, and enforces, in this order:

- `1 <= maxImpactBps <= MAX_IMPACT_BPS = 2,000` (code 2). 2,000 bps of sqrt is about +44% / -36% in price. Zero would refuse every swap at active liquidity.
- `1 <= maxQuoteIn, maxSubjectIn <= MAX_IN = 2^120 - 1` (codes 3 and 4), the most the packed slot holds. Raw units, so the sane level depends on the tokens; size it from the depth the pool is expected to hold, as SweepGuard's `maxIn`.
- `floorQuoteIn <= maxQuoteIn` (code 5) and `floorSubjectIn <= maxSubjectIn` (code 6). Zero is no floor. A floor equal to its ceiling turns that direction's impact cap off and leaves only the ceiling.

Any other length is code 1, the three-word terms of the version before the floor included. A word with high bits set fails its range check. `test_bind_termsAtAndPastTheirCeilings` binds the ceilings themselves and the smallest terms (1, 1, 1, 0, 0), and refuses zero, ceiling plus one, a dirty word and wrong lengths. `test_floor_bind_validation` refuses a floor one over its ceiling in each direction (5, 6), a dirty floor word, a bad ceiling before its floor (3, 4) and the three-word terms (1); binds floors of 0 and floors equal to their ceilings, which `config` returns and `Bound` carries; and sends a floor over its ceiling through the real launcher, which does not open the pool. `test_bind_badTermsStopTheLaunch` does the same for a zero impact cap: the root reverts with `ModuleCallReverted(block, bind, InvalidTerms(2))`.

Choosing the numbers is SweepGuard's rule. A sandwich around one swap pays only when the swap is larger than about the pool's fee times its depth, so `maxImpactBps` at or under the lowest LP fee the pool can charge makes the sandwich a loss. Liquidity added just in time inflates the impact cap and the ceilings do not move, so they are the bound that holds against that. They are also the only bound on an exact input at zero depth. Set them at the level the impact cap gives at the depth you expect honest liquidity to hold. Set each floor at or under the impact cap at the thinnest depth you still count as real (next section): the floor then decides only below that depth, which is where dust sits.

## The floor

Requested by Hookr (Nodar, 4 Nov 2026) to close the dust limit flagged in the previous version: dust liquidity parked over a price stopped in a gap made the impact cap read the dust, so the block admitted only dust-sized swaps until someone added real depth there. The floor is a size per direction that is always admitted:

| Parameter | Units | Admits | Bound by |
|---|---|---|---|
| `floorQuoteIn` | raw quote, the input of a buy | a buy paying in at most this, whatever the impact cap says | `maxQuoteIn` (bind refuses more, code 5) |
| `floorSubjectIn` | raw subject, the input of a sell | a sell paying in at most this, whatever the impact cap says | `maxSubjectIn` (bind refuses more, code 6) |

The rule, for an exact input of `amountIn` at nonzero depth: admitted if `amountIn <= ceiling` and `amountIn <= max(impact cap, floor)`. At zero depth nothing changes (the ceiling alone). One unit over the floor falls back to the impact cap. For an exact output the floor is checked the way the ceiling is: on the input the output costs at active liquidity, grossed up by the base LP fee and rounded up. An output over the impact cap is admitted when that cost is within the floor, and refused as `OVER_IMPACT` otherwise. Measured on the fixture's Rules, the largest exact-output buy under a 1e17 quote floor pays 103,074,705,407,130,325 through the router (+3.07%, the same Rules' charges as on the ceiling) and the sell pays exactly the 2e17 subject floor. An exact output larger than active liquidity pays out before the price reaches `MIN_SQRT_PRICE` or `MAX_SQRT_PRICE` cannot be costed and stays refused, so at dust depth the floor opens exact input only. The cost assumes the active liquidity holds across the move, so an exact output whose move crosses into thinner liquidity pays and moves more than it was costed at; that was already true within the impact cap, and the floor admits larger costed moves where it binds.

Storage and the swap path: the floors live in a second slot of the pool's binding, which `bind` writes only when a floor is set. The swap path reads that slot only for a swap over the impact cap, the one case a floor can change. It stays a static read; nothing is written outside `bind`.

Floor 0 is the block as it was. `MidasSizeCapMath.t.sol` runs the block at `80fbd9f` (kept verbatim as `test/fixtures/MidasSizeCapAdvisoryPrev.sol`, renamed) beside this one on arbitrary PoolManager states: bound with floors of 0, the two return the same `beforeSwap` bytes, the same `explainSwap` (allowed, reason, amountIn, limitIn) and the same `maxExactInput` in all four directions, on random swaps and on swaps one unit either side of the old bounds (`testFuzz_floorZeroDecidesAsBefore`, `testFuzz_floorZeroDecidesAsBefore_atTheBoundaries`). With floors set, `testFuzz_floorOnlyAddsSwapsWithinIt` checks that the floor never refuses what the old block admits, never admits over the ceiling, adds only swaps the old block refused for impact and whose input (or cost) is within the floor, keeps a refusal's reason, and for exact input at nonzero depth admits exactly `old || amountIn <= floor`. Every test in `MidasSizeCapAdvisory.t.sol` that predates the floor binds floors of 0 and still passes, the stranding regression (`test_runOut_*`) and the dust limit (`test_limit_dustLiquidityInAGap_refusesUntilDepthIsAdded`) included. What differs at floor 0 is outside the decisions: `bind` takes five words, the schema hash and the `Bound` event changed, and a refusal over the impact cap reads the floors' slot (about 2,300 gas more, see Gas).

### Can the floor be abused?

Yes, within limits that are measured here. The block keeps no state on the swap path (one of its properties: static reads only), so it cannot see repetition. The cap and the floor are per swap, and N floor-sized swaps in one transaction or one block are N admitted swaps.

What the floor changes is the size of a step at thin depth. The impact cap shrinks a swap as depth falls; the floor does not. Where the impact cap at depth L is below the floor, a floor-sized swap moves the price more than `maxImpactBps`. At price 1 the crossover depth is about `floor x 10,000 / maxImpactBps` (more generally `floor x 10,000 / (sqrt(p) x bps)` for a move up and `floor x 10,000 x sqrt(p) / bps` for a move down), and below it a floor-sized swap moves sqrt price about `bps x L* / L`. On the fixture at L = 1e19 with a 10 bps cap (crossover about 1e20 for the 1e17 quote floor and 2e20 for the 2e17 subject floor), a floor-sized buy moved sqrt price 96.5 to 97.5 bps and a floor-sized sell 195.5 to 199.4 bps, across the two token orders (`test_floor_overTheFloorFallsBackToTheImpactCap_bothDirectionsBothOrders`).

Walking a single-sided range out with floor-sized swaps, measured (`test_abuse_floorSizedSwapsWalkAThinSingleSidedRangeOutInOneTx`). Two new-token launches each hold 1e19 subject over ticks -60000..0, 50 bps, ceilings 1e21 and 2e21; one binds a 1e19 quote floor, one none. Each is bought out in one transaction by repeated exact-input buys until the price leaves the range:

| | Swaps | Quote paid | Subject bought | Router gas |
|---|---|---|---|---|
| 1e19 floor, floor-sized buys | 21 | 205,878,437,368,516,447,708 | 9,915,074,999,999,999,246 | 3,257,174 |
| no floor, buys at `maxExactInput` | 615 | 205,852,900,575,104,287,571 | 9,915,074,999,999,999,252 | 80,525,107 |

Every buy was admitted on both. The floor cut the swaps about 29-fold and the gas about 25-fold; the capital did not move (0.012% apart), because either way the walker buys every unit of subject in the range at the curve's price plus the Rules' charges. Without a floor the impact cap never bounded a cumulative walk either; it only forced it into more, smaller swaps, and that gas cost can push it past one block on a chain with a tight block gas limit. With a floor the same walk fits in a few million gas. After the walk both pools sit past the range at zero depth, where the ceiling alone already applied before the floor, and a sell brings each back into the range, so nothing is stranded. Leaving a single-sided range on its other side is a move into zero depth from the start, where the floor changes nothing because it is never above the ceiling.

What follows from that, stated plainly:

- The floor never lets one swap exceed its direction's ceiling. Exact input is exact (`test_floor_neverLetsASwapPastTheCeiling`); exact output is approximate in the way the ceiling already was (+3.14% paid over a 1e21 ceiling on a buy with the floor equal to the ceiling, measured).
- Where the floor exceeds the impact cap, SweepGuard's sandwich bound no longer holds for floor-sized swaps: a floor-sized victim swap at depth below about `floor / fee` can be worth sandwiching, and the trader's own price limit is then the protection. This is arithmetic from SweepGuard's rule; no sandwich was run against the floor here.
- Thin depth plus a floor makes the price cheaper to move in swap count and gas, though no cheaper in capital. That includes a same-transaction push of the spot price that another contract reads. A pool that wants the impact cap to hold at every depth should bind floors of 0, and accept the dust limit.
- The floor is one more way for a launcher to bind a weak cap: a floor equal to its ceiling switches that direction's impact cap off. Terms are public through `config` and the `Bound` event, and frozen at bind.
- A bound on cumulative movement per block would need state written on the swap path, which this block does not do by design. That would be a different block.

Unaudited, nothing deployed.

## The conformance kit

`hookr-1/test/kit/AdvisoryConformance.sol` runs unmodified, from the pinned checkout. `MidasSizeCapConformanceTest` fills in only the author hooks:

| Hook | Value |
|---|---|
| `_kitDeploy` | `new MidasSizeCapAdvisory(manager)` |
| `_kitRootData` | 50 bps, 1e22, 1e22, floors 0 0: the cap as it was, so the kit's results compare with earlier runs |
| `_kitRootCapPips` | 0, the declared LP-fee cap |
| `_kitRootGasLimit`, `_kitRootPhases` | `ADVISORY_GAS`, `PHASES` read from the block |
| `_kitSupportsPair` | false: a pair root's advisory returns a surcharge and has no way to refuse |
| `_kitOwnBuild`, `_kitArtifact` | true, `out/MidasSizeCapAdvisory.sol/MidasSizeCapAdvisory.json` |
| `_kitCold` | cools the block and the PoolManager, since the block reads the PoolManager on every swap |
| `_kitStress` | withdraws a seed-picked share of the kit pool's launch position, leaving 1 / 10^(seed % 6) of it, then advances the clock as the default does |
| `_kitWorstCase` | default. The kit pools open exactly on tick 0's boundary, the state where a swap down reads one more slot |

The kit builds the admission itself, with `failOpen` true, because it launches a fail-open pool. That differs from the declared admission (`failOpen` false), and the run keeps the kit's.

The size cap's state is the pool's depth, so that is what the stress moves. At the kit pool's full depth (L = 1e24) no size in the fuzz's range (1e9 to 1e18) reaches a 50 bps cap; without the stress the fuzz would pass without meeting a single refusal.

Result: 7 pass, 1 fails, 8 skipped.

| Check | Result |
|---|---|
| `test_kit_root_bindsOnce` | pass |
| `test_kit_root_returnSizes` | pass |
| `test_kit_root_gasAtCap` | pass, cold `beforeSwap` 14,090 and 15,254 gas against the 100,000 limit (14,014 and 15,183 before the floor), and the fail-closed pool trades 1e18 both ways. The kit cools with `vm.cool`, which re-cools slots but not an account already touched (see Gas), so these sit below the snapshot-cold figures |
| `test_kit_root_failOpen` | pass |
| `test_kit_root_launchBuy` | pass, the 1e21 dev buy fills on a fail-closed pool bound to the block |
| `test_kit_root_declarations` | pass: every IHookrAdvisory selector, BEFORE_SWAP admitted, codehash pinned, no DELEGATECALL, CALLCODE, SELFDESTRUCT or EIP-7702 designator |
| `test_kit_plainCodeIgnoresTheTrailingLength` | pass |
| `testFuzz_kit_root_surchargeWithinCap` | fails on `assertFalse(advice.reject, "reject")` |
| the eight `*_kit_pair_*` checks | skipped, `_kitSupportsPair` is false |

The one failure is the one Hookr flagged in advance. The fuzz asserts that advice never refuses, which holds for a fee advisory, and a size cap's job is to refuse. One run's counterexample was `args=[7205, true, false, 8]`: seed 7205 leaves 1/10^5 of the position, L = 1e19, and an exact-output buy of about 1e18 moves sqrt price about 10%, twenty times the 50 bps cap, so the advice is `reject`. The fuzz's surcharge and take assertions are ones the block meets on every swap, since its advice never carries either. Its last assertion, that the root's quote stays within the pool cap, does not apply to a refused swap: the quoter reverts for it. The counterexample changes from run to run because the fuzz seed is random; the failing assertion does not.

## Refuse-path tests

`MidasSizeCapAdvisory.t.sol` runs against the same real HookrRoot, HookrRules, launcher, router and quoter as the kit (Hookr's `PeripheryFixture`, unmodified). The block is admitted as it declares itself and bound by pools launched through `HookrLauncher.launchAdvised`: a fail-closed pool at 50 bps, `maxQuoteIn` 1e21 and `maxSubjectIn` 2e21 (the ceilings bind), a fail-open pool with the same terms on the fail-open deployment, a fail-closed pool at 10 bps with both ceilings at `MAX_IN` (the impact cap binds), and a fail-closed pool at 10 bps, ceilings at `MAX_IN` and both floors 1e22 (the floor sits over the impact cap). All open at price 1 with L = 1e24 across ticks -60000..60000, and all but the last bind floors of 0. Single-sided launches are built as a new-token launch builds them; the floor tests launch their own pools, thinned by withdrawing part of the launch position where they need thin depth.

| Property | Test |
|---|---|
| Fail-closed: one unit over the ceiling is refused with `SwapRejected`, exactly the ceiling fills and pays exactly the ceiling, buy and sell | `test_failClosed_overCapBuyRefused_atCapBuyFills`, `test_failClosed_overCapSellRefused_atCapSellFills` |
| The declared admission (`failOpen` false) makes the root refuse a fail-open pool | `test_declaredAdmission_refusesAFailOpenPool` |
| Fail-open: the same refusal reverts the swap as `InvalidModuleResult(block)` | `test_failOpen_refusalRevertsTheSwap` |
| Fail-open: a failed call lets an over-cap swap through at the native fee; fail-closed reverts it | `test_failOpen_failedCallLetsAnOverCapSwapThrough` |
| Ceiling, exact input, both directions: at the ceiling admitted, one more refused (`OVER_CEILING`) | `test_boundary_ceiling_exactInput_bothDirections` |
| Impact cap, exact input, both directions: equals SweepGuard's term, admitted at the cap and fills with a realised move within the cap (checked exactly), one more refused (`OVER_IMPACT`) | `test_boundary_impact_exactInput_bothDirections` |
| Impact cap, exact output, both directions: the largest output within the move is admitted and fills, one more refused | `test_boundary_impact_exactOutput_bothDirections` |
| Ceiling, exact output, both directions: the cost is checked as specified, the largest output whose cost fits fills, the next is refused | `test_boundary_ceiling_exactOutput_bothDirections` |
| Exact output pays above the ceiling by the Rules' charges: +3.07% on a buy, none on a sell | `test_limit_exactOutputPaysAboveTheCeilingByTheRulesCharges` |
| Exact output moves past the impact cap by the root's reservation: 10.0756 bps on a 10 bps buy, 10.0000 on a sell | `test_limit_exactOutputMovesPastTheImpactCapByTheReservation` |
| Zero depth: an exact input is bounded by its ceiling alone, an exact output is refused (`NO_LIQUIDITY`) | `test_noActiveLiquidity_ceilingAloneBoundsExactInput` |
| A price on a tick boundary is read on the side the swap moves into, both token orders | `test_priceOnTickBoundary_readsTheSideTheSwapMovesInto` |
| A single in-cap sell runs a single-sided launch out of its range to the router's price limit (tick 887271, or MIN_TICK with the subject as currency0), where no position can be placed; an in-cap buy brings it back into the range and trading resumes | `test_runOut_subjectAsCurrency1_inCapBuyBringsThePoolBack`, `test_runOut_subjectAsCurrency0_inCapBuyBringsThePoolBack` |
| Floors of 0: dust liquidity placed over a price stopped in a gap holds swaps to dust size until real depth is added there | `test_limit_dustLiquidityInAGap_refusesUntilDepthIsAdded` |
| The floor closes that: in the same state with floors set, a buy of exactly the quote floor and a sell of exactly the subject floor are admitted though the impact cap at the dust is a few wei, one more unit is refused for impact, an exact output there stays refused, and the floor-sized buy crosses into the launch range so trading resumes with no depth added. Both token orders | `test_floor_dustInAGap_floorSizedSwapTradesThePoolBack_bothTokenOrders` |
| Just over the floor falls back to the impact cap. At full depth the impact cap is above the floor and the floor changes nothing; thinned to L = 1e19, swaps between the impact cap and the floor are admitted, the floor fills paying exactly the floor, one over is refused and reverts through the router. Both directions, both token orders, realised moves logged | `test_floor_overTheFloorFallsBackToTheImpactCap_bothDirectionsBothOrders` |
| The floor never passes the ceiling: floors equal to the ceilings, `maxExactInput` is the ceiling, the ceiling fills paying exactly it, one over is `OVER_CEILING` and reverts; the largest exact output costed within the ceiling is admitted and the next refused. Both directions, both token orders | `test_floor_neverLetsASwapPastTheCeiling` |
| Exact output under the floor is costed as the ceiling costs it, both directions and token orders: the largest output within the floor is over the impact cap, admitted with exactly that cost and fills; one more is `OVER_IMPACT` with a cost over the floor | `test_floor_exactOutput_costedLikeTheCeiling_bothDirectionsBothOrders` |
| Floor bind validation: codes 5 and 6, dirty floor word, ceiling checked first, three-word terms refused, floors at 0 and at the ceiling bind, `config` and `Bound` carry them, the launcher refuses a floor over its ceiling, the schema hash names five words | `test_floor_bind_validation` |
| Floors of 0 on the fixture give the pre-floor answers at and one unit past each bound, exact input and exact output, with exact outputs over the impact cap left uncosted as before | `test_floor_zeroIsTheBlockAsItWas` |
| The abuse case: floor-sized buys walk a thin single-sided range out in one transaction in 21 swaps where the impact cap alone takes 615, for the same quote; the pool comes back with a sell | `test_abuse_floorSizedSwapsWalkAThinSingleSidedRangeOutInOneTx` |
| Out-of-range and malformed terms revert; the ceilings themselves bind | `test_bind_termsAtAndPastTheirCeilings`, `test_bind_badTermsStopTheLaunch` |
| A pool or admission other than declared is refused (hook, advisory, phases, gas, PoolManager, caps), and a pool binds once | `test_bind_refusesWhatItDoesNotDeclare` |
| Every `beforeSwap` path, the floor's included, cold, gives the advice expected of it and fits `ADVISORY_GAS`, and so does `bind` with floors of 0 and with floors set | `test_gas_everyPathUnderTheDeclaredLimit` |
| No admin or upgrade surface: the artifact exposes exactly 13 functions, 18 owner, upgrade, pause and setter probes revert from an outside caller and from the root, no EIP-1967 slot is set, no ether is accepted | `test_probe_noAdminOrUpgradeSurface` |
| Nothing writes storage outside `bind`: every view, and admitted and refused swaps through the router recorded as a full state diff (swaps the floor admits and refuses included, which read the floors' slot), write nothing; `bind` writes only the cap's slot with floors of 0, and the cap's and the floors' slots with a floor set | `test_probe_writesNoStorageOutsideBind` |
| The runtime has no CALL, CALLCODE, DELEGATECALL, CREATE, CREATE2, SELFDESTRUCT or TSTORE; its six external call sites are STATICCALL and it has two SSTOREs, both in `bind` | `test_probe_runtimeOpcodes` |
| `beforeSwap` never reverts on a bound fixture pool, at any amount and fee, at depths down to none and at prices one swap reaches | `testFuzz_neverRevertsOnABoundPool` |
| Any exact input up to `maxExactInput` fills with a realised move within the cap; anything above is refused | `testFuzz_exactInput_admittedMovesWithinTheCap_restRefused` |

`MidasSizeCapMath.t.sol`, adapted from the independent review's probe:

| Property | Test |
|---|---|
| On any PoolManager state, any swap and any floors, no revert, four clean words, within `ADVISORY_GAS`; at zero depth a reject exactly for an exact output or an exact input over its ceiling | `testFuzz_neverRevertsOnAnyPoolState` |
| An exact output inside the impact budget is costed without reverting at any price and depth | `testFuzz_exactOutputWithinTheBudgetNeverReverts` |
| An exact output over the impact cap, within what active liquidity pays out before the price extreme, is costed by the floor path without reverting at any price and depth, and admitted exactly when its cost is within the floor | `testFuzz_exactOutputOverTheImpactCap_floorCostsItWithoutReverting` |
| Floors of 0 decide exactly as the `80fbd9f` block: same `beforeSwap` bytes, `explainSwap` and `maxExactInput`, on random swaps and at the old bounds | `testFuzz_floorZeroDecidesAsBefore`, `testFuzz_floorZeroDecidesAsBefore_atTheBoundaries` |
| With floors set, the floor only adds swaps within it, never over the ceiling, keeps a refusal's reason, and for exact input at nonzero depth admits exactly `old || amountIn <= floor`; `maxExactInput` is `max(old, floor)` | `testFuzz_floorOnlyAddsSwapsWithinIt` |
| The price extremes, the most liquidity and the most negative net, the largest amounts of both signs | `test_extremes` |

Measured boundaries on the 1e24 pools: the 10 bps impact cap admits an exact-input buy of 999,999,999,999,999,999,999 and a sell of 1,001,001,001,001,001,001,001 (token1 in and token0 in respectively). Under the 1e21 and 2e21 ceilings the largest exact outputs the block admits are a buy of 996,006,981,039,903,216,493 and a sell of 1,990,031,876,438,381,866,558, the difference being the 0.30% base fee and the output's own impact.

## Gas

From `test_gas_everyPathUnderTheDeclaredLimit`. Each call is measured from a snapshot taken before anything in the test's transaction touched the block, the PoolManager or the registry, so their accounts and every slot read are cold and the root's cold access to the block is inside the figure. The root is warm for `bind`, as it is when it calls `bind`. In a real swap the PoolManager is already warm, so the `beforeSwap` figures are an upper bound.

The previous version of this test cooled with `vm.cool`, which re-cools slots but not an account already touched in the transaction, and it read its own `gasLimit` inside the measured window. Only its first path was fully cold, and that path also carried the test's own cold read; that is where the earlier 18,653 came from. The "before" column below is the `80fbd9f` block measured the new way.

| Call | Before the floor | With the floor |
|---|---|---|
| `beforeSwap`, exact input, price moving up | 16,401 | 16,471 |
| `beforeSwap`, exact input, moving down across tick 0 (reads one more slot) | 20,069 | 20,134 |
| `beforeSwap`, exact input, over the ceiling | 19,073 | 19,014 |
| `beforeSwap`, exact input, over the impact cap, floor 0 (now reads the floors' slot) | 20,058 | 22,347 |
| `beforeSwap`, exact output, admitted | 20,742 | 20,820 |
| `beforeSwap`, exact output, over the impact cap, floor 0 (now reads the floors' slot) | 19,638 | 21,935 |
| `beforeSwap`, exact input, floor admits it, up | | 18,712 |
| `beforeSwap`, exact input, floor admits it, down across tick 0 | | 22,381 |
| `beforeSwap`, exact input, over the impact cap and the floor | | 22,348 |
| `beforeSwap`, exact output, costed within the floor, up | | 21,233 |
| `beforeSwap`, exact output, costed within the floor, down across tick 0 | | 23,669 |
| `beforeSwap`, exact output, costed over the floor, down / up | | 23,669 / 21,235 |
| `beforeSwap`, exact output past what the depth pays out | | 22,281 |
| worst `beforeSwap` | 20,742 | 23,669 |
| `bind`, floors 0 (the block and the registry cold) | 51,136 | 52,069 |
| `bind`, a floor set | | 74,218 |

Measured the old way the worst path goes from 18,653 to 18,909. The kit's own cold measurement in `test_kit_root_gasAtCap` is 14,090 and 15,254, by `vm.cool`. On arbitrary states the math test's worst warm answer at the extremes is 8,109. The declared limit is 100,000, about four times the heaviest path. Runtime size 7,558 bytes (6,967 before the floor).

## Authority surface

None. No owner, no setter, no pause, no upgrade path, no proxy, no DELEGATECALL. The PoolManager is a constructor immutable. A pool's terms are written once, in `bind`, under the calling root's address, so a caller can only write its own namespace, and nothing changes them afterwards: the cap's slot always, the floors' slot only when a floor is set. Every other function is view or pure. The external calls are all reads: the PoolManager's slot0, liquidity and one tick's liquidity on the swap path, and in `bind` the root's `poolManager()` and `registry()` and the registry's `admission` for this contract. The runtime holds no CALL opcode at all.

## Failure cases and limits

In a fail-closed slot a refused swap reverts and moves nothing.

- The impact cap assumes the active liquidity holds across the move. A swap whose budget reaches past the edge of its range leaves the range, and with the router's price limit an in-cap sell runs a single-sided launch out to the price extreme. At spacing 60 that is above the largest usable tick (887271 against 887220) or below the smallest, where no position can ever be placed. The pool recovers: at zero depth an exact input up to the ceiling is admitted, crosses the empty ticks, and trades back into the range. `test_runOut_*` checks both token orders.
- At zero depth only the ceilings bound an exact input, and an exact output is refused. A trader's exact input that jumps a gap and then trades deep into the next range is held to the ceiling alone.
- With floors of 0, dust liquidity over a price that sits in a gap at a usable tick makes the impact cap read the dust, so the block admits only dust-sized swaps there until someone adds real depth at that price. Anyone can add it, after which trading resumes (`test_limit_dustLiquidityInAGap_refusesUntilDepthIsAdded`). A swap reaches such a price only by stopping on its own price limit; the router's default limit runs on to the extreme. A floor closes this for exact input: a floor-sized swap is admitted at any depth and crosses back into the range (`test_floor_dustInAGap_floorSizedSwapTradesThePoolBack_bothTokenOrders`). An exact output at dust depth stays refused, since it cannot be costed there.
- Where depth is below the floor's crossover, each floor-sized swap moves the price more than `maxImpactBps`, and repeated floor-sized swaps walk thin depth in few swaps for the same capital as one large swap. SweepGuard's sandwich bound does not hold for floor-sized swaps there. Measured and discussed under "The floor".
- Exact output is approximate against both bounds: the context carries the base LP fee only, so the Rules' LP surcharge, quote take and dynamic fee are outside the cost, and the root's reservation (Auto Burn on a buy, the quote take on a sell) is added after the advice. Measured +3.07% paid over the ceiling on a buy, 10.0756 bps on a 10 bps impact cap.
- The cap and the floor are per swap. A trader can split a large trade into swaps under the cap; each one is bounded, and the sandwich arithmetic holds per swap where the impact cap decides.
- Ceilings and floors are raw units per direction, fixed at bind. A token with odd decimals needs them set for it.
- The block reads one PoolManager, fixed at deploy, and refuses to bind for a root on another.
- `sqrtPriceLimitX96` is not read; the cap is the same whatever limit the swap carries.
- An arb recapture executor's leg on a pool with an advisory is asked like any other swap (`HookrRoot.beforeSwap`), so the cap applies to legs too.

## What testing turned up

The independent review found a permanent freeze in the first version. It refused every swap at zero active liquidity, including the swap that would cross back into range, and a single in-cap sell on Hookr's standard new-token launch ran the price to tick 887271, where no position can make liquidity active. The pool then refused every swap for good. The block now bounds an exact input at zero depth by the ceiling alone, and both run-out tests show the pool coming back. The review also measured the exact-output overruns above, which the NatSpec and this brief now state.

The first run of the kit failed in setUp with `vm.getCode: no matching artifact found`. Forge looks up `deployCode("PoolManager.sol:PoolManager")` only among the artifacts of the files a filtered or cached run selects, and the PoolManager compiles from a separate 0.8.26 fixture. `unchecked_cheatcode_artifacts = true` in `foundry.toml` lets the fixture read it from `out/`. Nothing in Hookr's files changed.

The tick-boundary case came up while reading the kit's launch-buy check, which builds exactly that single-sided range. Reading `getLiquidity` alone, as SweepGuard does, sees no depth there with the subject as currency1.

Adding the floor turned up two things. An exact output over the impact cap could not be costed by the existing path without risking a revert in `getNextSqrtPriceFromOutput` once the output exceeds what active liquidity pays out; the floor path first checks the output against the move to the price extreme, the same bound the impact path relies on, and refuses beyond it (`testFuzz_exactOutputOverTheImpactCap_floorCostsItWithoutReverting`). And the gas test's `vm.cool` re-cools slots but not an account already touched, so earlier figures after the first path were low by about two cold account accesses; the test now measures each call from a cold snapshot, and the table above gives both versions measured that way.

## Build settings

hookr-1 compiles with solc 0.8.37, via-IR, optimizer 200 runs, EVM prague, and its kit files require `^0.8.37`. `hookr-size-cap/foundry.toml` uses those settings so the block is built the way Hookr builds its own blocks; the PoolManager fixture compiles with 0.8.26, as hookr-1's does. This differs from the root of this repository (0.8.26, cancun). The source is `pragma solidity ^0.8.26` and also compiles with 0.8.26 for cancun, via-IR and legacy.

## Running it

```bash
cd hookr-size-cap
bash pin.sh            # hookr-contracts @ 5ba9dfc9, lib/forge-std @ c179529c, lib/v4-core @ 46c68346
forge test             # 55: 46 pass, 1 fails (testFuzz_kit_root_surchargeWithinCap, the expected one), 8 skipped
forge test --no-match-test testFuzz_kit_root_surchargeWithinCap   # 46 pass, 8 skipped
forge test --match-contract MidasSizeCapAdvisoryTest -vv           # the 32 refuse-path and floor tests with their figures
```

Unaudited, nothing deployed.
