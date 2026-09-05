# TimeWeightedExitHook

Prepared by Midas

Source: `src/TimeWeightedExitHook.sol`. Tests: `test/TimeWeightedExitHook.t.sol`.

## 1. What it does

TimeWeightedExitHook prices the exit rather than the entry. Anti-snipe launch windows make the first buyers pay; nothing in the standard toolkit makes the first sellers pay. This hook stamps each address on its first buy in a pool, then charges that address a sell fee that starts at `EXIT_FEE_START` at its own minute zero and decays linearly to `BASE_FEE` over `DECAY_SECONDS` of holding. Buys always pay `BASE_FEE`, at every moment, for every address.

The entire sell surcharge is returned as the pool's native dynamic LP fee. The hook does not set the return-delta flag, mints no ERC-6909 claims, holds no balance, and has no bucket, no claim function, and no recipient. There is no royalty, no deployer share and no author share, so there is no fee interest to disclose. Flipping is not banned; it pays the people who stayed, and the people who stayed are the liquidity providers. The NatSpec is explicit that this is meant to replace a supply cap, not to stack on top of one.

An address that sells without ever having bought through the pool, because it received the tokens by transfer, by airdrop, or through a router that did not identify it, has no stamp. It pays the full `EXIT_FEE_START` and is stamped at that moment, so its clock starts on its first sell rather than never starting. That is the conservative fallback: unknown means launch-level fee, not zero fee.

One thing must be configured after deployment, because v4's `initialize()` carries no hookData: which leg of the pair is the launched token. The pool's deployer declares it once with `setLaunchSide`, and until it is declared every swap on that pool reverts. A pool whose sell side is undefined does not trade.

## 2. Hook permission flags

`getHookPermissions()` returns `beforeInitialize` and `beforeSwap` set; every other flag false, including `beforeSwapReturnDelta`. In `Hooks.*_FLAG` terms that is `BEFORE_INITIALIZE_FLAG | BEFORE_SWAP_FLAG`, which is `(1 << 13) | (1 << 7)` = `0x2000 | 0x0080` = **0x2080**. The test file mines the deployment address with exactly this constant (`FLAGS` in `TimeWeightedExitHook.t.sol`).

The absent return-delta flag is the design statement. This hook cannot take a delta, so it cannot take value, so the whole of whatever it charges is the native LP fee and reaches liquidity providers through v4's own accounting. That is the structural difference from PolicyEnvelopeHook and MarketHoursGuardHook, both of which run at `0x2088` because both take a share in kind.

## 3. Authority surface

| Function | Who may call | What it can move | What it cannot move |
|---|---|---|---|
| `setLaunchSide(key, tokenIsZero)` | Only the pool's deployer, the address that called `initialize` | Declares once which leg is the launched token, which defines the sell direction | Reverts with `LaunchSideAlreadySet` on any second call, including one that would set the same value; cannot be undone or corrected |
| `beforeInitialize` (via PoolManager) | Whoever initializes a dynamic-fee pool | Records that sender as the pool's deployer | Reverts with `NotDynamicFee` on static-fee pools and `AlreadyInitialized` on re-initialization |
| `beforeSwap` (via PoolManager) | PoolManager | Stamps the trader if unstamped, returns the fee override | Reverts with `LaunchSideNotSet` until the launch side is declared; cannot exceed `EXIT_FEE_START`, cannot fall below `BASE_FEE` |
| `exitFeeFor`, `firstBuyOf`, `feeSchedule`, `poolConfig`, `firstBuy` | Anyone | Nothing; views only | Nothing |

That is the entire mutable surface: one one-shot declaration per pool, and two PoolManager callbacks. There is no owner, no ownership transfer, no proxy, no fallback, no setter for `BASE_FEE`, `EXIT_FEE_START` or `DECAY_SECONDS`, and no way for the deployer, an adopter, or the author to take anything out of the contract, because there is never anything in it. `test_noSetter_scheduleImmutable` exercises every external call the contract has and asserts the schedule reads back unchanged afterwards.

## 4. Parameters and ceilings

Compile-time ceilings the constructor cannot exceed, in pips (1,000,000 = 100%): `MAX_BASE_FEE = 10_000` (1.00%) and `MAX_EXIT_FEE_START = 100_000` (10.00%). The holding period is bounded by `MIN_DECAY_SECONDS = 1 hours` and `MAX_DECAY_SECONDS = 30 days`.

Constructor immutables and the checks applied to them: `_baseFee <= MAX_BASE_FEE`; `_exitFeeStart <= MAX_EXIT_FEE_START`; `_exitFeeStart >= _baseFee`; `_decaySeconds` inside `[MIN_DECAY_SECONDS, MAX_DECAY_SECONDS]`. All four bounds are inclusive, and `test_constructor_acceptsBoundaryValues` deploys both extreme corners to prove it: `(10_000, 100_000, 1 hours)` and `(0, 0, 30 days)`.

