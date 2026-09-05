# MarketHoursGuardHook

Prepared by Midas

Source: `src/MarketHoursGuardHook.sol`. Tests: `test/MarketHoursGuardHook.t.sol`.

## 1. What it does

MarketHoursGuardHook is a Uniswap v4 hook for pools whose quote leg is a tokenized equity. The underlying market keeps a session; the token does not, so an LP quoting through the night is writing a free option to whoever reads the overnight news first. The hook reads `block.timestamp`, classifies the pool into one of five regimes (Open, ClosedSession, Weekend, Holiday, Unconfigured) from a per-pool UTC session table and a per-year holiday bitmap, and applies one of two term sheets: inside the regular session the native LP fee is `OPEN_FEE`; everywhere else it is `CLOSED_FEE` and a per-swap size clamp on the specified amount is enforced. A fixed 0.05% royalty is taken from the specified currency in every regime and held as ERC-6909 claims until anyone pushes it to the immutable recipient; a swap small enough that the royalty rounds to zero pays nothing. The fallback is closed: a pool with no session table, or whose holiday calendar has not been written for the current year, trades on closed terms until its policy holder writes the missing entry.

What it deliberately does not do: it never halts the pool (a small swap succeeds in every regime), it never touches liquidity add or remove, it does not compute daylight-saving shifts, it does not read any oracle, and it does not let anyone change fees, ceilings, the royalty rate, or where the royalty goes.

## 2. Hook permission flags

`getHookPermissions()` returns `beforeInitialize`, `beforeSwap` and `beforeSwapReturnDelta` set; every other flag false. In `Hooks.*_FLAG` terms that is `BEFORE_INITIALIZE_FLAG | BEFORE_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG`, which is `(1 << 13) | (1 << 7) | (1 << 3)` = `0x2000 | 0x0080 | 0x0008` = **0x2088**. The test file mines the deployment address with exactly this constant (`FLAGS` in `MarketHoursGuardHook.t.sol`), and it matches the mask the deployed MidasRWAHook uses.

## 3. Authority surface

| Function | Who may call | What it can move | What it cannot move |
|---|---|---|---|
| `setSession(key, openMinute, closeMinute, weekdayMask)` | Pool policy holder (the address that called `initialize`) | Replaces the pool's session table, only inside the immutable envelope | Fees, clamp bounds, royalty, any token |
| `setHolidays(key, year, lo, hi)` | Pool policy holder | Writes the holiday bitmap for the current or a future year; new bitmap must be a superset of the old | Past years (frozen); cannot clear a bit; cannot set bits above day 366 |
| `setClosedMaxSize(key, closedMaxSize)` | Pool policy holder | Sets the closed-regime per-swap clamp within `[CLOSED_SIZE_FLOOR, CLOSED_SIZE_CAP]` | Anything outside the immutable bounds; no effect while open |
| `claimRoyalty(currency)` | Anyone | Redeems `royaltyBucket[currency]` and sends it to `ROYALTY_RECIPIENT` | Cannot redirect; caller receives nothing |
| `unlockCallback(data)` | PoolManager only | Settles claims and takes tokens to `ROYALTY_RECIPIENT` inside `claimRoyalty` | Reverts with `OnlyPoolManager` for any other caller |
| `beforeInitialize` (via PoolManager) | Whoever initializes a dynamic-fee pool | Records the initializer as policy holder | Reverts on static-fee pools and on re-initialization |
| `beforeSwap` (via PoolManager) | PoolManager | Mints the royalty claim, returns the fee override and the BeforeSwapDelta | Cannot exceed `CLOSED_FEE`; reverts with `TradeTooLargeWhileClosed` past the clamp |

There is no setter for `OPEN_FEE`, `CLOSED_FEE`, `ROYALTY_SHARE`, `ROYALTY_RECIPIENT`, `CLOSED_SIZE_FLOOR`, `CLOSED_SIZE_CAP`, or any of the session envelope constants, and there is no owner, no policy-holder transfer, and no upgrade path.

