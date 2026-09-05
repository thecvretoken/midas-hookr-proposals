// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title  CivilDate
/// @author Midas
/// @notice Proleptic-Gregorian calendar arithmetic on a Unix timestamp. No leap seconds,
///         no time zones: everything is UTC because block.timestamp is UTC.
///
///         Weekday convention: `weekday = (days + 4) % 7` with 0 = Sunday ... 6 = Saturday.
///         Day 0 (1970-01-01) was a Thursday, and (0 + 4) % 7 == 4 == Thursday, so the
///         convention is Sun=0, Mon=1, Tue=2, Wed=3, Thu=4, Fri=5, Sat=6.
///
///         Day-of-year is 1-based (Jan 1 == 1, Dec 31 == 365 or 366).
library CivilDate {
    uint256 internal constant SECONDS_PER_DAY = 86_400;

    /// @dev Days since 1970-01-01.
    function daysFromTimestamp(uint256 timestamp) internal pure returns (uint256) {
        return timestamp / SECONDS_PER_DAY;
    }

    /// @dev Minute of the UTC day, 0..1439.
    function minuteOfDay(uint256 timestamp) internal pure returns (uint256) {
        return (timestamp % SECONDS_PER_DAY) / 60;
    }

    /// @dev 0 = Sunday ... 6 = Saturday. See the library notice for the derivation.
    function weekday(uint256 timestamp) internal pure returns (uint256) {
        return (daysFromTimestamp(timestamp) + 4) % 7;
    }

    /// @dev Inverse of days-from-civil (Howard Hinnant's algorithm), restricted to
    ///      timestamps >= 0 so every intermediate stays unsigned.
    ///      Returns (year, month 1..12, day 1..31).
    function civilFromDays(uint256 days_) internal pure returns (uint256 year, uint256 month, uint256 day) {
        uint256 z = days_ + 719_468; // shift epoch to 0000-03-01
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097; // day of era        [0, 146096]
        uint256 yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365; // year of era [0, 399]
        uint256 y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // day of year, March-based [0, 365]
        uint256 mp = (5 * doy + 2) / 153; // [0, 11], 0 = March
        day = doy - (153 * mp + 2) / 5 + 1;
        month = mp < 10 ? mp + 3 : mp - 9;
        year = month <= 2 ? y + 1 : y;
    }

    function isLeapYear(uint256 year) internal pure returns (bool) {
        return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    }

    /// @dev (year, dayOfYear) for a timestamp, dayOfYear 1-based.
    function yearAndDayOfYear(uint256 timestamp) internal pure returns (uint256 year, uint256 dayOfYear) {
        uint256 days_ = daysFromTimestamp(timestamp);
        (uint256 y, uint256 m, uint256 d) = civilFromDays(days_);
        year = y;
        // Cumulative days before each month (non-leap).
        uint256[12] memory before = [uint256(0), 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
        dayOfYear = before[m - 1] + d;
        if (m > 2 && isLeapYear(y)) dayOfYear += 1;
    }
}

/// @title  MarketHoursGuardHook
/// @author Midas
/// @notice "Hours-Aware Quote Asset." A Uniswap v4 hook for pools whose quote leg is a
///         tokenized equity (Robinhood Chain stock tokens). The underlying market keeps a
///         session; the token does not. While the underlying is shut, the quote leg's
///         reference price is stale and the first print after the open gaps. Liquidity
///         providers who quote through the night are writing a free option to whoever
///         sees the overnight news first.
///
///         The hook never halts the pool. Instead it reads block.timestamp and applies one
///         of two term sheets:
///
///             Open    (inside the regular session)   OPEN_FEE   as the native LP fee
///             Closed  (everything else)              CLOSED_FEE as the native LP fee, and
///                                                    a per-swap size clamp
///
///         plus a fixed ROYALTY_SHARE taken from the specified currency on every swap via
///         BeforeSwapDelta and pushed to the immutable ROYALTY_RECIPIENT.
///
///         "Closed" is decided in this order, per pool, from block.timestamp alone:
///           1. Unconfigured   no session table, or no holiday calendar for the current year
///           2. Holiday        the day-of-year bit is set in this year's bitmap
///           3. Weekend        weekday bit not in the session's weekday mask
///           4. ClosedSession  minute-of-day outside [openMinute, closeMinute)
///           5. Open           otherwise
///
///         Fallback is CLOSED. A pool nobody configured, or whose holiday calendar lapsed
///         at the turn of the year, trades on closed terms until its policy holder writes
///         the missing entry. That is deliberate: forgetting to maintain the calendar
///         must never silently expose LPs to open-terms quoting outside the session.
///
///         Daylight-saving time is not computed. The session is a plain UTC minute-of-day
///         pair. When the underlying exchange shifts its UTC hours in spring and autumn
///         the policy holder re-points the table; between the shift and the update the
///         pool applies closed terms to the newly-open hour (conservative) and open terms
///         to the newly-closed hour (up to 60 minutes of exposure, bounded by the table's
///         immutable envelope). Adopters who want zero exposure should update the day
///         before the shift.
///
///         Size clamp trade-off: the clamp is applied to |amountSpecified| in the units of
///         the specified currency, with no oracle. For an exact-input swap of the base
///         token it therefore measures base units, not quote notional. Adopters should set
///         the clamp for the leg they are most worried about being hit on overnight and
///         accept that the other leg is bounded only loosely. A per-swap clamp is also
///         trivially split across several swaps; it is a rate-of-damage limiter that makes
///         each overnight print small enough for arbitrage to correct, not a hard cap.
///
///         Authority (Policy Envelope, minimal). The address that initialised the pool is
///         its policy holder and may:
///           - set or replace the session table, only inside the immutable global envelope
///             (open >= 12:00 UTC, close <= 22:00 UTC, 1h <= length <= 8h, weekdays only);
///           - write the holiday calendar for the current or a future year, append-only
///             (the new bitmaps must be supersets of the old); past years are frozen;
///           - set the closed-size clamp inside [CLOSED_SIZE_FLOOR, CLOSED_SIZE_CAP].
///         The policy holder cannot touch fees, ceilings, the royalty, or where the royalty
///         goes. There is no owner, no upgrade path, and no fee setter.
///
/// @dev    FEE INTEREST DISCLOSURE: the author of this contract receives ROYALTY_SHARE
///         (0.05%) of the specified amount on every swap through every pool that uses it.
///         Anyone deploying a pool with this hook should price that in.
///
/// @dev    UNAUDITED.
contract MarketHoursGuardHook is BaseHook, IUnlockCallback {
    using CurrencySettler for Currency;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;

    // ---------------------------------------------------------------------
    // Fee constants and ceilings, pips (1_000_000 = 100%)
    // ---------------------------------------------------------------------

    uint24 internal constant PIPS = 1_000_000;

    /// @notice Hard ceiling on the open-session LP fee.
    uint24 public constant MAX_OPEN_FEE = 10_000; // 1.00%

    /// @notice Hard ceiling on the closed LP fee.
    uint24 public constant MAX_CLOSED_FEE = 50_000; // 5.00%

    /// @notice Royalty taken from the specified currency on every swap.
    uint24 public constant ROYALTY_SHARE = 500; // 0.05%

    /// @notice Hard ceiling on the royalty. Checked at compile time in the constructor.
    uint24 public constant MAX_ROYALTY_SHARE = 1_000; // 0.10%

    // ---------------------------------------------------------------------
    // Session envelope, minutes of the UTC day
    // ---------------------------------------------------------------------

    /// @notice Earliest permitted session open, 12:00 UTC.
    uint16 public constant MIN_OPEN_MINUTE = 12 * 60;

    /// @notice Latest permitted session close, 22:00 UTC.
    uint16 public constant MAX_CLOSE_MINUTE = 22 * 60;

    /// @notice Shortest permitted session, 1 hour.
    uint16 public constant MIN_SESSION_MINUTES = 60;

    /// @notice Longest permitted session, 8 hours.
    uint16 public constant MAX_SESSION_MINUTES = 8 * 60;

    /// @notice Weekday bits a session may enable: Mon..Fri (bit 1..5; Sun = bit 0, Sat = bit 6).
    uint8 public constant WEEKDAY_MASK_ENVELOPE = 0x3E; // 0b0111110

    /// @notice Default NYSE regular session in standard time, for adopter convenience.
    uint16 public constant DEFAULT_OPEN_MINUTE = 13 * 60 + 30; // 13:30 UTC = 09:30 ET (EST)
    uint16 public constant DEFAULT_CLOSE_MINUTE = 20 * 60; // 20:00 UTC = 16:00 ET (EST)

    // ---------------------------------------------------------------------
    // Immutables, no setters anywhere in this contract
    // ---------------------------------------------------------------------

    /// @notice LP fee inside the regular session.
    uint24 public immutable OPEN_FEE;

    /// @notice LP fee outside the regular session. Always >= OPEN_FEE.
    uint24 public immutable CLOSED_FEE;

    /// @notice Smallest closed-size clamp a policy holder may set, and the clamp used when
    ///         none has been set. Strictly positive so an unconfigured pool still trades.
    uint128 public immutable CLOSED_SIZE_FLOOR;

    /// @notice Largest closed-size clamp a policy holder may set.
    uint128 public immutable CLOSED_SIZE_CAP;

    address public immutable ROYALTY_RECIPIENT;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    enum Regime {
        Open,
        ClosedSession,
        Holiday,
        Weekend,
        Unconfigured
    }

    struct Session {
        uint16 openMinute; // inclusive
        uint16 closeMinute; // exclusive
        uint8 weekdayMask; // bit i set => weekday i (Sun=0) is a trading day
        bool set;
    }

    struct PoolPolicy {
        address policyHolder;
        bool initialized;
        uint128 closedMaxSize; // 0 => CLOSED_SIZE_FLOOR
        Session session;
    }

    mapping(PoolId => PoolPolicy) internal _policy;

    /// @dev A year has up to 366 days and a word has 256 bits, so the calendar is two
    ///      words: `lo` bit (d - 1) covers day-of-year d in 1..256, `hi` bit (d - 257)
    ///      covers d in 257..366. Bits above day 366 in `hi` are rejected on write.
    struct Holidays {
        uint256 lo;
        uint256 hi;
        bool written; // unwritten => Regime.Unconfigured (closed)
    }

    uint256 internal constant HI_WORD_BITS = 366 - 256; // 110 usable bits in `hi`

    mapping(PoolId => mapping(uint256 => Holidays)) internal _holidays;

    /// @notice Royalty accrued in-kind, as ERC-6909 claims held by this contract.
    mapping(Currency => uint256) public royaltyBucket;

    // ---------------------------------------------------------------------
    // Events / Errors
    // ---------------------------------------------------------------------

    event PoolOpened(PoolId indexed id, address indexed policyHolder);
    event SessionSet(PoolId indexed id, uint16 openMinute, uint16 closeMinute, uint8 weekdayMask);
    event HolidaysSet(PoolId indexed id, uint256 indexed year, uint256 lo, uint256 hi);
    event ClosedMaxSizeSet(PoolId indexed id, uint128 closedMaxSize);
    event RoyaltyAccrued(PoolId indexed id, Currency indexed c, uint256 amount);
    event RoyaltyClaimed(Currency indexed c, uint256 amount);

    error NotDynamicFee();
    error AlreadyInitialized();
    error NotPolicyHolder();
    error SessionOutOfBounds();
    error HolidayYearFrozen();
    error HolidayBitmapNotSuperset();
    error HolidayBitmapInvalid();
    error ClosedSizeOutOfBounds();
    error TradeTooLargeWhileClosed(uint256 amount, uint256 maxWhileClosed);
    error NothingToClaim();
    error OnlyPoolManager();

    // ---------------------------------------------------------------------

    constructor(
        IPoolManager _poolManager,
        address _royaltyRecipient,
        uint24 _openFee,
        uint24 _closedFee,
        uint128 _closedSizeFloor,
        uint128 _closedSizeCap
    ) BaseHook(_poolManager) {
        require(ROYALTY_SHARE <= MAX_ROYALTY_SHARE, "royalty > ceiling");
        require(_openFee <= MAX_OPEN_FEE, "open fee > ceiling");
        require(_closedFee <= MAX_CLOSED_FEE, "closed fee > ceiling");
        require(_closedFee >= _openFee, "closed fee < open fee");
        require(_closedSizeFloor > 0, "size floor zero");
        require(_closedSizeFloor <= _closedSizeCap, "size floor > cap");
        require(_royaltyRecipient != address(0), "royalty zero");

        OPEN_FEE = _openFee;
        CLOSED_FEE = _closedFee;
        CLOSED_SIZE_FLOOR = _closedSizeFloor;
        CLOSED_SIZE_CAP = _closedSizeCap;
        ROYALTY_RECIPIENT = _royaltyRecipient;
    }

    // ---------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false, // never blocks exits
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------
    // Initialize
    // ---------------------------------------------------------------------

    /// @dev Records the initialiser as the pool's policy holder. Nothing else is set here:
    ///      v4's initialize() carries no hookData, so the session table, holiday bitmap and
    ///      size clamp are written afterwards by the policy holder. Until they are, the
    ///      pool trades on closed terms (Regime.Unconfigured).
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();

        PoolId id = key.toId();
        PoolPolicy storage p = _policy[id];
        if (p.initialized) revert AlreadyInitialized();

        p.policyHolder = sender;
        p.initialized = true;

        emit PoolOpened(id, sender);
        return BaseHook.beforeInitialize.selector;
    }

    // ---------------------------------------------------------------------
    // Policy envelope, policy holder only, bounded, never touches value
    // ---------------------------------------------------------------------

    modifier onlyPolicyHolder(PoolId id) {
        _checkPolicyHolder(id);
        _;
    }

    function _checkPolicyHolder(PoolId id) internal view {
        if (msg.sender != _policy[id].policyHolder) revert NotPolicyHolder();
    }

    /// @notice Set or replace the pool's regular session, in UTC minutes of the day.
    /// @dev    Bounded by the immutable envelope: open >= 12:00, close <= 22:00, length in
    ///         [1h, 8h], weekday bits restricted to Mon..Fri. Replacing an existing table is
    ///         allowed (this is how DST is handled) but only with another table inside the
    ///         same envelope, so the widest possible "open" window is fixed at deploy time.
    function setSession(PoolKey calldata key, uint16 openMinute, uint16 closeMinute, uint8 weekdayMask)
        external
        onlyPolicyHolder(key.toId())
    {
        if (openMinute < MIN_OPEN_MINUTE) revert SessionOutOfBounds();
        if (closeMinute > MAX_CLOSE_MINUTE) revert SessionOutOfBounds();
        if (closeMinute <= openMinute) revert SessionOutOfBounds();
        uint16 length = closeMinute - openMinute;
        if (length < MIN_SESSION_MINUTES || length > MAX_SESSION_MINUTES) revert SessionOutOfBounds();
        if (weekdayMask & ~WEEKDAY_MASK_ENVELOPE != 0) revert SessionOutOfBounds();

        PoolId id = key.toId();
        _policy[id].session = Session({openMinute: openMinute, closeMinute: closeMinute, weekdayMask: weekdayMask, set: true});

        emit SessionSet(id, openMinute, closeMinute, weekdayMask);
    }

    /// @notice Write the holiday calendar for `year` as two bitmaps: `lo` bit (d - 1) marks
    ///         day-of-year d in 1..256, `hi` bit (d - 257) marks d in 257..366.
    /// @dev    Append-only: both new words must contain every bit already set, so a
    ///         holiday once declared can never be un-declared (that would flip a closed day
    ///         to open terms). Only the current year and future years may be written; past
    ///         years are frozen. Writing all-zero is how a policy holder declares "this year
    ///         has no holidays" and lifts the Unconfigured fallback. Bits in `hi` above day
    ///         366 are rejected so the stored calendar is always meaningful.
    function setHolidays(PoolKey calldata key, uint256 year, uint256 lo, uint256 hi)
        external
        onlyPolicyHolder(key.toId())
    {
        (uint256 currentYear,) = CivilDate.yearAndDayOfYear(block.timestamp);
        if (year < currentYear) revert HolidayYearFrozen();
        if (hi >> HI_WORD_BITS != 0) revert HolidayBitmapInvalid();

        PoolId id = key.toId();
        Holidays storage h = _holidays[id][year];
        if ((lo & h.lo) != h.lo || (hi & h.hi) != h.hi) revert HolidayBitmapNotSuperset();

        h.lo = lo;
        h.hi = hi;
        h.written = true;

        emit HolidaysSet(id, year, lo, hi);
    }

    /// @notice Set the per-swap size clamp applied while closed, in units of the specified
    ///         currency. Must lie in [CLOSED_SIZE_FLOOR, CLOSED_SIZE_CAP].
    function setClosedMaxSize(PoolKey calldata key, uint128 closedMaxSize) external onlyPolicyHolder(key.toId()) {
        if (closedMaxSize < CLOSED_SIZE_FLOOR || closedMaxSize > CLOSED_SIZE_CAP) revert ClosedSizeOutOfBounds();

        PoolId id = key.toId();
        _policy[id].closedMaxSize = closedMaxSize;

        emit ClosedMaxSizeSet(id, closedMaxSize);
    }

    // ---------------------------------------------------------------------
    // Swap
    // ---------------------------------------------------------------------

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        bool open = _regime(id, block.timestamp) == Regime.Open;

        bool exactInput = params.amountSpecified < 0;
        uint256 specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        if (!open) {
            uint256 maxSize = _closedMaxSize(id);
            if (specifiedAmount > maxSize) revert TradeTooLargeWhileClosed(specifiedAmount, maxSize);
        }

        uint24 lpFee = open ? OPEN_FEE : CLOSED_FEE;

        Currency feeCurrency = exactInput
            ? (params.zeroForOne ? key.currency0 : key.currency1)
            : (params.zeroForOne ? key.currency1 : key.currency0);

        uint256 royaltyAmount = (specifiedAmount * ROYALTY_SHARE) / PIPS;

        if (royaltyAmount > 0) {
            // Hold the royalty as an ERC-6909 claim on the PoolManager.
            poolManager.mint(address(this), feeCurrency.toId(), royaltyAmount);
            royaltyBucket[feeCurrency] += royaltyAmount;
            emit RoyaltyAccrued(id, feeCurrency, royaltyAmount);
        }

        // Checked cast: a silent wrap would mint the full royalty as 6909 claims while
        // returning a smaller delta to the router. Reverting is the correct failure.
        return (
            BaseHook.beforeSwap.selector,
            toBeforeSwapDelta(royaltyAmount.toInt128(), 0),
            lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    // ---------------------------------------------------------------------
    // Royalty claim, permissionless push to the immutable recipient
    // ---------------------------------------------------------------------

    /// @notice Redeems accrued royalty claims for real tokens and forwards them to
    ///         ROYALTY_RECIPIENT. Anyone may call; nobody can redirect.
    function claimRoyalty(Currency c) external {
        uint256 amount = royaltyBucket[c];
        if (amount == 0) revert NothingToClaim();

        royaltyBucket[c] = 0;
        poolManager.unlock(abi.encode(c, amount));

        emit RoyaltyClaimed(c, amount);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        (Currency c, uint256 amount) = abi.decode(data, (Currency, uint256));
        c.settle(poolManager, address(this), amount, true);
        c.take(poolManager, ROYALTY_RECIPIENT, amount, false);
        return "";
    }

    // ---------------------------------------------------------------------
    // Regime logic
    // ---------------------------------------------------------------------

    function _closedMaxSize(PoolId id) internal view returns (uint256) {
        uint128 stored = _policy[id].closedMaxSize;
        return stored == 0 ? CLOSED_SIZE_FLOOR : stored;
    }

    function _isHoliday(Holidays storage h, uint256 dayOfYear) internal view returns (bool) {
        return dayOfYear <= 256
            ? (h.lo & (uint256(1) << (dayOfYear - 1))) != 0
            : (h.hi & (uint256(1) << (dayOfYear - 257))) != 0;
    }

    function _regime(PoolId id, uint256 timestamp) internal view returns (Regime) {
        Session memory s = _policy[id].session;
        if (!s.set) return Regime.Unconfigured;

        (uint256 year, uint256 dayOfYear) = CivilDate.yearAndDayOfYear(timestamp);
        Holidays storage h = _holidays[id][year];
        if (!h.written) return Regime.Unconfigured;

        if (_isHoliday(h, dayOfYear)) return Regime.Holiday;

        uint256 wd = CivilDate.weekday(timestamp);
        if (uint256(s.weekdayMask) & (uint256(1) << wd) == 0) return Regime.Weekend;

        uint256 minute = CivilDate.minuteOfDay(timestamp);
        if (minute < s.openMinute || minute >= s.closeMinute) return Regime.ClosedSession;

        return Regime.Open;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Which term sheet the pool is on right now, and why.
    function regimeOf(PoolKey calldata key) external view returns (Regime) {
        return _regime(key.toId(), block.timestamp);
    }

    /// @notice True only inside the configured regular session on a trading day.
    function isOpen(PoolKey calldata key) external view returns (bool) {
        return _regime(key.toId(), block.timestamp) == Regime.Open;
    }

    /// @notice LP fee a swap would pay right now (excludes the fixed ROYALTY_SHARE).
    function currentFee(PoolKey calldata key) external view returns (uint24) {
        return _regime(key.toId(), block.timestamp) == Regime.Open ? OPEN_FEE : CLOSED_FEE;
    }

    /// @notice Effective per-swap clamp while closed (falls back to CLOSED_SIZE_FLOOR).
    function closedMaxSizeOf(PoolKey calldata key) external view returns (uint256) {
        return _closedMaxSize(key.toId());
    }

    function policyHolderOf(PoolKey calldata key) external view returns (address) {
        return _policy[key.toId()].policyHolder;
    }

    function sessionOf(PoolKey calldata key) external view returns (Session memory) {
        return _policy[key.toId()].session;
    }

    function holidaysOf(PoolKey calldata key, uint256 year) external view returns (Holidays memory) {
        return _holidays[key.toId()][year];
    }

    /// @notice Whether `dayOfYear` (1-based) of `year` is a declared holiday for this pool.
    function isHoliday(PoolKey calldata key, uint256 year, uint256 dayOfYear) external view returns (bool) {
        if (dayOfYear == 0 || dayOfYear > 366) return false;
        return _isHoliday(_holidays[key.toId()][year], dayOfYear);
    }

    /// @notice Expose the calendar routine so integrators and tests can check it.
    function civilDate(uint256 timestamp)
        external
        pure
        returns (uint256 year, uint256 month, uint256 day, uint256 dayOfYear, uint256 weekday_)
    {
        (year, month, day) = CivilDate.civilFromDays(CivilDate.daysFromTimestamp(timestamp));
        (, dayOfYear) = CivilDate.yearAndDayOfYear(timestamp);
        weekday_ = CivilDate.weekday(timestamp);
    }
}
