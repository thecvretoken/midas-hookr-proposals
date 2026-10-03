# SweepGuard

The three sweep rails from MidasRWAHook as a library, with the 09-22 route fix built in, run against the four attacks that matter for a fee-conversion or buyback path. Since 2 Oct it also carries a per-conversion size cap, a bounded recovery path, and a non-reverting preview for read-only callers.

Author: Midas. Status: UNAUDITED, not deployed. Source `src/libraries/SweepGuard.sol`. Tests `test/SweepGuard.t.sol` (18, the pure core, four of them fuzzed), and against a live v4 PoolManager `test/SweepGuardScenarios.t.sol` (12), `test/SweepGuardSizeAndRecovery.t.sol` (11), `test/SweepGuardIntegration.t.sol` (4) and `test/SweepGuardInvariants.t.sol` (6, five of them stateful invariants). Every figure below comes from the `-vv` logs of those files.

## What it is

A contract that converts its own balance through a pool it does not control calls the guard around the swap. The guard takes the route and that route's seeded reference as inputs. It refuses a second conversion on the same route inside `interval`, refuses a route whose spot sits more than `bandBps` from the reference (compared on sqrtPriceX96), caps how much one conversion may move, and puts a floor under the realised output.

A route has no reference until it is sealed with a seed, and an unsealed route is refused. That is the 09-22 fix generalised. No path remains where the first conversion adopts whatever spot the caller presents. Seal the route list in a constructor, expose no setter, and the route set is fixed for the life of the contract.

The core is pure. `next(route, params, spot, now)` reverts or returns the state to store, `capIn(...)` returns the largest conversion allowed, `minOut(...)` returns the floor, and `reseedNext(...)` returns a recovered route, so a read-only block can evaluate all of them while the contract that settles stores the result. `preview(...)` runs the whole admission sequence and returns a `Status` instead of reverting. `seal`, `admit` and `reseed` are the storage forms. `test/utils/GuardedSweeper.sol` is a complete consumer in about a hundred and twenty lines.

```solidity
struct Params { uint32 interval; uint16 bandBps; uint16 floorBps; uint8 smoothing; bool anchorFloor; uint16 maxDriftBps; uint16 maxImpactBps; }
struct Route  { uint160 seed; uint64 lastAt; uint160 ref; uint64 reseededAt; uint128 maxIn; }
struct ReseedWalls { uint16 maxStepBps; uint32 minInterval; uint32 minStall; }
enum Status { Ok, NotSeeded, NotInitialized, TooSoon, OutOfBand, NothingConvertible }
struct Quote { Status status; uint256 amountIn; uint256 floorOut; uint160 refUsed; Route next; }

function seal(Route storage r, uint160 seedSqrtPriceX96, uint128 maxIn) internal;     // once per route
function next(Route memory r, Params memory p, uint160 spot, uint256 nowTs) internal pure returns (Route memory);
function admit(Route storage r, Params memory p, uint160 spot) internal returns (uint160 refUsed);
function status(Route memory r, Params memory p, uint160 spot, uint256 nowTs) internal pure returns (Status);
function preview(Route memory r, Params memory p, uint160 spot, uint128 liquidity, bool zeroForOne, uint256 balance, uint256 nowTs) internal pure returns (Quote memory);
function capIn(Route memory r, Params memory p, uint128 liquidity, uint160 spot, bool zeroForOne) internal pure returns (uint256);
function minOut(Params memory p, uint256 amountIn, bool zeroForOne, uint160 spot, uint160 refUsed) internal pure returns (uint256);
function enforce(uint256 out, uint256 floorOut) internal pure;
function reseedNext(Route memory r, ReseedWalls memory w, uint160 target, uint256 nowTs) internal pure returns (Route memory);
function reseed(Route storage r, ReseedWalls memory w, uint160 target) internal returns (uint160 newRef);
function quote(uint256 amountIn, bool zeroForOne, uint160 sqrtPriceX96) internal pure returns (uint256);
function spotOf(IPoolManager pm, PoolKey memory route) internal view returns (uint160);
function liquidityOf(IPoolManager pm, PoolKey memory route) internal view returns (uint128);
```

