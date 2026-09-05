// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title  FloorBidHook
/// @author Midas
/// @notice A Uniswap v4 hook that gives an ordinary token launch a small balance sheet
///         with no credit risk. Instead of burning a slice of every swap (which destroys
///         the capital along with the supply), the hook accumulates a quote-denominated
///         fee and periodically parks it as single-sided range liquidity just under spot:
///         a standing bid that the pool itself owns. If price falls into the band, the
///         pool has bought its own token cheap and holds the inventory. If price later
///         rises back through the band, the pool has sold it back for quote. Either way
///         the capital never leaves the pool.
///
///         Fee: 1.00% total, all of it a compile-time constant.
///
///             When the specified currency is the QUOTE (a buy in exact-input form,
///             or a sell quoted exact-output in quote):
///                 LP     0.50%   native dynamic LP fee (override from beforeSwap)
///                 FLOOR  0.50%   BeforeSwapDelta on the quote currency, into the bucket
///
///             When the specified currency is the launched TOKEN (a sell in exact-input
///             form, or a buy quoted exact-output in token):
///                 LP     1.00%   native dynamic LP fee; the hook takes nothing
///
///         The floor share is only ever collected in the quote currency, so no
///         conversion is ever needed, and the token side pays the full 1.00% to LPs so
///         that sells are never cheaper than buys.
///
///         Custody: everything the hook collects is held as ERC-6909 claims on the
///         PoolManager and only ever becomes pool liquidity again. There is no owner, no
///         claim function, no withdraw function, no royalty and no deployer share. The
///         deployer's single privilege is the one-shot `setQuoteSide`, which declares
///         which leg is the quote asset and cannot redirect value.
///
///         Price-magnet mitigation: a standing bid right under spot is a target. Three
///         things make it a poor one:
///           1. the band is strictly below spot (it never contains the current tick),
///              so the pool never buys at or above the price at posting;
///           2. funding is slow: at most one post/roll per FUNDING_INTERVAL and only
///              once the bucket reaches MIN_POST, so there is nothing to farm block by
///              block;
///           3. a reference guard: the hook keeps a slow sqrt-price reference per pool
///              and refuses to post if spot has moved more than MAX_REF_DEVIATION_BPS
///              from it. Pumping the price and then posting a bid under the pumped spot
///              (to dump into it) is refused; the reference can only catch up a quarter
///              of the gap per interval via the permissionless `nudgeReference`.
///
///         Failure cases: if the bucket never reaches MIN_POST the fee simply sits as
///         claims (still unwithdrawable). If price sits permanently outside the
///         reference band, posting is blocked until enough nudges have moved the
///         reference (4 intervals for a 30% move). If the band cannot be placed
///         because spot is within one band of the usable tick range, posting reverts
///         and the bucket keeps accruing.
///
/// @dev    No fee-interest disclosure: the author of this contract receives nothing
///         from pools that use it.
///
/// @dev    UNAUDITED.
contract FloorBidHook is BaseHook, IUnlockCallback {
    using CurrencySettler for Currency;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ---------------------------------------------------------------------
    // Fee constants, pips (1_000_000 = 100%)
    // ---------------------------------------------------------------------

    uint24 internal constant PIPS = 1_000_000;

    uint24 public constant TOTAL_FEE   = 10_000; // 1.00%
    uint24 public constant LP_SHARE    =  5_000; // 0.50% when the floor share is taken
    uint24 public constant FLOOR_SHARE =  5_000; // 0.50% on the quote currency

    /// @notice Hard ceiling. Nothing here can ever charge more.
    uint24 public constant MAX_TOTAL_FEE = 10_000; // 1.00%

    // ---------------------------------------------------------------------
    // Posting policy, constructor immutables validated against hardcoded bounds
    // ---------------------------------------------------------------------

    uint256 public constant MIN_FUNDING_INTERVAL = 1 hours;
    uint256 public constant MAX_FUNDING_INTERVAL = 7 days;

    /// @notice Widest band allowed, in ticks. 10_000 ticks is roughly a 2.7x price range.
    int24 public constant MAX_BAND_TICKS = 10_000;

    /// @notice Max deviation of spot from the stored reference, in bps of sqrt price.
    uint256 public constant MAX_REF_DEVIATION_BPS = 1_000; // 10%
    uint256 internal constant BPS = 10_000;

    /// @dev Reference update weight: ref = (3*ref + spot) / 4.
    uint256 internal constant REF_SMOOTHING = 4;

    /// @notice Minimum seconds between any two of postFloor / rollFloor / nudgeReference
    ///         on the same pool.
    uint256 public immutable FUNDING_INTERVAL;

    /// @notice Requested band width in ticks. Rounded UP to the pool's tickSpacing at
    ///         posting time.
    int24 public immutable BAND_TICKS;

    /// @notice Minimum quote in the bucket before a bid can be posted.
    uint256 public immutable MIN_POST;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    struct PoolConfig {
        address deployer;
        bool quoteIsZero;
        bool quoteSet;
        bool initialized;
    }

    /// @notice A range position owned by the hook.
    /// @param tickLower     lower tick of the band
    /// @param tickUpper     upper tick of the band
    /// @param liquidity     liquidity currently in the position (0 once rolled)
    /// @param salt          position salt, unique per posting
    /// @param holdsZero     true if the band was posted holding currency0
    /// @param isAsk         true if the band was posted holding the launched token
    struct Floor {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bytes32 salt;
        bool holdsZero;
        bool isAsk;
    }

    mapping(PoolId => PoolConfig) public poolConfig;

    /// @notice Quote-currency fee accrued and not yet posted, held as ERC-6909 claims.
    mapping(PoolId => uint256) internal _floorBucket;

    /// @notice Launched-token inventory not currently in a position (rounding dust and
    ///         LP fees collected on roll), held as ERC-6909 claims. Never withdrawable;
    ///         swept back into liquidity on the next roll to an ask.
    mapping(PoolId => uint256) internal _tokenBucket;

    mapping(PoolId => Floor[]) internal _floors;

    /// @notice Slow-moving reference sqrt price per pool.
    mapping(PoolId => uint160) public refSqrtPriceX96;

    /// @notice Timestamp of the last post / roll / nudge on each pool.
    mapping(PoolId => uint64) public lastActionAt;

    // ---------------------------------------------------------------------
    // Events / Errors
    // ---------------------------------------------------------------------

    event PoolOpened(PoolId indexed id, address indexed deployer);
    event QuoteSideSet(PoolId indexed id, bool quoteIsZero);
    event FloorAccrued(PoolId indexed id, uint256 amount);
    event FloorPosted(
        PoolId indexed id, uint256 indexed index, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amountUsed, bool isAsk
    );
    event FloorRolled(PoolId indexed id, uint256 indexed fromIndex, uint256 indexed toIndex);
    event ReferenceUpdated(PoolId indexed id, uint160 refSqrtPriceX96);

    error NotDynamicFee();
    error AlreadyInitialized();
    error NotDeployer();
    error QuoteAlreadySet();
    error QuoteNotSet();
    error OnlyPoolManager();
    error TooSoon();
    error BucketTooSmall();
    error PriceDeviates();
    error BandOutOfRange();
    error NoFloor();
    error FloorInactive();
    error NotConverted();
    error LiquidityZero();
    error AmountExceedsBucket();

    // ---------------------------------------------------------------------

    constructor(IPoolManager _poolManager, uint256 _fundingInterval, int24 _bandTicks, uint256 _minPost)
        BaseHook(_poolManager)
    {
        require(LP_SHARE + FLOOR_SHARE == TOTAL_FEE, "share mismatch");
        require(TOTAL_FEE <= MAX_TOTAL_FEE, "fee > ceiling");
        require(_fundingInterval >= MIN_FUNDING_INTERVAL && _fundingInterval <= MAX_FUNDING_INTERVAL, "interval");
        require(_bandTicks > 0 && _bandTicks <= MAX_BAND_TICKS, "band");
        require(_minPost > 0, "min post");

        FUNDING_INTERVAL = _fundingInterval;
        BAND_TICKS = _bandTicks;
        MIN_POST = _minPost;
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

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();

        PoolId id = key.toId();
        if (poolConfig[id].initialized) revert AlreadyInitialized();

        poolConfig[id] = PoolConfig({deployer: sender, quoteIsZero: false, quoteSet: false, initialized: true});

        emit PoolOpened(id, sender);
        return BaseHook.beforeInitialize.selector;
    }

    /// @notice One-shot declaration of which leg is the quote asset.
    /// @dev    v4's initialize() carries no hookData, so this cannot live in
    ///         _beforeInitialize. Single-use, deployer-only, and swaps revert until it is
    ///         set. This is the deployer's only privilege and it cannot move value.
    function setQuoteSide(PoolKey calldata key, bool quoteIsZero) external {
        PoolId id = key.toId();
        PoolConfig storage cfg = poolConfig[id];

        if (msg.sender != cfg.deployer) revert NotDeployer();
        if (cfg.quoteSet) revert QuoteAlreadySet();

        cfg.quoteIsZero = quoteIsZero;
        cfg.quoteSet = true;

        emit QuoteSideSet(id, quoteIsZero);
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
        PoolConfig memory cfg = poolConfig[id];
        if (!cfg.quoteSet) revert QuoteNotSet();

        bool exactInput = params.amountSpecified < 0;
        // The specified currency: input for exact-input, output for exact-output.
        bool specifiedIsZero = exactInput ? params.zeroForOne : !params.zeroForOne;

        if (specifiedIsZero != cfg.quoteIsZero) {
            // Token side specified: no hook delta, LPs take the whole 1.00%.
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), TOTAL_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        uint256 specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 feeAmount = (specifiedAmount * FLOOR_SHARE) / PIPS;

        if (feeAmount > 0) {
            Currency quote = cfg.quoteIsZero ? key.currency0 : key.currency1;
            // Hold the floor share as an ERC-6909 claim on the PoolManager.
            poolManager.mint(address(this), quote.toId(), feeAmount);
            _floorBucket[id] += feeAmount;
            emit FloorAccrued(id, feeAmount);
        }

        // Checked cast: a silent wrap would mint the full fee as claims while returning
        // a smaller delta to the router. Reverting the swap is the correct failure.
        return (
            BaseHook.beforeSwap.selector,
            toBeforeSwapDelta(feeAmount.toInt128(), 0),
            LP_SHARE | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    // ---------------------------------------------------------------------
    // Posting
    // ---------------------------------------------------------------------

    enum Action {
        POST,
        ROLL
    }

    struct CallbackData {
        Action action;
        PoolKey key;
        uint256 index;
    }

    /// @notice Permissionless. Posts the whole quote bucket as a single-sided bid
    ///         strictly below spot, owned by the hook.
    /// @dev    Guards, in order: quote side set; rate limit; bucket >= MIN_POST;
    ///         spot within the reference band. Reference is then updated
    ///         ref = (3*ref + spot)/4 (seeded from spot on the first action).
    function postFloor(PoolKey calldata key) external returns (uint256 index) {
        PoolId id = key.toId();
        if (!poolConfig[id].quoteSet) revert QuoteNotSet();
        if (_floorBucket[id] < MIN_POST) revert BucketTooSmall();

        _gate(id);

        bytes memory result = poolManager.unlock(abi.encode(CallbackData({action: Action.POST, key: key, index: 0})));
        index = abi.decode(result, (uint256));
    }

    /// @notice Permissionless. Once a band has been fully crossed, a bid that now holds
    ///         only the launched token, or an ask that now holds only quote, removes it
    ///         and re-posts everything it held on the far side of spot: a bid becomes an
    ///         ask BAND_TICKS above spot; an ask becomes a bid below spot. Reverts while
    ///         the band is only partially converted.
    /// @dev    Same rate limit and reference band as postFloor. LP fees the position
    ///         earned in the other currency go to that currency's bucket. Nothing leaves
    ///         the hook.
    function rollFloor(PoolKey calldata key, uint256 index) external returns (uint256 newIndex) {
        PoolId id = key.toId();
        if (index >= _floors[id].length) revert NoFloor();
        Floor memory f = _floors[id][index];
        if (f.liquidity == 0) revert FloorInactive();

        (, int24 tick,,) = poolManager.getSlot0(id);
        bool holdsZeroNow;
        if (tick < f.tickLower) holdsZeroNow = true;
        else if (tick >= f.tickUpper) holdsZeroNow = false;
        else revert NotConverted();
        if (holdsZeroNow == f.holdsZero) revert NotConverted();

        _gate(id);

        bytes memory result =
            poolManager.unlock(abi.encode(CallbackData({action: Action.ROLL, key: key, index: index})));
        newIndex = abi.decode(result, (uint256));
    }

    /// @notice Permissionless. Moves the reference a quarter of the way toward spot
    ///         without posting. Shares the rate limit with postFloor / rollFloor, so
    ///         catching up after a large genuine move costs several intervals, which is
    ///         exactly what makes holding a manipulated price expensive.
    function nudgeReference(PoolKey calldata key) external {
        PoolId id = key.toId();
        if (!poolConfig[id].quoteSet) revert QuoteNotSet();
        uint64 last = lastActionAt[id];
        // forge-lint: disable-next-line(block-timestamp)
        if (last != 0 && block.timestamp < uint256(last) + FUNDING_INTERVAL) revert TooSoon();
        lastActionAt[id] = uint64(block.timestamp);

        (uint160 spot,,,) = poolManager.getSlot0(id);
        _updateRef(id, spot);
    }

    /// @dev Rate limit + reference band, then record the action and update the reference.
    function _gate(PoolId id) internal {
        uint64 last = lastActionAt[id];
        // Guard on != 0 so the first-ever action is not gated by the interval.
        // block.timestamp is safe here: the guard is hour-scale and validator drift is seconds.
        // forge-lint: disable-next-line(block-timestamp)
        if (last != 0 && block.timestamp < uint256(last) + FUNDING_INTERVAL) revert TooSoon();

        (uint160 spot,,,) = poolManager.getSlot0(id);
        uint160 ref = refSqrtPriceX96[id];
        if (ref != 0) {
            // Compare in sqrt space; a sqrt band of N% is roughly 2N% in price terms.
            uint256 hi = (uint256(ref) * (BPS + MAX_REF_DEVIATION_BPS)) / BPS;
            uint256 lo = (uint256(ref) * (BPS - MAX_REF_DEVIATION_BPS)) / BPS;
            if (spot > hi || spot < lo) revert PriceDeviates();
        }

        lastActionAt[id] = uint64(block.timestamp);
        _updateRef(id, spot);
    }

    function _updateRef(PoolId id, uint160 spot) internal {
        uint160 ref = refSqrtPriceX96[id];
        // casting to 'uint160' is safe because a weighted average of two uint160 values
        // cannot exceed max(ref, spot).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 next = ref == 0 ? spot : uint160((uint256(ref) * (REF_SMOOTHING - 1) + uint256(spot)) / REF_SMOOTHING);
        refSqrtPriceX96[id] = next;
        emit ReferenceUpdated(id, next);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        CallbackData memory d = abi.decode(data, (CallbackData));
        PoolId id = d.key.toId();
        PoolConfig memory cfg = poolConfig[id];

        if (d.action == Action.POST) {
            uint256 amount = _floorBucket[id];
            _floorBucket[id] = 0;
            (uint256 idx, uint256 rest) = _post(d.key, cfg.quoteIsZero, amount, false);
            _floorBucket[id] = rest;
            return abi.encode(idx);
        }

        // ROLL
        Floor storage f = _floors[id][d.index];
        uint128 liq = f.liquidity;
        f.liquidity = 0;

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            d.key,
            ModifyLiquidityParams({
                tickLower: f.tickLower,
                tickUpper: f.tickUpper,
                liquidityDelta: -int256(uint256(liq)),
                salt: f.salt
            }),
            ""
        );

        // Removal deltas are non-negative (principal + fees). Take them as claims.
        uint256 got0 = delta.amount0() > 0 ? uint256(uint128(delta.amount0())) : 0;
        uint256 got1 = delta.amount1() > 0 ? uint256(uint128(delta.amount1())) : 0;
        d.key.currency0.take(poolManager, address(this), got0, true);
        d.key.currency1.take(poolManager, address(this), got1, true);

        (uint256 gotQuote, uint256 gotToken) = cfg.quoteIsZero ? (got0, got1) : (got1, got0);
        _floorBucket[id] += gotQuote;
        _tokenBucket[id] += gotToken;

        // A bid that has been crossed re-posts as an ask, and vice versa.
        bool toAsk = !f.isAsk;
        uint256 newIdx;
        uint256 leftover;
        if (toAsk) {
            uint256 amt = _tokenBucket[id];
            _tokenBucket[id] = 0;
            (newIdx, leftover) = _post(d.key, !cfg.quoteIsZero, amt, true);
            _tokenBucket[id] = leftover;
        } else {
            uint256 amt = _floorBucket[id];
            _floorBucket[id] = 0;
            (newIdx, leftover) = _post(d.key, cfg.quoteIsZero, amt, false);
            _floorBucket[id] = leftover;
        }

        emit FloorRolled(id, d.index, newIdx);
        return abi.encode(newIdx);
    }

    /// @dev Adds `amount` of the currency indicated by `holdsZero` as a single-sided
    ///      band on the far side of spot, paid by burning the hook's claims. Must be
    ///      called inside the unlock callback.
    function _post(PoolKey memory key, bool holdsZero, uint256 amount, bool isAsk)
        internal
        returns (uint256 index, uint256 leftover)
    {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        (int24 tickLower, int24 tickUpper) = _band(tick, key.tickSpacing, holdsZero);

        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 liquidity;
        uint256 required;
        if (holdsZero) {
            liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtA, sqrtB, amount);
            required = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, true);
            // LiquidityAmounts rounds intermediates down, v4 rounds the required amount
            // up; the two can disagree by a unit. Step liquidity down until they agree.
            while (required > amount && liquidity > 0) {
                liquidity -= 1;
                required = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, true);
            }
        } else {
            liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, amount);
            required = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, true);
            while (required > amount && liquidity > 0) {
                liquidity -= 1;
                required = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, true);
            }
        }
        if (liquidity == 0) revert LiquidityZero();

        index = _floors[id].length;
        bytes32 salt = bytes32(index + 1);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            ""
        );

        // Exactly one leg is owed and it must fit inside what we set aside.
        int128 owed = holdsZero ? delta.amount0() : delta.amount1();
        int128 other = holdsZero ? delta.amount1() : delta.amount0();
        if (other != 0) revert BandOutOfRange();
        uint256 used = owed < 0 ? uint256(uint128(-owed)) : 0;
        if (used > amount) revert AmountExceedsBucket();

        (holdsZero ? key.currency0 : key.currency1).settle(poolManager, address(this), used, true);

        _floors[id].push(
            Floor({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity,
                salt: salt,
                holdsZero: holdsZero,
                isAsk: isAsk
            })
        );

        emit FloorPosted(id, index, tickLower, tickUpper, liquidity, used, isAsk);
        leftover = amount - used;
    }

    /// @dev A band of ~BAND_TICKS (rounded up to spacing) that never contains `tick`
    ///      and holds only the `holdsZero` currency: above spot for currency0, below
    ///      spot for currency1 (v4 prices are token1 per token0).
    function _band(int24 tick, int24 spacing, bool holdsZero) internal view returns (int24 lower, int24 upper) {
        int24 width = ((BAND_TICKS + spacing - 1) / spacing) * spacing;
        int24 minTick = TickMath.minUsableTick(spacing);
        int24 maxTick = TickMath.maxUsableTick(spacing);

        if (holdsZero) {
            // smallest spacing multiple strictly greater than tick
            lower = _ceilTick(tick + 1, spacing);
            upper = lower + width;
            if (upper > maxTick) revert BandOutOfRange();
        } else {
            // largest spacing multiple strictly less than tick
            upper = _floorTick(tick - 1, spacing);
            lower = upper - width;
            if (lower < minTick) revert BandOutOfRange();
        }
    }

    function _floorTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 c = tick / spacing;
        if (tick < 0 && tick % spacing != 0) c -= 1;
        return c * spacing;
    }

    function _ceilTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 c = tick / spacing;
        if (tick > 0 && tick % spacing != 0) c += 1;
        return c * spacing;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Quote fee accrued and not yet posted, held as ERC-6909 claims.
    function floorBucket(PoolKey calldata key) external view returns (uint256) {
        return _floorBucket[key.toId()];
    }

    /// @notice Launched-token inventory not currently in a position (dust and LP fees
    ///         collected on roll), held as ERC-6909 claims.
    function tokenBucket(PoolKey calldata key) external view returns (uint256) {
        return _tokenBucket[key.toId()];
    }

    function floorCount(PoolKey calldata key) external view returns (uint256) {
        return _floors[key.toId()].length;
    }

    function floorAt(PoolKey calldata key, uint256 index) external view returns (Floor memory) {
        return _floors[key.toId()][index];
    }

    /// @notice Earliest timestamp at which postFloor / rollFloor / nudgeReference may
    ///         be called again on this pool.
    function nextPostAllowedAt(PoolKey calldata key) external view returns (uint256) {
        uint64 last = lastActionAt[key.toId()];
        return last == 0 ? 0 : uint256(last) + FUNDING_INTERVAL;
    }

    /// @notice What the band at `index` currently holds, at spot.
    function floorHoldings(PoolKey calldata key, uint256 index) external view returns (uint256 amount0, uint256 amount1) {
        PoolId id = key.toId();
        Floor memory f = _floors[id][index];
        if (f.liquidity == 0) return (0, 0);
        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(id);
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(f.tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(f.tickUpper);
        if (tick < f.tickLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, f.liquidity, false);
        } else if (tick < f.tickUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, f.liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, f.liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, f.liquidity, false);
        }
    }

    /// @notice The band postFloor would use right now, for UI display.
    function previewBand(PoolKey calldata key) external view returns (int24 tickLower, int24 tickUpper) {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        return _band(tick, key.tickSpacing, poolConfig[id].quoteIsZero);
    }
}
