# Fee-Stream Collateral

Design spec. Status: memo, not a proposal. Hookr's module registry has no credit slot deployed, so there is no market to build this against yet. The interfaces in `src/interfaces/IFeeStream.sol` and `src/interfaces/IFeeStreamCredit.sol` encode this document; no implementation exists. Everything below is UNAUDITED and must be audited before real money touches it.

## 1. Purpose

A creator who launches a token through a Hookr hook such as `PolicyEnvelopeHook` earns a fee share on every swap (the 25% deployer bucket). Today that share is a claim right locked to one address: whoever initialised the pool calls `claimDeployer` and takes whatever has accrued. It is income, but it is not capital. A creator who needs money now has one option, selling supply, which is the option that hurts holders most.

Fee-Stream Collateral turns the claim right into a stream, a transferable position that receives the deployer bucket of one pool in one quote currency, and then lets the stream holder post that stream as collateral against pool-native credit. The lender advances quote currency. The stream repays the lender out of fees that arrive afterwards. The creator never sells a token, the lender never receives a token, and the launched token is never moved by either contract.

The two pieces are separable. The stream wrapper and the accrual reader are useful on their own, for example to sell or escrow a fee share. The credit line is the part that needs a market.

## 2. Oracle assumptions and valuation

There is no price feed. The only input to valuation is the hook's own accounting, read on chain by the wrapper. The wrapper is the pool's deployer (it calls `initialize` itself, see section 9), so `deployerBucket[poolId][quote]` is its to claim and nobody else's. Each call to `sync` claims that bucket into the wrapper and records the claimed amount against the current epoch. An epoch is one day: `epoch = block.timestamp / 86400`. Accrual is attributed to the epoch in which `sync` ran, not the epoch in which the swaps happened. `sync` is permissionless so the lender can force attribution and the creator cannot hide fees indefinitely; fees left unclaimed in the hook are invisible to valuation, which errs conservative.

Only realised fees count. Projected fees, volume forecasts, token price and TVL never enter. The valuation window is `N = 30` completed epochs. The formula is exact:

```
V = sum over the last N completed epochs of accrual[epoch]
```

where `accrual[epoch]` is the quote-currency amount claimed by `sync` in that epoch. V is denominated in the quote currency and nothing is converted. A pool that quotes in USDC produces a V in USDC; a pool that quotes in a stock token produces a V in that stock token, and the credit line for that stream is denominated in that stock token too. Fees the hook accrues in the launched token are not part of V, are not swept to any lender, and are forwarded to the stream holder untouched (section 7).

The current, incomplete epoch is excluded from V so a burst of wash volume in the last hour before a draw cannot inflate the line. Wash trading over a full 30 day window remains possible; the haircut is what makes it uneconomic.

## 3. Sizing

The credit line for a stream is

```
L = h * V,   h = 25% (2_500 bps)
```

and any draw `d` is refused unless `D + d <= L` where `D` is outstanding debt. `L` is computed and stored at the moment of each draw, never between draws, so `D <= L` is a statement about the last draw and is always true (invariant 2).

The haircut is severe on purpose. Ordinary collateral is haircut for volatility; a fee stream is haircut for correlation. Fee income on a launched token is a function of that token's volume, and volume on a small token collapses in exactly the scenario where the creator would default: when the token dies. The collateral and the borrower's ability to pay are the same variable. A 25% advance rate means the lender is made whole if the next 30 days deliver a quarter of what the last 30 did, plus whatever the reserve holds. Trailing fee income for launched tokens also decays structurally after the launch window, so a flat extrapolation of V overstates the future even absent a crash. 25% leaves room for both.

Interest is charged as a fixed draw fee: each draw `d` adds `d * (1 + f)` to `D`, with `f` immutable per line and bounded by a hardcoded ceiling of 2_000 bps (20%). There is no time-based accrual. A borrower who does not control the repayment schedule must not carry debt that grows on its own; with a draw fee, `D` changes only at draws (up) and at sweeps (down), which makes every invariant below checkable at exactly two code paths.