Deployed values: `interval` 1 hour, `bandBps` 1000 (10% in sqrt), `floorBps` 300, `smoothing` 4. Everything beyond the deployed rails is off by default. `anchorFloor` quotes the floor at the stored reference as well as at spot and takes the stricter, which answers the floor quoting the moved spot. `maxDriftBps` clamps the reference to within that distance of its seed, which stops the slow walk. `maxImpactBps` and the per-route `maxIn` cap one conversion's size. `reseed` is the recovery path, covered below.

## Results

Route: hookless v4 pool, 0.30% fee, L = 1e21 across ticks -60000..60000 at price 1, about 1,000 tokens of each side in range. The attacker always pushes as far as the guard admits, to the band edge or, with the anchored floor, to the deepest price a conversion still clears. Shortfall is measured against an honest conversion of the same size at the fair price. Attacker P&L is in tokens at price 1, after route fees.

| Scenario | Config | Size vs depth | Shortfall | Attacker P&L |
|---|---|---|---|---|
| Pump-sweep-dump, adverse edge +10% sqrt (+21% price) | deployed | 0.1% | 17.34% | -0.40 |
| Pump-sweep-dump, adverse edge -10% sqrt (-19% price) | deployed | 0.1% | 18.99% | -0.45 |
| Pump-sweep-dump | anchored floor | 0.1% | 2.61%, edge reverts | -0.06 |
| Same-tx sandwich | deployed | 1% | 18.92% | +1.35 on a 10-token bucket |
| Same-tx sandwich | anchored floor | 1% | 1.74%, edge reverts | +0.24 |
| Slow walk, 24 hourly | deployed | 0.1% each | 18.99% at #1, 30.40% at #4, 74.71% at #24 | -47.35 cumulative |
| Slow walk, 24 hourly | anchored floor | 0.1% each | 2.61% at #1, 16.31% at #24 | -5.15 |
| Slow walk, 24 hourly | anchored, 2% drift cap | 0.1% each | 2.61% at #1, held at 6.46% from #12 | -3.04 |

Legit large move, nothing manipulated. As deployed, tokenOut getting 20% dearer is out of band and honest conversions stall; 15% is admitted and the reference follows to 0.9805. With the anchored floor a real 5% adverse move stalls and 2% clears. A favourable 15% move clears under both.

Routing. A same-pair pool on another fee tier has a fresh PoolId and no seed, and is refused before the bucket is touched.

## What the numbers say

The band sets the bound. At the deployed 10% a single conversion can be pushed 17.3% or 19.0% short, depending on which side of the pair is being bought, because the band is symmetric in sqrt and price is its square. The 3% floor never fires there. It is quoted at the moved spot, so all it can see is the route fee and the trade's own impact.

The cooldown limits frequency only. Pump, convert and dump fit inside one transaction, so nothing is held across a block. Whether that pays comes down to conversion size against route depth. At 0.1% of depth the round-trip fees cost the attacker more than the bucket loses; at 1% the attacker nets about 13% of the bucket. On a 0.30% route the break-even sits near 0.3% of depth.

The reference can be walked. It only learns from prices seen at conversion time, and an attacker who owns those prints moves it 2.5% in sqrt per conversion. From the fourth, an honest conversion at the fair price is out of band and only the attacker can convert. Nothing in the deployed rails bounds this over time. In practice the attacker's fee bill does, 47 tokens across 24 rounds at this depth.

Anchoring the floor to the reference shrinks the adverse side to roughly the floor, about 2.6% per conversion here, and slows the walk about sevenfold. A drift cap stops the walk outright. The cost is liveness. A real adverse move larger than the floor stalls the path, and with no oracle there are two ways out: the price coming back, or a trusted re-seed.

