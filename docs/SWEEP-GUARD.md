# SweepGuard

The three sweep rails from MidasRWAHook as a library, with the 09-22 route fix built in, run against the four attacks that matter for a fee-conversion or buyback path.

Author: Midas. Status: UNAUDITED, not deployed. Source `src/libraries/SweepGuard.sol`. Tests `test/SweepGuard.t.sol` (11, the pure core) and `test/SweepGuardScenarios.t.sol` (12, against a live v4 PoolManager). Every figure below comes from `forge test --match-path test/SweepGuardScenarios.t.sol -vv`.

## What it is

A contract that converts its own balance through a pool it does not control calls the guard around the swap. The guard takes the route and that route's seeded reference as inputs. It refuses a second conversion on the same route inside `interval`, refuses a route whose spot sits more than `bandBps` from the reference (compared on sqrtPriceX96), and puts a floor under the realised output.

A route has no reference until it is sealed with a seed, and an unsealed route is refused. That is the 09-22 fix generalised. No path remains where the first conversion adopts whatever spot the caller presents. Seal the route list in a constructor, expose no setter, and the route set is fixed for the life of the contract.

The core is pure. `next(route, params, spot, now)` reverts or returns the state to store, and `minOut(...)` returns the floor, so a read-only block can evaluate both while the contract that settles stores the result. `seal` and `admit` are the storage forms. `test/utils/GuardedSweeper.sol` is a complete consumer in about a hundred lines.

```solidity
struct Params { uint32 interval; uint16 bandBps; uint16 floorBps; uint8 smoothing; bool anchorFloor; uint16 maxDriftBps; }
struct Route  { uint160 seed; uint160 ref; uint64 lastAt; }

function seal(Route storage r, uint160 seedSqrtPriceX96) internal;     // once per route
function next(Route memory r, Params memory p, uint160 spot, uint256 nowTs) internal pure returns (Route memory);
function admit(Route storage r, Params memory p, uint160 spot) internal returns (uint160 refUsed);
function minOut(Params memory p, uint256 amountIn, bool zeroForOne, uint160 spot, uint160 refUsed) internal pure returns (uint256);
function enforce(uint256 out, uint256 floorOut) internal pure;
function quote(uint256 amountIn, bool zeroForOne, uint160 sqrtPriceX96) internal pure returns (uint256);
function spotOf(IPoolManager pm, PoolKey memory route) internal view returns (uint160);
```

Deployed values: `interval` 1 hour, `bandBps` 1000 (10% in sqrt), `floorBps` 300, `smoothing` 4. Two options sit beyond the deployed rails, both off by default. `anchorFloor` quotes the floor at the stored reference as well as at spot and takes the stricter, which answers the floor quoting the moved spot. `maxDriftBps` clamps the reference to within that distance of its seed, which stops the slow walk.

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

## For fee conversion and buyback

Anchored floor on, drift cap on, and re-seeding behind the policy envelope, as a capsule that may move a route's seed by a bounded step at a bounded rate. That is the authority shape the envelope already gives the fee.

One rail is not built yet: a cap on conversion size relative to the route's in-range liquidity, which the guard can read from the pool. Size against depth decides whether manipulation pays at all, so the next bound belongs there.

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
forge test                         # 154: the 131 plus 23 for the guard
cd sweep-route-0922 && forge test  # 29: the 28 from 09-22 plus the replay
```