## 4. Liquidation: the stream is the repayment

There is no forced sale, no auction, no keeper that seizes anything. When `sync` claims a new accrual `a` in the quote currency and a line is outstanding, the amount is split in a fixed order. First a reserve slice `r * a` with `r = 10%` goes to the line's reserve. Then everything remaining goes to the lender until `D` is zero. Only after `D` reaches zero does anything reach the stream holder. Nothing goes to the creator ahead of the lender, ever.

If fees slow down, the line freezes. Let `A_K` be accrual over the last `K = 7` completed epochs and `S` be the service rate, the per-epoch amount needed to retire the debt by maturity:

```
S = D / max(1, maturityEpoch - currentEpoch)
```

Freeze triggers (either is sufficient, evaluated on every `sync` and every `draw`):

```
F1: A_K / K < S
F2: D > R + h * V
```

Unfreeze requires both of the following, evaluated at `sync`, with a 25% hysteresis margin so the line does not flap:

```
U1: A_K / K >= S * 1.25
U2: D <= R + h * V
```

A frozen line accepts no draws. Repayment continues from whatever arrives. Once `currentEpoch >= maturityEpoch` with `D > 0`, the line enters a terminal freeze: the reserve is applied to `D` immediately, the line can never unfreeze, and sweeps continue until `D` is zero. When `D` reaches zero the line closes, the remaining reserve is released to the stream holder, and the stream is unlocked.

## 5. Backstop reserve

The reserve is funded from the stream itself, 10% of every quote accrual while `D > 0`. It exists to cover the gap that opens when V decays after a draw. The reserve invariant is

```
D <= R + h * V
```

where `R` is the reserve balance of the line. It is a precondition of every draw: a draw is refused if the post-draw `D` would violate it. It is also a health condition: if V decays until it fails, the line freezes (F2) and cannot unfreeze until it holds again (U2). At maturity the reserve is applied to the debt in full, so `D` after maturity is at most the unreserved shortfall, which then continues to be serviced by the stream.

The invariant is not a hard global. V is exogenous and can fall faster than R grows. The spec makes that explicit rather than pretending otherwise: what is guaranteed is that no code path lets `D` cross the bound, and that any crossing caused by V is met with a freeze.

## 6. Invariants

Each is stated so that a single test can falsify it.

1. Conservation. For every stream and quote currency, the total ever claimed from the hook into the wrapper equals the total paid to lenders, plus the current reserve balance, plus the total released to stream holders, plus the wrapper's held balance for that stream. Falsified by any unit that cannot be accounted for.
2. Solvency at draw. Immediately after any successful draw, `D <= L` where `L = h * V` was computed in that same call. Falsified by a draw that succeeds with `D > h * V`.
3. Reserve bound at draw. Immediately after any successful draw, `D <= R + h * V`. Falsified by a draw that succeeds with `D > R + h * V`.
4. Debt monotone between draws. `D` increases only inside `draw`. Every other function leaves `D` unchanged or lower. Falsified by any non-draw call that raises `D`.
5. Lender seniority. While `D > 0`, no function transfers quote currency from a stream to its holder. Falsified by a holder receiving quote while a line is outstanding.
6. No forced sale. Neither contract contains a code path that swaps, sells, seizes or transfers the launched token to anyone other than the stream holder, and the credit line contains no code path that touches the launched token at all. Falsified by static inspection: any call into the pool manager's `swap` or any transfer of the base currency from the credit contract.
7. Stream transfer preserves claims. A completed transfer changes only the holder address. Debt, reserve, epoch history, lock state and lender are unchanged. Falsified by any of those fields differing across a transfer.
8. Freeze monotone. A frozen line with `D > 0` and no new accrual since the freeze remains frozen. A line past maturity with `D > 0` never unfreezes. Falsified by an unfreeze without an intervening accrual, or any unfreeze after maturity.
9. No draw while frozen. `draw` reverts whenever the line is frozen. Falsified by a successful draw in frozen state.
10. Lock exclusivity. A stream with an open line cannot be cancelled, unwrapped or pledged to a second line. Falsified by any of those succeeding while `D > 0` or a line is open.
11. Terms immutable. After `open`, the line's lender, fee, maturity and haircut cannot change by any call. Falsified by any function that mutates them.
12. Epoch exclusion. V never includes the current incomplete epoch. Falsified by a draw whose stored L reflects same-epoch accrual.