## Size cap

A sandwich around one conversion costs the attacker about fee x depth x push for the two legs and takes about size x 2 x push from the bucket. The push cancels. So the sandwich pays only when one conversion is larger than roughly the route fee times the route's depth, whatever the band. `maxImpactBps` expresses that directly: the largest conversion whose own impact on sqrt price, at the pool's active liquidity, stays within that many bps. Set it at or under the route fee and the sandwich is a loss at any push. The rest of the bucket waits for the next interval.

Measured with a same-tx sandwich at the band edge against a 100-token bucket on the 0.30% route:

| maxImpactBps | Converted per call | Attacker P&L |
|---|---|---|
| 15 | 1.67 | -0.31 |
| 30 | 3.34 | +0.01 |
| 60 | 6.71 | +0.68 |
| 120 | 13.50 | +2.07 |

Break-even lands on the 0.30% fee, as the arithmetic says it should. The 1% bucket case that netted the attacker +1.35 above loses 0.31 with the cap at 15 bps, and 8.33 of its 10 tokens stay in the bucket for later intervals. Honest flow converts in slices of about 1.5 tokens per interval here, each within bounty, fee and impact of fair.

Active liquidity has a weakness of its own: anyone can add it just in time. Pump the route to the edge, park a large narrow position at the pumped price, and the measured depth balloons, the impact cap with it, and the conversion fills against that position at the bad price. With only the impact cap the attacker nets +1.28 on a 10-token bucket. The per-route ceiling `maxIn`, fixed at seal, does not move, and the same attack loses 0.35 with it set at 1.5 tokens. Set `maxIn` at the same level as the impact cap, computed from the depth you expect honest liquidity to hold, and let the impact cap tighten below it when the pool thins.

## Recovery

`reseed` moves a route's reference and seed toward a target by at most `maxStepBps`, no more often than `minInterval`, and only after the route has admitted nothing for `minStall`. The consumer decides who may call it. Spot alone cannot tell a real move from a staged one, so recovery needs an authority, and the walls keep that authority narrow. It cannot touch a route that is converting normally, cannot jump, and cannot hurry.

Measured with walls of 5% per step, one hour between steps and a six-hour stall. A real move to sqrt 0.8 (price 0.64) after an honest conversion stalls the route out of band. The authority is refused before the six hours are up, a second step inside the hour is refused, and anyone but the authority is refused. Three steps take the reference to 0.95, 0.9025 and 0.857, the band then admits the market, the conversion clears, and the reference follows to 0.843. With the anchored floor and a 2% drift cap, a real 5% move stalls at the floor, one step re-anchors the seed at the market, the conversion clears, and the drift cap holds around the new seed.

## Other fee tiers and prices

The rule carries over to every route tried. Same-tx sandwich at the band edge, attacker P&L in bps of the converted slice's value, from `test_feeRule_holdsAcrossFeeTiersAndPrices`. Tick -195000 is a raw price near 3.3e-9, where an 18-decimal token trades against a 6-decimal one.

| Route fee | Price | Cap at half the fee | Cap at twice the fee |
|---|---|---|---|
| 0.05% | 1 | -2814 | +994 |
| 0.05% | tick -195000 | -2814 | +994 |
| 0.30% | 1 | -1883 | +1011 |
| 0.30% | tick -195000 | -1883 | +1011 |
| 1.00% | 1 | -1938 | +1059 |
| 1.00% | tick -195000 | -1938 | +1059 |

Price drops out exactly, as the arithmetic says it should. Half of 5 bps rounds down to 2, which is why the 0.05% row loses more.

## Hooked and dynamic-fee routes