The test suite runs the documented defaults: `BASE = 10_000` (1.00%), `START = 80_000` (8.00%), `DECAY = 3 days`. The decay is linear and flat afterwards: for elapsed time below `DECAY_SECONDS` the fee is `EXIT_FEE_START - (EXIT_FEE_START - BASE_FEE) * elapsed / DECAY_SECONDS`, and at or past `DECAY_SECONDS` it is exactly `BASE_FEE`, forever. The trader identity comes from `hookData` when it is exactly 32 bytes and decodes to an address, and falls back to `sender`, the router, otherwise.

## 5. Invariants and the tests that prove them

| Invariant | Test | What would fail if broken |
|---|---|---|
| The sell fee never increases with holding time and always sits in `[BASE_FEE, EXIT_FEE_START]` | `testFuzz_exitFee_monotonicAndBounded` | Any pair of holding times where the later one is dearer, or any quote outside the band |
| The curve is exactly the stated linear ramp: start at stamp, base at `DECAY_SECONDS`, flat after | `test_exitFee_atStampIsStart`, `test_exitFee_midpointIsLinear`, `test_exitFee_atDecayIsBase` | A fee other than `EXIT_FEE_START` at elapsed zero, a midpoint off the line, or the fee moving again a year later |
| The charged fee equals the quoted fee on a real swap, and the override reaches the pool | `test_sell_realSwapPaysDecayedFee`, `test_sell_emitsExitFeeCharged` | A long hold not netting more than a same-size immediate sell, or the emitted fee and elapsed not matching the formula |
| Buys always pay `BASE_FEE`, regardless of stamp state | `test_buy_alwaysBaseFee`, `test_buy_doesNotEmitExitFee` | A fresh, a just-stamped and a long-held wallet getting different buy outputs, or a buy emitting `ExitFeeCharged` |
| An unstamped seller pays the full start fee and its clock starts then | `test_unstampedSeller_paysStartAndGetsStamped`, `test_unstampedSeller_outputMatchesFreshBuyer` | An unstamped sell going cheap, no stamp being written, or its output diverging from a freshly stamped seller's |
| The first buy wins; nothing later moves the stamp | `test_secondBuy_doesNotResetStamp` | A second buy or an intervening sell resetting the clock and cheapening a later exit |
| Stamps are per pool and per address | `test_stamps_arePerPool` | A stamp on one pool being visible on another, or one address's stamp applying to another |
| The hook holds nothing; the whole fee is the native LP fee | `test_hookHoldsNothing_feeIsNativeLP`, `test_lpEarnsTheSurcharge` | Any ERC-20 or ERC-6909 balance at the hook in either currency after a mixed run of swaps, or LP fee growth not scaling with the exit fee |
| `setLaunchSide` is deployer-only and single use, and swaps revert until it is set | `test_setLaunchSide_onlyDeployer`, `test_setLaunchSide_isOneShot`, `test_swapReverts_beforeLaunchSideSet` | A stranger declaring the side, a second call succeeding, or a swap landing on an undeclared pool |
| `tokenIsZero` genuinely flips which direction is the sell | `test_launchSide_flipsSellDirection` | The surcharge landing on the buy leg of a pool whose token is currency1 |
| The trader in `hookData` is stamped, not the router or the caller | `test_hookData_stampsTraderNotRouter` | The router or the EOA caller being stamped when a trader was forwarded |
| Malformed or empty `hookData` falls back to the router, visibly | `test_emptyHookData_treatsRouterAsTrader`, `test_malformedHookData_fallsBackToRouter` | A four-byte payload being decoded as an address, or the fallback silently stamping something else |
| The constructor refuses every schedule outside the hardcoded ceilings | `testFuzz_constructor_enforcesCeilings`, `test_constructor_rejectsBaseAboveCeiling`, `test_constructor_rejectsExitAboveCeiling`, `test_constructor_rejectsExitBelowBase`, `test_constructor_rejectsDecayOutOfBounds`, `test_constructor_acceptsBoundaryValues` | An out-of-ceiling deployment succeeding, or a legal boundary deployment being refused |
| The schedule is immutable and reads back after every path | `test_constructor_storesSchedule`, `test_noSetter_scheduleImmutable` | Any external call changing `BASE_FEE`, `EXIT_FEE_START` or `DECAY_SECONDS` |
| Static-fee pools are refused | `test_revertsOnStaticFeePool` | A non-dynamic-fee pool initializing on this hook |

## 6. Failure cases and open problems

