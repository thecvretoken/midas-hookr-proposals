// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {MarketHoursGuardHook, CivilDate} from "../src/MarketHoursGuardHook.sol";

/// @notice Tests for MarketHoursGuardHook. Run with `forge test -vv`.
///
/// Every timestamp below is a known UTC instant computed off-chain:
///   2026-09-09 (Wednesday, day-of-year 252), 2026-09-12 (Saturday), 2026-09-13 (Sunday),
///   2026-12-25 (Friday, day-of-year 359, NYSE holiday), 2027-01-01 (Friday).
contract MarketHoursGuardHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    MarketHoursGuardHook hook;
    PoolId id;

    // NOTE: `key` is inherited from Deployers — do not redeclare it here.

    address royalty = address(0xFEE5);
    address stranger = address(0xBEEF);

    uint24 constant OPEN_FEE = 3_000; // 0.30%
    uint24 constant CLOSED_FEE = 20_000; // 2.00%
    uint128 constant SIZE_FLOOR = 1e15;
    uint128 constant SIZE_CAP = 1e18;

    uint16 constant OPEN_MIN = 13 * 60 + 30; // 13:30 UTC
    uint16 constant CLOSE_MIN = 20 * 60; // 20:00 UTC
    uint8 constant MON_FRI = 0x3E;

    // Known instants (UTC).
    uint256 constant WED_1500 = 1788966000; // 2026-09-09 15:00 Wed
    uint256 constant WED_0300 = 1788922800; // 2026-09-09 03:00 Wed
    uint256 constant WED_1329 = 1788960540; // one minute before the open
    uint256 constant WED_1330 = 1788960600; // the open
    uint256 constant WED_1959 = 1788983940; // last open minute
    uint256 constant WED_2000 = 1788984000; // the close
    uint256 constant SAT_1500 = 1789225200; // 2026-09-12 15:00 Sat
    uint256 constant SUN_1500 = 1789311600; // 2026-09-13 15:00 Sun
    uint256 constant XMAS_1500 = 1798210800; // 2026-12-25 15:00 Fri, doy 359
    uint256 constant JAN1_2027 = 1798761600; // 2027-01-01 00:00 Fri
    // Day-of-year 359 lives in the `hi` word (days 257..366): bit 359 - 257 = 102.
    uint256 constant XMAS_HI = uint256(1) << (359 - 257);

    int256 constant SMALL = 1e14; // below SIZE_FLOOR
    int256 constant LARGE = 5e15; // above SIZE_FLOOR, below SIZE_CAP

    uint160 constant FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        deployCodeTo(
            "MarketHoursGuardHook.sol:MarketHoursGuardHook",
            abi.encode(manager, royalty, OPEN_FEE, CLOSED_FEE, SIZE_FLOOR, SIZE_CAP),
            address(FLAGS)
        );
        hook = MarketHoursGuardHook(address(FLAGS));

        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        id = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    /// @dev Standard configuration: NYSE hours, Mon-Fri, Christmas 2026 as the only holiday.
    function _configure(PoolKey memory k) internal {
        hook.setSession(k, OPEN_MIN, CLOSE_MIN, MON_FRI);
        hook.setHolidays(k, 2026, 0, XMAS_HI);
    }

    /// @dev PoolManager wraps hook reverts in CustomRevert.WrappedError; build the exact bytes.
    function _wrappedTooLarge(uint256 amount, uint256 max) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(MarketHoursGuardHook.TradeTooLargeWhileClosed.selector, amount, max),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _seedLiquidity(PoolKey memory k) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e18, salt: 0}), ""
        );
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amount) internal {
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _freshKey(int24 spacing) internal returns (PoolKey memory k) {
        k = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, spacing, IHooks(address(hook)));
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
    }

    function _regime(PoolKey memory k) internal view returns (MarketHoursGuardHook.Regime) {
        return hook.regimeOf(k);
    }

    function _assertRegime(PoolKey memory k, MarketHoursGuardHook.Regime expected, string memory why) internal view {
        assertEq(uint8(_regime(k)), uint8(expected), why);
    }

    /// @dev Runs the constructor at a flag-valid address and returns whether it succeeded.
    ///      Used to prove the ceilings bite; `new` cannot be used because BaseHook validates
    ///      the deployment address's flag bits.
    function _tryDeploy(
        uint24 openFee,
        uint24 closedFee,
        uint128 floor,
        uint128 cap,
        address recipient,
        uint160 salt
    ) internal returns (bool ok) {
        address where = address(FLAGS | (salt << 24));
        bytes memory code = abi.encodePacked(
            type(MarketHoursGuardHook).creationCode, abi.encode(manager, recipient, openFee, closedFee, floor, cap)
        );
        vm.etch(where, code);
        (ok,) = where.call("");
    }

    // -----------------------------------------------------------------
    // Calendar routine
    // -----------------------------------------------------------------

    /// @dev Civil-date inverse checked against known dates, including a leap day, the last
    ///      day of a leap year, the 2000 and 2100 century rules, and the Unix epoch.
    function test_civilDate_knownDates() public view {
        _checkDate(0, 1970, 1, 1, 1, 4); // Thursday
        _checkDate(1709164800, 2024, 2, 29, 60, 4); // leap day, Thursday
        _checkDate(1735603200, 2024, 12, 31, 366, 2); // Tuesday
        _checkDate(951868800, 2000, 3, 1, 61, 3); // 2000 is a leap year, Wednesday
        _checkDate(4107542400, 2100, 3, 1, 60, 1); // 2100 is not, Monday
        _checkDate(WED_1500, 2026, 9, 9, 252, 3); // Wednesday
        _checkDate(XMAS_1500, 2026, 12, 25, 359, 5); // Friday
        _checkDate(1798675200, 2026, 12, 31, 365, 4); // Thursday
        _checkDate(JAN1_2027, 2027, 1, 1, 1, 5); // Friday
        _checkDate(SAT_1500, 2026, 9, 12, 255, 6);
        _checkDate(SUN_1500, 2026, 9, 13, 256, 0);
    }

    function _checkDate(uint256 ts, uint256 y, uint256 m, uint256 d, uint256 doy, uint256 wd) internal view {
        (uint256 year, uint256 month, uint256 day, uint256 dayOfYear, uint256 weekday) = hook.civilDate(ts);
        assertEq(year, y, "year");
        assertEq(month, m, "month");
        assertEq(day, d, "day");
        assertEq(dayOfYear, doy, "dayOfYear");
        assertEq(weekday, wd, "weekday");
    }

    /// @dev Day-of-year advances by exactly one per day and wraps to 1 at a year boundary.
    function testFuzz_civilDate_dayOfYearIsContiguous(uint256 ts) public view {
        ts = bound(ts, 0, 20_000 * 365 days);
        (uint256 y0,,, uint256 doy0, uint256 wd0) = hook.civilDate(ts);
        (uint256 y1,,, uint256 doy1, uint256 wd1) = hook.civilDate(ts + 1 days);

        assertEq(wd1, (wd0 + 1) % 7, "weekday advances by one");
        assertGe(doy0, 1, "doy lower bound");
        assertLe(doy0, 366, "doy upper bound");
        if (y1 == y0) {
            assertEq(doy1, doy0 + 1, "same year: doy + 1");
        } else {
            assertEq(y1, y0 + 1, "year advances by one");
            assertEq(doy1, 1, "new year starts at doy 1");
            assertEq(doy0, CivilDate.isLeapYear(y0) ? 366 : 365, "old year ended on its last day");
        }
    }

    // -----------------------------------------------------------------
    // Regimes
    // -----------------------------------------------------------------

    /// @dev I2: a pool nobody configured is closed — closed fee, and the size clamp bites.
    function test_unconfigured_isClosed() public {
        _seedLiquidity(key);
        vm.warp(WED_1500); // would be open if configured

        _assertRegime(key, MarketHoursGuardHook.Regime.Unconfigured, "no session table");
        assertFalse(hook.isOpen(key));
        assertEq(hook.currentFee(key), CLOSED_FEE, "unconfigured pays closed fee");
        assertEq(hook.closedMaxSizeOf(key), SIZE_FLOOR, "unconfigured clamp is the floor");

        vm.expectRevert(_wrappedTooLarge(uint256(LARGE), uint256(SIZE_FLOOR)));
        _swap(key, true, -LARGE);
    }

    /// @dev I2 (calendar lapse): a session table alone is not enough — the current year's
    ///      holiday bitmap must have been written, or the pool falls back to closed.
    function test_unconfigured_whenHolidayYearUnwritten() public {
        _configure(key); // writes 2026 only
        vm.warp(WED_1500);
        _assertRegime(key, MarketHoursGuardHook.Regime.Open, "2026 configured");

        vm.warp(JAN1_2027 + 15 hours); // Friday 15:00 UTC 2027, inside session hours
        _assertRegime(key, MarketHoursGuardHook.Regime.Unconfigured, "2027 bitmap never written");
        assertEq(hook.currentFee(key), CLOSED_FEE);

        hook.setHolidays(key, 2027, 0, 0); // "no holidays" lifts the fallback
        _assertRegime(key, MarketHoursGuardHook.Regime.Open, "2027 now configured");
    }

    function test_open_insideSession() public {
        _configure(key);
        vm.warp(WED_1500);
        _assertRegime(key, MarketHoursGuardHook.Regime.Open, "Wednesday 15:00 UTC");
        assertTrue(hook.isOpen(key));
        assertEq(hook.currentFee(key), OPEN_FEE);
    }

    function test_closedSession_outsideHours_andBoundaries() public {
        _configure(key);

        vm.warp(WED_0300);
        _assertRegime(key, MarketHoursGuardHook.Regime.ClosedSession, "03:00 UTC");
        assertEq(hook.currentFee(key), CLOSED_FEE);

        vm.warp(WED_1329);
        _assertRegime(key, MarketHoursGuardHook.Regime.ClosedSession, "13:29 is before the open");
        vm.warp(WED_1330);
        _assertRegime(key, MarketHoursGuardHook.Regime.Open, "13:30 is the open (inclusive)");
        vm.warp(WED_1959);
        _assertRegime(key, MarketHoursGuardHook.Regime.Open, "19:59 is the last open minute");
        vm.warp(WED_2000);
        _assertRegime(key, MarketHoursGuardHook.Regime.ClosedSession, "20:00 is the close (exclusive)");
    }

    /// @dev I6: Saturday and Sunday are closed even though the table is valid and the
    ///      minute-of-day is inside the session.
    function test_weekend_isClosed() public {
        _configure(key);

        vm.warp(SAT_1500);
        _assertRegime(key, MarketHoursGuardHook.Regime.Weekend, "Saturday 15:00 UTC");
        assertFalse(hook.isOpen(key));
        assertEq(hook.currentFee(key), CLOSED_FEE);

        vm.warp(SUN_1500);
        _assertRegime(key, MarketHoursGuardHook.Regime.Weekend, "Sunday 15:00 UTC");
        assertEq(hook.currentFee(key), CLOSED_FEE);
    }

    function test_holiday_isClosed() public {
        _configure(key);
        vm.warp(XMAS_1500); // Friday, in session hours, but a declared holiday
        _assertRegime(key, MarketHoursGuardHook.Regime.Holiday, "Christmas 2026");
        assertFalse(hook.isOpen(key));
        assertEq(hook.currentFee(key), CLOSED_FEE);

        // The day before is an ordinary open Thursday.
        vm.warp(XMAS_1500 - 1 days);
        _assertRegime(key, MarketHoursGuardHook.Regime.Open, "Christmas Eve is a trading day here");
    }

    // -----------------------------------------------------------------
    // Policy envelope
    // -----------------------------------------------------------------

    /// @dev I3: bits can be added but never cleared, in either word.
    function test_holidays_appendOnly() public {
        _configure(key); // 2026: hi = XMAS_HI

        // Adding bits is fine: Thanksgiving (doy 330 -> hi bit 73) and New Year (doy 1 -> lo bit 0).
        uint256 thanksgivingHi = uint256(1) << (330 - 257);
        uint256 newYearLo = 1;
        hook.setHolidays(key, 2026, newYearLo, XMAS_HI | thanksgivingHi);
        MarketHoursGuardHook.Holidays memory h = hook.holidaysOf(key, 2026);
        assertTrue(h.written);
        assertEq(h.lo, newYearLo);
        assertEq(h.hi, XMAS_HI | thanksgivingHi);
        assertTrue(hook.isHoliday(key, 2026, 1));
        assertTrue(hook.isHoliday(key, 2026, 330));
        assertTrue(hook.isHoliday(key, 2026, 359));
        assertFalse(hook.isHoliday(key, 2026, 2));

        // Clearing Christmas (hi word) reverts.
        vm.expectRevert(MarketHoursGuardHook.HolidayBitmapNotSuperset.selector);
        hook.setHolidays(key, 2026, newYearLo, thanksgivingHi);

        // Clearing New Year (lo word) reverts.
        vm.expectRevert(MarketHoursGuardHook.HolidayBitmapNotSuperset.selector);
        hook.setHolidays(key, 2026, 0, XMAS_HI | thanksgivingHi);

        // Writing all-zero over a non-zero calendar reverts.
        vm.expectRevert(MarketHoursGuardHook.HolidayBitmapNotSuperset.selector);
        hook.setHolidays(key, 2026, 0, 0);

        // Bits above day 366 are rejected.
        vm.expectRevert(MarketHoursGuardHook.HolidayBitmapInvalid.selector);
        hook.setHolidays(key, 2026, newYearLo, XMAS_HI | thanksgivingHi | (uint256(1) << 110));

        // Rewriting the identical calendar is a no-op that succeeds.
        hook.setHolidays(key, 2026, newYearLo, XMAS_HI | thanksgivingHi);
    }

    /// @dev Past years are frozen: once the clock is in 2027, 2026 cannot be touched.
    function test_holidays_pastYearFrozen() public {
        _configure(key);
        vm.warp(JAN1_2027);
        vm.expectRevert(MarketHoursGuardHook.HolidayYearFrozen.selector);
        hook.setHolidays(key, 2026, 1, XMAS_HI);

        // Current and future years are writable.
        hook.setHolidays(key, 2027, 1, 0);
        hook.setHolidays(key, 2030, 1, 0);
    }

    /// @dev I4: every edge of the envelope rejects.
    function test_session_rejectsOutsideEnvelope() public {
        // open before 12:00 UTC
        vm.expectRevert(MarketHoursGuardHook.SessionOutOfBounds.selector);
        hook.setSession(key, 11 * 60 + 59, 18 * 60, MON_FRI);
        // close after 22:00 UTC
        vm.expectRevert(MarketHoursGuardHook.SessionOutOfBounds.selector);
        hook.setSession(key, 14 * 60, 22 * 60 + 1, MON_FRI);
        // shorter than 1h
        vm.expectRevert(MarketHoursGuardHook.SessionOutOfBounds.selector);
        hook.setSession(key, 14 * 60, 14 * 60 + 59, MON_FRI);
        // longer than 8h
        vm.expectRevert(MarketHoursGuardHook.SessionOutOfBounds.selector);
        hook.setSession(key, 12 * 60, 20 * 60 + 1, MON_FRI);
        // inverted
        vm.expectRevert(MarketHoursGuardHook.SessionOutOfBounds.selector);
        hook.setSession(key, 18 * 60, 14 * 60, MON_FRI);
        // weekend bit (Saturday)
        vm.expectRevert(MarketHoursGuardHook.SessionOutOfBounds.selector);
        hook.setSession(key, OPEN_MIN, CLOSE_MIN, MON_FRI | 0x40);
        // weekend bit (Sunday)
        vm.expectRevert(MarketHoursGuardHook.SessionOutOfBounds.selector);
        hook.setSession(key, OPEN_MIN, CLOSE_MIN, MON_FRI | 0x01);

        // The extreme legal table is accepted: 12:00-20:00 and 14:00-22:00.
        hook.setSession(key, 12 * 60, 20 * 60, MON_FRI);
        hook.setSession(key, 14 * 60, 22 * 60, MON_FRI);
        MarketHoursGuardHook.Session memory s = hook.sessionOf(key);
        assertEq(s.openMinute, 14 * 60);
        assertEq(s.closeMinute, 22 * 60);
        assertTrue(s.set);
    }

    /// @dev I4 (fuzz): the envelope check is exactly the documented predicate.
    function testFuzz_session_envelopeIsExact(uint16 open, uint16 close, uint8 mask) public {
        open = uint16(bound(open, 0, 1440));
        close = uint16(bound(close, 0, 1440));

        bool legal = open >= hook.MIN_OPEN_MINUTE() && close <= hook.MAX_CLOSE_MINUTE() && close > open
            && (close - open) >= hook.MIN_SESSION_MINUTES() && (close - open) <= hook.MAX_SESSION_MINUTES()
            && (mask & ~hook.WEEKDAY_MASK_ENVELOPE()) == 0;

        if (!legal) vm.expectRevert(MarketHoursGuardHook.SessionOutOfBounds.selector);
        hook.setSession(key, open, close, mask);

        if (legal) {
            MarketHoursGuardHook.Session memory s = hook.sessionOf(key);
            assertEq(s.openMinute, open);
            assertEq(s.closeMinute, close);
            assertEq(s.weekdayMask, mask);
        }
    }

    /// @dev DST handling: the policy holder can re-point an existing table inside the envelope.
    function test_session_canBeReplacedForDST() public {
        _configure(key);
        // US daylight time: 09:30-16:00 ET = 13:30-20:00 UTC (EDT is UTC-4).
        // US standard time: 09:30-16:00 ET = 14:30-21:00 UTC (EST is UTC-5).
        hook.setSession(key, 14 * 60 + 30, 21 * 60, MON_FRI);
        vm.warp(WED_1330);
        _assertRegime(key, MarketHoursGuardHook.Regime.ClosedSession, "13:30 is before the shifted open");
        vm.warp(WED_2000 + 30 minutes);
        _assertRegime(key, MarketHoursGuardHook.Regime.Open, "20:30 is inside the shifted session");
    }

    /// @dev I5: a stranger cannot configure anything; the policy holder can.
    function test_policyHolder_onlyInitializerMayConfigure() public {
        assertEq(hook.policyHolderOf(key), address(this), "initialiser is the policy holder");

        vm.startPrank(stranger);
        vm.expectRevert(MarketHoursGuardHook.NotPolicyHolder.selector);
        hook.setSession(key, OPEN_MIN, CLOSE_MIN, MON_FRI);
        vm.expectRevert(MarketHoursGuardHook.NotPolicyHolder.selector);
        hook.setHolidays(key, 2026, 0, XMAS_HI);
        vm.expectRevert(MarketHoursGuardHook.NotPolicyHolder.selector);
        hook.setClosedMaxSize(key, SIZE_FLOOR);
        vm.stopPrank();

        // Policy holder succeeds at all three.
        hook.setSession(key, OPEN_MIN, CLOSE_MIN, MON_FRI);
        hook.setHolidays(key, 2026, 0, XMAS_HI);
        hook.setClosedMaxSize(key, SIZE_FLOOR * 2);
        assertEq(hook.closedMaxSizeOf(key), SIZE_FLOOR * 2);
    }

    /// @dev A different initialiser gets a different policy holder; pools are independent.
    function test_policyHolder_isPerPool() public {
        vm.prank(stranger);
        PoolKey memory k2 = _freshKey(120);
        assertEq(hook.policyHolderOf(k2), stranger);

        // We (holder of `key`) cannot configure k2, and stranger cannot configure `key`.
        vm.expectRevert(MarketHoursGuardHook.NotPolicyHolder.selector);
        hook.setSession(k2, OPEN_MIN, CLOSE_MIN, MON_FRI);
        vm.prank(stranger);
        vm.expectRevert(MarketHoursGuardHook.NotPolicyHolder.selector);
        hook.setSession(key, OPEN_MIN, CLOSE_MIN, MON_FRI);

        vm.prank(stranger);
        hook.setSession(k2, OPEN_MIN, CLOSE_MIN, MON_FRI);
        assertTrue(hook.sessionOf(k2).set);
        assertFalse(hook.sessionOf(key).set, "configuring k2 did not touch key");
    }

    function test_closedMaxSize_boundedByImmutables() public {
        vm.expectRevert(MarketHoursGuardHook.ClosedSizeOutOfBounds.selector);
        hook.setClosedMaxSize(key, SIZE_FLOOR - 1);
        vm.expectRevert(MarketHoursGuardHook.ClosedSizeOutOfBounds.selector);
        hook.setClosedMaxSize(key, SIZE_CAP + 1);
        vm.expectRevert(MarketHoursGuardHook.ClosedSizeOutOfBounds.selector);
        hook.setClosedMaxSize(key, 0);

        hook.setClosedMaxSize(key, SIZE_FLOOR);
        hook.setClosedMaxSize(key, SIZE_CAP);
        assertEq(hook.closedMaxSizeOf(key), SIZE_CAP);
    }

    // -----------------------------------------------------------------
    // Swaps
    // -----------------------------------------------------------------

    /// @dev I7: the same swap reverts while closed and passes while open; raising the clamp
    ///      inside the envelope lets it pass while closed too.
    function test_sizeClamp_onlyWhileClosed() public {
        _configure(key);
        _seedLiquidity(key);

        vm.warp(WED_0300); // closed session
        vm.expectRevert(_wrappedTooLarge(uint256(LARGE), uint256(SIZE_FLOOR)));
        _swap(key, true, -LARGE);

        // Exact-output is clamped on the specified amount too.
        vm.expectRevert(_wrappedTooLarge(uint256(LARGE), uint256(SIZE_FLOOR)));
        _swap(key, false, LARGE);

        vm.warp(WED_1500); // open
        _swap(key, true, -LARGE); // passes
        _swap(key, false, LARGE); // passes

        // Policy holder widens the clamp (inside the cap) and the closed swap now passes.
        hook.setClosedMaxSize(key, uint128(uint256(LARGE)));
        vm.warp(WED_0300);
        _swap(key, true, -LARGE);
        // ... but one wei more still reverts.
        vm.expectRevert(_wrappedTooLarge(uint256(LARGE) + 1, uint256(LARGE)));
        _swap(key, true, -(LARGE + 1));
    }

    /// @dev I9: the pool never halts. A small swap succeeds in every one of the five regimes.
    function test_neverHalts_smallSwapInEveryRegime() public {
        _seedLiquidity(key);

        vm.warp(WED_1500);
        _assertRegime(key, MarketHoursGuardHook.Regime.Unconfigured, "");
        _swap(key, true, -SMALL);

        _configure(key);
        _assertRegime(key, MarketHoursGuardHook.Regime.Open, "");
        _swap(key, true, -SMALL);

        vm.warp(WED_0300);
        _assertRegime(key, MarketHoursGuardHook.Regime.ClosedSession, "");
        _swap(key, false, -SMALL);

        vm.warp(SAT_1500);
        _assertRegime(key, MarketHoursGuardHook.Regime.Weekend, "");
        _swap(key, true, SMALL);

        vm.warp(XMAS_1500);
        _assertRegime(key, MarketHoursGuardHook.Regime.Holiday, "");
        _swap(key, false, SMALL);
    }

    /// @dev The closed LP fee is actually charged: an identical exact-input swap returns
    ///      less output while closed than while open.
    function test_closedFee_isChargedOnSwap() public {
        _configure(key);
        _seedLiquidity(key);

        vm.warp(WED_1500);
        uint256 before = currency1.balanceOf(address(this));
        _swap(key, true, -SMALL);
        uint256 outOpen = currency1.balanceOf(address(this)) - before;

        vm.warp(WED_0300);
        before = currency1.balanceOf(address(this));
        _swap(key, true, -SMALL);
        uint256 outClosed = currency1.balanceOf(address(this)) - before;

        assertGt(outOpen, outClosed, "closed swap returns less (higher fee)");
        // Sanity on magnitude: the fee gap is 1.7% of a 1e14 swap ~= 1.7e12, price impact negligible.
        assertApproxEqRel(outOpen - outClosed, (uint256(SMALL) * (CLOSED_FEE - OPEN_FEE)) / 1_000_000, 0.05e18);
    }

    // -----------------------------------------------------------------
    // Royalty and guards
    // -----------------------------------------------------------------

    /// @dev I8: the recipient is a constructor immutable. The contract exposes no function
    ///      that writes it (there is no setter in the ABI — see the authority surface in the
    ///      NatSpec), and the permissionless claim pays that address regardless of caller.
    function test_royalty_recipientIsImmutableAndPaid() public {
        assertEq(hook.ROYALTY_RECIPIENT(), royalty, "recipient == constructor arg");
        assertEq(hook.ROYALTY_SHARE(), 500);
        assertLe(hook.ROYALTY_SHARE(), hook.MAX_ROYALTY_SHARE());

        _configure(key);
        _seedLiquidity(key);
        vm.warp(WED_1500);
        _swap(key, true, -LARGE);

        uint256 expected = (uint256(LARGE) * 500) / 1_000_000;
        assertEq(hook.royaltyBucket(currency0), expected, "royalty accrued on specified currency");

        uint256 before = currency0.balanceOf(royalty);
        uint256 strangerBefore = currency0.balanceOf(stranger);
        vm.prank(stranger);
        hook.claimRoyalty(currency0); // permissionless push
        assertEq(currency0.balanceOf(royalty) - before, expected, "immutable recipient paid");
        assertEq(currency0.balanceOf(stranger), strangerBefore, "caller receives nothing");
        assertEq(hook.royaltyBucket(currency0), 0, "bucket drained");

        vm.expectRevert(MarketHoursGuardHook.NothingToClaim.selector);
        hook.claimRoyalty(currency0);
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.prank(stranger);
        vm.expectRevert(MarketHoursGuardHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(currency0, uint256(1)));
    }

    function test_revertsOnStaticFeePool() public {
        PoolKey memory bad = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(bad, TickMath.getSqrtPriceAtTick(0));
    }

    /// @dev Every constructor ceiling bites, and the legal configuration deploys.
    function test_constructor_enforcesCeilings() public {
        assertTrue(_tryDeploy(OPEN_FEE, CLOSED_FEE, SIZE_FLOOR, SIZE_CAP, royalty, 1), "legal config deploys");
        assertFalse(_tryDeploy(10_001, CLOSED_FEE, SIZE_FLOOR, SIZE_CAP, royalty, 2), "open fee > 1%");
        assertFalse(_tryDeploy(OPEN_FEE, 50_001, SIZE_FLOOR, SIZE_CAP, royalty, 3), "closed fee > 5%");
        assertFalse(_tryDeploy(5_000, 4_999, SIZE_FLOOR, SIZE_CAP, royalty, 4), "closed < open");
        assertFalse(_tryDeploy(OPEN_FEE, CLOSED_FEE, 0, SIZE_CAP, royalty, 5), "floor zero");
        assertFalse(_tryDeploy(OPEN_FEE, CLOSED_FEE, SIZE_CAP + 1, SIZE_CAP, royalty, 6), "floor > cap");
        assertFalse(_tryDeploy(OPEN_FEE, CLOSED_FEE, SIZE_FLOOR, SIZE_CAP, address(0), 7), "recipient zero");
        // Boundary values are legal.
        assertTrue(_tryDeploy(10_000, 50_000, 1, 1, royalty, 8), "ceilings themselves are legal");
        assertTrue(_tryDeploy(10_000, 10_000, SIZE_FLOOR, SIZE_CAP, royalty, 9), "closed == open is legal");
    }

    // -----------------------------------------------------------------
    // Fuzz properties
    // -----------------------------------------------------------------

    /// @dev I1: at any timestamp the fee is never below OPEN_FEE, never above CLOSED_FEE,
    ///      equals OPEN_FEE exactly when open and CLOSED_FEE exactly when closed. Together:
    ///      fee(closed) >= fee(open) for every pair of instants.
    function testFuzz_closedFeeNeverBelowOpenFee(uint256 t) public {
        _configure(key);
        hook.setHolidays(key, 2027, 1, 0); // two configured years so both branches are reachable
        vm.warp(bound(t, 0, 4_000_000_000));

        uint24 fee = hook.currentFee(key);
        assertGe(fee, hook.OPEN_FEE(), "never below open fee");
        assertLe(fee, hook.CLOSED_FEE(), "never above closed fee");
        assertLe(fee, hook.MAX_CLOSED_FEE(), "never above ceiling");
        if (hook.isOpen(key)) assertEq(fee, hook.OPEN_FEE());
        else assertEq(fee, hook.CLOSED_FEE());
    }

    /// @dev regimeOf, isOpen and currentFee agree with each other and with a from-scratch
    ///      recomputation of the regime off the same timestamp.
    function testFuzz_regimeConsistentWithIsOpenAndFee(uint256 t, uint256 tOffset) public {
        _configure(key);
        hook.setHolidays(key, 2027, uint256(1) << (1 - 1), 0); // Jan 1 2027 is a holiday (lo bit 0)
        // Concentrate on 2026-2027 so every regime is hit, then spread a little wider.
        t = bound(t, 1_767_225_600 /* 2026-01-01 */, 1_830_297_600 /* 2028-01-01 */);
        t += bound(tOffset, 0, 365 days * 3);
        vm.warp(t);

        MarketHoursGuardHook.Regime r = _regime(key);
        bool open = hook.isOpen(key);
        uint24 fee = hook.currentFee(key);

        assertEq(open, r == MarketHoursGuardHook.Regime.Open, "isOpen <=> regime Open");
        assertEq(fee, open ? OPEN_FEE : CLOSED_FEE, "fee follows regime");

        // Independent recomputation.
        (uint256 year,,, uint256 doy, uint256 wd) = hook.civilDate(t);
        uint256 minute = (t % 86_400) / 60;
        MarketHoursGuardHook.Regime expected;
        if (year != 2026 && year != 2027) expected = MarketHoursGuardHook.Regime.Unconfigured;
        else if (year == 2026 && doy == 359) expected = MarketHoursGuardHook.Regime.Holiday;
        else if (year == 2027 && doy == 1) expected = MarketHoursGuardHook.Regime.Holiday;
        else if (wd == 0 || wd == 6) expected = MarketHoursGuardHook.Regime.Weekend;
        else if (minute < OPEN_MIN || minute >= CLOSE_MIN) expected = MarketHoursGuardHook.Regime.ClosedSession;
        else expected = MarketHoursGuardHook.Regime.Open;
        assertEq(uint8(r), uint8(expected), "regime matches independent recomputation");
    }

    /// @dev I2 (fuzz): with no configuration at all, no timestamp is ever open.
    function testFuzz_unconfiguredNeverOpens(uint256 t) public {
        vm.warp(bound(t, 0, 4_000_000_000));
        assertFalse(hook.isOpen(key));
        _assertRegime(key, MarketHoursGuardHook.Regime.Unconfigured, "");
        assertEq(hook.currentFee(key), CLOSED_FEE);
    }

    /// @dev I3 (fuzz): for any old/new pair, the write succeeds iff new is a superset of old
    ///      in both words.
    function testFuzz_holidays_supersetRule(uint256 lo1, uint256 hi1, uint256 lo2, uint256 hi2) public {
        hi1 = bound(hi1, 0, (uint256(1) << 110) - 1);
        hi2 = bound(hi2, 0, (uint256(1) << 110) - 1);
        hook.setHolidays(key, 2026, lo1, hi1);
        bool superset = (lo2 & lo1) == lo1 && (hi2 & hi1) == hi1;
        if (!superset) vm.expectRevert(MarketHoursGuardHook.HolidayBitmapNotSuperset.selector);
        hook.setHolidays(key, 2026, lo2, hi2);
        MarketHoursGuardHook.Holidays memory h = hook.holidaysOf(key, 2026);
        assertEq(h.lo, superset ? lo2 : lo1);
        assertEq(h.hi, superset ? hi2 : hi1);
    }

    /// @dev Every day-of-year 1..366 can be marked and is reported back through isHoliday,
    ///      and marking one day never marks a neighbour.
    function testFuzz_holidays_everyDayAddressable(uint16 doy) public {
        doy = uint16(bound(doy, 1, 366));
        (uint256 lo, uint256 hi) = doy <= 256 ? (uint256(1) << (doy - 1), uint256(0)) : (uint256(0), uint256(1) << (doy - 257));
        hook.setHolidays(key, 2026, lo, hi);
        assertTrue(hook.isHoliday(key, 2026, doy));
        if (doy > 1) assertFalse(hook.isHoliday(key, 2026, doy - 1));
        if (doy < 366) assertFalse(hook.isHoliday(key, 2026, doy + 1));
    }
}
