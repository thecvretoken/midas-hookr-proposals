// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SweepGuard} from "../src/libraries/SweepGuard.sol";
import {GuardedSweeper} from "./utils/GuardedSweeper.sol";
import {SweepGuardBase, AtomicSandwich} from "./utils/SweepGuardBase.sol";

/// @notice Sets its pool's dynamic LP fee and nothing else. Stands in for any hook that can
///         charge less than the nominal fee: a discount window, an envelope sitting at its floor.
contract DynamicFeeHook {
    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function setFee(PoolKey calldata key, uint24 fee) external {
        pm.updateDynamicLPFee(key, fee);
    }
}

/// @notice Runs the guard steps on live pool state and reports their gas.
contract GuardSteps {
    using SweepGuard for SweepGuard.Route;
    using PoolIdLibrary for PoolKey;

    IPoolManager immutable pm;
    mapping(PoolId => SweepGuard.Route) internal routes;

    constructor(IPoolManager pm_, PoolKey memory key, uint160 seed, uint128 maxIn) {
        pm = pm_;
        routes[key.toId()].seal(seed, maxIn);
    }

    function run(PoolKey calldata key, SweepGuard.Params calldata p, uint256 bal) external returns (uint256 used) {
        uint256 g = gasleft();
        PoolId id = key.toId();
        uint160 spot = SweepGuard.spotOf(pm, key);
        uint256 cap = SweepGuard.capIn(routes[id], p, SweepGuard.liquidityOf(pm, key), spot, true);
        uint160 refUsed = routes[id].admit(p, spot);
        uint256 amt = bal < cap ? bal : cap;
        uint256 floorOut = SweepGuard.minOut(p, amt, true, spot, refUsed);
        SweepGuard.enforce(floorOut, floorOut);
        used = g - gasleft();
    }
}