## 4. Parameters and ceilings

Compile-time constants, in pips (1,000,000 = 100%): `MAX_OPEN_FEE = 10_000` (1.00%), `MAX_CLOSED_FEE = 50_000` (5.00%), `ROYALTY_SHARE = 500` (0.05%), `MAX_ROYALTY_SHARE = 1_000` (0.10%). The session envelope, in UTC minutes of the day: `MIN_OPEN_MINUTE = 720` (12:00), `MAX_CLOSE_MINUTE = 1320` (22:00), `MIN_SESSION_MINUTES = 60`, `MAX_SESSION_MINUTES = 480`, `WEEKDAY_MASK_ENVELOPE = 0x3E` (Monday through Friday; Sunday is bit 0, Saturday is bit 6). Convenience defaults `DEFAULT_OPEN_MINUTE = 810` (13:30 UTC) and `DEFAULT_CLOSE_MINUTE = 1200` (20:00 UTC) are exposed but nothing forces their use. The holiday `hi` word may use only its low 110 bits (`HI_WORD_BITS = 366 - 256`).

Constructor immutables and the checks applied to them: `OPEN_FEE <= MAX_OPEN_FEE`; `CLOSED_FEE <= MAX_CLOSED_FEE`; `CLOSED_FEE >= OPEN_FEE`; `CLOSED_SIZE_FLOOR > 0`; `CLOSED_SIZE_FLOOR <= CLOSED_SIZE_CAP`; `ROYALTY_RECIPIENT != address(0)`; and `ROYALTY_SHARE <= MAX_ROYALTY_SHARE` is re-asserted in the constructor even though both are constants. The test suite deploys with `OPEN_FEE = 3_000`, `CLOSED_FEE = 20_000`, `CLOSED_SIZE_FLOOR = 1e15`, `CLOSED_SIZE_CAP = 1e18`. A pool whose `closedMaxSize` was never set uses `CLOSED_SIZE_FLOOR`.

## 5. Invariants and the tests that prove them

| Invariant | Test | What would fail if broken |
|---|---|---|
| Fee is `OPEN_FEE` exactly when open, `CLOSED_FEE` otherwise, never outside `[OPEN_FEE, CLOSED_FEE]` | `testFuzz_closedFeeNeverBelowOpenFee`, `test_closedFee_isChargedOnSwap` | A timestamp where the fee dips below open or above closed; or an identical swap not returning less while closed |
| Unconfigured pool is closed, at every timestamp | `testFuzz_unconfiguredNeverOpens`, `test_unconfigured_isClosed`, `test_unconfigured_whenHolidayYearUnwritten` | Any instant where `isOpen` is true without a session and a written holiday year; or the clamp not biting |
| Holiday calendar is append-only and past years are frozen | `test_holidays_appendOnly`, `testFuzz_holidays_supersetRule`, `test_holidays_pastYearFrozen` | A write that clears a bit succeeding, or a write to a past year succeeding |
| Session table only accepts values inside the envelope | `test_session_rejectsOutsideEnvelope`, `testFuzz_session_envelopeIsExact` | Any `(open, close, mask)` outside the documented predicate being accepted, or a legal one being rejected |
| Only the initializer may configure, and only its own pool | `test_policyHolder_onlyInitializerMayConfigure`, `test_policyHolder_isPerPool` | A stranger configuring a pool, or one holder reaching another pool |
| Weekend and holiday close the pool even inside session minutes | `test_weekend_isClosed`, `test_holiday_isClosed`, `test_closedSession_outsideHours_andBoundaries` | Saturday, Sunday or a declared holiday reporting Open; or the open/close minute boundaries drifting |
| Size clamp applies only while closed and is bounded by the immutables | `test_sizeClamp_onlyWhileClosed`, `test_closedMaxSize_boundedByImmutables` | A large swap passing while closed, or reverting while open; or a clamp outside `[FLOOR, CAP]` being stored |
| Royalty recipient is immutable, claim is permissionless and pays only the recipient | `test_royalty_recipientIsImmutableAndPaid` | Caller receiving funds, recipient not receiving the full bucket, or bucket not draining |
| Pool never halts | `test_neverHalts_smallSwapInEveryRegime` | A sub-clamp swap reverting in any of the five regimes |
| Calendar arithmetic is correct across leap and century rules | `test_civilDate_knownDates`, `testFuzz_civilDate_dayOfYearIsContiguous`, `testFuzz_holidays_everyDayAddressable` | A wrong day-of-year or weekday, a day-of-year that does not advance by one, or a day that cannot be marked |
| `regimeOf`, `isOpen` and `currentFee` agree with an independent recomputation | `testFuzz_regimeConsistentWithIsOpenAndFee` | Any divergence between the three views or from the from-scratch regime |
| Constructor ceilings bite | `test_constructor_enforcesCeilings` | An out-of-ceiling deployment succeeding |
| Static-fee pools are refused; `unlockCallback` is manager-only | `test_revertsOnStaticFeePool`, `test_unlockCallback_onlyPoolManager` | A static-fee pool initializing, or a stranger entering the settlement path |

