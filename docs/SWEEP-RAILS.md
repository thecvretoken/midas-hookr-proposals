# Three rails for a permissionless sweep

Hardening a hook-owned conversion against a pool the hook does not control.

Author: Midas
Status: implemented and deployed inside MidasRWAHook (Robinhood Chain, 0xC97C22C241EcD0B9fb5656307e47C8a674ee2088), unaudited, never adopted by a third-party pool. Extracted here because the rails are useful apart from that hook.

---

## The problem these solve

A hook accrues fee value in some currency and needs to convert it into another asset through a pool. There are two ways to do it.

Inline, on every swap. This adds gas to every trade, and it makes the conversion perfectly predictable, so it can be sandwiched every single time. It is the obvious design and it is the wrong one.

Batched, through a permissionless entry point anyone can call. This is the right shape. It moves the cost off the swap path and lets a keeper pay the gas in exchange for a bounty. But it creates a new problem: the hook is now offering to trade its own balance, at whatever price the route pool happens to show, to anyone who asks. Push the route, call the sweep, pull the route back.

The standard answer is to read a time-weighted price instead of spot. That answer is not available here, and it is worth being precise about why.

v4 has no built-in oracle. Observations are something an oracle hook maintains, and a hook maintains them for the pool it is attached to. The route pool is not this hook's pool. It may have no oracle hook at all, it may have one with an interface this hook has never heard of, and in either case the hook has no way to require it, because the route is supplied by the caller at call time. `getSlot0` is the whole of what can be read, and `getSlot0` is spot.

So the design constraint is: spot is all you get, the entry point must stay open to anyone, and the funds are already in the contract. The three rails below are what that leaves.

---

## Rail 1: per-route rate limit

One sweep per route per hour. Keyed on the route's `PoolId`, not globally, so a hook converting through several routes is not starved when one of them is on cooldown.

```solidity
uint256 public constant MIN_SWEEP_INTERVAL = 1 hours;
mapping(PoolId => uint64) public lastSweepAt;

uint64 last = lastSweepAt[routeId];
if (last != 0 && block.timestamp < uint256(last) + MIN_SWEEP_INTERVAL) revert SweepTooSoon();
```

What it buys: it converts a one-block attack into a sustained one. Without it, the whole exploit is atomic. Flash loan, move the route, sweep, move it back, repay, all inside one transaction with no price risk. With it, an attacker who wants two sweeps at a manipulated price has to hold that price across an hour of open arbitrage, funded, against everyone else on the chain. The attack does not become impossible, it becomes an inventory position.

Two implementation notes that cost me time:

The `last != 0` guard is load bearing. Without it the check reads `block.timestamp < MIN_SWEEP_INTERVAL`, which is false on any real chain and therefore looks fine, but is true on a fresh test chain where the timestamp starts near zero. The first-ever sweep silently reverts only in tests. That is the worst possible place for a bug to live.

`block.timestamp` is the right clock here. The guard is hour scale and validator drift is seconds. There is nothing to gain from shaving a few seconds off a one-hour cooldown, so the usual objection does not apply.

## Rail 2: self-maintained reference band, in sqrt space

The hook keeps its own slow reference price per route. A sweep is only allowed if route spot sits inside a band around that reference, and every sweep drags the reference part of the way toward the spot it just used.

```solidity
uint256 public constant MAX_REF_DEVIATION_BPS = 1_000; // 10%
uint256 internal constant REF_SMOOTHING = 4;           // ref = (3*ref + spot) / 4
mapping(PoolId => uint160) public refSqrtPriceX96;

uint160 ref = refSqrtPriceX96[routeId];
if (ref != 0) {
    uint256 hi = (uint256(ref) * (BPS + MAX_REF_DEVIATION_BPS)) / BPS;
    uint256 lo = (uint256(ref) * (BPS - MAX_REF_DEVIATION_BPS)) / BPS;
    if (spot > hi || spot < lo) revert RoutePriceDeviates();
}

refSqrtPriceX96[routeId] =
    ref == 0 ? spot : uint160((uint256(ref) * (REF_SMOOTHING - 1) + uint256(spot)) / REF_SMOOTHING);
```

Three things make this worth writing up rather than reaching for an external oracle.

It costs nothing to maintain. There is no keeper heartbeat, no feed subscription, no staleness check, no fallback path for when the feed goes dark. The reference is sampled exactly when it is used and at no other time, so it cannot go stale in any way that matters. A price that is only consulted during sweeps only needs to be correct during sweeps.

It composes with rail 1 to price manipulation in time rather than capital. One sweep moves the reference a quarter of the way. Walking the reference from P to 2P is not one trade, it is a sequence of steps, each capped at the band, each separated by the cooldown, each one an hour of holding a wrong price in public. Rail 2 bounds the size of a step and rail 1 bounds how often you get to take one. Neither does that alone.