/// @notice What Hookr will hit wiring the guard in: a read-only preview that has to match the
///         real sweep, the fee rule on other fee tiers and prices, hooked dynamic-fee routes, and
///         what the guard costs per conversion. Figures in docs/SWEEP-GUARD.md come from -vv.
contract SweepGuardIntegration is SweepGuardBase {
    using PoolIdLibrary for PoolKey;

    // =====================================================================
    // Read-only preview
    // =====================================================================

    /// @dev previewSweep, a view, predicts the real sweep: Ok with the amount the sweep then takes
    ///      and a floor the fill clears, then TooSoon and OutOfBand exactly where the sweep
    ///      reverts with those errors, and NotSeeded for a route that was never sealed.
    function test_preview_matchesWhatTheSweepDoes() public {
        SweepGuard.Params memory p = _cfg(false, 0);
        p.maxImpactBps = 15;
        GuardedSweeper s = _sweeper(p, true);
        _fund(s, 1e19);

        SweepGuard.Quote memory q = s.previewSweep(route);
        assertEq(uint8(q.status), uint8(SweepGuard.Status.Ok));
        uint256 before = currency0.balanceOf(address(s));
        uint256 out = _keeperSweep(s);
        uint256 took = before - currency0.balanceOf(address(s));
        assertEq(took - q.amountIn, (took * 50) / 10_000, "previewed amount is the swap, net of the bounty");
        assertGe(out, q.floorOut, "fill clears the previewed floor");
        assertEq(_ref(s), q.next.ref, "previewed state is the stored state");

        q = s.previewSweep(route);
        assertEq(uint8(q.status), uint8(SweepGuard.Status.TooSoon));
        vm.prank(keeper);
        vm.expectRevert(SweepGuard.TooSoon.selector);
        s.sweep(route, 0);

        vm.warp(block.timestamp + 1 hours);
        _moveTo(uint160((uint256(SQRT1) * 8500) / BPS));
        q = s.previewSweep(route);
        assertEq(uint8(q.status), uint8(SweepGuard.Status.OutOfBand));
        assertEq(q.amountIn, 0);
        vm.prank(keeper);
        vm.expectRevert(SweepGuard.OutOfBand.selector);
        s.sweep(route, 0);

        PoolKey memory unsealed = PoolKey(currency0, currency1, 500, 10, IHooks(address(0)));
        assertEq(uint8(s.previewSweep(unsealed).status), uint8(SweepGuard.Status.NotSeeded));
    }

    // =====================================================================
    // The fee rule on other fee tiers and prices
    // =====================================================================

    /// @dev Same-tx sandwich at the band edge, the attacker's best case, on 0.05%, 0.30% and 1%
    ///      routes, at price 1 and at tick -195000 (a raw price near 3.3e-9, where an 18-decimal
    ///      token trades against a 6-decimal one). With the cap at half the fee the attacker
    ///      loses on every route; at twice the fee he wins on every route.
    function test_feeRule_holdsAcrossFeeTiersAndPrices() public {
        uint24[3] memory fees = [uint24(500), 3000, 10_000];
        // 30 rather than 60 for the 0.30% tier: the fixture already holds the 0.30%/60 pool at price 1.
        int24[3] memory spacings = [int24(10), 30, 200];
        int24[2] memory ticks = [int24(0), -195_000];
        for (uint256 f; f < 3; f++) {
            uint16 feeBps = uint16(fees[f] / 100);
            for (uint256 t; t < 2; t++) {
                int256 under = _edgeSandwichBps(fees[f], spacings[f], ticks[t], feeBps / 2);
                int256 over = _edgeSandwichBps(fees[f], spacings[f], ticks[t], feeBps * 2);
                emit log_named_uint("route fee, bps", feeBps);
                emit log_named_int("  tick", ticks[t]);
                emit log_named_int("  cap at half the fee: attacker P&L, bps of the slice", under);
                emit log_named_int("  cap at twice the fee: attacker P&L, bps of the slice", over);
                assertLt(under, 0, "half the fee should lose");
                assertGt(over, 0, "twice the fee should win");
            }
        }
    }

    // =====================================================================
    // Hooked, dynamic-fee routes
    // =====================================================================

    /// @dev A dynamic-fee route quoting 0.30% whose hook drops to 0.05%. A cap calibrated to the
    ///      nominal fee lets the sandwich pay, because the attacker's legs are priced at the fee
    ///      in force when he trades. Calibrated to the lowest fee the route can charge, it loses.
    function test_dynamicFeeRoute_calibrateFromTheLowestFee() public {
        int256 nominal = _dynamicFeeSandwichBps(15);
        int256 lowest = _dynamicFeeSandwichBps(2);
        emit log_named_int("fee drops to 0.05%, cap from the 0.30% nominal: attacker P&L, bps of the slice", nominal);
        emit log_named_int("fee drops to 0.05%, cap from the 0.05% floor: attacker P&L, bps of the slice", lowest);
        assertGt(nominal, 0, "nominal calibration is beaten");
        assertLt(lowest, 0, "floor calibration holds");
    }

    // =====================================================================
    // Gas
    // =====================================================================

    /// @dev Cold storage, as a real transaction sees it. The guard steps alone, the preview, and
    ///      a whole sweep (guard, unlock, swap, settle, bounty) on the 0.30% route.
    function test_gas_whatTheGuardCostsPerConversion() public {
        SweepGuard.Params memory p = _cfg(true, 200);
        p.maxImpactBps = 15;

        GuardSteps steps = new GuardSteps(manager, route, SQRT1, 1.5e18);
        vm.cool(address(steps));
        vm.cool(address(manager));
        uint256 guardOnly = steps.run(route, p, 1e19);

        GuardedSweeper s = _sweeper(p, true, 1.5e18);
        _fund(s, 1e19);
        vm.cool(address(s));
        vm.cool(address(manager));
        uint256 g = gasleft();
        s.previewSweep(route);
        uint256 previewGas = g - gasleft();

        vm.cool(address(s));
        vm.cool(address(manager));
        vm.cool(Currency.unwrap(currency0));
        vm.cool(Currency.unwrap(currency1));
        vm.prank(keeper);
        g = gasleft();
        s.sweep(route, 0);
        uint256 sweepGas = g - gasleft();

        emit log_named_uint("guard steps alone (spot, depth, cap, admit, floor), gas", guardOnly);
        emit log_named_uint("previewSweep, gas", previewGas);
        emit log_named_uint("whole sweep including the swap, gas", sweepGas);
        assertLt(guardOnly, 30_000);
        assertLt(sweepGas, 250_000);
    }

    // =====================================================================
    // helpers
    // =====================================================================

    function _pool(uint24 fee, int24 spacing, int24 tick, IHooks hook) internal returns (PoolKey memory key, uint160 s0) {
        key = PoolKey(currency0, currency1, fee, spacing, hook);
        s0 = TickMath.getSqrtPriceAtTick(tick);
        manager.initialize(key, s0);
    }

    function _addDepth(PoolKey memory key, int24 tick) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tick - 60_000,
                tickUpper: tick + 60_000,
                liquidityDelta: int256(uint256(L)),
                salt: 0
            }),
            ""
        );
    }

    /// @dev A sweeper converting currency0 into currency1 on `key`, seeded at `s0`.
    function _sweeperAt(PoolKey memory key, uint160 s0, SweepGuard.Params memory p) internal returns (GuardedSweeper) {
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = key;
        uint160[] memory seeds = new uint160[](1);
        seeds[0] = s0;
        uint128[] memory caps = new uint128[](1);
        return new GuardedSweeper(manager, currency0, currency1, keys, seeds, caps, p, address(this), _walls());
    }

    /// @dev Same-tx sandwich at the lower band edge against a bucket the cap always binds on.
    ///      Returns the attacker's P&L valued at the pool's starting price, in bps of the
    ///      converted slice's value.
    function _sandwichBps(PoolKey memory key, uint160 s0, GuardedSweeper s) internal returns (int256) {
        MockERC20(Currency.unwrap(currency0)).mint(address(s), 1e30);
        AtomicSandwich atk = new AtomicSandwich(manager, swapRouter, s, currency0, currency1);
        MockERC20(Currency.unwrap(currency0)).mint(address(atk), 1e30);
        MockERC20(Currency.unwrap(currency1)).mint(address(atk), 1e30);
        uint256 v0 = _valueAt(address(atk), s0);
        uint256 b0 = currency0.balanceOf(address(s));
        atk.run(key, uint160((uint256(s0) * (BPS - s.params().bandBps)) / BPS), s0);
        uint256 slice = SweepGuard.quote(b0 - currency0.balanceOf(address(s)), true, s0);
        int256 pnl = int256(_valueAt(address(atk), s0)) - int256(v0);
        return (pnl * int256(BPS)) / int256(slice);
    }

    function _edgeSandwichBps(uint24 fee, int24 spacing, int24 tick, uint16 capBps) internal returns (int256 bps) {
        uint256 snap = vm.snapshotState();
        (PoolKey memory key, uint160 s0) = _pool(fee, spacing, tick, IHooks(address(0)));
        _addDepth(key, tick);
        SweepGuard.Params memory p = _cfg(false, 0);
        p.maxImpactBps = capBps;
        bps = _sandwichBps(key, s0, _sweeperAt(key, s0, p));
        vm.revertToState(snap);
    }

    function _dynamicFeeSandwichBps(uint16 capBps) internal returns (int256 bps) {
        uint256 snap = vm.snapshotState();
        address hookAddr = address(uint160(0x4444000000000000000000000000000000000000));
        vm.etch(hookAddr, address(new DynamicFeeHook(manager)).code);
        DynamicFeeHook hook = DynamicFeeHook(hookAddr);
        (PoolKey memory key, uint160 s0) = _pool(LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, 0, IHooks(hookAddr));
        hook.setFee(key, 3000);
        _addDepth(key, 0);
        SweepGuard.Params memory p = _cfg(false, 0);
        p.maxImpactBps = capBps;
        GuardedSweeper s = _sweeperAt(key, s0, p);
        hook.setFee(key, 500); // the window the attacker waits for
        bps = _sandwichBps(key, s0, s);
        vm.revertToState(snap);
    }

    function _valueAt(address who, uint160 s0) internal view returns (uint256) {
        return currency1.balanceOf(who) + SweepGuard.quote(currency0.balanceOf(who), true, s0);
    }
}