## 7. Authority

There is no owner and no upgrade path. Every rate above is a constant or a per-line immutable validated against a hardcoded ceiling at `open`.

The stream holder can transfer the stream in two steps: propose, then the recipient accepts. A proposal to `address(0)` cancels. Until acceptance, the current holder keeps every right. The holder can claim the remainder (quote after debt, base at any time) and can call `sync`. The holder cannot redirect fees: there is no function that sets a payout address, and `claimRemainder` pays only the holder of record. While a line is outstanding, the holder cannot unwrap the stream, cannot open a second line, and cannot cancel. Transfer during an outstanding line is permitted because the debt travels with the stream (invariant 7); the buyer takes it subject to the lender's seniority.

The lender's terms are immutable per line. The lender cannot accelerate, cannot seize, cannot change the fee, and cannot force a sync beyond calling the permissionless one. `open` is a two-step handshake: the holder pledges the stream to a named lender with a hash of the terms, and the lender opens the line by funding it with matching terms. Either side can walk away before the other step.

`sync` and `repayFromAccrual` are permissionless. Anyone may cause accrual to be recognised and routed; nobody can change where it goes.

The launched token side of the deployer bucket is forwarded to the stream holder by `sync` and by `claimRemainder`, never valued, never swept, never reserved. Under `PolicyEnvelopeHook` the wrapper also receives the policy capsule at initialisation; it immediately proposes the capsule to the creator and holds no fee-setting authority itself.

## 8. Failure cases and scope

A creator can throttle fees to starve the lender, for example by moving the fee to the envelope floor or by steering volume elsewhere. The design does not prevent this; it bounds the loss to `L` minus reserve and puts the loss on the lender who priced it. A creator can also inflate V with wash volume; the cost is the full swap fee on every wash trade for 30 days to raise a 25% advance, which is negative expected value at any envelope inside `PolicyEnvelopeHook`'s absolute floor of 0.01%. Sync timing can shift accrual between adjacent epochs, which the 30 epoch window and the 7 epoch freeze window are wide enough to absorb.

If the hook is drained, paused or replaced, V goes to zero, the line freezes, and the lender is repaid only from reserve. If the quote token is a rebasing or fee-on-transfer asset, conservation fails; such tokens are out of scope. If the wrapper's `initialize` call front-runs or is front-run, the stream may be attached to the wrong pool; the wrapper checks the returned `PoolId` against the key it was given.

Out of scope: multi-currency valuation, cross-pool netting, interest that accrues with time, partial stream sales, lender pools or tranching, and any secondary market for streams. Also out of scope: a hook-side deployer transfer, which would let existing pools be wrapped after the fact; today only pools initialised through the wrapper can be wrapped.

This design requires an audit before any real money is placed against it. The interfaces are for review, not deployment.

## 9. Mapping into the Hookr modular stack

Two parts are reusable blocks. The stream wrapper (`IFeeStream`: wrap, transfer, accept, claim) is a generic holder of a hook's deployer claim right and depends only on the hook exposing `claimDeployer` and `deployerBucket`, which both `PolicyEnvelopeHook` and `MidasRWAHook` already do. The accrual reader (the epoch bucketing behind `accruedInWindow`) is a pure view over the wrapper's own records and can serve any consumer: a credit line, a revenue-share sale, a dashboard, a DAO treasury.

The credit line (`IFeeStreamCredit`) is standalone. It depends on the stream wrapper's lock and route hooks and on nothing else in Hookr, and it should not be registered until a credit slot exists in the module registry. When that slot exists, the registration should carry the constants (h, r, N, K, hysteresis, fee ceiling, epoch length) as immutables validated against the ceilings in this document, following the Policy Envelope pattern: parameters may vary per line inside walls that cannot move.