The comparison is in sqrt space on purpose. It is done on `sqrtPriceX96` directly, not on a derived price, which means a band of N percent in sqrt is roughly 2N percent in price, because price is the square. The 10 percent constant is therefore about a 21 percent price band. That is deliberately generous. The failure mode of a tight band is that honest sweeps stop working in a volatile pair and the value never converts, and I would rather be loose and functional than tight and bricked. The generosity is the thing to argue about, not the sqrt space, which is just where the data already lives and saves a squaring.

The honest weak point: `ref == 0` means unset, and the first sweep on a route adopts spot without any band check. Rail 2 does not protect the first sweep. Rail 3 and the caller's own minimum are what cover that case.

## Rail 3: slippage floor against pre-swap spot

Quote the swap at the pre-swap sqrt price, take a floor under that quote, execute, and revert if the realised output came in below the floor.

```solidity
uint256 public constant MAX_SWEEP_SLIPPAGE_BPS = 300; // 3%

uint256 floorOut = (_quoteAtSpot(route, c, amountIn, spot) * (BPS - MAX_SWEEP_SLIPPAGE_BPS)) / BPS;
// ... unlock, swap ...
if (goldOut < floorOut) revert SweepSlippage();
if (goldOut < minGoldOut) revert InsufficientGoldOut();
```

This is not the same thing as the caller-supplied minimum, and keeping both is the point. `minGoldOut` protects the caller. In a permissionless sweep the caller is a keeper who is paid a bounty for calling and has no stake in the hook getting a good price, so the caller's minimum can be set to 1 and the transaction still pays. The floor is the hook protecting itself from its own keeper. The keeper's minimum is layered on top for the keeper's own reasons.

The quote is deliberately an upper bound. `_quoteAtSpot` is pure geometry off the sqrt price and ignores both the route's fee and the curve impact of the trade, so the 3 percent band is absorbing three different things at once: real price movement between quote and fill, the route's fee tier, and the hook's own price impact. That has a consequence worth stating plainly rather than discovering later. On a 1 percent route the band left over for actual movement is nearer 2 percent, and on a fat-fee route this rail will brick sweeps outright. The constant has to be tuned against the fee tier of the routes the hook expects to use, or the quote has to be made fee-aware.

Rail 3 also catches the case the first two structurally cannot: the sweep is large and the route is shallow, so the hook's own trade is the price move. Spot is honest, the reference band passes, the cooldown passes, and the execution is still terrible. Nothing about manipulation is involved. Only a check on realised output sees it.

---

## How they compose

Three rails because there are three different adversaries, and each rail is bypassable alone.

| | one-block manipulator | patient manipulator | shallow route or oversized sweep |
| --- | --- | --- | --- |
| Rate limit | catches | no | no |
| Reference band | catches | raises cost per step | no |
| Slippage floor | partial | partial | catches |

The rate limit denies atomicity. The reference band denies a large single step and makes a sequence of small ones expensive in time. The slippage floor is the only one that does not care about manipulation at all and simply refuses a bad fill.

All three fail closed, and failing closed is safe here for a specific reason that does not generalise: the value being swept is fee accrual sitting in a bucket. A refused sweep delays a conversion, it does not lose anything or trap a user. If you lift these rails into a path where somebody is waiting on the output, the fail-closed default has to be reconsidered, because there the cost of not acting is no longer zero.

---

## Parameters

| Constant | Value here | What moves it |
| --- | --- | --- |
| `MIN_SWEEP_INTERVAL` | 1 hour | Accrual rate. Fast accrual wants a shorter interval or the bucket outgrows what the route can absorb in one trade. |
| `MAX_REF_DEVIATION_BPS` | 1000, so 10% in sqrt, about 21% in price | Route volatility. Tighten on a stable pair, loosen on a volatile one. Tight enough to brick honest sweeps is worse than loose. |
| `REF_SMOOTHING` | 4, so a quarter step per sweep | How many periods you want a walk to take. Higher is slower to follow real moves as well as fake ones. |
| `MAX_SWEEP_SLIPPAGE_BPS` | 300 | Route fee tier plus expected impact at typical sweep size. Must exceed the fee tier or nothing ever sweeps. |
| `KEEPER_BOUNTY` | 50 bps of the swept amount | Gas cost on the chain. Low enough and nobody calls it. |

---

## Coverage

The rails are exercised by `test_sweep_setsReferenceAndRateLimits`, `test_sweep_rejectsDeviatedRoute`, `test_sweep_referenceStartsUnset`, `test_sweep_respectsMinGoldOut`, `test_sweep_hookRetainsNothing`, and `test_sweep_burnsToDeadAndPaysKeeper`, plus the entry-point reverts for a non-gold route, gold as input, an empty bucket, and an uninitialised route. 25 tests pass on the hook overall. It is unaudited.

## What generalises

Nothing above depends on what is being converted, on burning, or on how the fee was split before it landed in the bucket. The shape is: a contract holding value, a permissionless function that converts that value through a pool the contract does not control, and no trustworthy price feed for that pool. Any hook with that shape can take all three rails as written and retune the four constants.

The part I would not reuse without thought is the sqrt-space band on a pool whose price can legitimately move an order of magnitude, since a band wide enough to permit that is wide enough to be worthless. In that case the reference needs to move on something other than sweeps.
