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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {MidasRWAHook} from "../src/MidasRWAHook.sol";

/// @notice Sweep-route tests, kept separate from the main suite because they are about
///         the routing surface of sweepAndBurn rather than the fee curve.
///
/// The point of interest: sweepAndBurn validates the route only as "GOLD is one of the
/// two currencies" and "slot0 is non-zero". The route PoolKey is otherwise whatever the
/// caller passes. Every one of the four sweep gates ? cooldown, reference band, spot
/// quote, minGoldOut ? is then measured against that caller-named pool. On a pool with a
/// fresh PoolId the cooldown and the band are skipped entirely, and the floor is quoted
/// at the caller's own spot. These tests execute against that, they do not assert around
/// it.
contract SweepRouteTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    MidasRWAHook hook;
    // NOTE: `key` is inherited from Deployers ? do not redeclare it here.
    PoolId id;
    Currency gold;

    address royalty = address(0xFEE5);
    address attacker = address(0xBEEF);

    uint256 constant WINDOW = 120;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        gold = deployMintAndApproveCurrency();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        // Permit only the canonical GOLD route (fee 3000), seeded at price 1. The attacker
        // route in these tests uses a different fee tier, so it is deliberately NOT on the
        // list ? that is the whole point of the routing tests below.
        PoolKey[] memory routes = new PoolKey[](1);
        routes[0] = _honestRouteKey();
        uint160[] memory seeds = new uint160[](1);
        seeds[0] = TickMath.getSqrtPriceAtTick(0);
        deployCodeTo(
            "MidasRWAHook.sol:MidasRWAHook",
            abi.encode(manager, gold, royalty, routes, seeds),
            address(flags)
        );
        hook = MidasRWAHook(address(flags));

        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        id = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        hook.setQuoteSide(key, true);
    }

    // --- helpers, borrowed from the main suite --------------------------------

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

    function _seedLiquidity(PoolKey memory k, uint128 L) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: int128(L), salt: 0}), ""
        );
    }

    function _accrueFees() internal {
        vm.warp(block.timestamp + WINDOW);
        _seedLiquidity(key, 1e18);
        _swap(key, true, -1e16);
    }

    function _slot0(PoolId pid) internal view returns (uint160 s) {
        (s,,,) = StateLibrary.getSlot0(manager, pid);
    }

    /// @dev The canonical GOLD route key (fee 3000), no pool created. Used both to permit
    ///      the route at deploy and to stand the pool up inside a test.
    function _honestRouteKey() internal view returns (PoolKey memory) {
        (Currency a, Currency b) = currency0 < gold ? (currency0, gold) : (gold, currency0);
        return PoolKey(a, b, 3000, 60, IHooks(address(0)));
    }

    /// @dev An honest, deep GOLD route at price 1. This is the pool a real keeper would
    ///      route through, and the one permitted at deploy.
    function _honestGoldRoute() internal returns (PoolKey memory route) {
        route = _honestRouteKey();
        manager.initialize(route, TickMath.getSqrtPriceAtTick(0));
        _seedLiquidity(route, 1e18);
    }

    /// @dev An attacker-controlled GOLD route. Same currency pair, so it passes the
    ///      RouteNotGold check, but a different fee tier means a *different PoolId* ? its
    ///      reference and cooldown are unset ? and it is seeded thin and far from price 1
    ///      so GOLD is expensive in currency0 terms. The bucket buys almost no GOLD here.
    ///      `dearTicks` is a magnitude; the sign is chosen so GOLD is made EXPENSIVE in
    ///      currency0 terms whichever way the two currencies sorted. Price = token1/token0;
    ///      if GOLD is token1 it is dear when price is high (+tick), if GOLD is token0 it is
    ///      dear when price is low (-tick).
    function _attackerGoldRoute(int24 dearTicks, uint128 L) internal returns (PoolKey memory route) {
        (Currency a, Currency b) = currency0 < gold ? (currency0, gold) : (gold, currency0);
        // price = token1/token0 = (sqrtP/2^96)^2. GOLD dear in currency0 terms means few
        // GOLD per currency0. If GOLD is token1, price = GOLD/other, dear = LOW price =
        // negative tick. If GOLD is token0, price = other/GOLD, dear = HIGH price = positive.
        bool goldIsToken1 = (Currency.unwrap(b) == Currency.unwrap(gold));
        int24 startTick = goldIsToken1 ? -dearTicks : dearTicks;
        route = PoolKey(a, b, 500, 10, IHooks(address(0))); // fee tier 500 -> distinct PoolId
        manager.initialize(route, TickMath.getSqrtPriceAtTick(startTick));
        _seedLiquidity(route, L);
    }

    // -------------------------------------------------------------------------
    // 1. The routing gap, executed
    // -------------------------------------------------------------------------

    /// @dev The bucket is drained through a pool the attacker chose and priced, on the
    ///      first sweep, with no honest route ever touched. Compares GOLD burned via the
    ///      attacker route against GOLD an honest route would have burned from the same
    ///      bucket. If the gap is large, the burn was effectively skimmed.
    /// @dev The fix, proven. The attacker deploys their own GOLD pool (distinct fee tier,
    ///      so distinct PoolId) and prices it however they like. Before the allowlist this
    ///      sweep succeeded and burned ~1% of fair value, leaving the rest as the
    ///      attacker's LP. Now the route is not on the deploy-sealed list and the sweep
    ///      reverts before touching the bucket. The honest, permitted route still works.
    function test_route_attackerSuppliedPoolRejected() public {
        // The attacker's pool: same currency pair (passes the GOLD check), different fee
        // tier (fresh PoolId), mispriced. It is not on the allowlist.
        PoolKey memory evil = _attackerGoldRoute(46000, 1e21);
        PoolId eid = evil.toId();
        _accrueFees();

        assertFalse(hook.allowedRoute(eid), "attacker route is not permitted");
        uint256 bucketBefore = hook.burnBucket(currency0);
        assertGt(bucketBefore, 0, "precondition: bucket funded");

        // The sweep is refused before any swap, and the bucket is untouched.
        vm.prank(attacker);
        vm.expectRevert(MidasRWAHook.RouteNotAllowed.selector);
        hook.sweepAndBurn(currency0, evil, 0);

        assertEq(hook.burnBucket(currency0), bucketBefore, "bucket untouched by the refused sweep");

        // The honest, permitted route still converts and burns normally.
        PoolKey memory honest = _honestGoldRoute();
        assertTrue(hook.allowedRoute(honest.toId()), "honest route is permitted");
        uint256 deadBefore = gold.balanceOf(hook.DEAD());
        vm.prank(attacker);
        hook.sweepAndBurn(currency0, honest, 0);
        assertGt(gold.balanceOf(hook.DEAD()) - deadBefore, 0, "permitted route still burns GOLD");
        assertEq(hook.burnBucket(currency0), 0, "bucket drained through the permitted route");
    }

    // -------------------------------------------------------------------------
    // 2. Scenarios Nodar asked for, on an honest route
    // -------------------------------------------------------------------------

    /// @dev Manipulate only around each eligible sweep and restore between them, so the
    ///      reference samples only the manipulated prints. Measures what the bucket loses
    ///      per sweep versus an unmanipulated baseline. This is on the *honest* route, so
    ///      the band and cooldown are both live ? it isolates the sampling weakness from
    ///      the routing gap above.
    function test_scenario_manipulateAroundEachSweep() public {
        PoolKey memory route = _honestGoldRoute();
        PoolId rid = route.toId();

        // Baseline: two clean sweeps, no manipulation.
        uint256 cleanBurn;
        {
            uint256 snap = vm.snapshot();
            _accrueFees();
            uint256 d0 = gold.balanceOf(hook.DEAD());
            hook.sweepAndBurn(currency0, route, 0);
            vm.warp(block.timestamp + hook.MIN_SWEEP_INTERVAL());
            _swap(key, true, -1e16);
            hook.sweepAndBurn(currency0, route, 0);
            cleanBurn = gold.balanceOf(hook.DEAD()) - d0;
            vm.revertTo(snap);
        }

        // Manipulated: before each sweep push the route down toward the band edge, sweep,
        // then restore it. "Down" makes GOLD dearer, so the bucket burns less. Kept just
        // inside the 10% sqrt band so the deviation guard does not trip.
        _accrueFees();
        uint256 dStart = gold.balanceOf(hook.DEAD());

        _nudgeWithinBand(route, rid);
        hook.sweepAndBurn(currency0, route, 0);
        _restore(route, rid);

        vm.warp(block.timestamp + hook.MIN_SWEEP_INTERVAL());
        _swap(key, true, -1e16);

        _nudgeWithinBand(route, rid);
        hook.sweepAndBurn(currency0, route, 0);
        _restore(route, rid);

        uint256 manipBurn = gold.balanceOf(hook.DEAD()) - dStart;

        emit log_named_uint("clean two-sweep burn ", cleanBurn);
        emit log_named_uint("manip two-sweep burn ", manipBurn);
        // The manipulated run burns less GOLD for the same bucket. Documented, not
        // asserted tightly ? the size depends on how close to the band edge you push.
        assertLt(manipBurn, cleanBurn, "manipulated-around-sweep run burns less than clean");
    }

    /// @dev A legitimate large price move on the route while the sweep-only reference is
    ///      stale. The reference only updates on sweeps, so a real move between sweeps is
    ///      seen by the *next* sweep as an out-of-band deviation and refused ? a live pool
    ///      wedges its own honest sweeps until the move happens to fall inside the band.
    function test_scenario_legitimateMoveStallsSweeps() public {
        PoolKey memory route = _honestGoldRoute();
        PoolId rid = route.toId();
        _accrueFees();

        hook.sweepAndBurn(currency0, route, 0); // seeds reference at price 1
        uint160 refAfter = hook.refSqrtPriceX96(rid);

        // A genuine ~20% move on the route, no manipulation, just the market.
        _swap(route, true, -25e16);
        vm.warp(block.timestamp + hook.MIN_SWEEP_INTERVAL());
        _swap(key, true, -1e16); // refill bucket

        uint160 moved = _slot0(rid);
        uint256 lo = (uint256(refAfter) * (10_000 - hook.MAX_REF_DEVIATION_BPS())) / 10_000;
        assertLt(moved, lo, "precondition: legit move is outside the stale band");

        // The honest sweep is now refused, even though nothing was manipulated.
        vm.expectRevert(MidasRWAHook.RoutePriceDeviates.selector);
        hook.sweepAndBurn(currency0, route, 0);
    }

    // --- band-edge nudging helpers -------------------------------------------

    /// @dev Push the route just inside the lower band edge (GOLD dearer) so the deviation
    ///      guard passes but the quote is measured against a worse price.
    function _nudgeWithinBand(PoolKey memory route, PoolId rid) internal {
        uint160 ref = hook.refSqrtPriceX96(rid);
        uint256 lo = (uint256(ref) * (10_000 - hook.MAX_REF_DEVIATION_BPS())) / 10_000;
        // Binary-search a swap size that lands spot just above lo. Cheap and deterministic
        // enough for a test; a handful of steps.
        uint256 sizeSnap = vm.snapshot();
        int256 size = -1e15;
        for (uint256 i = 0; i < 12; i++) {
            vm.revertTo(sizeSnap);
            sizeSnap = vm.snapshot();
            _swap(route, true, size);
            if (_slot0(rid) > uint160(lo + (lo / 200))) {
                size = size * 2; // still inside band, push harder
            } else {
                vm.revertTo(sizeSnap);
                sizeSnap = vm.snapshot();
                break;
            }
        }
        _swap(route, true, size / 2);
    }

    function _restore(PoolKey memory route, PoolId rid) internal {
        // Swap the other way until we are back near price 1. Approximate; the reference
        // has already been sampled, which is the whole point.
        uint160 s = _slot0(rid);
        if (s < TickMath.getSqrtPriceAtTick(0)) {
            _swap(route, false, -1e15);
        }
    }
}