The attacker pays the fee in force when he trades, which on a hooked route need not be the nominal one. `test_dynamicFeeRoute_calibrateFromTheLowestFee` runs a dynamic-fee route quoting 0.30% whose hook drops to 0.05%. With the cap calibrated to half the nominal fee (15 bps) the sandwich clears +1314 bps of the slice. Calibrated to half the 0.05% floor (2 bps) it loses 2814. Set `maxImpactBps` from the lowest fee the route can charge. On a Hookr route that is the floor of its policy envelope, not the fee it usually shows.

## Read-only callers

`preview` returns a `Quote`: the status, the amount a conversion may take, its floor, the reference used and the state to store if it settles. Nothing reverts, so a read-only block, a keeper or a UI can ask whether a conversion would go through and on what terms. `status` is the single set of checks behind both paths, so `preview` and `next` cannot drift apart; `testFuzz_preview_neverDisagreesWithNext` checks that across random route states, spots, times, depths and balances, including that every refusal maps to the error `next` would revert with. The reference consumer exposes it as the view `previewSweep`, and `test_preview_matchesWhatTheSweepDoes` holds it to the real sweep: the same amount, a floor the fill clears, the state that gets stored, and `TooSoon`, `OutOfBand` and `NotSeeded` exactly where the sweep refuses.

## Gas

Cold storage, as a real transaction sees it, on the 0.30% route (`test_gas_whatTheGuardCostsPerConversion`). The guard steps alone (read spot and depth, size the cap, admit, quote and enforce the floor) cost about 23,000 gas. `previewSweep` costs about 26,000. A whole sweep through the reference consumer, swap and settlement included, costs about 155,000.

## Compatibility

`bash compat.sh` compiles every library function against v4-core at the commit `deps.sh` pins, which is Uniswap's current main, and at the v4.0.0 release, with solc 0.8.24, 0.8.26 and 0.8.37, legacy and via-IR. All twelve builds pass. The library imports nothing whose location changed between those versions, so the SwapParams move that stopped gold-standard compiling cannot reach it. The reference consumer and the tests use the current layout.

## Random sequences

`test/SweepGuardInvariants.t.sol` hands a fuzzer six actions: an attacker moving the route up to 15% per trade, arbitrage back to fair, keeper sweeps, time jumps of up to three hours, fees arriving in the bucket, and reseed attempts, half of them re-anchoring to the market and half aimed anywhere from half to double the reference. Five properties are checked after every step: no conversion exceeds the ceiling, admitted conversions are at least an interval apart, the reference stays inside the drift cap, every reseed stays inside its walls, and every token is accounted for (the bucket loses only what sweeps take, the keeper receives exactly the bounty, the sweeper never holds output). Each property ran 64 sequences of 64 actions, 20,480 actions in all, with no violation. One seeded run of 600 steps checks all five after each step and reports what it exercised: 26 admitted conversions, the largest exactly the 1.5-token ceiling, 16 reseeds allowed and 98 refused by the walls, the largest step exactly the 5% wall.

## For fee conversion and buyback

Anchored floor on, drift cap on, `maxImpactBps` at or under half the lowest fee the route can charge with `maxIn` at the same level for each route, and `reseed` behind the policy envelope, as a capsule that may move a route's seed by a bounded step at a bounded rate. That is the authority shape the envelope already gives the fee. A read-only block calls `preview`; whatever settles calls `admit` and stores the result.

The cap turns the cooldown into a throughput limit. Fee accrual faster than one capped slice per interval builds up in the bucket, and the answer then is a shorter interval rather than a bigger slice, since each slice is unprofitable to attack on its own.

## Authority surface

The library holds no authority and no balances. In the reference consumer `GuardedSweeper` there is no owner, no setter and no upgrade path. Routes, seeds, ceilings, parameters and walls are fixed at construction. One authority address may call `reseed`, and that is the whole of its power. It cannot change a ceiling, a parameter, a route or where output goes, and it cannot act on a route that is converting normally. `test_authority_canOnlyReseed_noSetterSelectorsExist` calls twelve plausible setter and upgrade signatures as the authority and as an outsider, every one reverts, and the guard's state is byte-identical afterwards.

