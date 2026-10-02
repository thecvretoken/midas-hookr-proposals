// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SweepGuard} from "../src/libraries/SweepGuard.sol";
import {GuardedSweeper} from "./utils/GuardedSweeper.sol";
import {SweepGuardBase, AtomicSandwich} from "./utils/SweepGuardBase.sol";

/// @notice The four scenarios, run against a real v4 PoolManager and a hookless 0.30% route
///         holding L = 1e21 in ticks -60000..60000 at price 1 (about 1e21 of each token in
///         range). Each config is the deployed MidasRWAHook rails (1 h, 10% sqrt band, 3%
///         floor, quarter-step reference) plus, where named, the anchored floor or drift cap.
///         The attacker always pushes as far as the guard admits: the band edge, or the
///         deepest price a sweep still clears when the floor is anchored. Every figure in
///         docs/SWEEP-GUARD.md comes from the -vv logs of this file.
contract SweepGuardScenarios is SweepGuardBase {
    // =====================================================================
    // 1. Pump-sweep-dump: an honest keeper's sweep sandwiched across transactions
    // =====================================================================

    /// @dev tokenOut sorts as token0, so the adverse edge is +10% in sqrt, +21% in price.
    ///      Expected shortfall 1 - 1/1.21 = 17.4%. The 3% floor does not fire.
    function test_pumpSweepDump_asDeployed_upperEdge() public {
        GuardedSweeper s = _sweeper(_cfg(false, 0), false);
        _pumpSweepDumpAtEdge(s, 1736, "upper edge (+10% sqrt, +21% price)");
    }

    /// @dev tokenOut sorts as token1, the 09-22 GOLD ordering. Adverse edge -10% sqrt, -19%
    ///      in price. Expected shortfall 1 - 0.81 = 19.0%.
    function test_pumpSweepDump_asDeployed_lowerEdge() public {
        GuardedSweeper s = _sweeper(_cfg(false, 0), true);
        _pumpSweepDumpAtEdge(s, 1900, "lower edge (-10% sqrt, -19% price)");
    }

    /// @dev Same attack with the floor quoted at the stored reference. The edge now reverts,
    ///      and the deepest pump a sweep still clears costs the bucket under 3%.
    function test_pumpSweepDump_anchoredFloor() public {
        GuardedSweeper s = _sweeper(_cfg(true, 0), false);
        _fund(s, 1e18);
        uint256 honest = _honestOut(s);
        uint160 edge = _edge(s);

        uint256 snap = vm.snapshotState();
        _moveTo(edge);
        vm.prank(keeper);
        vm.expectRevert(SweepGuard.BelowFloor.selector);
        s.sweep(route, 0);
        vm.revertToState(snap);

        uint160 deepest = _deepestAdmissible(s, edge);
        (uint256 out, int256 pnl) = _sandwich(s, deepest);
        uint256 loss = _lossBps(honest, out);
        emit log_named_decimal_uint("anchored: deepest admissible sqrt / 2^96", _r18(deepest), 18);
        emit log_named_decimal_uint("anchored: shortfall vs honest (%)", loss, 2);
        emit log_named_decimal_int("anchored: attacker P&L (tokens)", pnl, 18);
        assertLe(loss, 300, "shortfall capped by the floor, not the band");
    }

    // =====================================================================
    // 2. Same-transaction manipulation: the cooldown does not stop an atomic sandwich
    // =====================================================================

    /// @dev Bucket at 1% of route depth. One call pumps to the edge, sweeps and dumps back.
    ///      The cooldown is irrelevant because nothing is held across a block.
    function test_sameTx_asDeployed_profitsAtThisBucketToDepth() public {
        GuardedSweeper s = _sweeper(_cfg(false, 0), true);
        _fund(s, 1e19);
        uint256 honest = _honestOut(s);
        AtomicSandwich atk = _atomic(s);
        uint256 v0 = _value(address(atk));
        uint256 out = atk.run(route, _edge(s), SQRT1);
        int256 pnl = int256(_value(address(atk))) - int256(v0);
        uint256 loss = _lossBps(honest, out);
        emit log_named_decimal_uint("same-tx: shortfall vs honest (%)", loss, 2);
        emit log_named_decimal_int("same-tx: attacker P&L (tokens)", pnl, 18);
        assertGt(loss, 1800, "bucket loses about the band-edge amount");
        assertGt(pnl, 0, "profitable at 1% bucket-to-depth");
    }

    function test_sameTx_anchoredFloor() public {
        GuardedSweeper s = _sweeper(_cfg(true, 0), true);
        _fund(s, 1e19);
        uint256 honest = _honestOut(s);
        AtomicSandwich atk = _atomic(s);
        uint160 edge = _edge(s);

        uint256 snap = vm.snapshotState();
        vm.expectRevert(SweepGuard.BelowFloor.selector);
        atk.run(route, edge, SQRT1);
        vm.revertToState(snap);

        uint160 deepest = _deepestAdmissible(s, edge);
        uint256 v0 = _value(address(atk));
        uint256 out = atk.run(route, deepest, SQRT1);
        int256 pnl = int256(_value(address(atk))) - int256(v0);
        uint256 loss = _lossBps(honest, out);
        emit log_named_decimal_uint("same-tx anchored: shortfall vs honest (%)", loss, 2);
        emit log_named_decimal_int("same-tx anchored: attacker P&L (tokens)", pnl, 18);
        assertLe(loss, 300);
    }

    // =====================================================================
    // 3. Slow walk: one sandwich per cooldown, 24 in a row (one day at 1 h)
    // =====================================================================

    /// @dev Every sweep samples the edge, so the reference steps 2.5% in sqrt per sweep:
    ///      0.975^n. From the 4th sweep an honest sweep at the fair price is out of band, so
    ///      only the attacker can sweep. The attacker pays route fees on every leg.
    function test_slowWalk_asDeployed() public {
        GuardedSweeper s = _sweeper(_cfg(false, 0), true);
        (uint256 capturedAt, uint256 lastLoss) = _walk(s, false, "deployed");
        uint256 expect = 1e18;
        for (uint256 i; i < 24; i++) {
            expect = (expect * 975) / 1000;
        }
        assertApproxEqRel(_r18(_ref(s)), expect, 2e15, "reference = 0.975^24 of the seed");
        assertEq(capturedAt, 4, "honest sweeps refused from the 4th sweep");
        assertGt(lastLoss, 7000, "24th sweep pays over 70% below fair");
    }

    /// @dev Anchored floor: each sweep can only be pushed a little under the reference, so
    ///      the walk is far slower, and honest sweeps are never locked out within the day.
    function test_slowWalk_anchoredFloor() public {
        GuardedSweeper s = _sweeper(_cfg(true, 0), true);
        (uint256 capturedAt,) = _walk(s, true, "anchored");
        assertEq(capturedAt, 0, "honest sweeps still admitted");
        assertGt(_r18(_ref(s)), 0.9e18, "walked well under 10% in sqrt over the day");
    }

    /// @dev Anchored floor plus a 2% drift cap: the reference stops at the cap and the
    ///      shortfall per sweep stops growing.
    function test_slowWalk_anchoredFloorWithDriftCap() public {
        GuardedSweeper s = _sweeper(_cfg(true, 200), true);
        (uint256 capturedAt, uint256 lastLoss) = _walk(s, true, "anchored+cap");
        assertEq(capturedAt, 0);
        assertGe(_ref(s), uint160((uint256(SQRT1) * 9800) / BPS), "reference held at the cap");
        assertLe(lastLoss, 700, "worst sweep stays near 1 - 0.98^2 * 0.97");
    }

    // =====================================================================
    // 4. Legit large move: the market reprices and stays there
    // =====================================================================

    /// @dev tokenOut 20% dearer for real: past the band, so honest sweeps stall until the price
    ///      comes back inside it. 15% is inside: admitted, and the reference follows.
    function test_legitLargeMove_asDeployed() public {
        GuardedSweeper s = _sweeper(_cfg(false, 0), true);
        _fund(s, 1e18);
        _moveTo(TickMath.getSqrtPriceAtTick(-2232)); // price 0.80
        vm.prank(keeper);
        vm.expectRevert(SweepGuard.OutOfBand.selector);
        s.sweep(route, 0);

        _moveTo(TickMath.getSqrtPriceAtTick(-1625)); // price 0.85
        _keeperSweep(s);
        emit log_named_decimal_uint("deployed: ref after admitted 15% move / 2^96", _r18(_ref(s)), 18);
        assertLt(_ref(s), SQRT1, "reference followed the real move");
    }

    /// @dev The cost of anchoring: a real 5% move stalls honest sweeps even inside the band,
    ///      because the floor is now quoted at the stale reference. 2% still clears.
    function test_legitLargeMove_anchoredFloor() public {
        GuardedSweeper s = _sweeper(_cfg(true, 0), true);
        _fund(s, 1e18);
        _moveTo(TickMath.getSqrtPriceAtTick(-513)); // price 0.95
        vm.prank(keeper);
        vm.expectRevert(SweepGuard.BelowFloor.selector);
        s.sweep(route, 0);

        _moveTo(TickMath.getSqrtPriceAtTick(-202)); // price 0.98
        _keeperSweep(s);
    }

    /// @dev Favourable moves (tokenOut cheaper) are never blocked short of the band, anchored
    ///      or not: a cheaper fill only helps the bucket.
    function test_legitLargeMove_favourableSideClears() public {
        GuardedSweeper a = _sweeper(_cfg(false, 0), true);
        GuardedSweeper b = _sweeper(_cfg(true, 0), true);
        _fund(a, 1e18);
        _fund(b, 1e18);
        _moveTo(TickMath.getSqrtPriceAtTick(1398)); // price 1.15
        _keeperSweep(a);
        _keeperSweep(b);
    }

    // =====================================================================
    // The routing gap from 09-22, against the library
    // =====================================================================

    /// @dev A same-pair pool on another fee tier has a fresh PoolId and no seed, so it is
    ///      refused before the bucket is touched.
    function test_attackerRoute_unseededIsRefused() public {
        GuardedSweeper s = _sweeper(_cfg(false, 0), true);
        _fund(s, 1e18);
        PoolKey memory evil = PoolKey(currency0, currency1, 500, 10, IHooks(address(0)));
        manager.initialize(evil, TickMath.getSqrtPriceAtTick(-40_000));
        modifyLiquidityRouter.modifyLiquidity(
            evil, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e18, salt: 0}), ""
        );
        vm.prank(attacker);
        vm.expectRevert(SweepGuard.RouteNotSeeded.selector);
        s.sweep(evil, 0);
        assertEq(currency0.balanceOf(address(s)), 1e18, "bucket untouched");
    }
}
