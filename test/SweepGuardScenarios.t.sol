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

/// @notice Pump, sweep and dump inside a single transaction.
contract AtomicSandwich {
    using PoolIdLibrary for PoolKey;

    IPoolManager immutable pm;
    PoolSwapTest immutable router;
    GuardedSweeper immutable sweeper;

    constructor(IPoolManager pm_, PoolSwapTest router_, GuardedSweeper sweeper_, Currency a, Currency b) {
        pm = pm_;
        router = router_;
        sweeper = sweeper_;
        MockERC20(Currency.unwrap(a)).approve(address(router_), type(uint256).max);
        MockERC20(Currency.unwrap(b)).approve(address(router_), type(uint256).max);
    }

    function run(PoolKey calldata route, uint160 pumpTo, uint160 restoreTo) external returns (uint256 out) {
        _moveTo(route, pumpTo);
        out = sweeper.sweep(route, 0);
        _moveTo(route, restoreTo);
    }

    function _moveTo(PoolKey memory route, uint160 target) internal {
        (uint160 s,,,) = StateLibrary.getSlot0(pm, route.toId());
        if (s == target) return;
        router.swap(
            route,
            SwapParams({zeroForOne: target < s, amountSpecified: -1e36, sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}

/// @notice The four scenarios, run against a real v4 PoolManager and a hookless 0.30% route
///         holding L = 1e21 in ticks -60000..60000 at price 1 (about 1e21 of each token in
///         range). Each config is the deployed MidasRWAHook rails (1 h, 10% sqrt band, 3%
///         floor, quarter-step reference) plus, where named, the anchored floor or drift cap.
///         The attacker always pushes as far as the guard admits: the band edge, or the
///         deepest price a sweep still clears when the floor is anchored. Every figure in
///         docs/SWEEP-GUARD.md comes from the -vv logs of this file.
contract SweepGuardScenarios is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint128 constant L = 1e21;
    uint256 constant BPS = 10_000;
    address keeper = address(0xC0FFEE);
    address attacker = address(0xBAD);
    uint160 SQRT1;
    PoolKey route;
    PoolId rid;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        SQRT1 = TickMath.getSqrtPriceAtTick(0);
        route = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        rid = route.toId();
        manager.initialize(route, SQRT1);
        modifyLiquidityRouter.modifyLiquidity(
            route,
            ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: int256(uint256(L)), salt: 0}),
            ""
        );
        MockERC20(Currency.unwrap(currency0)).mint(attacker, 1e24);
        MockERC20(Currency.unwrap(currency1)).mint(attacker, 1e24);
        vm.startPrank(attacker);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

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

    // =====================================================================
    // helpers
    // =====================================================================

    function _cfg(bool anchor, uint16 drift) internal pure returns (SweepGuard.Params memory) {
        return SweepGuard.Params({
            interval: 1 hours, bandBps: 1000, floorBps: 300, smoothing: 4, anchorFloor: anchor, maxDriftBps: drift
        });
    }

    function _sweeper(SweepGuard.Params memory p, bool outIsToken1) internal returns (GuardedSweeper) {
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = route;
        uint160[] memory seeds = new uint160[](1);
        seeds[0] = SQRT1;
        return new GuardedSweeper(
            manager, outIsToken1 ? currency0 : currency1, outIsToken1 ? currency1 : currency0, keys, seeds, p
        );
    }

    function _atomic(GuardedSweeper s) internal returns (AtomicSandwich atk) {
        atk = new AtomicSandwich(manager, swapRouter, s, currency0, currency1);
        MockERC20(Currency.unwrap(currency0)).mint(address(atk), 1e24);
        MockERC20(Currency.unwrap(currency1)).mint(address(atk), 1e24);
    }

    function _fund(GuardedSweeper s, uint256 amt) internal {
        MockERC20(Currency.unwrap(s.tokenIn())).mint(address(s), amt);
    }

    function _spot() internal view returns (uint160 s) {
        (s,,,) = StateLibrary.getSlot0(manager, rid);
    }

    function _ref(GuardedSweeper s) internal view returns (uint160 r) {
        (, r,) = s.routes(rid);
    }

    function _value(address who) internal view returns (uint256) {
        return currency0.balanceOf(who) + currency1.balanceOf(who);
    }

    function _r18(uint160 s) internal pure returns (uint256) {
        return (uint256(s) * 1e18) >> 96;
    }

    function _lossBps(uint256 honest, uint256 got) internal pure returns (uint256) {
        return honest > got ? ((honest - got) * BPS) / honest : 0;
    }

    function _moveTo(uint160 target) internal {
        uint160 s = _spot();
        if (s == target) return;
        vm.prank(attacker);
        swapRouter.swap(
            route,
            SwapParams({zeroForOne: target < s, amountSpecified: -1e36, sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev The most adverse spot the band admits, i.e. tokenOut at its dearest.
    function _edge(GuardedSweeper s) internal view returns (uint160) {
        uint256 band = s.params().bandBps;
        uint256 ref = _ref(s);
        return Currency.unwrap(s.tokenOut()) == Currency.unwrap(currency1)
            ? uint160((ref * (BPS - band)) / BPS)
            : uint160((ref * (BPS + band)) / BPS);
    }

    function _keeperSweep(GuardedSweeper s) internal returns (uint256) {
        vm.prank(keeper);
        return s.sweep(route, 0);
    }

    function _honestOut(GuardedSweeper s) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        out = _keeperSweep(s);
        vm.revertToState(snap);
    }

    function _tryAt(GuardedSweeper s, uint160 target) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        _moveTo(target);
        vm.prank(keeper);
        (ok,) = address(s).call(abi.encodeCall(GuardedSweeper.sweep, (route, 0)));
        vm.revertToState(snap);
    }

    /// @dev Binary search for the deepest pump toward `edge` at which a sweep still clears.
    function _deepestAdmissible(GuardedSweeper s, uint160 edge) internal returns (uint160) {
        if (_tryAt(s, edge)) return edge;
        uint256 ok = _spot();
        uint256 bad = edge;
        for (uint256 i; i < 64; i++) {
            uint256 m = (ok + bad) / 2;
            if (m == ok || m == bad) break;
            if (_tryAt(s, uint160(m))) ok = m;
            else bad = m;
        }
        return uint160(ok);
    }

    /// @dev Pump to `target`, keeper sweeps, dump back to fair. P&L valued at price 1.
    function _sandwich(GuardedSweeper s, uint160 target) internal returns (uint256 out, int256 pnl) {
        uint256 v0 = _value(attacker);
        _moveTo(target);
        out = _keeperSweep(s);
        _moveTo(SQRT1);
        pnl = int256(_value(attacker)) - int256(v0);
    }

    function _pumpSweepDumpAtEdge(GuardedSweeper s, uint256 expectBps, string memory label) internal {
        _fund(s, 1e18);
        uint256 honest = _honestOut(s);
        uint160 edge = _edge(s);
        (uint256 out, int256 pnl) = _sandwich(s, edge);
        uint256 loss = _lossBps(honest, out);
        emit log_named_string("case", label);
        emit log_named_uint("route depth L", L);
        emit log_named_uint("sweep size before 0.5% bounty", 1e18);
        emit log_named_decimal_uint("pumped to sqrt / 2^96", _r18(edge), 18);
        emit log_named_uint("honest out", honest);
        emit log_named_uint("sandwiched out", out);
        emit log_named_decimal_uint("shortfall vs honest (%)", loss, 2);
        emit log_named_decimal_int("attacker P&L (tokens, after fees)", pnl, 18);
        assertApproxEqAbs(loss, expectBps, 15, "band-edge shortfall; the floor quoted at spot never fires");
    }

    function _honestAdmittedNextWindow(GuardedSweeper s) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 1 hours);
        _fund(s, 1e18);
        vm.prank(keeper);
        (ok,) = address(s).call(abi.encodeCall(GuardedSweeper.sweep, (route, 0)));
        vm.revertToState(snap);
    }

    /// @dev 24 consecutive sandwiches, one per cooldown, each pushed as far as admitted.
    function _walk(GuardedSweeper s, bool search, string memory label)
        internal
        returns (uint256 capturedAt, uint256 lastLoss)
    {
        _fund(s, 1e18);
        uint256 honest = _honestOut(s);
        int256 cum;
        for (uint256 n = 1; n <= 24; n++) {
            if (n > 1) {
                vm.warp(block.timestamp + 1 hours);
                _fund(s, 1e18);
            }
            uint160 target = search ? _deepestAdmissible(s, _edge(s)) : _edge(s);
            (uint256 out, int256 pnl) = _sandwich(s, target);
            cum += pnl;
            lastLoss = _lossBps(honest, out);
            if (capturedAt == 0 && !_honestAdmittedNextWindow(s)) capturedAt = n;
            if (n == 1 || n == 4 || n == 12 || n == 24) {
                emit log_named_uint(string.concat(label, " sweep #"), n);
                emit log_named_decimal_uint("  ref after / 2^96", _r18(_ref(s)), 18);
                emit log_named_decimal_uint("  shortfall vs fair (%)", lastLoss, 2);
                emit log_named_decimal_int("  attacker cumulative P&L (tokens)", cum, 18);
            }
        }
        emit log_named_uint(string.concat(label, ": honest sweeps refused from sweep # (0 = never)"), capturedAt);
    }
}