Trader identity is the weak point, and the NatSpec says so at the top of the contract rather than in a footnote. `beforeSwap` receives `sender`, which is the router, not the end user. Routers that forward the real trader do so in `hookData`; routers that do not leave every one of their users sharing a single stamp. That router's first buyer stamps it, and everyone who later sells through it pays a fee derived from that first stamp, which decays toward `BASE_FEE` and can therefore be lower than a fresh wallet would pay. `test_emptyHookData_treatsRouterAsTrader` demonstrates exactly this: after the decay period the shared router stamp quotes `BASE_FEE` for everyone behind it. `test_malformedHookData_fallsBackToRouter` shows the same outcome for hookData that is not exactly 32 bytes. A router can also simply lie about the trader, and there is no way to verify that from inside a hook. The fee is an economic nudge; it is not access control, and it should not be sold as one.

The clock measures wallet age in the pool, not token ownership. `firstBuy` is written once per address per pool and never moves, and the sell fee is computed from that timestamp, not from when the tokens being sold were acquired. An address that bought a trivial amount at launch and waited out the decay sells at `BASE_FEE` on any quantity thereafter, including tokens transferred in afterwards. The hook cannot see transfers, so nothing prevents routing exits through an aged wallet. This raises the cost and the coordination burden of a fast exit; it does not close the path.

The one-shot launch-side declaration is unforgiving in both directions. If the deployer never calls `setLaunchSide`, every swap on that pool reverts permanently, and since the hook takes no liquidity permissions the only remaining action on that pool is removing liquidity. If the deployer calls it with the wrong boolean, the mistake is permanent and it inverts the entire mechanism: buys are charged the decaying surcharge and sells pay `BASE_FEE`. There is no correction path, no second call, and no error state the contract can detect, because both values are valid for some pool. `test_setLaunchSide_isOneShot` confirms that even a repeat call with the same value reverts.

The constructor accepts a schedule of zero. `test_constructor_acceptsBoundaryValues` deploys `(0, 0, 30 days)` successfully, so a hook that charges nothing on buys and nothing on sells is a legal deployment of this contract. As with the envelope in PolicyEnvelopeHook, the guarantee is that the published schedule is the one that will hold, not that the published schedule is meaningful. A reviewer must read the constructor arguments.

Buys are not free. `BASE_FEE` is charged on every entry as well as on every fully decayed exit, so a launch that also wants a zero-fee entry cannot get it from this hook without setting `BASE_FEE` to zero, which also sets the floor every exit decays to at zero.

Unlike MarketHoursGuardHook, this hook does halt: `beforeSwap` reverts with `LaunchSideNotSet` before the declaration, and the PoolManager surfaces that as a wrapped hook failure rather than the named error. Time is `block.timestamp` only, with no oracle and no block-number fallback, so the decay is subject to the same second-scale proposer influence as any timestamp-based schedule; at a three-day ramp that is immaterial, at the one-hour minimum decay it is a larger fraction of the curve.

One test-harness note that a reviewer reproducing these results will hit: under via_ir the optimizer may common-subexpression the `TIMESTAMP` opcode within a single call frame, so `vm.warp(block.timestamp + x)` twice in a row does not advance twice. The test file reads the clock through `vm.getBlockTimestamp()` throughout for that reason. It is a property of the test scaffolding, not of the contract.

## 7. Status

Status: compiles under solc 0.8.26 via_ir, 30/30 Foundry tests passing, bytecode 4,790 bytes runtime. Not deployed. Unaudited.

Initcode is 5,767 bytes.

## 8. Where it fits in the Hookr stack

This is the smallest of the proposed hooks by some distance, 4,790 bytes of runtime against PolicyEnvelopeHook's 7,714, and the reason is that it holds nothing. No bucket, no claim path, no unlock callback, no royalty. Everything it charges is the native LP fee, which makes it the cleanest block in the set to compose with something else: it occupies `beforeInitialize` and `beforeSwap` and returns only a fee override, so the only real conflict with another hook is the fee override itself.

It is the launch-side counterpart to PolicyEnvelopeHook rather than a competitor to it. PolicyEnvelopeHook answers who may move a fee and by how much; TimeWeightedExitHook answers who should pay it and when, with a schedule nobody can move at all. A launch that wants both would have to choose, since both own the override, and the honest framing for a builder is that these are two answers to one slot.

Against the deployed hooks the relationship is one of contrast. GoldStandardHook (PAXG quote, `0xA0E75Ca3470638AF11417e0EAC79a1f50129e0cC`) and MidasRWAHook (stock-token quote, `0xC97C22C241EcD0B9fb5656307e47C8a674ee2088`), both verified on Robinhood Chain and both unaudited, quote assets with an outside reference price, where a punitive exit fee is a bad idea because it widens the gap to that reference. This hook is for the case those two do not serve: a launched token with no outside price, where the only thing anchoring the first days is who is willing to wait.