## 6. Failure cases and open problems

Daylight-saving time is not computed. The session is a plain UTC minute pair and the policy holder must re-point it twice a year. Between the exchange's shift and the update, the NatSpec states the pool applies closed terms to the newly open hour and open terms to the newly closed hour, which is up to 60 minutes of open-terms exposure outside the real session. An adopter who wants zero exposure must update the day before the shift.

The size clamp has no oracle. It is applied to `|amountSpecified|` in the units of the specified currency, so for an exact-input swap of the base token it measures base units, not quote notional. The NatSpec says to set the clamp for the leg the adopter most fears being hit on overnight and to accept that the other leg is bounded only loosely. The clamp is also trivially split across several swaps; it is a rate-of-damage limiter, not a hard cap.

The conservative fallback cuts both ways. A holiday calendar that is not rewritten each year drops the pool to closed terms on January 1 (`test_unconfigured_whenHolidayYearUnwritten`). A holiday once declared can never be undeclared, so a mistaken bit closes that day for that year, permanently. The policy holder is the address that called `initialize`, and there is no transfer or recovery path for it: if that key is lost, the session table can never be re-pointed for DST and no future year's calendar can be written, so the pool trades on closed terms from the next January 1 forever.

The royalty is taken in every regime, including closed, on the specified amount. On exact-output swaps it is taken from the output currency, following the MidasRWAHook pattern. The accrual is guarded on a non-zero amount, so any swap whose specified amount is below 2,000 units rounds to zero and pays no royalty at all.

The test file's fuzz over regimes bounds timestamps to 2026 through 2030 for coverage; timestamps before 1970 are unsupported by construction (`CivilDate` is restricted to non-negative inputs).

## 7. Status

Status: compiles under solc 0.8.26 via_ir, 28/28 Foundry tests passing, bytecode 8,135 bytes runtime. Not deployed. Unaudited.

## 8. Where it fits in the Hookr stack

This is a standalone hook rather than a composable block: it owns the fee override, takes its own delta, and carries its own royalty, so it is a complete term sheet for one pool type. That pool type is the one MidasRWAHook (stock-token quote, `0xC97C22C241EcD0B9fb5656307e47C8a674ee2088`) explicitly leaves unprotected: its README states it has no oracle and no circuit breaker, that the quote asset's underlying market is closed nights and weekends while the pool trades continuously, and that LPs bear that gap risk unpriced. MarketHoursGuardHook is the direct answer to that limitation, and it borrows MidasRWAHook's `beforeSwap` accrual pattern, its `0x2088` permission mask, and its `last != 0` style guards. It has little to do for GoldStandardHook (PAXG quote, `0xA0E75Ca3470638AF11417e0EAC79a1f50129e0cC`), since a gold-backed quote does not carry an exchange session in the same way. The minimal Policy Envelope it uses (a per-pool policy holder moving three parameters inside immutable walls) is the same pattern PolicyEnvelopeHook generalizes.