The trust that remains is the target. An authority acting in bad faith on a stalled route can walk the reference by `maxStepBps` per `minInterval`, and no further. Choose the walls with that in mind.

## Parameters

`validate` enforces 0 < `bandBps` < 10,000, `floorBps` < 10,000, `smoothing` >= 1, `maxDriftBps` < 10,000, `maxImpactBps` < 10,000, and 0 < `maxStepBps` < 10,000 for the walls. Tighter ceilings belong to the consumer. Values used in the tests: interval 1 hour, band 1000, floor 300, smoothing 4, drift cap 200, impact cap 15 bps on a 0.30% route, `maxIn` 1.5 tokens against about 1,000 tokens of depth, walls 500 bps per step, one hour apart, after a six-hour stall. `floorBps` has to clear the route fee plus a slice's impact, because the quote ignores both.

## Invariants and the test that proves each

| Invariant | Test |
|---|---|
| An unsealed route is refused before anything moves | `test_unseededRouteRefused`, `test_attackerRoute_unseededIsRefused` |
| Sealing is one-shot and the seed is non-zero | `test_seed_isOneShotAndNonZero` |
| One admitted conversion per route per interval, and a capped remainder cannot be pulled early | `test_cooldown`, `test_sizeCap_remainderCannotBeDrainedInsideTheInterval` |
| Spot outside the band never converts | `test_bandEdgesInclusive`, `test_legitLargeMove_asDeployed` |
| The reference moves a quarter step, stays between reference and spot, and inside the drift cap | `test_referenceMovesAQuarterStep`, `testFuzz_referenceStaysBetweenRefAndSpot`, `test_driftCapClampsReference` |
| Realised output never falls below the floor, and the anchored floor is quoted at the reference | `test_minOut_spotFloorTracksMovedSpot_anchorDoesNot`, `test_pumpSweepDump_anchoredFloor`, `test_sameTx_anchoredFloor` |
| Converting `capIn` never moves sqrt price past `maxImpactBps` at constant liquidity | `testFuzz_capIn_neverExceedsItsImpact`, `test_capIn_impactMatchesTarget` |
| No conversion exceeds the seal-time ceiling, including when liquidity is inflated just in time | `test_capIn_ceilingAndOff`, `test_sizeCap_jitLiquidityBeatsImpactCap_ceilingHolds` |
| A sandwich loses with the cap at or under the route fee | `test_sizeCap_breakEvenSitsAtTheRouteFee`, `test_sizeCap_turnsTheProfitableSameTxCaseIntoALoss` |
| The cap shrinks when liquidity leaves, and no active liquidity converts nothing | `test_sizeCap_shrinksWhenLiquidityLeaves`, `test_sizeCap_zeroActiveLiquidityConvertsNothing` |
| A reseed moves at most one step, never inside the interval, never within the stall window, and never touches the ceiling or the conversion clock | `testFuzz_reseed_wallsHoldOverAnySequence`, `test_reseed_wallsHold`, `test_reseed_stepIsClampedAndReanchors` |
| The authority can only reseed | `test_authority_canOnlyReseed_noSetterSelectorsExist` |
| A real move recovers in bounded steps | `test_recovery_reseedWalksTheReferenceToARealMove`, `test_recovery_anchoredFloorWithDriftCap` |
| `preview` never disagrees with `next`, and matches the real sweep | `testFuzz_preview_neverDisagreesWithNext`, `test_preview_matchesWhatTheSweepDoes` |
| The fee rule holds at every fee tier and price tried, and on a dynamic-fee route when calibrated to its lowest fee | `test_feeRule_holdsAcrossFeeTiersAndPrices`, `test_dynamicFeeRoute_calibrateFromTheLowestFee` |
| Ceiling, interval, drift cap, reseed walls and token accounting hold across random sequences | `invariant_*` and `test_sixHundredRandomSteps_everyInvariantHoldsAtEveryStep` in `test/SweepGuardInvariants.t.sol` |

