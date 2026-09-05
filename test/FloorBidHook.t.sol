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
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";

import {FloorBidHook} from "../src/FloorBidHook.sol";

/// @notice Tests for FloorBidHook. Run with `forge test -vv --match-path test/FloorBidHook.t.sol`.
///
/// Default orientation: currency1 is the quote (quoteIsZero = false), currency0 is the
/// launched token. In v4 price is token1 per token0, so "below spot" means lower ticks
/// and a bid is a band with tickUpper < currentTick. The mirrored orientation is
/// covered explicitly and in the fuzz.
contract FloorBidHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    FloorBidHook hook;
    PoolId id;

    // NOTE: `key` is inherited from Deployers — do not redeclare it here.

    address stranger = address(0xBEEF);

    uint256 constant INTERVAL = 1 hours;
    int24 constant BAND = 600;
    uint256 constant MIN_POST = 1e15;
    int24 constant SPACING = 60;
    int128 constant SEED_L = 1e21;

    uint160 flags;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        deployCodeTo("FloorBidHook.sol:FloorBidHook", abi.encode(manager, INTERVAL, BAND, MIN_POST), address(flags));
        hook = FloorBidHook(address(flags));
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    /// @dev Opens the main pool at `initTick`, declares the quote side, seeds full-range
    ///      liquidity so that swaps large enough to cross a band do not run dry.
    function _open(int24 initTick, bool quoteIsZero) internal {
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(address(hook)));
        id = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(initTick));
        hook.setQuoteSide(key, quoteIsZero);
        _seed(key);
    }

    function _seed(PoolKey memory k) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(k.tickSpacing),
                tickUpper: TickMath.maxUsableTick(k.tickSpacing),
                liquidityDelta: SEED_L,
                salt: 0
            }),
            ""
        );
    }

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amount) internal {
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings(),
            ""
        );
    }

    /// @dev Exact-input buy: quote in. With quote = currency1 that is oneForZero.
    function _buy(uint256 quoteIn) internal {
        bool quoteIsZero = _quoteIsZero();
        _swap(key, quoteIsZero, -int256(quoteIn));
    }

    /// @dev Exact-input sell: token in.
    function _sell(uint256 tokenIn) internal {
        bool quoteIsZero = _quoteIsZero();
        _swap(key, !quoteIsZero, -int256(tokenIn));
    }

    function _quoteIsZero() internal view returns (bool q) {
        (, q,,) = hook.poolConfig(id);
    }

    function _quote() internal view returns (Currency) {
        return _quoteIsZero() ? currency0 : currency1;
    }

    function _token() internal view returns (Currency) {
        return _quoteIsZero() ? currency1 : currency0;
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    function _sqrt() internal view returns (uint160 s) {
        (s,,,) = manager.getSlot0(id);
    }

    function _claims(Currency c) internal view returns (uint256) {
        return manager.balanceOf(address(hook), c.toId());
    }

    function _posLiquidity(FloorBidHook.Floor memory f) internal view returns (uint128) {
        return manager.getPositionLiquidity(
            id, Position.calculatePositionKey(address(hook), f.tickLower, f.tickUpper, f.salt)
        );
    }

    /// @dev Accrue enough quote into the bucket to clear MIN_POST.
    function _accrue() internal {
        _buy(1e18); // 0.5% -> 5e15 >= MIN_POST
    }

    /// @dev Attempts a raw deploy at a flagged address; returns whether the constructor ran.
    function _tryDeploy(uint256 interval, int24 band, uint256 minPost) internal returns (bool ok) {
        address where = address(flags | uint160(0x1000000));
        bytes memory code = abi.encodePacked(vm.getCode("FloorBidHook.sol:FloorBidHook"), abi.encode(manager, interval, band, minPost));
        vm.etch(where, code);
        (ok,) = where.call("");
        vm.etch(where, "");
    }

    // -----------------------------------------------------------------
    // Constructor bounds (rule 1: immutables validated against hardcoded ceilings)
    // -----------------------------------------------------------------

    function test_constructor_enforcesBounds() public {
        assertTrue(_tryDeploy(1 hours, 600, 1), "lower bounds ok");
        assertTrue(_tryDeploy(7 days, 10_000, 1), "upper bounds ok");
        assertFalse(_tryDeploy(1 hours - 1, 600, 1), "interval below 1h");
        assertFalse(_tryDeploy(7 days + 1, 600, 1), "interval above 7d");
        assertFalse(_tryDeploy(1 hours, 0, 1), "band zero");
        assertFalse(_tryDeploy(1 hours, 10_001, 1), "band above ceiling");
        assertFalse(_tryDeploy(1 hours, 600, 0), "min post zero");
    }

    // -----------------------------------------------------------------
    // I9: quote side one-shot / deployer-only; swaps revert until set
    // -----------------------------------------------------------------

    function test_revertsOnStaticFeePool() public {
        PoolKey memory bad = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(bad, TickMath.getSqrtPriceAtTick(0));
    }

    function test_setQuoteSide_onlyDeployer() public {
        PoolKey memory k2 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 200, IHooks(address(hook)));
        manager.initialize(k2, TickMath.getSqrtPriceAtTick(0));

        vm.prank(stranger);
        vm.expectRevert(FloorBidHook.NotDeployer.selector);
        hook.setQuoteSide(k2, true);
    }

    function test_setQuoteSide_isOneShot() public {
        _open(0, false);
        vm.expectRevert(FloorBidHook.QuoteAlreadySet.selector);
        hook.setQuoteSide(key, true);
        vm.expectRevert(FloorBidHook.QuoteAlreadySet.selector);
        hook.setQuoteSide(key, false);
    }

    function test_swapReverts_beforeQuoteSideSet() public {
        PoolKey memory k2 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        manager.initialize(k2, TickMath.getSqrtPriceAtTick(0));
        _seed(k2);

        vm.expectRevert();
        _swap(k2, true, -1e18);
        vm.expectRevert();
        _swap(k2, false, -1e18);
    }

    function test_postFloor_revertsBeforeQuoteSideSet() public {
        PoolKey memory k2 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        manager.initialize(k2, TickMath.getSqrtPriceAtTick(0));
        vm.expectRevert(FloorBidHook.QuoteNotSet.selector);
        hook.postFloor(k2);
        vm.expectRevert(FloorBidHook.QuoteNotSet.selector);
        hook.nudgeReference(k2);
    }

    // -----------------------------------------------------------------
    // I8: fee split conserves; sells are not cheaper than buys
    // -----------------------------------------------------------------

    /// @dev A buy accrues exactly FLOOR_SHARE of the input to the bucket, held 1:1 as claims.
    function test_buy_accruesExactFloorShare() public {
        _open(0, false);
        uint256 amountIn = 1e18;
        _buy(amountIn);

        uint256 expected = (amountIn * hook.FLOOR_SHARE()) / 1_000_000;
        assertEq(hook.floorBucket(key), expected, "bucket == 0.50% of quote in");
        assertEq(_claims(_quote()), expected, "claims back the bucket 1:1");
        assertEq(_claims(_token()), 0, "no token taken on a buy");
        assertEq(_quote().balanceOf(address(hook)), 0, "hook never holds ERC20");
    }

    /// @dev A sell (token specified) accrues nothing to the hook — LPs take the full 1.00%.
    function test_sell_accruesNothing() public {
        _open(0, false);
        _sell(1e18);
        assertEq(hook.floorBucket(key), 0, "no floor share on the token side");
        assertEq(_claims(_token()), 0, "no token claims");
        assertEq(_claims(_quote()), 0, "no quote claims");
    }

    /// @dev Exact-output with the quote specified (a sell asking for an exact amount of
    ///      quote) still charges the floor share, on the quote output.
    function test_exactOutputQuote_chargesFloorShare() public {
        _open(0, false);
        uint256 wantOut = 1e18;
        _swap(key, true, int256(wantOut)); // zeroForOne, exact output of currency1 (quote)
        uint256 expected = (wantOut * hook.FLOOR_SHARE()) / 1_000_000;
        assertEq(hook.floorBucket(key), expected, "floor share on exact-out quote");
    }

    /// @dev Effective fee vs a zero-fee reference pool with identical liquidity:
    ///      buy ~0.9975% (0.5% then 0.5% compounding), sell 1.00%. Sell >= buy.
    function test_feeSplit_sellNotCheaperThanBuy() public {
        _open(0, false);
        PoolKey memory ref = PoolKey(currency0, currency1, 0, SPACING, IHooks(address(0)));
        manager.initialize(ref, TickMath.getSqrtPriceAtTick(0));
        _seed(ref);

        uint256 amt = 1e18;

        // Buy: quote (currency1) in, token (currency0) out.
        uint256 b0 = currency0.balanceOf(address(this));
        _swap(key, false, -int256(amt));
        uint256 outHooked = currency0.balanceOf(address(this)) - b0;
        b0 = currency0.balanceOf(address(this));
        _swap(ref, false, -int256(amt));
        uint256 outRef = currency0.balanceOf(address(this)) - b0;
        uint256 buyFeePips = ((outRef - outHooked) * 1_000_000) / outRef;

        // Sell: token in, quote out. Fresh state is not needed: the previous swaps
        // moved both pools identically enough at this size (L = 1e21).
        uint256 b1 = currency1.balanceOf(address(this));
        _swap(key, true, -int256(amt));
        uint256 sellHooked = currency1.balanceOf(address(this)) - b1;
        b1 = currency1.balanceOf(address(this));
        _swap(ref, true, -int256(amt));
        uint256 sellRef = currency1.balanceOf(address(this)) - b1;
        uint256 sellFeePips = ((sellRef - sellHooked) * 1_000_000) / sellRef;

        assertGe(buyFeePips, 9_960, "buy fee ~0.9975%");
        assertLe(buyFeePips, 9_980, "buy fee ~0.9975%");
        assertGe(sellFeePips, 9_990, "sell fee ~1.00%");
        assertLe(sellFeePips, 10_010, "sell fee ~1.00%");
        assertGe(sellFeePips, buyFeePips, "sells are not cheaper than buys");
        assertLe(sellFeePips, hook.MAX_TOTAL_FEE() + 10, "never above the ceiling");
    }

    // -----------------------------------------------------------------
    // I2 / I3: band strictly below spot; posting uses only the bucket
    // -----------------------------------------------------------------

    function test_postFloor_bandStrictlyBelowSpot_quoteIsOne() public {
        _open(0, false);
        _accrue();
        int24 tick = _tick();

        uint256 idx = hook.postFloor(key);
        FloorBidHook.Floor memory f = hook.floorAt(key, idx);

        assertEq(hook.floorCount(key), 1);
        assertLt(f.tickUpper, tick, "band entirely below spot");
        assertEq(f.tickUpper - f.tickLower, BAND, "band width");
        assertEq(f.tickLower % SPACING, 0, "aligned lower");
        assertEq(f.tickUpper % SPACING, 0, "aligned upper");
        assertFalse(f.holdsZero, "bid holds currency1 = quote");
        assertFalse(f.isAsk);
        assertEq(_posLiquidity(f), f.liquidity, "position exists in the manager under the hook");

        (uint256 a0, uint256 a1) = hook.floorHoldings(key, idx);
        assertEq(a0, 0, "no token in a fresh bid");
        assertGt(a1, 0, "quote in the bid");
    }

    /// @dev Mirrored orientation: quote = currency0, so "below spot" for the token is
    ///      HIGHER ticks and the bid holds only currency0 (tick < tickLower).
    function test_postFloor_bandStrictlyBelowSpot_quoteIsZero() public {
        _open(0, true);
        _accrue();
        int24 tick = _tick();

        uint256 idx = hook.postFloor(key);
        FloorBidHook.Floor memory f = hook.floorAt(key, idx);

        assertGt(f.tickLower, tick, "band entirely above the tick == below spot for the token");
        assertEq(f.tickUpper - f.tickLower, BAND, "band width");
        assertTrue(f.holdsZero, "bid holds currency0 = quote");
        (uint256 a0, uint256 a1) = hook.floorHoldings(key, idx);
        assertGt(a0, 0, "quote in the bid");
        assertEq(a1, 0, "no token in a fresh bid");
    }

    function test_postFloor_usesOnlyBucket() public {
        _open(0, false);
        _accrue();
        uint256 before = hook.floorBucket(key);
        uint256 claimsBefore = _claims(_quote());
        assertEq(before, claimsBefore);

        uint256 idx = hook.postFloor(key);
        (, uint256 inPos) = hook.floorHoldings(key, idx);
        uint256 after_ = hook.floorBucket(key);

        assertLe(after_ * 1_000_000, before, "leftover dust <= 1 ppm");
        assertEq(_claims(_quote()), after_, "free claims == bucket, nothing unaccounted");
        // used = before - after_; position holds it (rounding of a wei on the read side)
        assertLe(before - after_ - inPos, 2, "bucket decreased by what the position holds");
        assertGe(before - after_, inPos, "position never holds more than was drawn");
        assertEq(_quote().balanceOf(address(hook)), 0, "no ERC20 at the hook");
    }

    /// @dev Fuzz I2 + I3 across ticks, orientation and post size.
    function testFuzz_postFloor_bandBelowSpot_bucketAccounting(int24 initTick, bool quoteIsZero, uint256 buyIn) public {
        initTick = int24(bound(int256(initTick), -200_000, 200_000));
        initTick = (initTick / SPACING) * SPACING;
        buyIn = bound(buyIn, MIN_POST * 200, 1e22);

        _open(initTick, quoteIsZero);
        _buy(buyIn);

        uint256 before = hook.floorBucket(key);
        assertEq(before, (buyIn * hook.FLOOR_SHARE()) / 1_000_000, "accrual exact");
        int24 tick = _tick();

        uint256 idx = hook.postFloor(key);
        FloorBidHook.Floor memory f = hook.floorAt(key, idx);

        if (quoteIsZero) {
            assertGt(f.tickLower, tick, "band above tick (below spot for token)");
        } else {
            assertLt(f.tickUpper, tick, "band below tick");
        }
        assertEq(f.tickUpper - f.tickLower, BAND);
        assertEq(f.tickLower % SPACING, 0);
        assertEq(f.holdsZero, quoteIsZero);
        assertGt(f.liquidity, 0);

        uint256 after_ = hook.floorBucket(key);
        assertLe(after_ * 1_000_000, before, "dust <= 1 ppm of the post");
        assertEq(_claims(_quote()), after_, "free claims == bucket");
        assertEq(_claims(_token()), 0, "no token drawn");

        (uint256 a0, uint256 a1) = hook.floorHoldings(key, idx);
        (uint256 q, uint256 t) = quoteIsZero ? (a0, a1) : (a1, a0);
        assertEq(t, 0, "fresh bid holds no token");
        assertLe(q, before - after_, "position <= drawn");
        assertLe(before - after_ - q, 2, "drawn == position (rounding)");
    }

    // -----------------------------------------------------------------
    // I4: rate limit and minimum size
    // -----------------------------------------------------------------

    function test_postFloor_minSize() public {
        _open(0, false);
        _buy((MIN_POST * 1_000_000) / 5_000 - 1e6); // just under MIN_POST after 0.5%
        assertLt(hook.floorBucket(key), MIN_POST);
        vm.expectRevert(FloorBidHook.BucketTooSmall.selector);
        hook.postFloor(key);

        _buy(1e18);
        hook.postFloor(key);
    }

    function test_postFloor_rateLimited() public {
        _open(0, false);
        _accrue();
        hook.postFloor(key);
        assertEq(hook.nextPostAllowedAt(key), vm.getBlockTimestamp() + INTERVAL);

        _accrue();
        vm.expectRevert(FloorBidHook.TooSoon.selector);
        hook.postFloor(key);

        vm.warp(vm.getBlockTimestamp() + INTERVAL - 1);
        vm.expectRevert(FloorBidHook.TooSoon.selector);
        hook.postFloor(key);

        vm.warp(vm.getBlockTimestamp() + 1);
        hook.postFloor(key);
        assertEq(hook.floorCount(key), 2);
    }

    function test_nudge_sharesRateLimit() public {
        _open(0, false);
        _accrue();
        hook.postFloor(key);
        vm.expectRevert(FloorBidHook.TooSoon.selector);
        hook.nudgeReference(key);

        vm.warp(vm.getBlockTimestamp() + INTERVAL);
        hook.nudgeReference(key);
        _accrue();
        vm.expectRevert(FloorBidHook.TooSoon.selector);
        hook.postFloor(key);
    }

    // -----------------------------------------------------------------
    // I5: reference band guard
    // -----------------------------------------------------------------

    /// @dev First post seeds the reference. After a pump of >10% in sqrt price,
    ///      posting is refused; each nudge (one per interval) closes a quarter of the
    ///      gap, and posting resumes once spot is back inside the band.
    function test_refGuard_pumpBlocksPost_nudgeCatchesUp() public {
        _open(0, false);
        _accrue();
        uint160 spot0 = _sqrt();
        hook.postFloor(key);
        assertEq(hook.refSqrtPriceX96(id), spot0, "first post seeds reference");

        // Pump: 1.5e20 quote into L = 1e21 lifts sqrt price ~15%.
        _buy(15e19);
        uint160 pumped = _sqrt();
        assertGt(uint256(pumped) * 10_000, uint256(spot0) * 11_000, "precondition: >10% in sqrt");

        vm.warp(vm.getBlockTimestamp() + INTERVAL);
        vm.expectRevert(FloorBidHook.PriceDeviates.selector);
        hook.postFloor(key);

        // Nudge 1: ref = (3*ref + spot)/4 — gap shrinks to ~11%, still out of band.
        hook.nudgeReference(key);
        uint160 ref1 = hook.refSqrtPriceX96(id);
        assertEq(ref1, uint160((uint256(spot0) * 3 + uint256(pumped)) / 4), "ref update formula");
        vm.warp(vm.getBlockTimestamp() + INTERVAL);
        vm.expectRevert(FloorBidHook.PriceDeviates.selector);
        hook.postFloor(key);

        // Nudge 2: gap ~8.4%, inside the band.
        hook.nudgeReference(key);
        vm.warp(vm.getBlockTimestamp() + INTERVAL);
        uint256 idx = hook.postFloor(key);
        assertEq(idx, 1, "post resumed once the reference caught up");
    }

    /// @dev A dump past the band is refused the same way (the guard is symmetric).
    function test_refGuard_dumpBlocksPost() public {
        _open(0, false);
        _accrue();
        hook.postFloor(key);
        _sell(2e20);
        _accrue();
        vm.warp(vm.getBlockTimestamp() + INTERVAL);
        vm.expectRevert(FloorBidHook.PriceDeviates.selector);
        hook.postFloor(key);
    }

    // -----------------------------------------------------------------
    // I6: the floor executes — the pool buys its own token
    // -----------------------------------------------------------------

    function test_floorExecutes_poolBuysOwnToken() public {
        _open(0, false);
        _accrue();
        uint256 idx = hook.postFloor(key);
        FloorBidHook.Floor memory f = hook.floorAt(key, idx);

        (uint256 t0, uint256 q0) = hook.floorHoldings(key, idx);
        assertEq(t0, 0);
        assertGt(q0, 0);

        // Sell through the band.
        _sell(1e20);
        assertLt(_tick(), f.tickLower, "precondition: price fell through the band");

        (uint256 t1, uint256 q1) = hook.floorHoldings(key, idx);
        assertGt(t1, 0, "position now holds launched token: the pool bought it");
        assertEq(q1, 0, "all the quote was spent on the bid");
        assertEq(_posLiquidity(f), f.liquidity, "position still owned by the hook");
        assertEq(currency0.balanceOf(address(hook)), 0, "nothing left the manager");
        assertEq(_claims(_token()), 0, "inventory sits in the position, not free");
    }

    // -----------------------------------------------------------------
    // I7: roll — inventory becomes an ask, never leaves the hook
    // -----------------------------------------------------------------

    function test_rollFloor_revertsWhilePartial() public {
        _open(0, false);
        _accrue();
        uint256 idx = hook.postFloor(key);
        FloorBidHook.Floor memory f = hook.floorAt(key, idx);

        vm.warp(vm.getBlockTimestamp() + INTERVAL);
        vm.expectRevert(FloorBidHook.NotConverted.selector);
        hook.rollFloor(key, idx); // untouched

        _sell(3e18); // ~0.6% move: inside the band, partially converted
        int24 t = _tick();
        assertTrue(t >= f.tickLower && t < f.tickUpper, "precondition: inside band");
        vm.expectRevert(FloorBidHook.NotConverted.selector);
        hook.rollFloor(key, idx);
    }

    function test_rollFloor_repostsAsAsk_inventoryStaysInHook() public {
        _open(0, false);
        _accrue();
        uint256 idx = hook.postFloor(key);
        _sell(1e20);
        FloorBidHook.Floor memory f = hook.floorAt(key, idx);
        assertLt(_tick(), f.tickLower, "precondition: fully converted");

        // Rate limit applies to rolls too.
        vm.expectRevert(FloorBidHook.TooSoon.selector);
        hook.rollFloor(key, idx);
        vm.warp(vm.getBlockTimestamp() + INTERVAL);

        // Reference: spot fell ~10% in sqrt; nudge until the roll is allowed.
        while (true) {
            try hook.rollFloor(key, idx) returns (uint256) {
                break;
            } catch {
                hook.nudgeReference(key);
                vm.warp(vm.getBlockTimestamp() + INTERVAL);
            }
        }

        (uint256 tokenHeld,) = hook.floorHoldings(key, idx); // 0 now: inactive
        assertEq(tokenHeld, 0, "old floor drained");
        assertEq(hook.floorAt(key, idx).liquidity, 0, "old floor inactive");
        assertEq(_posLiquidity(f), 0, "old position removed in the manager");

        uint256 newIdx = idx + 1;
        assertEq(hook.floorCount(key), 2);
        FloorBidHook.Floor memory a = hook.floorAt(key, newIdx);
        assertTrue(a.isAsk, "re-posted as an ask");
        assertTrue(a.holdsZero, "ask holds the token (currency0)");
        assertGt(a.tickLower, _tick(), "ask strictly above spot");
        assertEq(a.tickUpper - a.tickLower, BAND);
        assertEq(_posLiquidity(a), a.liquidity);

        (uint256 askToken, uint256 askQuote) = hook.floorHoldings(key, newIdx);
        assertGt(askToken, 0, "inventory is liquidity again");
        assertEq(askQuote, 0);

        // Custody: every unit of token the hook ever received is either in the ask or
        // in the token bucket (dust), still as claims. Nothing at any EOA.
        assertEq(_claims(_token()), hook.tokenBucket(key), "free token claims == token bucket");
        assertLe(hook.tokenBucket(key) * 1_000_000, askToken, "token bucket is dust");
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
        assertEq(_claims(_quote()), hook.floorBucket(key), "free quote claims == quote bucket");

        vm.warp(vm.getBlockTimestamp() + INTERVAL);
        vm.expectRevert(FloorBidHook.FloorInactive.selector);
        hook.rollFloor(key, idx);
        vm.expectRevert(FloorBidHook.NoFloor.selector);
        hook.rollFloor(key, 99);
    }

    /// @dev Full cycle: bid -> ask -> bid. After the ask is crossed upward the pool has
    ///      sold the token for quote, and the roll posts that quote as a fresh bid.
    function test_rollFloor_askBackToBid() public {
        _open(0, false);
        _accrue();
        uint256 bid = hook.postFloor(key);
        _sell(1e20);
        vm.warp(vm.getBlockTimestamp() + INTERVAL);
        uint256 ask;
        while (true) {
            try hook.rollFloor(key, bid) returns (uint256 i) {
                ask = i;
                break;
            } catch {
                hook.nudgeReference(key);
                vm.warp(vm.getBlockTimestamp() + INTERVAL);
            }
        }
        FloorBidHook.Floor memory a = hook.floorAt(key, ask);

        _buy(3e20); // back up through the ask
        assertGe(_tick(), a.tickUpper, "precondition: ask fully crossed");
        (, uint256 quoteInAsk) = hook.floorHoldings(key, ask);
        assertGt(quoteInAsk, 0, "the pool sold the token for quote");

        vm.warp(vm.getBlockTimestamp() + INTERVAL);
        uint256 bid2;
        while (true) {
            try hook.rollFloor(key, ask) returns (uint256 i) {
                bid2 = i;
                break;
            } catch {
                hook.nudgeReference(key);
                vm.warp(vm.getBlockTimestamp() + INTERVAL);
            }
        }
        FloorBidHook.Floor memory b = hook.floorAt(key, bid2);
        assertFalse(b.isAsk, "back to a bid");
        assertLt(b.tickUpper, _tick(), "bid strictly below spot");
        (uint256 t2, uint256 q2) = hook.floorHoldings(key, bid2);
        assertEq(t2, 0);
        assertGt(q2, 0, "quote is a bid again");
        assertEq(_claims(_quote()), hook.floorBucket(key));
        assertEq(_claims(_token()), hook.tokenBucket(key));
    }

    // -----------------------------------------------------------------
    // I1: custody — nothing withdrawable, by anyone
    // -----------------------------------------------------------------

    /// @dev The hook exposes no claim, withdraw, sweep, rescue or ownership function.
    ///      Selectors that a leaky version would have are called raw and must revert
    ///      (there is no fallback / receive either), from a stranger and the deployer.
    function test_noWithdrawPath_existsOrWorks() public {
        _open(0, false);
        _accrue();
        hook.postFloor(key);
        _accrue(); // leave a live bucket as well

        bytes[] memory calls = new bytes[](8);
        calls[0] = abi.encodeWithSignature("claimDeployer(bytes32,address)", id, currency1);
        calls[1] = abi.encodeWithSignature("claimRoyalty(address)", currency1);
        calls[2] = abi.encodeWithSignature("withdraw(address,uint256)", currency1, 1);
        calls[3] = abi.encodeWithSignature("sweep(address)", currency1);
        calls[4] = abi.encodeWithSignature("rescue(address,address,uint256)", currency1, address(this), 1);
        calls[5] = abi.encodeWithSignature("transferOwnership(address)", address(this));
        calls[6] = abi.encodeWithSignature("setFee(uint24)", uint24(0));
        calls[7] = ""; // plain call: no receive/fallback

        address[2] memory callers = [address(this), stranger]; // deployer and stranger
        for (uint256 c = 0; c < callers.length; c++) {
            for (uint256 i = 0; i < calls.length; i++) {
                vm.prank(callers[c]);
                (bool ok,) = address(hook).call(calls[i]);
                assertFalse(ok, "a value-moving entry point exists");
            }
        }

        // ERC-6909 claims cannot be pulled by anyone: the hook never sets an operator.
        assertFalse(manager.isOperator(address(hook), address(this)));
        assertFalse(manager.isOperator(address(hook), stranger));
        assertEq(manager.allowance(address(hook), address(this), currency1.toId()), 0);
    }

    /// @dev Conservation: every wei of quote the hook has taken from swappers is either
    ///      free claims (== bucket) or inside a hook-owned position.
    function test_custody_everythingAccountedFor() public {
        _open(0, false);
        uint256 taken;
        for (uint256 i = 0; i < 3; i++) {
            _buy(1e18);
            taken += (1e18 * uint256(hook.FLOOR_SHARE())) / 1_000_000;
            hook.postFloor(key);
            vm.warp(vm.getBlockTimestamp() + INTERVAL);
        }
        uint256 inPositions;
        for (uint256 i = 0; i < hook.floorCount(key); i++) {
            (, uint256 q) = hook.floorHoldings(key, i);
            inPositions += q;
        }
        uint256 free = _claims(_quote());
        assertEq(free, hook.floorBucket(key), "free claims == bucket");
        assertLe(taken - free - inPositions, 6, "taken == free + positions (per-post rounding)");
        assertEq(currency1.balanceOf(address(hook)), 0, "no ERC20 at the hook");
        assertEq(currency1.balanceOf(stranger), 0);
    }

    // -----------------------------------------------------------------
    // Band placement edge
    // -----------------------------------------------------------------

    /// @dev Spot within one band of the usable tick edge: the band cannot be placed
    ///      without touching the edge, so the hook refuses rather than post a malformed
    ///      band. Exercised through previewBand (the same _band routine postFloor uses)
    ///      because at these prices a single unit of quote buys the whole token supply,
    ///      so fee accrual cannot be staged realistically.
    function test_postFloor_revertsWhenBandCannotFit() public {
        int24 low = TickMath.minUsableTick(30) + 30;
        PoolKey memory k1 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 30, IHooks(address(hook)));
        manager.initialize(k1, TickMath.getSqrtPriceAtTick(low));
        hook.setQuoteSide(k1, false); // bid below spot has no room
        vm.expectRevert(FloorBidHook.BandOutOfRange.selector);
        hook.previewBand(k1);

        int24 high = TickMath.maxUsableTick(SPACING) - SPACING;
        PoolKey memory k2 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(address(hook)));
        manager.initialize(k2, TickMath.getSqrtPriceAtTick(high));
        hook.setQuoteSide(k2, true); // bid is above the tick: no room either
        vm.expectRevert(FloorBidHook.BandOutOfRange.selector);
        hook.previewBand(k2);

        // And a normal pool previews the same band postFloor then uses.
        _open(0, false);
        _accrue();
        (int24 pl, int24 pu) = hook.previewBand(key);
        uint256 idx = hook.postFloor(key);
        FloorBidHook.Floor memory f = hook.floorAt(key, idx);
        assertEq(f.tickLower, pl);
        assertEq(f.tickUpper, pu);
    }
}
