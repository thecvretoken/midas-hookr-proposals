// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrAdvisory} from "hookr/interfaces/IHookrAdvisory.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "hookr/interfaces/IHookrRouter.sol";
import {IHookrRootState} from "hookr/interfaces/IHookrRootState.sol";
import {IHookrRootEvents} from "hookr/interfaces/IHookrRootEvents.sol";
import {HookrToken} from "hookr/support/HookrToken.sol";
import {PeripheryFixture} from "hookr-test/periphery/PeripheryFixture.sol";
import {MidasSizeCapAdvisory} from "../src/MidasSizeCapAdvisory.sol";

/// @notice The refuse path the kit does not cover, run against a real HookrRoot, HookrRules, launcher, router and
///         quoter on one PoolManager and one HookrRegistry (Hookr's PeripheryFixture, unmodified). `cap` is
///         admitted as it declares itself: ADVISORY, every cap zero, ADVISORY_GAS, BEFORE_SWAP, fee-only, failOpen
///         false. A second deployment of the same code, `capOpen`, is admitted fail-open the way Hookr's kit admits
///         every advisory, for the fail-open slot tests. Pools launched through HookrLauncher.launchAdvised:
///         - closedKey, `cap`, fail-closed: 50 bps, maxQuoteIn 1e21, maxSubjectIn 2e21. The ceilings bind (the 50 bps
///           impact cap is about 5e21 at the pool's L = 1e24).
///         - openKey, `capOpen`, fail-open, same terms.
///         - impactKey, `cap`, fail-closed: 10 bps, both ceilings at MAX_IN. The impact cap binds, about 1e21.
///         - floorKey, `cap`, fail-closed: 10 bps, both ceilings at MAX_IN, both floors 1e22. The floor sits above the
///           impact cap, so swaps between about 1e21 and 1e22 are admitted by the floor alone.
///         Every pool opens at price 1, exactly on tick 0's boundary, with L = 1e24 across ticks -60000..60000. Every
///         pool but floorKey binds floors of 0, the block as it was before the floor; the floor tests launch their own.
contract MidasSizeCapAdvisoryTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant PIPS = 1_000_000;
    uint256 internal constant QUOTE_IN = 1e21;
    uint256 internal constant SUBJECT_IN = 2e21;
    /// @dev The floors the floor tests bind: 1e17 quote for a buy, 2e17 subject for a sell.
    uint256 internal constant FLOOR_QUOTE = 1e17;
    uint256 internal constant FLOOR_SUBJECT = 2e17;

    MidasSizeCapAdvisory internal cap;
    MidasSizeCapAdvisory internal capOpen;
    uint32 internal gasLimit;
    PoolKey internal closedKey;
    PoolKey internal openKey;
    PoolKey internal impactKey;
    PoolKey internal floorKey;
    bytes32 internal closedFamily;

    function setUp() public {
        _setUpPeriphery();
        cap = new MidasSizeCapAdvisory(manager);
        capOpen = new MidasSizeCapAdvisory(manager);
        gasLimit = cap.ADVISORY_GAS();
        _admit(address(cap), false);
        _admit(address(capOpen), true);
        (closedKey, closedFamily) = _launch(_subject(), false, _terms(50, QUOTE_IN, SUBJECT_IN));
        (openKey,) = _launch(_subject(), true, _terms(50, QUOTE_IN, SUBJECT_IN));
        (impactKey,) = _launch(_subject(), false, _terms(10, cap.MAX_IN(), cap.MAX_IN()));
        (floorKey,) = _launch(_subject(), false, _termsF(10, cap.MAX_IN(), cap.MAX_IN(), 1e22, 1e22));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Fail-closed and fail-open slots
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Fail-closed: a buy one unit over maxQuoteIn is refused with the root's SwapRejected; a buy of exactly
    ///         maxQuoteIn fills.
    function test_failClosed_overCapBuyRefused_atCapBuyFills() public {
        _refused(closedKey, true, true, QUOTE_IN + 1);
        (uint256 paid, uint256 got) = _route(closedKey, true, true, QUOTE_IN);
        assertEq(paid, QUOTE_IN, "paid the specified input");
        assertGt(got, 0, "filled");
    }

    /// @notice Fail-closed: a sell one unit over maxSubjectIn is refused; a sell of exactly maxSubjectIn fills.
    function test_failClosed_overCapSellRefused_atCapSellFills() public {
        _refused(closedKey, false, true, SUBJECT_IN + 1);
        (uint256 paid, uint256 got) = _route(closedKey, false, true, SUBJECT_IN);
        assertEq(paid, SUBJECT_IN, "paid the specified input");
        assertGt(got, 0, "filled");
    }

    /// @notice The admission the block declares (failOpen false) keeps it out of fail-open slots: the root refuses
    ///         to open a fail-open pool naming it (HookrLane.initializePool), and the launch reverts.
    function test_declaredAdmission_refusesAFailOpenPool() public {
        HookrToken subject = _subject();
        vm.expectRevert(IHookrRootEvents.InvalidConfig.selector);
        this.launchFor(address(cap), subject, true, _terms(50, QUOTE_IN, SUBJECT_IN));
        (PoolKey memory key,) = _launchWith(address(cap), subject, false, _terms(50, QUOTE_IN, SUBJECT_IN));
        assertFalse(root.poolConfig(key.toId()).advisoryFailOpen, "the same pool opens fail-closed");
    }

    /// @notice Fail-open, under a fail-open admission as the kit grants: the same refusal reverts the swap too, as
    ///         InvalidModuleResult(advisory) where a fail-closed slot gives SwapRejected, because HookrRoot._advice
    ///         refuses `reject` from any fail-open advisory. The block gives the same advice in both slots; an in-cap
    ///         swap fills.
    function test_failOpen_refusalRevertsTheSwap() public {
        HookrTypes.SwapContext memory open = _ctx(openKey, true, true, QUOTE_IN + 1);
        HookrTypes.SwapContext memory closed = _ctx(closedKey, true, true, QUOTE_IN + 1);
        assertTrue(_adviseWith(capOpen, open).reject, "open slot advice");
        assertTrue(_advise(closed).reject, "closed slot advice");
        bytes memory invalid =
            _wrapped(abi.encodeWithSelector(IHookrRootEvents.InvalidModuleResult.selector, address(capOpen)));
        _routeReverts(openKey, true, true, QUOTE_IN + 1, invalid);
        _routeReverts(openKey, false, true, SUBJECT_IN + 1, invalid);
        (, uint256 got) = _route(openKey, true, true, QUOTE_IN);
        assertGt(got, 0, "in-cap swap fills");
    }

    /// @notice What fail-open does change: when the block's call itself fails, a fail-open pool lets an over-cap swap
    ///         through at its native LP fee (the admitted LP-fee cap, zero, is the fallback surcharge), and a
    ///         fail-closed pool reverts it with the block's reason. The block never reverts on a bound pool
    ///         (testFuzz_neverRevertsOnABoundPool), so this needs a mocked failure.
    function test_failOpen_failedCallLetsAnOverCapSwapThrough() public {
        uint256 nativeFee = quoter.quote(_swap(openKey, true, true, uint128(QUOTE_IN)), trader).lpFeePips;
        vm.mockCallRevert(address(capOpen), abi.encodeWithSelector(IHookrAdvisory.beforeSwap.selector), "down");
        vm.mockCallRevert(address(cap), abi.encodeWithSelector(IHookrAdvisory.beforeSwap.selector), "down");
        assertEq(
            quoter.quote(_swap(openKey, true, true, uint128(QUOTE_IN + 1)), trader).lpFeePips, nativeFee, "no surcharge"
        );
        (, uint256 got) = _route(openKey, true, true, QUOTE_IN + 1);
        assertGt(got, 0, "fail-open let it through");
        _routeReverts(
            closedKey,
            true,
            true,
            QUOTE_IN + 1,
            _wrapped(
                abi.encodeWithSelector(
                    IHookrRootEvents.ModuleCallReverted.selector,
                    address(cap),
                    IHookrAdvisory.beforeSwap.selector,
                    bytes("down")
                )
            )
        );
    }

    // ------------------------------------------------------------------------------------------------------------
    // Boundaries, exact input and exact output, both directions
    // ------------------------------------------------------------------------------------------------------------

    /// @notice The ceilings, exact input, both directions: exactly the ceiling is admitted, one more is refused.
    function test_boundary_ceiling_exactInput_bothDirections() public {
        for (uint256 i; i < 2; ++i) {
            bool isBuy = i == 0;
            uint256 ceiling = isBuy ? QUOTE_IN : SUBJECT_IN;
            assertEq(cap.maxExactInput(address(root), closedKey.toId(), _zeroForOne(closedKey, isBuy), isBuy), ceiling);
            assertFalse(_advise(_ctx(closedKey, isBuy, true, ceiling)).reject, "at the ceiling");
            (bool ok, MidasSizeCapAdvisory.Reason reason,,) = _explain(_ctx(closedKey, isBuy, true, ceiling + 1));
            assertFalse(ok, "over the ceiling");
            assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.OVER_CEILING), "reason");
        }
    }

    /// @notice The impact cap, exact input, both directions. The cap equals SweepGuard.capIn computed independently
    ///         here on the pool's own slot0 and liquidity; the cap is admitted and fills through the router with a
    ///         realised sqrt move within maxImpactBps; one more unit is refused.
    function test_boundary_impact_exactInput_bothDirections() public {
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            bool isBuy = i == 0;
            bool zeroForOne = _zeroForOne(impactKey, isBuy);
            uint256 expected = _sweepGuardCapIn(impactKey.toId(), 10, zeroForOne);
            assertEq(cap.maxExactInput(address(root), impactKey.toId(), zeroForOne, isBuy), expected, "capIn");
            (bool ok, MidasSizeCapAdvisory.Reason reason,,) = _explain(_ctx(impactKey, isBuy, true, expected + 1));
            assertFalse(ok, "one over the cap");
            assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.OVER_IMPACT), "reason");
            assertFalse(_advise(_ctx(impactKey, isBuy, true, expected)).reject, "at the cap");
            (uint160 before,,,) = manager.getSlot0(impactKey.toId());
            _route(impactKey, isBuy, true, expected);
            (uint160 afterSwap,,,) = manager.getSlot0(impactKey.toId());
            _assertMoveWithin(before, afterSwap, 10);
            console2.log(isBuy ? "impact cap, exact-input buy" : "impact cap, exact-input sell", expected);
            vm.revertToState(snap);
        }
    }

    /// @notice The impact cap, exact output, both directions: the largest output whose own move at active liquidity
    ///         is maxImpactBps is admitted, one more unit is refused, and the admitted output fills.
    function test_boundary_impact_exactOutput_bothDirections() public {
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            bool isBuy = i == 0;
            bool zeroForOne = _zeroForOne(impactKey, isBuy);
            uint256 maxOut = _impactOut(impactKey.toId(), 10, zeroForOne);
            assertFalse(_advise(_ctx(impactKey, isBuy, false, maxOut)).reject, "at the cap");
            (bool ok, MidasSizeCapAdvisory.Reason reason,,) = _explain(_ctx(impactKey, isBuy, false, maxOut + 1));
            assertFalse(ok, "one over");
            assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.OVER_IMPACT), "reason");
            (, uint256 got) = _route(impactKey, isBuy, false, maxOut);
            assertGe(got, maxOut, "the output was delivered");
            _refused(impactKey, isBuy, false, maxOut * 2);
            vm.revertToState(snap);
        }
    }

    /// @notice The ceilings, exact output, both directions: the check costs the output at active liquidity, grosses it
    ///         up by the base LP fee, and compares it with the ceiling. The largest output whose cost fits is admitted
    ///         and fills; the next is refused.
    function test_boundary_ceiling_exactOutput_bothDirections() public {
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            bool isBuy = i == 0;
            bool zeroForOne = _zeroForOne(closedKey, isBuy);
            uint256 ceiling = isBuy ? QUOTE_IN : SUBJECT_IN;
            uint256 lo = _largestExactOutput(closedKey, isBuy, ceiling);
            (bool ok, MidasSizeCapAdvisory.Reason reason, uint256 costIn, uint256 limitIn) =
                _explain(_ctx(closedKey, isBuy, false, lo));
            assertTrue(ok, "largest output that fits");
            assertEq(costIn, _costIn(closedKey.toId(), zeroForOne, lo), "cost");
            assertEq(limitIn, ceiling, "limit");
            (ok, reason, costIn,) = _explain(_ctx(closedKey, isBuy, false, lo + 1));
            assertFalse(ok, "next output");
            assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.OVER_CEILING), "reason");
            assertGt(costIn, ceiling, "its cost");
            (, uint256 got) = _route(closedKey, isBuy, false, lo);
            assertGe(got, lo, "filled");
            vm.revertToState(snap);
            _refused(closedKey, isBuy, false, lo + 1);
            console2.log(isBuy ? "largest exact-output buy" : "largest exact-output sell", lo);
        }
    }

    /// @notice A limit, measured. The exact-output ceiling grosses up by the base LP fee only, so through the router
    ///         the largest exact output the block admits pays the Rules' other charges on top: above the ceiling, by a
    ///         few percent on this fixture's Rules. The exact-input ceiling is exact (test_failClosed_*).
    function test_limit_exactOutputPaysAboveTheCeilingByTheRulesCharges() public {
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            bool isBuy = i == 0;
            uint256 ceiling = isBuy ? QUOTE_IN : SUBJECT_IN;
            uint256 out = _largestExactOutput(closedKey, isBuy, ceiling);
            (bool ok,,,) = _explain(_ctx(closedKey, isBuy, false, out));
            assertTrue(ok, "admitted");
            (uint256 paid,) = _route(closedKey, isBuy, false, out);
            console2.log(isBuy ? "exact-output buy, ceiling" : "exact-output sell, ceiling", ceiling);
            console2.log("  paid", paid);
            if (paid > ceiling) console2.log("  over, in 1e-4 bps", (paid - ceiling) * 1e8 / ceiling);
            assertLe(paid, ceiling * 105 / 100, "within the Rules' charges");
            vm.revertToState(snap);
        }
    }

    /// @notice A limit, measured. The root reserves the Auto Burn (buys) or the quote take (sells) on top of an exact
    ///         output after the advice, so the largest exact output within the impact cap moves the price a little
    ///         past it.
    function test_limit_exactOutputMovesPastTheImpactCapByTheReservation() public {
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            bool isBuy = i == 0;
            uint256 maxOut = _impactOut(impactKey.toId(), 10, _zeroForOne(impactKey, isBuy));
            (uint160 before,,,) = manager.getSlot0(impactKey.toId());
            _route(impactKey, isBuy, false, maxOut);
            (uint160 afterSwap,,,) = manager.getSlot0(impactKey.toId());
            uint256 d = afterSwap > before ? afterSwap - before : before - afterSwap;
            console2.log(
                isBuy ? "exact-output buy move, 1e-6 bps" : "exact-output sell move, 1e-6 bps", d * 1e10 / before
            );
            assertLe(d * BPS, 10 * uint256(before) * 102 / 100, "within 2% of the cap");
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // No active liquidity, and a price on a tick boundary
    // ------------------------------------------------------------------------------------------------------------

    /// @notice With the whole launch position withdrawn there is no active liquidity. The impact cap does not apply at
    ///         zero depth: an exact input is bounded by its direction's ceiling alone (admitted at it, refused one
    ///         over), and an exact output, which cannot be costed at zero depth, is refused.
    function test_noActiveLiquidity_ceilingAloneBoundsExactInput() public {
        uint128 held = launcher.position(closedFamily, 0).liquidity;
        launcher.withdraw(closedFamily, 0, held, 0, 0, address(this), vm.getBlockTimestamp());
        assertEq(manager.getLiquidity(closedKey.toId()), 0, "no liquidity");
        for (uint256 i; i < 2; ++i) {
            bool isBuy = i == 0;
            uint256 ceiling = isBuy ? QUOTE_IN : SUBJECT_IN;
            assertEq(cap.maxExactInput(address(root), closedKey.toId(), _zeroForOne(closedKey, isBuy), isBuy), ceiling);
            (bool ok, MidasSizeCapAdvisory.Reason reason,,) = _explain(_ctx(closedKey, isBuy, true, ceiling));
            assertTrue(ok, "exact input at the ceiling");
            (ok, reason,,) = _explain(_ctx(closedKey, isBuy, true, ceiling + 1));
            assertFalse(ok, "one over the ceiling");
            assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.OVER_CEILING), "reason");
            (ok, reason,,) = _explain(_ctx(closedKey, isBuy, false, 1));
            assertFalse(ok, "exact output");
            assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.NO_LIQUIDITY), "reason");
        }
    }

    /// @notice A launch whose single-sided range ends exactly at the opening price, as a new-token launch does. With
    ///         the subject as currency1 the range is -60000..0 and the PoolManager reports zero active liquidity at
    ///         tick 0, yet a buy moves down across tick 0 into the full range first. The block reads the side the swap
    ///         moves into: the buy is held to the impact cap at the range's own depth (computed here from the
    ///         position's liquidity), admitted at it, refused one over, and fills within the cap. A sell moves away
    ///         from the range into zero depth, where only the ceiling applies. With the subject as currency0 (range
    ///         0..60000) the same holds the other way up.
    function test_priceOnTickBoundary_readsTheSideTheSwapMovesInto() public {
        uint256 maxIn = cap.MAX_IN();
        for (uint256 i; i < 2; ++i) {
            bool subjectIs0 = i == 1;
            HookrToken subject = _subjectOn(subjectIs0);
            (PoolKey memory key, bytes32 family) = _launchSingleSided(subject, _terms(10, maxIn, maxIn));
            (uint160 spot, int24 tick,,) = manager.getSlot0(key.toId());
            assertEq(spot, SQRT_ONE, "price");
            assertEq(tick, 0, "tick");
            assertEq(manager.getLiquidity(key.toId()) == 0, !subjectIs0, "slot0 depth");
            bool buyDown = _zeroForOne(key, true);
            assertEq(buyDown, !subjectIs0, "a buy moves into the range");
            uint256 expected = _capAt(spot, launcher.position(family, 0).liquidity, 10, buyDown);
            assertEq(
                cap.maxExactInput(address(root), key.toId(), buyDown, true), expected, "buy cap at the range's depth"
            );
            assertLt(expected, maxIn, "the impact cap binds");
            (bool ok, MidasSizeCapAdvisory.Reason reason,,) = _explain(_ctx(key, true, true, expected + 1));
            assertFalse(ok, "one over");
            assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.OVER_IMPACT), "reason");
            assertEq(cap.maxExactInput(address(root), key.toId(), !buyDown, false), maxIn, "sell: zero depth");
            (ok, reason,,) = _explain(_ctx(key, false, false, 1));
            assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.NO_LIQUIDITY), "exact-output sell");
            assertFalse(_advise(_ctx(key, true, true, expected)).reject, "at the cap");
            _route(key, true, true, expected);
            (uint160 afterBuy,,,) = manager.getSlot0(key.toId());
            _assertMoveWithin(spot, afterBuy, 10);
        }
    }

    /// @notice The freeze the independent review found, and its fix, with the subject as currency1. A single in-cap
    ///         sell whose impact budget reaches past the top of a single-sided launch range leaves the range, and with
    ///         the router's price limit runs to tick 887271, above the largest tick a position at spacing 60 can cover,
    ///         so no liquidity can ever be active there. Before the fix the block refused every swap at zero depth and
    ///         the pool was frozen for good. Now an exact-input buy up to the ceiling is admitted, crosses the empty
    ///         ticks back into the range, and trading resumes.
    function test_runOut_subjectAsCurrency1_inCapBuyBringsThePoolBack() public {
        _runOutAndRecover(false);
    }

    /// @notice The mirror case: the subject as currency0, range 0..60000, the in-cap sell runs down to MIN_TICK, below
    ///         the smallest usable tick, and an in-cap buy brings the pool back.
    function test_runOut_subjectAsCurrency0_inCapBuyBringsThePoolBack() public {
        _runOutAndRecover(true);
    }

    /// @notice A limit that remains. A swap that stops in a gap between ranges at a usable tick (here by its price
    ///         limit) can have dust liquidity placed over that price. The impact cap then reads the dust and refuses
    ///         anything but dust-sized swaps until real depth is added at that price, after which trading resumes.
    function test_limit_dustLiquidityInAGap_refusesUntilDepthIsAdded() public {
        HookrToken subject = _subjectOn(false);
        (PoolKey memory key,) = _launchSingleSided(subject, _terms(50, QUOTE_IN, SUBJECT_IN));
        (, uint256 got) = _route(key, true, true, 1e18);
        IHookrRouter.Swap memory sell = _swap(key, false, true, uint128(got * 3));
        sell.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(120);
        vm.prank(trader);
        router.swap(sell, address(0), new uint256[](0));
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(tick, 120, "stopped in the gap above the range");
        assertEq(manager.getLiquidity(key.toId()), 0, "zero depth");
        assertFalse(_advise(_ctx(key, true, true, 1e15)).reject, "zero depth: the ceiling alone");
        PoolModifyLiquidityTest lp = _lp(key);
        lp.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: 60, tickUpper: 180, liquidityDelta: 1e3, salt: 0}), ""
        );
        (bool ok, MidasSizeCapAdvisory.Reason reason,,) = _explain(_ctx(key, true, true, 1e15));
        assertFalse(ok, "dust depth refuses");
        assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.OVER_IMPACT), "reason");
        lp.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: 0, tickUpper: 180, liquidityDelta: 1e21, salt: 0}), ""
        );
        assertFalse(_advise(_ctx(key, true, true, 1e15)).reject, "real depth admits");
        (, uint256 bought) = _route(key, true, true, 1e15);
        assertGt(bought, 0, "trading resumes");
    }

    // ------------------------------------------------------------------------------------------------------------
    // The floor: the size always admitted, whatever the impact cap says
    // ------------------------------------------------------------------------------------------------------------

    /// @notice The known limit, closed. test_limit_dustLiquidityInAGap_refusesUntilDepthIsAdded shows dust over a price
    ///         stopped in a gap holding a floor-0 pool to dust-sized swaps. With floors of 1e17 quote and 2e17 subject
    ///         the same state, built the same way, admits a buy of exactly the quote floor and a sell of exactly the
    ///         subject floor, though the impact cap read at the dust is a few wei; one unit more falls back to that
    ///         cap and is refused. An exact output there is still refused: it is larger than anything the dust pays
    ///         out, so it cannot be costed. The floor-sized buy crosses the dust and the gap into the launch range and
    ///         trading resumes without anyone adding depth. Both token orders.
    function test_floor_dustInAGap_floorSizedSwapTradesThePoolBack_bothTokenOrders() public {
        for (uint256 i; i < 2; ++i) {
            bool subjectIs0 = i == 1;
            PoolKey memory key = _dustInAGap(subjectIs0, _termsF(50, QUOTE_IN, SUBJECT_IN, FLOOR_QUOTE, FLOOR_SUBJECT));
            PoolId id = key.toId();
            (uint160 spot,,,) = manager.getSlot0(id);
            uint128 dust = manager.getLiquidity(id);
            assertEq(dust, 1e3, "dust depth");
            for (uint256 d; d < 2; ++d) {
                bool isBuy = d == 0;
                bool zeroForOne = _zeroForOne(key, isBuy);
                uint256 floor = isBuy ? FLOOR_QUOTE : FLOOR_SUBJECT;
                uint256 dustCap = _capAt(spot, dust, 50, zeroForOne);
                assertLt(dustCap, 1e3, "the impact cap at the dust is dust");
                assertEq(cap.maxExactInput(address(root), id, zeroForOne, isBuy), floor, "maxExactInput is the floor");
                (bool ok, MidasSizeCapAdvisory.Reason reason, uint256 amountIn,) =
                    _explain(_ctx(key, isBuy, true, floor));
                assertTrue(ok, "the floor is admitted");
                assertEq(amountIn, floor);
                (ok, reason,,) = _explain(_ctx(key, isBuy, true, floor + 1));
                assertFalse(ok, "one over the floor");
                assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.OVER_IMPACT), "falls back to the impact cap");
                (ok, reason,,) = _explain(_ctx(key, isBuy, false, 1e15));
                assertFalse(ok, "exact output past what the dust pays out");
                assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.OVER_IMPACT), "exact output reason");
            }
            (, uint256 bought) = _route(key, true, true, FLOOR_QUOTE);
            assertGt(bought, 0, "the floor-sized buy filled");
            (, int24 tick,,) = manager.getSlot0(id);
            assertTrue(subjectIs0 ? tick >= 0 : tick < 0, "back in the launch range");
            assertGt(manager.getLiquidity(id), 1e3, "real depth again");
            (, bought) = _route(key, true, true, 1e18);
            assertGt(bought, 0, "trading resumes");
        }
    }

    /// @notice Where the floor sits relative to the impact cap decides everything. On a full-depth pool (L = 1e24,
    ///         10 bps, both ceilings at MAX_IN) the impact cap is about 1e21, far above the floors, and the floor changes nothing: admitted up
    ///         to the impact cap, refused one over. On the same terms with the launch position thinned to 1e-5 of
    ///         itself (L = 1e19) the impact cap is about 1e16, under the floors: an exact input between the two is
    ///         admitted, exactly the floor is admitted and fills, one over is refused for impact. The realised move of
    ///         that floor-sized swap is logged: past the 10 bps cap, which is what a floor means at thin depth. Both
    ///         directions, both token orders.
    function test_floor_overTheFloorFallsBackToTheImpactCap_bothDirectionsBothOrders() public {
        bytes memory terms = _termsF(10, cap.MAX_IN(), cap.MAX_IN(), FLOOR_QUOTE, FLOOR_SUBJECT);
        for (uint256 i; i < 2; ++i) {
            bool subjectIs0 = i == 1;
            (PoolKey memory deep,) = _launch(_subjectOn(subjectIs0), false, terms);
            PoolKey memory thin = _thinPool(subjectIs0, terms, 1e5);
            for (uint256 d; d < 2; ++d) {
                bool isBuy = d == 0;
                uint256 floor = isBuy ? FLOOR_QUOTE : FLOOR_SUBJECT;

                bool zeroForOne = _zeroForOne(deep, isBuy);
                uint256 impact = _sweepGuardCapIn(deep.toId(), 10, zeroForOne);
                assertGt(impact, floor, "deep: the impact cap is above the floor");
                assertEq(
                    cap.maxExactInput(address(root), deep.toId(), zeroForOne, isBuy), impact, "deep: the impact cap"
                );
                assertFalse(_advise(_ctx(deep, isBuy, true, impact)).reject, "deep: at the impact cap");
                (bool ok, MidasSizeCapAdvisory.Reason reason,,) = _explain(_ctx(deep, isBuy, true, impact + 1));
                assertFalse(ok, "deep: one over the impact cap");
                assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.OVER_IMPACT), "deep: reason");

                zeroForOne = _zeroForOne(thin, isBuy);
                impact = _sweepGuardCapIn(thin.toId(), 10, zeroForOne);
                assertLt(impact * 5, floor, "thin: the impact cap is well under the floor");
                assertEq(cap.maxExactInput(address(root), thin.toId(), zeroForOne, isBuy), floor, "thin: the floor");
                assertFalse(_advise(_ctx(thin, isBuy, true, impact + 1)).reject, "thin: between the cap and the floor");
                assertFalse(_advise(_ctx(thin, isBuy, true, floor)).reject, "thin: at the floor");
                (ok, reason,,) = _explain(_ctx(thin, isBuy, true, floor + 1));
                assertFalse(ok, "thin: one over the floor");
                assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.OVER_IMPACT), "thin: reason");
                _refused(thin, isBuy, true, floor + 1);

                uint256 snap = vm.snapshotState();
                (uint160 before,,,) = manager.getSlot0(thin.toId());
                (uint256 paid,) = _route(thin, isBuy, true, floor);
                assertEq(paid, floor, "a floor-sized exact input pays exactly the floor");
                (uint160 afterSwap,,,) = manager.getSlot0(thin.toId());
                uint256 move = afterSwap > before ? afterSwap - before : before - afterSwap;
                assertGt(move * BPS, 10 * uint256(before), "past the 10 bps cap");
                console2.log(
                    isBuy
                        ? "thin pool, floor-sized buy, sqrt move in 1e-2 bps"
                        : "thin pool, floor-sized sell, sqrt move in 1e-2 bps",
                    move * BPS * 100 / before
                );
                vm.revertToState(snap);
            }
        }
    }

    /// @notice A floor never lets a swap past its ceiling. Floors equal to the ceilings (the most `bind` accepts) on a
    ///         thinned pool (L = 1e22, the impact cap about 1e19): maxExactInput is the ceiling, the ceiling is admitted
    ///         and an exact input of it pays exactly the ceiling, one more is refused as OVER_CEILING and reverts
    ///         through the router. For exact output the largest output whose cost fits the ceiling is admitted and one
    ///         more is refused; what that output pays through the router, logged, is above the ceiling by the Rules'
    ///         charges, the same approximation test_limit_exactOutputPaysAboveTheCeilingByTheRulesCharges measures
    ///         without a floor. Both directions, both token orders.
    function test_floor_neverLetsASwapPastTheCeiling() public {
        for (uint256 i; i < 2; ++i) {
            bool subjectIs0 = i == 1;
            PoolKey memory key = _thinPool(subjectIs0, _termsF(10, QUOTE_IN, SUBJECT_IN, QUOTE_IN, SUBJECT_IN), 100);
            for (uint256 d; d < 2; ++d) {
                bool isBuy = d == 0;
                bool zeroForOne = _zeroForOne(key, isBuy);
                uint256 ceiling = isBuy ? QUOTE_IN : SUBJECT_IN;
                assertLt(_sweepGuardCapIn(key.toId(), 10, zeroForOne) * 10, ceiling, "the impact cap is far under");
                assertEq(cap.maxExactInput(address(root), key.toId(), zeroForOne, isBuy), ceiling, "the ceiling");
                assertFalse(_advise(_ctx(key, isBuy, true, ceiling)).reject, "at the ceiling");
                (bool ok, MidasSizeCapAdvisory.Reason reason,,) = _explain(_ctx(key, isBuy, true, ceiling + 1));
                assertFalse(ok, "one over the ceiling");
                assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.OVER_CEILING), "reason");
                _refused(key, isBuy, true, ceiling + 1);

                uint256 lo = _largestExactOutput(key, isBuy, ceiling);
                uint256 costIn;
                (ok,, costIn,) = _explain(_ctx(key, isBuy, false, lo));
                assertTrue(ok, "largest exact output within the ceiling");
                assertLe(costIn, ceiling, "its cost");
                (ok,, costIn,) = _explain(_ctx(key, isBuy, false, lo + 1));
                assertFalse(ok, "the next output");
                assertGt(costIn, ceiling, "its cost is over");

                uint256 snap = vm.snapshotState();
                (uint256 paid,) = _route(key, isBuy, true, ceiling);
                assertEq(paid, ceiling, "exact input: exactly the ceiling");
                vm.revertToState(snap);
                (paid,) = _route(key, isBuy, false, lo);
                console2.log(
                    isBuy
                        ? "floor = ceiling, exact-output buy, ceiling"
                        : "floor = ceiling, exact-output sell, ceiling",
                    ceiling
                );
                console2.log("  paid", paid);
                assertLe(paid, ceiling * 105 / 100, "exact output: within the Rules' charges");
                vm.revertToState(snap);
            }
        }
    }

    /// @notice Exact output under the floor, both directions and token orders, on the thinned pool (L = 1e19, 10 bps,
    ///         floors 1e17 and 2e17). The output is costed as the ceiling costs it: at active liquidity, grossed up
    ///         by the base LP fee, rounded up. The largest output whose cost fits the floor is over the impact cap
    ///         (the floor is what admits it), is admitted with exactly that cost, and fills; one more is refused as
    ///         OVER_IMPACT with a cost over the floor. What it pays through the router is logged against the floor.
    function test_floor_exactOutput_costedLikeTheCeiling_bothDirectionsBothOrders() public {
        bytes memory terms = _termsF(10, QUOTE_IN, SUBJECT_IN, FLOOR_QUOTE, FLOOR_SUBJECT);
        for (uint256 i; i < 2; ++i) {
            bool subjectIs0 = i == 1;
            PoolKey memory key = _thinPool(subjectIs0, terms, 1e5);
            for (uint256 d; d < 2; ++d) {
                bool isBuy = d == 0;
                bool zeroForOne = _zeroForOne(key, isBuy);
                uint256 floor = isBuy ? FLOOR_QUOTE : FLOOR_SUBJECT;
                uint256 lo = _largestExactOutput(key, isBuy, floor);
                assertGt(lo, _impactOut(key.toId(), 10, zeroForOne), "over the impact cap");
                (bool ok, MidasSizeCapAdvisory.Reason reason, uint256 costIn, uint256 limitIn) =
                    _explain(_ctx(key, isBuy, false, lo));
                assertTrue(ok, "the floor admits it");
                assertEq(costIn, _costIn(key.toId(), zeroForOne, lo), "costed as the ceiling costs it");
                assertLe(costIn, floor, "within the floor");
                assertEq(limitIn, isBuy ? QUOTE_IN : SUBJECT_IN, "limit is the ceiling");
                (ok, reason, costIn,) = _explain(_ctx(key, isBuy, false, lo + 1));
                assertFalse(ok, "one more");
                assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.OVER_IMPACT), "reason");
                assertGt(costIn, floor, "its cost is over the floor");
                _refused(key, isBuy, false, lo + 1);
                uint256 snap = vm.snapshotState();
                (uint256 paid, uint256 got) = _route(key, isBuy, false, lo);
                assertGe(got, lo, "delivered");
                console2.log(
                    isBuy
                        ? "exact-output buy under the quote floor, paid"
                        : "exact-output sell under the subject floor, paid",
                    paid
                );
                assertLe(paid, floor * 105 / 100, "within the Rules' charges of the floor");
                vm.revertToState(snap);
            }
        }
    }

    /// @notice Bind takes exactly five words. A floor above its own direction's ceiling is refused (codes 5 and 6),
    ///         a dirty floor word is caught by the same check, a bad ceiling is reported before its floor, and the
    ///         three-word terms of the version before the floor are refused as the wrong length. Floors of 0 and
    ///         floors equal to their ceilings bind; `config` returns them and `Bound` carries them. Through the real
    ///         launcher a floor over its ceiling stops the launch. The schema hash names all five words.
    function test_floor_bind_validation() public {
        uint256 maxIn = cap.MAX_IN();
        bytes memory code1 = abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 1);
        _bindReverts(abi.encode(uint256(50), uint256(1), uint256(1)), code1);
        _bindReverts(_termsF(50, 10, 20, 11, 0), abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 5));
        _bindReverts(_termsF(50, 10, 20, 0, 21), abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 6));
        _bindReverts(_termsF(50, 20, 10, 20, 11), abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 6));
        _bindReverts(
            _termsF(50, maxIn, maxIn, maxIn + 1, 0),
            abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 5)
        );
        _bindReverts(
            _termsF(50, maxIn, maxIn, 0, (1 << 255) | 1),
            abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 6)
        );
        _bindReverts(_termsF(50, 0, 20, 1, 0), abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 3));
        _bindReverts(_termsF(50, 10, 0, 0, 1), abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 4));

        (PoolKey memory key, HookrTypes.PoolConfig memory pc) = _freshPool();
        bytes memory data = _termsF(50, 10, 20, 10, 20);
        vm.expectEmit(true, true, false, true, address(cap));
        emit MidasSizeCapAdvisory.Bound(address(root), key.toId(), 50, 10, 20, 10, 20);
        vm.prank(address(root));
        assertEq(cap.bind(key, pc, data), keccak256(data), "config hash");
        MidasSizeCapAdvisory.Config memory c = cap.config(address(root), key.toId());
        assertEq(c.maxImpactBps, 50);
        assertEq(c.maxQuoteIn, 10);
        assertEq(c.maxSubjectIn, 20);
        assertEq(c.floorQuoteIn, 10);
        assertEq(c.floorSubjectIn, 20);

        (key, pc) = _freshPool();
        vm.expectEmit(true, true, false, true, address(cap));
        emit MidasSizeCapAdvisory.Bound(
            address(root), key.toId(), 50, uint120(maxIn), uint120(maxIn), 0, uint120(maxIn)
        );
        vm.prank(address(root));
        cap.bind(key, pc, _termsF(50, maxIn, maxIn, 0, maxIn));
        c = cap.config(address(root), key.toId());
        assertEq(c.floorQuoteIn, 0);
        assertEq(c.floorSubjectIn, maxIn);

        HookrToken subject = _subject();
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallReverted.selector,
                address(cap),
                IHookrAdvisory.bind.selector,
                abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 5)
            )
        );
        this.launchFor(address(cap), subject, false, _termsF(50, QUOTE_IN, SUBJECT_IN, QUOTE_IN + 1, 0));

        assertEq(
            cap.configSchemaHash(),
            keccak256(
                "MidasSizeCap(uint16 maxImpactBps,uint120 maxQuoteIn,uint120 maxSubjectIn,uint120 floorQuoteIn,uint120 floorSubjectIn)"
            ),
            "schema"
        );
    }

    /// @notice Floors of 0 are the block as it was, on the real fixture: on the impact-bound pool and the
    ///         ceiling-bound pool, maxExactInput in every direction equals what the pre-floor rule gives (SweepGuard's
    ///         term against the ceiling, computed here), and exact inputs and outputs one unit either side of each
    ///         bound get the pre-floor answer. MidasSizeCapMath.t.sol runs the 80fbd9f block beside this one on
    ///         arbitrary states and finds every answer identical; every other test in this file binds floors of 0.
    function test_floor_zeroIsTheBlockAsItWas() public {
        PoolKey[2] memory keys = [impactKey, closedKey];
        for (uint256 k; k < 2; ++k) {
            PoolKey memory key = keys[k];
            MidasSizeCapAdvisory.Config memory c = cap.config(address(root), key.toId());
            assertEq(c.floorQuoteIn, 0, "no quote floor");
            assertEq(c.floorSubjectIn, 0, "no subject floor");
            for (uint256 d; d < 2; ++d) {
                bool isBuy = d == 0;
                bool zeroForOne = _zeroForOne(key, isBuy);
                uint256 ceiling = isBuy ? c.maxQuoteIn : c.maxSubjectIn;
                uint256 impact = _sweepGuardCapIn(key.toId(), c.maxImpactBps, zeroForOne);
                uint256 maxIn = impact < ceiling ? impact : ceiling;
                assertEq(cap.maxExactInput(address(root), key.toId(), zeroForOne, isBuy), maxIn, "maxExactInput");
                assertFalse(_advise(_ctx(key, isBuy, true, maxIn)).reject, "at the cap");
                (bool ok, MidasSizeCapAdvisory.Reason reason,,) = _explain(_ctx(key, isBuy, true, maxIn + 1));
                assertFalse(ok, "one over");
                assertEq(
                    uint8(reason),
                    uint8(
                        impact < ceiling
                            ? MidasSizeCapAdvisory.Reason.OVER_IMPACT
                            : MidasSizeCapAdvisory.Reason.OVER_CEILING
                    ),
                    "reason"
                );
                uint256 out = _impactOut(key.toId(), c.maxImpactBps, zeroForOne);
                uint256 amountIn;
                (ok, reason, amountIn,) = _explain(_ctx(key, isBuy, false, out + 1));
                assertFalse(ok, "exact output one over the impact cap");
                assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.OVER_IMPACT), "exact output reason");
                assertEq(amountIn, 0, "not costed, as before");
            }
        }
    }

    /// @notice The abuse case, measured: many floor-sized swaps in one transaction walking a single-sided range out.
    ///         Two new-token launches each hold 1e19 subject over -60000..0 (subject as currency1, L about 1.05e19),
    ///         at 50 bps with the usual ceilings; one binds a 1e19 quote floor, one none. Each is bought out by
    ///         repeated exact-input buys in this one transaction until the price leaves the range: floor-sized buys on
    ///         the first, buys sized at maxExactInput (the impact cap) on the second. Every buy is admitted on both.
    ///         The floor cuts the number of swaps (and the gas) by more than an order of magnitude; the quote paid to
    ///         walk out is the same within 1%, since either way the walker buys every unit of subject in the range at
    ///         the curve's price plus the Rules' charges. The block keeps no state on the swap path, so it cannot see
    ///         the repetition; the floor makes each step independent of depth. After the walk the pool sits past the
    ///         range at zero depth, where the pre-floor rule (the ceiling alone) already applied, and a sell brings it
    ///         back: nothing is stranded.
    function test_abuse_floorSizedSwapsWalkAThinSingleSidedRangeOutInOneTx() public {
        (PoolKey memory withFloor,) =
            _launchSingleSidedSized(_subjectOn(false), _termsF(50, QUOTE_IN, SUBJECT_IN, 1e19, 0), 1e19);
        (PoolKey memory noFloor,) = _launchSingleSidedSized(_subjectOn(false), _terms(50, QUOTE_IN, SUBJECT_IN), 1e19);
        assertLt(
            cap.maxExactInput(address(root), noFloor.toId(), true, true), 1e19 / 10, "at the start the cap is far under"
        );
        (uint256 nFloor, uint256 paidFloor, uint256 gasFloor, uint256 gotFloor) = _walkOut(withFloor, 1e19);
        (uint256 nCap, uint256 paidCap, uint256 gasCap, uint256 gotCap) = _walkOut(noFloor, 0);
        console2.log("walk out with a 1e19 floor: swaps", nFloor);
        console2.log("  quote paid", paidFloor);
        console2.log("  subject bought", gotFloor);
        console2.log("  router gas", gasFloor);
        console2.log("walk out at the impact cap: swaps", nCap);
        console2.log("  quote paid", paidCap);
        console2.log("  subject bought", gotCap);
        console2.log("  router gas", gasCap);
        assertLt(nFloor * 10, nCap, "the floor cuts the swaps by more than tenfold");
        assertApproxEqRel(paidFloor, paidCap, 0.01e18, "the same quote either way");
        assertApproxEqRel(gotFloor, gotCap, 0.01e18, "the same subject either way");
        // Out of the range at zero depth: the ceiling alone, as before the floor; a sell brings the price back.
        for (uint256 k; k < 2; ++k) {
            PoolKey memory key = k == 0 ? withFloor : noFloor;
            assertEq(manager.getLiquidity(key.toId()), 0, "past the range");
            assertEq(cap.maxExactInput(address(root), key.toId(), false, false), SUBJECT_IN, "sell: the ceiling");
            _route(key, false, true, 1e18);
            (, int24 tick,,) = manager.getSlot0(key.toId());
            assertGe(tick, -60_000, "back in the range");
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Bind
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Zero and over-ceiling terms revert, as does any length but five words; the ceilings themselves are
    ///         accepted.
    function test_bind_termsAtAndPastTheirCeilings() public {
        uint256 maxIn = cap.MAX_IN();
        uint256 maxBps = cap.MAX_IMPACT_BPS();
        _bindReverts(
            abi.encode(uint256(50), uint256(1)), abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 1)
        );
        _bindReverts(
            abi.encode(uint256(50), uint256(1), uint256(1), uint256(1)),
            abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 1)
        );
        _bindReverts(
            abi.encode(uint256(50), uint256(1), uint256(1), uint256(0), uint256(0), uint256(0)),
            abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 1)
        );
        _bindReverts(_terms(0, 1, 1), abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 2));
        _bindReverts(_terms(maxBps + 1, 1, 1), abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 2));
        _bindReverts(_terms(1 << 16 | 50, 1, 1), abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 2));
        _bindReverts(_terms(50, 0, 1), abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 3));
        _bindReverts(_terms(50, maxIn + 1, 1), abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 3));
        _bindReverts(_terms(50, 1, 0), abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 4));
        _bindReverts(_terms(50, 1, maxIn + 1), abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 4));
        (PoolKey memory key, HookrTypes.PoolConfig memory pc) = _freshPool();
        vm.prank(address(root));
        bytes memory data = _terms(maxBps, maxIn, maxIn);
        assertEq(cap.bind(key, pc, data), keccak256(data), "config hash");
        MidasSizeCapAdvisory.Config memory c = cap.config(address(root), key.toId());
        assertEq(c.maxImpactBps, maxBps);
        assertEq(c.maxQuoteIn, maxIn);
        assertEq(c.maxSubjectIn, maxIn);
        assertEq(c.floorQuoteIn, 0);
        assertEq(c.floorSubjectIn, 0);
        (key, pc) = _freshPool();
        vm.prank(address(root));
        cap.bind(key, pc, _terms(1, 1, 1));
    }

    /// @notice A pool or admission that says anything other than what the block declares is refused, and a pool binds
    ///         once.
    function test_bind_refusesWhatItDoesNotDeclare() public {
        bytes memory data = _terms(50, 1, 1);
        (PoolKey memory key, HookrTypes.PoolConfig memory pc) = _freshPool();
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidPoolConfig.selector, 1));
        cap.bind(key, pc, data);
        pc.advisory = address(0xBEEF);
        _bindReverts(key, pc, data, 2);
        (key, pc) = _freshPool();
        for (uint8 phases; phases < 4; ++phases) {
            if (phases == HookrTypes.BEFORE_SWAP) continue;
            pc.advisoryPhases = phases;
            _bindReverts(key, pc, data, 3);
        }
        (key, pc) = _freshPool();
        pc.advisoryGasLimit = gasLimit - 1;
        _bindReverts(key, pc, data, 4);
        (key, pc) = _freshPool();
        MidasSizeCapAdvisory other = new MidasSizeCapAdvisory(IPoolManager(address(registry)));
        pc.advisory = address(other);
        vm.prank(address(root));
        vm.expectRevert(abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidPoolConfig.selector, 5));
        other.bind(key, pc, data);
        (key, pc) = _freshPool();
        IHookrRegistry.Admission memory a = registry.admission(address(root), address(cap));
        a.caps.maxLpFeePips = 1;
        vm.mockCall(
            address(registry), abi.encodeCall(IHookrRegistry.admission, (address(root), address(cap))), abi.encode(a)
        );
        _bindReverts(key, pc, data, 6);
        vm.clearMockedCalls();
        vm.prank(address(root));
        cap.bind(key, pc, data);
        vm.prank(address(root));
        vm.expectRevert(abi.encodeWithSelector(MidasSizeCapAdvisory.AlreadyBound.selector, address(root), key.toId()));
        cap.bind(key, pc, data);
    }

    /// @notice Through the real launcher, a pool whose terms are out of range does not open: the root reverts the
    ///         launch with the block's reason inside ModuleCallReverted.
    function test_bind_badTermsStopTheLaunch() public {
        HookrToken subject = _subject();
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallReverted.selector,
                address(cap),
                IHookrAdvisory.bind.selector,
                abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidTerms.selector, 2)
            )
        );
        this.launchFor(address(cap), subject, false, _terms(0, QUOTE_IN, SUBJECT_IN));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Gas
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Every beforeSwap path answers within ADVISORY_GAS and gives the advice expected of it, the floor's paths
    ///         included, and so does bind, with floors of 0 and with floors set. The figures are logged.
    /// @dev    Each call is measured from a snapshot taken before anything in this transaction touched the block, the
    ///         PoolManager or the registry, so their accounts and every slot read are cold, and the caller's cold
    ///         access to the block is inside the figure. vm.cool alone, which the earlier version of this test used,
    ///         re-cools slots but not an account already touched, so only the first path it measured was fully cold.
    ///         The root is warm for bind, as it is when it calls bind; the PoolManager is warm during a real swap, so
    ///         the beforeSwap figures are an upper bound.
    function test_gas_everyPathUnderTheDeclaredLimit() public {
        HookrTypes.SwapContext[14] memory paths = [
            _ctx(closedKey, _buyFor(closedKey, false), true, 1e18), // admitted, up, no boundary read
            _ctx(closedKey, _buyFor(closedKey, true), true, 1e18), // admitted, down, reads tick 0's liquidity
            _ctx(closedKey, _buyFor(closedKey, true), true, 1e30), // over the ceiling
            _ctx(impactKey, _buyFor(impactKey, true), true, 1e22), // over the impact cap, floor 0
            _ctx(closedKey, _buyFor(closedKey, true), false, 1e18), // exact output, admitted
            _ctx(closedKey, _buyFor(closedKey, true), false, 1e30), // exact output over the impact cap, floor 0
            _ctx(floorKey, _buyFor(floorKey, false), true, 5e21), // over the impact cap, within the floor, up
            _ctx(floorKey, _buyFor(floorKey, true), true, 5e21), // the same, down across tick 0
            _ctx(floorKey, _buyFor(floorKey, true), true, 2e22), // over the impact cap and the floor
            _ctx(floorKey, _buyFor(floorKey, false), false, 5e21), // exact output costed under the floor, up
            _ctx(floorKey, _buyFor(floorKey, true), false, 5e21), // the same, down across tick 0
            _ctx(floorKey, _buyFor(floorKey, true), false, 2e22), // exact output costed over the floor
            _ctx(floorKey, _buyFor(floorKey, false), false, 2e22), // the same, up
            _ctx(floorKey, _buyFor(floorKey, true), false, 1e30) // exact output past what the depth pays out
        ];
        string[14] memory names = [
            "beforeSwap exact in, up",
            "beforeSwap exact in, down across tick 0",
            "beforeSwap exact in, over the ceiling",
            "beforeSwap exact in, over the impact cap",
            "beforeSwap exact out, admitted",
            "beforeSwap exact out, over the impact cap",
            "beforeSwap exact in, floor admits, up",
            "beforeSwap exact in, floor admits, down across tick 0",
            "beforeSwap exact in, over the impact cap and the floor",
            "beforeSwap exact out, floor admits, up",
            "beforeSwap exact out, floor admits, down across tick 0",
            "beforeSwap exact out, costed over the floor, down",
            "beforeSwap exact out, costed over the floor, up",
            "beforeSwap exact out, past what the depth pays out"
        ];
        bool[14] memory admitted =
            [true, true, false, false, true, false, true, true, false, true, true, false, false, false];
        bytes[2] memory binds;
        for (uint256 f; f < 2; ++f) {
            (PoolKey memory key, HookrTypes.PoolConfig memory pc) = _freshPool();
            bytes memory terms = f == 0
                ? _terms(50, QUOTE_IN, SUBJECT_IN)
                : _termsF(50, QUOTE_IN, SUBJECT_IN, FLOOR_QUOTE, FLOOR_SUBJECT);
            binds[f] = abi.encodeCall(IHookrAdvisory.bind, (key, pc, terms));
        }
        // Everything the window would otherwise read from this contract's storage, read now.
        address block_ = address(cap);
        address caller = address(root);
        uint32 limit = gasLimit;
        uint256 cold = vm.snapshotState();

        uint256 worst;
        for (uint256 i; i < paths.length; ++i) {
            bytes memory input = abi.encodeCall(IHookrAdvisory.beforeSwap, (paths[i]));
            vm.revertToState(cold);
            vm.prank(caller);
            uint256 g = gasleft();
            (bool ok, bytes memory out) = block_.staticcall{gas: limit}(input);
            uint256 used = g - gasleft();
            assertTrue(ok, names[i]);
            assertEq(out.length, 128, "four words");
            assertEq(abi.decode(out, (HookrTypes.Advice)).reject, !admitted[i], names[i]);
            console2.log(names[i], used);
            if (used > worst) worst = used;
        }
        assertLe(worst, limit, "within the declared limit");
        console2.log("beforeSwap worst case, cold", worst);

        for (uint256 f; f < 2; ++f) {
            vm.revertToState(cold);
            vm.prank(caller);
            uint256 before = gasleft();
            (bool bound,) = block_.call{gas: limit}(binds[f]);
            uint256 bindGas = before - gasleft();
            assertTrue(bound, "bind within the limit");
            console2.log(f == 0 ? "bind, cold, floors 0" : "bind, cold, floors set", bindGas);
            assertLe(bindGas, limit);
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Authority and storage probes
    // ------------------------------------------------------------------------------------------------------------

    /// @notice The build artifact exposes exactly these functions: the five IHookrAdvisory calls, three views and four
    ///         constants. No owner, setter, pause, initializer or upgrade function exists, no proxy slot is set, and
    ///         nothing answers an unknown selector or a plain transfer.
    function test_probe_noAdminOrUpgradeSurface() public {
        string[13] memory expected = [
            "ADVISORY_GAS()",
            "MAX_IMPACT_BPS()",
            "MAX_IN()",
            "PHASES()",
            "afterSwap((bytes32,address,address,address,address,address,bool,bool,bool,bool,int256,uint160,uint24),int128,int128)",
            "beforeAddLiquidity(bytes32,address)",
            "beforeSwap((bytes32,address,address,address,address,address,bool,bool,bool,bool,int256,uint160,uint24))",
            "bind((address,address,uint24,int24,address),(address,address,address,address,address,uint24,(uint24,uint24,uint16),uint32,uint32,uint8,bool,bytes32),bytes)",
            "config(address,bytes32)",
            "configSchemaHash()",
            "explainSwap(address,(bytes32,address,address,address,address,address,bool,bool,bool,bool,int256,uint160,uint24))",
            "maxExactInput(address,bytes32,bool,bool)",
            "poolManager()"
        ];
        string[] memory exposed = vm.parseJsonKeys(
            vm.readFile("out/MidasSizeCapAdvisory.sol/MidasSizeCapAdvisory.json"), ".methodIdentifiers"
        );
        assertEq(exposed.length, expected.length, "function count");
        for (uint256 i; i < expected.length; ++i) {
            bool found;
            for (uint256 j; j < exposed.length; ++j) {
                if (keccak256(bytes(exposed[j])) == keccak256(bytes(expected[i]))) found = true;
            }
            assertTrue(found, expected[i]);
        }
        string[18] memory admin = [
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "acceptOwnership()",
            "setOwner(address)",
            "admin()",
            "changeAdmin(address)",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "implementation()",
            "proxiableUUID()",
            "initialize()",
            "initialize(bytes)",
            "pause()",
            "unpause()",
            "setConfig(address,bytes32,uint16,uint120,uint120)",
            "setManager(address)",
            "kill()"
        ];
        vm.record();
        for (uint256 i; i < admin.length; ++i) {
            for (uint256 who; who < 2; ++who) {
                vm.prank(who == 0 ? address(this) : address(root));
                (bool ok,) = address(cap).call(abi.encodeWithSignature(admin[i], address(0xBEEF)));
                assertFalse(ok, admin[i]);
            }
        }
        (, bytes32[] memory writes) = vm.accesses(address(cap));
        assertEq(writes.length, 0, "no write");
        (bool sent,) = address(cap).call{value: 1}("");
        assertFalse(sent, "takes no ether");
        assertEq(vm.load(address(cap), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc), bytes32(0));
        assertEq(vm.load(address(cap), 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103), bytes32(0));
        assertEq(vm.load(address(cap), 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50), bytes32(0));
    }

    /// @notice Nothing but bind writes storage. Every other function, admitted and refused swaps through the router
    ///         (every account access in them recorded), the floor's included, leave the block's storage untouched;
    ///         bind writes the caller's binding of the pool: one slot with floors of 0, two with a floor.
    function test_probe_writesNoStorageOutsideBind() public {
        vm.record();
        HookrTypes.SwapContext memory x = _ctx(closedKey, true, true, 1e18);
        vm.startPrank(address(root));
        cap.beforeSwap(x);
        cap.beforeSwap(_ctx(closedKey, true, true, 1e30));
        cap.afterSwap(x, -1e18, 1e18);
        cap.beforeAddLiquidity(closedKey.toId(), trader);
        vm.stopPrank();
        cap.configSchemaHash();
        cap.config(address(root), closedKey.toId());
        cap.explainSwap(address(root), x);
        cap.maxExactInput(address(root), closedKey.toId(), true, true);
        (, bytes32[] memory writes) = vm.accesses(address(cap));
        assertEq(writes.length, 0, "views wrote");

        vm.startStateDiffRecording();
        _route(closedKey, true, true, 1e18);
        _route(closedKey, false, false, 1e18);
        IHookrRouter.Swap memory over = _swap(closedKey, true, true, uint128(QUOTE_IN + 1));
        vm.prank(trader);
        try router.swap(over, address(0), new uint256[](0)) {
            revert("over-cap swap filled");
        } catch {}
        // Swaps the floor admits and refuses, which read the floors' slot.
        _route(floorKey, true, true, 5e21);
        IHookrRouter.Swap memory overFloor = _swap(floorKey, false, true, uint128(2e22));
        vm.prank(trader);
        try router.swap(overFloor, address(0), new uint256[](0)) {
            revert("over-floor swap filled");
        } catch {}
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        uint256 reads;
        bytes32 floors = bytes32(
            uint256(keccak256(abi.encode(floorKey.toId(), keccak256(abi.encode(address(root), uint256(0)))))) + 1
        );
        bool readFloors;
        for (uint256 i; i < accesses.length; ++i) {
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory s = accesses[i].storageAccesses[j];
                if (s.account != address(cap)) continue;
                assertFalse(s.isWrite, "a swap wrote the block's storage");
                if (s.slot == floors) readFloors = true;
                ++reads;
            }
        }
        assertGt(reads, 0, "the swaps read the binding");
        assertTrue(readFloors, "the floor swaps read the floors");

        (PoolKey memory key, HookrTypes.PoolConfig memory pc) = _freshPool();
        vm.record();
        vm.prank(address(root));
        cap.bind(key, pc, _terms(50, 1, 1));
        (, writes) = vm.accesses(address(cap));
        bytes32 slot = keccak256(abi.encode(key.toId(), keccak256(abi.encode(address(root), uint256(0)))));
        assertGt(writes.length, 0, "bind wrote");
        for (uint256 i; i < writes.length; ++i) {
            assertEq(writes[i], slot, "floors 0: only the cap's slot");
        }

        // With a floor, bind writes the floors' slot too, and nothing else.
        (key, pc) = _freshPool();
        vm.record();
        vm.prank(address(root));
        cap.bind(key, pc, _termsF(50, 2, 2, 1, 0));
        (, writes) = vm.accesses(address(cap));
        slot = keccak256(abi.encode(key.toId(), keccak256(abi.encode(address(root), uint256(0)))));
        bool wroteCap;
        bool wroteFloors;
        for (uint256 i; i < writes.length; ++i) {
            if (writes[i] == slot) wroteCap = true;
            else if (writes[i] == bytes32(uint256(slot) + 1)) wroteFloors = true;
            else revert("bind wrote outside the binding");
        }
        assertTrue(wroteCap && wroteFloors, "floors set: the binding's two slots");
    }

    /// @notice The runtime's linear decoding: no CALL, CALLCODE, DELEGATECALL, CREATE, CREATE2, SELFDESTRUCT or
    ///         TSTORE; its external calls are STATICCALLs; SSTORE appears only for bind's writes. The metadata tail
    ///         is cut by its length, which is safe for the block's own build (the kit's scan covers the strict case).
    function test_probe_runtimeOpcodes() public view {
        bytes memory code = address(cap).code;
        assertEq(code.length, vm.getDeployedCode("out/MidasSizeCapAdvisory.sol/MidasSizeCapAdvisory.json").length);
        uint256 end = code.length - 2 - (uint256(uint8(code[code.length - 2])) << 8 | uint8(code[code.length - 1]));
        uint256[256] memory count;
        for (uint256 i; i < end; ++i) {
            uint8 op = uint8(code[i]);
            ++count[op];
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        assertEq(count[0xf1], 0, "CALL");
        assertEq(count[0xf2], 0, "CALLCODE");
        assertEq(count[0xf4], 0, "DELEGATECALL");
        assertEq(count[0xf0], 0, "CREATE");
        assertEq(count[0xf5], 0, "CREATE2");
        assertEq(count[0xff], 0, "SELFDESTRUCT");
        assertEq(count[0x5d], 0, "TSTORE");
        assertGt(count[0xfa], 0, "STATICCALL");
        assertGt(count[0x55], 0, "SSTORE");
        assertLe(count[0x55], 3, "SSTORE sites");
        console2.log("runtime bytes", code.length);
        console2.log("SSTORE sites", count[0x55]);
        console2.log("STATICCALL sites", count[0xfa]);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------------------------------------------------

    /// @notice On a bound pool beforeSwap never reverts and never runs out of ADVISORY_GAS, for any specified amount,
    ///         direction and base fee, at depths from the whole launch position down to none, and at any price one
    ///         swap can push the fixture pool to, out of range included (the block is mocked out of the way for the
    ///         push). Its advice is only ever a reject: no surcharge, no take, no recipient. A fail-open slot would let
    ///         a reverting call through, so this is the property that matters there. MidasSizeCapMath.t.sol covers
    ///         arbitrary PoolManager states.
    function testFuzz_neverRevertsOnABoundPool(
        bool isBuy,
        int256 amount,
        uint24 fee,
        uint256 push,
        bool pushUp,
        uint8 thin
    ) public {
        uint128 held = launcher.position(closedFamily, 0).liquidity;
        uint128 keep = thin % 8 == 7 ? 0 : uint128(held / 10 ** (thin % 8));
        if (keep < held) launcher.withdraw(closedFamily, 0, held - keep, 0, 0, address(this), vm.getBlockTimestamp());
        push = bound(push, 0, 4e25);
        if (push != 0) {
            vm.mockCall(
                address(cap),
                abi.encodeWithSelector(IHookrAdvisory.beforeSwap.selector),
                abi.encode(HookrTypes.Advice(0, 0, address(0), false))
            );
            IHookrRouter.Swap memory p = _swap(closedKey, pushUp, true, uint128(push));
            vm.prank(trader);
            try router.swap(p, address(0), new uint256[](0)) {} catch {}
            vm.clearMockedCalls();
        }
        HookrTypes.SwapContext memory x = _ctx(closedKey, isBuy, true, 1);
        x.amountSpecified = amount;
        x.exactInput = amount < 0;
        x.baseLpFeePips = fee;
        vm.prank(address(root));
        (bool ok, bytes memory out) =
            address(cap).staticcall{gas: gasLimit}(abi.encodeCall(IHookrAdvisory.beforeSwap, (x)));
        assertTrue(ok, "beforeSwap reverted");
        assertEq(out.length, 128, "four words");
        HookrTypes.Advice memory a = abi.decode(out, (HookrTypes.Advice));
        assertEq(a.lpFeeSurchargePips, 0, "surcharge");
        assertEq(a.quoteTakePips, 0, "take");
        assertEq(a.recipient, address(0), "recipient");
    }

    /// @notice Any exact input up to maxExactInput is admitted and fills through the router with a realised sqrt move
    ///         within maxImpactBps; anything above it is refused.
    function testFuzz_exactInput_admittedMovesWithinTheCap_restRefused(bool isBuy, uint256 amount) public {
        bool zeroForOne = _zeroForOne(impactKey, isBuy);
        uint256 maxIn = cap.maxExactInput(address(root), impactKey.toId(), zeroForOne, isBuy);
        amount = bound(amount, 1e6, 3 * maxIn);
        bool admitted = !_advise(_ctx(impactKey, isBuy, true, amount)).reject;
        assertEq(admitted, amount <= maxIn, "admitted exactly up to the cap");
        if (!admitted) {
            _refused(impactKey, isBuy, true, amount);
            return;
        }
        (uint160 before,,,) = manager.getSlot0(impactKey.toId());
        _route(impactKey, isBuy, true, amount);
        (uint160 afterSwap,,,) = manager.getSlot0(impactKey.toId());
        _assertMoveWithin(before, afterSwap, 10);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Bind terms with floors of 0: the block as it was before the floor.
    function _terms(uint256 impactBps, uint256 quoteIn, uint256 subjectIn) internal pure returns (bytes memory) {
        return abi.encode(impactBps, quoteIn, subjectIn, uint256(0), uint256(0));
    }

    function _termsF(uint256 impactBps, uint256 quoteIn, uint256 subjectIn, uint256 floorQuote, uint256 floorSubject)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(impactBps, quoteIn, subjectIn, floorQuote, floorSubject);
    }

    /// @dev Admits a deployment of the block on the root through the registry's timelock: as it declares itself, or
    ///         fail-open as the kit admits every advisory.
    function _admit(address advisory, bool failOpen) internal {
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: advisory,
            codeHash: advisory.codehash,
            schemaHash: MidasSizeCapAdvisory(advisory).configSchemaHash(),
            caps: HookrTypes.Caps(0, 0, 0),
            gasLimit: MidasSizeCapAdvisory(advisory).ADVISORY_GAS(),
            phaseMask: MidasSizeCapAdvisory(advisory).PHASES(),
            feeOnly: true,
            failOpen: failOpen
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
    }

    /// @dev A new subject token, funded for the launcher and for the trader's sells.
    function _subject() internal returns (HookrToken s) {
        s = new HookrToken("Size Cap Subject", "SCS", 1e30, address(this));
        s.approve(address(launcher), type(uint256).max);
        s.transfer(trader, 1e27);
        vm.prank(trader);
        s.approve(address(router), type(uint256).max);
    }

    /// @dev A new subject that sorts as currency0 (`as0`) or currency1 against tokenB.
    function _subjectOn(bool as0) internal returns (HookrToken s) {
        for (uint256 i; i < 32; ++i) {
            s = _subject();
            if ((address(s) < address(tokenB)) == as0) return s;
        }
        revert("no subject on that side");
    }

    /// @dev Launches one pool of `subject` against tokenB on the root, bound with `data` to `cap` (fail-closed) or to
    ///      `capOpen` (fail-open).
    function _launch(HookrToken subject, bool failOpen, bytes memory data)
        internal
        returns (PoolKey memory key, bytes32 family)
    {
        return _launchWith(failOpen ? address(capOpen) : address(cap), subject, failOpen, data);
    }

    function _launchWith(address advisory, HookrToken subject, bool failOpen, bytes memory data)
        internal
        returns (PoolKey memory key, bytes32 family)
    {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _advised(advisory, failOpen);
        bytes[] memory configs = new bytes[](1);
        configs[0] = data;
        (family,) = launcher.launchAdvised(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            configs,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    /// @dev External entry for a launch whose revert a test expects.
    function launchFor(address advisory, HookrToken subject, bool failOpen, bytes memory data) external {
        _launchWith(advisory, subject, failOpen, data);
    }

    /// @dev A launch whose subject-only range ends exactly at the opening price, the shape of a new-token launch.
    function _launchSingleSided(HookrToken subject, bytes memory data)
        internal
        returns (PoolKey memory key, bytes32 family)
    {
        return _launchSingleSidedSized(subject, data, 1e24);
    }

    /// @dev The same, holding `amount` of the subject.
    function _launchSingleSidedSized(HookrToken subject, bytes memory data, uint256 amount)
        internal
        returns (PoolKey memory key, bytes32 family)
    {
        bool subjectIs0 = address(subject) < address(tokenB);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _advised(address(cap), false);
        members[0].tickLower = subjectIs0 ? int24(0) : int24(-60_000);
        members[0].tickUpper = subjectIs0 ? int24(60_000) : int24(0);
        uint160 lower = TickMath.getSqrtPriceAtTick(members[0].tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(members[0].tickUpper);
        uint128 liquidity = subjectIs0
            ? LiquidityAmounts.getLiquidityForAmount0(lower, upper, amount)
            : LiquidityAmounts.getLiquidityForAmount1(lower, upper, amount);
        members[0].liquidity = liquidity / 1000 * 999;
        members[0].amount0Max = subjectIs0 ? uint128(amount) : 0;
        members[0].amount1Max = subjectIs0 ? 0 : uint128(amount);
        bytes[] memory configs = new bytes[](1);
        configs[0] = data;
        (family,) = launcher.launchAdvised(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            configs,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    function _advised(address advisory, bool failOpen) internal view returns (IHookrLauncher.Member memory m) {
        m = _member(Currency.wrap(address(tokenB)));
        m.config.advisory = advisory;
        m.config.advisoryGasLimit = gasLimit;
        m.config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        m.config.advisoryFailOpen = failOpen;
    }

    /// @dev A key and config the root could bind but never opened: a fresh pair, so a direct bind is new.
    function _freshPool() internal returns (PoolKey memory key, HookrTypes.PoolConfig memory pc) {
        HookrToken s = new HookrToken("Fresh", "F", 1, address(this));
        (Currency c0, Currency c1) = address(s) < address(tokenB)
            ? (Currency.wrap(address(s)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(s)));
        key = PoolKey(c0, c1, 0x800000, 60, IHooks(address(root)));
        pc = root.poolConfig(closedKey.toId());
        pc.subject = Currency.wrap(address(s));
    }

    function _bindReverts(bytes memory data, bytes memory reason) internal {
        (PoolKey memory key, HookrTypes.PoolConfig memory pc) = _freshPool();
        vm.prank(address(root));
        vm.expectRevert(reason);
        cap.bind(key, pc, data);
    }

    function _bindReverts(PoolKey memory key, HookrTypes.PoolConfig memory pc, bytes memory data, uint8 code) internal {
        vm.prank(address(root));
        vm.expectRevert(abi.encodeWithSelector(MidasSizeCapAdvisory.InvalidPoolConfig.selector, code));
        cap.bind(key, pc, data);
    }

    function _zeroForOne(PoolKey memory key, bool isBuy) internal view returns (bool) {
        return isBuy == (root.poolConfig(key.toId()).quote == key.currency0);
    }

    /// @dev The isBuy whose swap runs zeroForOne == `down` on `key`.
    function _buyFor(PoolKey memory key, bool down) internal view returns (bool) {
        return down == (root.poolConfig(key.toId()).quote == key.currency0);
    }

    /// @dev The context the root passes for a router swap on `key` by the trader.
    function _ctx(PoolKey memory key, bool isBuy, bool exactInput, uint256 amount)
        internal
        view
        returns (HookrTypes.SwapContext memory x)
    {
        HookrTypes.PoolConfig memory pc = root.poolConfig(key.toId());
        bool zeroForOne = isBuy == (pc.quote == key.currency0);
        x = HookrTypes.SwapContext({
            id: key.toId(),
            sender: address(router),
            payer: trader,
            beneficiary: trader,
            subject: pc.subject,
            quote: pc.quote,
            authenticated: true,
            isBuy: isBuy,
            exactInput: exactInput,
            zeroForOne: zeroForOne,
            amountSpecified: exactInput ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE : MAX_PRICE,
            baseLpFeePips: pc.baseLpFeePips
        });
    }

    function _advise(HookrTypes.SwapContext memory x) internal returns (HookrTypes.Advice memory) {
        return _adviseWith(cap, x);
    }

    function _adviseWith(MidasSizeCapAdvisory advisory, HookrTypes.SwapContext memory x)
        internal
        returns (HookrTypes.Advice memory)
    {
        vm.prank(address(root));
        return advisory.beforeSwap(x);
    }

    function _explain(HookrTypes.SwapContext memory x)
        internal
        view
        returns (bool, MidasSizeCapAdvisory.Reason, uint256, uint256)
    {
        return cap.explainSwap(address(root), x);
    }

    /// @dev A router swap by the trader; returns what the trader paid and received. The parameters are built first:
    ///      building them makes a call, and the prank must reach the router.
    function _route(PoolKey memory key, bool isBuy, bool exactInput, uint256 amount)
        internal
        returns (uint256 paid, uint256 got)
    {
        IHookrRouter.Swap memory p = _swap(key, isBuy, exactInput, uint128(amount));
        vm.prank(trader);
        (paid, got) = router.swap(p, address(0), new uint256[](0));
    }

    /// @dev A router swap by the trader that must revert with `reason`.
    function _routeReverts(PoolKey memory key, bool isBuy, bool exactInput, uint256 amount, bytes memory reason)
        internal
    {
        IHookrRouter.Swap memory p = _swap(key, isBuy, exactInput, uint128(amount));
        vm.expectRevert(reason);
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
    }

    /// @dev A router swap by the trader that the root refuses with SwapRejected, the block's advice in a fail-closed
    ///      slot.
    function _refused(PoolKey memory key, bool isBuy, bool exactInput, uint256 amount) internal {
        _routeReverts(
            key, isBuy, exactInput, amount, _wrapped(abi.encodeWithSelector(IHookrRootState.SwapRejected.selector))
        );
    }

    /// @dev The PoolManager's wrapping of a root beforeSwap revert.
    function _wrapped(bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(root),
            IHooks.beforeSwap.selector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev SweepGuard.capIn's impact term, written out here on the pool's slot0 and liquidity.
    function _sweepGuardCapIn(PoolId id, uint256 bps, bool zeroForOne) internal view returns (uint256) {
        (uint160 spot,,,) = manager.getSlot0(id);
        uint128 liquidity = manager.getLiquidity(id);
        if (zeroForOne) {
            uint160 lower = uint160((uint256(spot) * (BPS - bps)) / BPS);
            return SqrtPriceMath.getAmount0Delta(lower, spot, liquidity, false);
        }
        uint160 upper = uint160((uint256(spot) * (BPS + bps)) / BPS);
        return SqrtPriceMath.getAmount1Delta(spot, upper, liquidity, false);
    }

    /// @dev The output the same move pays out.
    function _impactOut(PoolId id, uint256 bps, bool zeroForOne) internal view returns (uint256) {
        (uint160 spot,,,) = manager.getSlot0(id);
        uint128 liquidity = manager.getLiquidity(id);
        if (zeroForOne) {
            uint160 lower = uint160((uint256(spot) * (BPS - bps)) / BPS);
            return SqrtPriceMath.getAmount1Delta(lower, spot, liquidity, false);
        }
        uint160 upper = uint160((uint256(spot) * (BPS + bps)) / BPS);
        return SqrtPriceMath.getAmount0Delta(spot, upper, liquidity, false);
    }

    /// @dev The input an exact output costs at active liquidity, grossed up by the base LP fee, rounded up.
    function _costIn(PoolId id, bool zeroForOne, uint256 out) internal view returns (uint256) {
        (uint160 spot,,,) = manager.getSlot0(id);
        uint128 liquidity = manager.getLiquidity(id);
        uint160 next = SqrtPriceMath.getNextSqrtPriceFromOutput(spot, liquidity, out, zeroForOne);
        uint256 c = zeroForOne
            ? SqrtPriceMath.getAmount0Delta(next, spot, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(spot, next, liquidity, true);
        return FullMath.mulDivRoundingUp(c, PIPS, PIPS - root.poolConfig(id).baseLpFeePips);
    }

    /// @dev Asserts |after - before| <= bps / 10,000 of before, in sqrt price, exactly.
    function _assertMoveWithin(uint160 before, uint160 afterSwap, uint256 bps) internal pure {
        uint256 d = afterSwap > before ? afterSwap - before : before - afterSwap;
        assertLe(d * BPS, bps * uint256(before), "realised move within the cap");
    }

    /// @dev SweepGuard's impact term at a given spot and depth.
    function _capAt(uint160 spot, uint128 liquidity, uint256 bps, bool zeroForOne) internal pure returns (uint256) {
        if (zeroForOne) {
            uint160 lower = uint160((uint256(spot) * (BPS - bps)) / BPS);
            return SqrtPriceMath.getAmount0Delta(lower, spot, liquidity, false);
        }
        uint160 upper = uint160((uint256(spot) * (BPS + bps)) / BPS);
        return SqrtPriceMath.getAmount1Delta(spot, upper, liquidity, false);
    }

    /// @dev The largest exact output whose cost, as the block computes it, fits `ceiling`.
    function _largestExactOutput(PoolKey memory key, bool isBuy, uint256 ceiling) internal view returns (uint256 lo) {
        bool zeroForOne = _zeroForOne(key, isBuy);
        lo = 1;
        uint256 hi = ceiling;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (_costIn(key.toId(), zeroForOne, mid) <= ceiling) lo = mid;
            else hi = mid - 1;
        }
    }

    /// @dev A pool of a new subject on the given side, bound with `data`, its launch position thinned to 1/`divisor`
    ///      of itself (L = 1e24 / divisor at price 1).
    function _thinPool(bool subjectIs0, bytes memory data, uint256 divisor) internal returns (PoolKey memory key) {
        bytes32 family;
        (key, family) = _launch(_subjectOn(subjectIs0), false, data);
        uint128 held = launcher.position(family, 0).liquidity;
        launcher.withdraw(family, 0, held - uint128(held / divisor), 0, 0, address(this), vm.getBlockTimestamp());
        assertEq(manager.getLiquidity(key.toId()), held / divisor, "thinned");
    }

    /// @dev test_limit_dustLiquidityInAGap's state, for either token order: a single-sided launch, a 1e18 buy into
    ///      it, a sell of three times what the buy got stopped by its price limit 120 ticks outside the range, and
    ///      1e3 of liquidity placed over that price.
    function _dustInAGap(bool subjectIs0, bytes memory data) internal returns (PoolKey memory key) {
        (key,) = _launchSingleSided(_subjectOn(subjectIs0), data);
        (, uint256 got) = _route(key, true, true, 1e18);
        int24 gap = subjectIs0 ? int24(-120) : int24(120);
        IHookrRouter.Swap memory sell = _swap(key, false, true, uint128(got * 3));
        sell.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(gap);
        vm.prank(trader);
        router.swap(sell, address(0), new uint256[](0));
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(tick, gap, "stopped in the gap");
        assertEq(manager.getLiquidity(key.toId()), 0, "zero depth");
        _lp(key)
            .modifyLiquidity(
                key, ModifyLiquidityParams({tickLower: gap - 60, tickUpper: gap + 60, liquidityDelta: 1e3, salt: 0}), ""
            );
    }

    /// @dev Exact-input buys on a subject-as-currency1 single-sided launch (range -60000..0) until the price leaves the
    ///      range: of `size` each, or of maxExactInput each when `size` is 0. Every buy must be admitted. Returns the
    ///      swaps, the quote paid, the gas the router calls used and the subject bought.
    function _walkOut(PoolKey memory key, uint256 size)
        internal
        returns (uint256 n, uint256 paid, uint256 gasUsed, uint256 got)
    {
        PoolId id = key.toId();
        assertTrue(_zeroForOne(key, true), "a buy moves down");
        while (true) {
            (, int24 tick,,) = manager.getSlot0(id);
            if (tick < -60_000) break;
            uint256 amount = size != 0 ? size : cap.maxExactInput(address(root), id, true, true);
            IHookrRouter.Swap memory p = _swap(key, true, true, uint128(amount));
            vm.prank(trader);
            uint256 g = gasleft();
            (uint256 inPaid, uint256 out) = router.swap(p, address(0), new uint256[](0));
            gasUsed += g - gasleft();
            paid += inPaid;
            got += out;
            ++n;
            require(n < 5000, "walk did not end");
        }
    }

    /// @dev A v4 liquidity router funded and approved for `key`'s tokens.
    function _lp(PoolKey memory key) internal returns (PoolModifyLiquidityTest lp) {
        lp = new PoolModifyLiquidityTest(manager);
        HookrToken(Currency.unwrap(key.currency0)).approve(address(lp), type(uint256).max);
        HookrToken(Currency.unwrap(key.currency1)).approve(address(lp), type(uint256).max);
    }

    /// @dev Launches a single-sided pool, buys into it, then makes one in-cap sell of three times what the buy got,
    ///      which leaves the range and runs to the router's price limit at zero depth. Checks the block's advice
    ///      there, then that an in-cap exact-input buy brings the price back into the range and trading resumes.
    function _runOutAndRecover(bool subjectIs0) internal {
        HookrToken subject = _subjectOn(subjectIs0);
        (PoolKey memory key,) = _launchSingleSided(subject, _terms(50, QUOTE_IN, SUBJECT_IN));
        (, uint256 got) = _route(key, true, true, 1e18);
        assertFalse(_advise(_ctx(key, false, true, got * 3)).reject, "the sell is within the cap");
        _route(key, false, true, got * 3);
        (uint160 spot, int24 tick,,) = manager.getSlot0(key.toId());
        uint160 limit = _zeroForOne(key, false) ? MIN_PRICE : MAX_PRICE;
        assertEq(spot, limit, "ran to the router's price limit");
        assertEq(tick, subjectIs0 ? TickMath.MIN_TICK : int24(887_271), "tick");
        assertTrue(
            tick < TickMath.minUsableTick(key.tickSpacing) || tick > TickMath.maxUsableTick(key.tickSpacing),
            "no position can cover the price"
        );
        assertEq(manager.getLiquidity(key.toId()), 0, "zero depth");
        bool buyDown = _zeroForOne(key, true);
        assertEq(cap.maxExactInput(address(root), key.toId(), buyDown, true), QUOTE_IN, "buy: the ceiling alone");
        (bool ok, MidasSizeCapAdvisory.Reason reason,,) = _explain(_ctx(key, true, true, QUOTE_IN + 1));
        assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.OVER_CEILING), "over the ceiling");
        (ok, reason,,) = _explain(_ctx(key, true, false, 1e15));
        assertEq(uint8(reason), uint8(MidasSizeCapAdvisory.Reason.NO_LIQUIDITY), "exact output at zero depth");
        (ok,,,) = _explain(_ctx(key, true, true, 1e15));
        assertTrue(ok, "an exact-input buy is admitted");
        (, uint256 bought) = _route(key, true, true, 1e15);
        assertGt(bought, 0, "the buy filled");
        (, tick,,) = manager.getSlot0(key.toId());
        assertTrue(subjectIs0 ? tick >= 0 : tick < 0, "back in the range");
        assertGt(manager.getLiquidity(key.toId()), 0, "depth again");
        (, bought) = _route(key, true, true, 1e18);
        assertGt(bought, 0, "trading resumes");
        console2.log(
            subjectIs0 ? "run out to MIN_TICK, back to tick" : "run out to tick 887271, back to tick", int256(tick)
        );
    }
}