## Failure cases

Every one fails closed. A refused conversion leaves value in the bucket and traps nobody.

A real move past the band, or past the floor when anchored, stalls conversions until the price returns or the authority reseeds. A cap calibrated to a dynamic-fee route's nominal fee rather than its lowest lets the sandwich pay when the fee drops (`test_dynamicFeeRoute_calibrateFromTheLowestFee`). Depth concentrated right at spot over a thin floor makes the impact cap overshoot, since it assumes constant liquidity across its move, and the floor refuses the fill; `maxIn` sized to the depth inside the cap's range is the remedy (`test_sizeCap_constantLiquidityAssumption_floorIsTheBackstop`). No active liquidity at spot converts nothing. A floor under the route fee refuses every conversion. A fee-on-transfer input token fails to settle with the PoolManager and reverts. Accrual faster than one slice per interval builds up in the bucket.

## What testing turned up

With no active liquidity at spot the cap is zero, and the first version of the reference consumer passed a zero amount to the PoolManager, which reverted with v4's own error. Same outcome, unclear reason. It now refuses with `NothingConvertible` before unlocking. Uncapped, the same pool lets the swap jump to the next initialized tick, and only the floor stops it.

The impact cap's constant-liquidity assumption fails on a pool that is deep only right at spot. The floor catches it and `maxIn` fixes it, so it is documented as a limit rather than patched.

Under via-IR, `block.timestamp` read inside a loop around `vm.warp` can be cached, which once sent a test's clock backwards. The loops now track time locally. No result changed.

## The 09-22 14% case

`sweep-route-0922/test/Case14Replay.t.sol` replays it with the original helpers and pins both totals to the reported figures (`forge test --match-test test_case14_replay -vv`).

Route: GOLD against currency0, 0.30% fee, L = 1e18 across ticks -60000..60000, opened at price 1 and seeded at 1. GOLD sorts as token1, so the adverse edge is the lower one. Each sweep converts 52,237,500,000,000 (a 52,500,000,000,000 bucket less the 0.5% bounty), about 0.005% of depth, so its own impact is negligible.

| | Sweep 1 | Sweep 2 |
|---|---|---|
| Reference before, sqrt | 1.000000 | 0.985005 |
| Lower band edge | 0.900000 | 0.886504 |
| Route spot before the push | 1.000000 | 0.940970 |
| Attacker push, currency0 in | 6.4e16 | 3.2e16 |
| Spot at sweep, sqrt / price | 0.940019 / 0.883636 | 0.913545 / 0.834564 |
| GOLD out | 46,018,215,902,932 | 43,462,703,083,906 |
| GOLD out, clean run | 52,078,075,232,830 | 52,072,651,263,460 |
| Shortfall | 11.64% | 16.53% |
| Reference after | 0.985005 | 0.967140 |

Totals: 89,480,918,986,838 against 104,150,726,496,290 clean, 14.09% short.

The attacker steps, as the test runs them. Before each sweep, a currency0-in push starts at 1e15 and doubles until the next doubling would land within 0.5% of the lower edge, and the last push that stayed outside that margin is applied. Then the sweep. Then a "restore" of a single 1e15 swap back, which barely moves the price, so sweep 2 starts from 0.941 and lands deeper.

The 14% is the band-edge mechanism measured short of the edge. Sweep 1 sat about 60% of the way to the edge in sqrt, sweep 2 about 80%. Pushed all the way, as the scenarios above do, this token order gives 19.0% and the other gives 17.4%.

## Running it

```bash
bash deps.sh                       # every dependency at a pinned commit
forge test                         # 182: the 131 plus 51 for the guard
bash compat.sh                     # the library against v4-core main and v4.0.0, solc 0.8.24 to 0.8.37
cd sweep-route-0922 && forge test  # 29: the 28 from 09-22 plus the replay
```
