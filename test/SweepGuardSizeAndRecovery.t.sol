// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SweepGuard} from "../src/libraries/SweepGuard.sol";
import {GuardedSweeper} from "./utils/GuardedSweeper.sol";
import {SweepGuardBase, AtomicSandwich} from "./utils/SweepGuardBase.sol";

/// @notice The two pieces added after 2 Oct: a per-conversion size cap, and a bounded recovery
///         path for a route stalled by a real price move. Same fixture as SweepGuardScenarios:
///         0.30% route, L = 1e21 in ticks -60000..60000 at price 1. Figures in
///         docs/SWEEP-GUARD.md come from the -vv logs of this file.
contract SweepGuardSizeAndRecovery is SweepGuardBase {
    using PoolIdLibrary for PoolKey;

    // =====================================================================
    // Size cap
    // =====================================================================

    /// @dev Same-tx sandwich at the band edge against a 100-token bucket, with the cap set at
    ///      15, 30, 60 and 120 bps of sqrt impact. Break-even should sit near the 0.30% route
    ///      fee: below it the attacker's two legs cost more than the take.
    function test_sizeCap_breakEvenSitsAtTheRouteFee() public {
        uint16[4] memory caps = [uint16(15), 30, 60, 120];
        int256[4] memory pnl;
        for (uint256 i; i < 4; i++) {
            uint256 snap = vm.snapshotState();
            SweepGuard.Params memory p = _cfg(false, 0);
            p.maxImpactBps = caps[i];
            GuardedSweeper s = _sweeper(p, true);
            _fund(s, 1e20);
            AtomicSandwich atk = _atomic(s);
            uint256 v0 = _value(address(atk));
            uint256 before = currency0.balanceOf(address(s));
            atk.run(route, _edge(s), SQRT1);
            pnl[i] = int256(_value(address(atk))) - int256(v0);
            emit log_named_uint("maxImpactBps", caps[i]);
            emit log_named_decimal_uint("  converted this call (tokens)", before - currency0.balanceOf(address(s)), 18);
            emit log_named_decimal_int("  attacker P&L (tokens)", pnl[i], 18);
            vm.revertToState(snap);
        }
        assertLt(pnl[0], 0, "15 bps, half the fee: sandwich loses");
        assertGt(pnl[2], 0, "60 bps, twice the fee: sandwich pays");
        assertGt(pnl[3], pnl[2], "and pays more the bigger the cap");
    }

    /// @dev The case that netted the attacker +1.35 on a 10-token bucket in SweepGuardScenarios,
    ///      rerun with the cap at half the route fee.
    function test_sizeCap_turnsTheProfitableSameTxCaseIntoALoss() public {
        SweepGuard.Params memory p = _cfg(false, 0);
        p.maxImpactBps = 15;
        GuardedSweeper s = _sweeper(p, true);
        _fund(s, 1e19);
        AtomicSandwich atk = _atomic(s);
        uint256 v0 = _value(address(atk));
        atk.run(route, _edge(s), SQRT1);
        int256 pnl = int256(_value(address(atk))) - int256(v0);
        emit log_named_decimal_int("same-tx, 1% bucket, capped at 15 bps: attacker P&L", pnl, 18);
        emit log_named_decimal_uint("left in the bucket for later", currency0.balanceOf(address(s)), 18);
        assertLt(pnl, 0);
        assertGt(currency0.balanceOf(address(s)), 8e18, "most of the bucket waits for later intervals");
    }

    /// @dev Why the impact cap needs a ceiling. Active liquidity is read at conversion time, so an
    ///      attacker who pumps the route and then parks a large narrow position at the pumped
    ///      price inflates it, the impact cap balloons, and the sweep fills against that position
    ///      at the bad price. The seal-time ceiling `maxIn` does not move, and the attack loses.
    function test_sizeCap_jitLiquidityBeatsImpactCap_ceilingHolds() public {
        int256 noCeiling = _jitAttack(0);
        int256 withCeiling = _jitAttack(1.5e18);
        emit log_named_decimal_int("JIT + edge pump, impact cap only: attacker P&L", noCeiling, 18);
        emit log_named_decimal_int("JIT + edge pump, ceiling 1.5 tokens: attacker P&L", withCeiling, 18);
        assertGt(noCeiling, 0, "impact cap alone is beaten");
        assertLt(withCeiling, 0, "the ceiling holds");
    }

    /// @dev Honest flow under the cap: each interval converts one capped slice near fair, and the
    ///      remainder waits. Arbitrage is assumed to return the route to fair between intervals.
    function test_sizeCap_honestFlowConvertsInSlices() public {
        SweepGuard.Params memory p = _cfg(false, 0);
        p.maxImpactBps = 15;
        GuardedSweeper s = _sweeper(p, true);
        _fund(s, 1e19);
        uint256 last = currency0.balanceOf(address(s));
        uint256 t = block.timestamp; // tracked locally: via-IR may cache block.timestamp across vm.warp
        for (uint256 i; i < 3; i++) {
            if (i > 0) {
                t += 1 hours;
                vm.warp(t);
                _moveTo(SQRT1); // arbitrage brings the route back to fair between intervals
            }
            uint256 out = _keeperSweep(s);
            uint256 left = currency0.balanceOf(address(s));
            uint256 converted = last - left;
            assertApproxEqRel(converted, 1.5e18, 2e16, "one slice of about 0.15% of depth");
            // 0.5% bounty + 0.30% route fee + about 0.15% average impact
            assertGt(out, (converted * 9890) / 10_000, "slice fills within bounty + fee + impact of fair");
            last = left;
        }
        emit log_named_decimal_uint("left after three hourly slices (tokens)", last, 18);
    }

    // =====================================================================
    // Recovery
    // =====================================================================

    /// @dev A real move to sqrt 0.8 (price 0.64) after an honest conversion. Honest sweeps stall
    ///      out of band. The reseed authority cannot act until the route has been stalled for six
    ///      hours, then walks the reference 5% per hour until the band admits the market.
    function test_recovery_reseedWalksTheReferenceToARealMove() public {
        GuardedSweeper s = _sweeper(_cfg(false, 0), true);
        _fund(s, 1e18);
        _keeperSweep(s);
        uint256 convertedAt = block.timestamp;

        _moveTo(uint160((uint256(SQRT1) * 8000) / BPS));
        vm.warp(block.timestamp + 1 hours);
        _fund(s, 1e18);
        vm.prank(keeper);
        vm.expectRevert(SweepGuard.OutOfBand.selector);
        s.sweep(route, 0);

        uint160 market = _spot();
        vm.expectRevert(SweepGuard.RouteNotStalled.selector);
        s.reseed(route, market);
        vm.prank(attacker);
        vm.expectRevert(GuardedSweeper.NotAuthority.selector);
        s.reseed(route, market);

        uint256 t = convertedAt + 6 hours; // tracked locally: via-IR may cache block.timestamp
        vm.warp(t);
        uint256 steps;
        while (true) {
            s.reseed(route, market);
            steps++;
            emit log_named_decimal_uint("  reseed -> ref / 2^96", _r18(_ref(s)), 18);
            if (_tryAt(s, market)) break;
            vm.expectRevert(SweepGuard.ReseedTooSoon.selector);
            s.reseed(route, market);
            t += 1 hours;
            vm.warp(t);
            require(steps < 10, "never recovered");
        }
        _keeperSweep(s);
        emit log_named_uint("reseeds before the band admitted the market", steps);
        emit log_named_decimal_uint("ref after the first recovered sweep / 2^96", _r18(_ref(s)), 18);
        assertEq(steps, 3, "0.95, 0.9025, 0.857: the third step brings 0.8 inside the band");
    }

    /// @dev Anchored floor with a 2% drift cap stalls on a real 5% move. One reseed re-anchors the
    ///      seed at the market, the sweep clears, and the drift cap now holds around the new seed.
    function test_recovery_anchoredFloorWithDriftCap() public {
        GuardedSweeper s = _sweeper(_cfg(true, 200), true);
        _fund(s, 1e18);
        _keeperSweep(s);
        uint256 convertedAt = block.timestamp;

        _moveTo(TickMath.getSqrtPriceAtTick(-513)); // price 0.95, a real move
        vm.warp(block.timestamp + 1 hours);
        _fund(s, 1e18);
        vm.prank(keeper);
        vm.expectRevert(SweepGuard.BelowFloor.selector);
        s.sweep(route, 0);

        vm.warp(convertedAt + 6 hours);
        uint160 market = _spot();
        s.reseed(route, market);
        assertEq(_seed(s), market, "seed re-anchored at the market");
        _keeperSweep(s);
        uint256 seedNow = _seed(s);
        uint256 ref = _ref(s);
        assertLe(ref, (seedNow * 10_200) / BPS);
        assertGe(ref, (seedNow * 9800) / BPS);
    }


    // =====================================================================
    // Adversarial checks on the two new pieces
    // =====================================================================

    /// @dev The capped remainder cannot be pulled through early: a second conversion inside the
    ///      interval is refused for the keeper and the attacker alike, and the bucket is untouched.
    function test_sizeCap_remainderCannotBeDrainedInsideTheInterval() public {
        SweepGuard.Params memory p = _cfg(false, 0);
        p.maxImpactBps = 15;
        GuardedSweeper s = _sweeper(p, true);
        _fund(s, 1e19);
        _keeperSweep(s);
        uint256 left = currency0.balanceOf(address(s));
        vm.prank(keeper);
        vm.expectRevert(SweepGuard.TooSoon.selector);
        s.sweep(route, 0);
        vm.prank(attacker);
        vm.expectRevert(SweepGuard.TooSoon.selector);
        s.sweep(route, 0);
        assertEq(currency0.balanceOf(address(s)), left, "remainder untouched");
    }

    /// @dev When honest liquidity leaves, the impact cap shrinks with it: 90% of the depth
    ///      withdrawn, about a tenth of the slice.
    function test_sizeCap_shrinksWhenLiquidityLeaves() public {
        SweepGuard.Params memory p = _cfg(false, 0);
        p.maxImpactBps = 15;
        GuardedSweeper s = _sweeper(p, true);
        _fund(s, 1e19);
        modifyLiquidityRouter.modifyLiquidity(
            route, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: -9e20, salt: 0}), ""
        );
        uint256 before = currency0.balanceOf(address(s));
        _keeperSweep(s);
        uint256 converted = before - currency0.balanceOf(address(s));
        emit log_named_decimal_uint("slice with 10% of the depth left (tokens)", converted, 18);
        assertApproxEqRel(converted, 1.5e17, 2e16);
    }

    /// @dev No active liquidity at spot: the only liquidity sits 6-12% below. Uncapped, the swap
    ///      jumps the gap and the floor has to stop it. Capped, nothing converts at all.
    function test_sizeCap_zeroActiveLiquidityConvertsNothing() public {
        PoolKey memory gap = PoolKey(currency0, currency1, 500, 10, IHooks(address(0)));
        manager.initialize(gap, SQRT1);
        modifyLiquidityRouter.modifyLiquidity(
            gap, ModifyLiquidityParams({tickLower: -1200, tickUpper: -600, liquidityDelta: 1e21, salt: 0}), ""
        );
        SweepGuard.Params memory capped = _cfg(false, 0);
        capped.maxImpactBps = 15;
        GuardedSweeper a = _sweeperOn(gap, _cfg(false, 0), 0);
        GuardedSweeper b = _sweeperOn(gap, capped, 0);
        _fund(a, 1e18);
        _fund(b, 1e18);
        vm.prank(keeper);
        vm.expectRevert(SweepGuard.BelowFloor.selector);
        a.sweep(gap, 0);
        vm.prank(keeper);
        vm.expectRevert(GuardedSweeper.NothingConvertible.selector);
        b.sweep(gap, 0);
    }

    /// @dev The cap assumes constant liquidity across its move. Here the depth sits only within
    ///      10 ticks of spot over a thin floor, so a slice sized from active liquidity runs past
    ///      the deep band into the thin one. The output floor stops it. A seal-time ceiling sized
    ///      to the deep band lets the slice clear.
    function test_sizeCap_constantLiquidityAssumption_floorIsTheBackstop() public {
        PoolKey memory steep = PoolKey(currency0, currency1, 500, 10, IHooks(address(0)));
        manager.initialize(steep, SQRT1);
        modifyLiquidityRouter.modifyLiquidity(
            steep, ModifyLiquidityParams({tickLower: -10, tickUpper: 10, liquidityDelta: 1e22, salt: 0}), ""
        );
        modifyLiquidityRouter.modifyLiquidity(
            steep, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e18, salt: 0}), ""
        );
        SweepGuard.Params memory p = _cfg(false, 0);
        p.maxImpactBps = 15;
        GuardedSweeper a = _sweeperOn(steep, p, 0);
        GuardedSweeper b = _sweeperOn(steep, p, 4e18);
        _fund(a, 2e19);
        _fund(b, 2e19);
        vm.prank(keeper);
        vm.expectRevert(SweepGuard.BelowFloor.selector);
        a.sweep(steep, 0);
        vm.prank(keeper);
        uint256 out = b.sweep(steep, 0);
        emit log_named_decimal_uint("steep pool, ceiling 4 tokens: converted out (tokens)", out, 18);
        assertGt(out, 0);
    }

    /// @dev The authority's whole power is `reseed`. Twelve plausible setter and upgrade
    ///      signatures, called by the authority and by an outsider, all revert, and the guard's
    ///      observable state is byte-identical afterwards. A reseed itself moves only the
    ///      reference, the seed and its timestamp.
    function test_authority_canOnlyReseed_noSetterSelectorsExist() public {
        GuardedSweeper s = _sweeper(_cfg(true, 200), true, 1.5e18);
        bytes32 before = _stateHash(s);
        bytes[12] memory probes = [
            abi.encodeWithSignature("setParams((uint32,uint16,uint16,uint8,bool,uint16,uint16))", _cfg(false, 0)),
            abi.encodeWithSignature("setWalls((uint16,uint32,uint32))", _walls()),
            abi.encodeWithSignature("setAuthority(address)", attacker),
            abi.encodeWithSignature("transferOwnership(address)", attacker),
            abi.encodeWithSignature("renounceOwnership()"),
            abi.encodeWithSignature("setMaxIn(bytes32,uint128)", PoolId.unwrap(rid), uint128(1e30)),
            abi.encodeWithSignature("addRoute(bytes32,uint160,uint128)", bytes32(uint256(1)), SQRT1, uint128(0)),
            abi.encodeWithSignature("seal(bytes32,uint160,uint128)", PoolId.unwrap(rid), SQRT1, uint128(0)),
            abi.encodeWithSignature("setSink(address)", attacker),
            abi.encodeWithSignature("setBounty(uint256)", uint256(10_000)),
            abi.encodeWithSignature("upgradeTo(address)", attacker),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", attacker, bytes(""))
        ];
        address[2] memory callers = [address(this), attacker];
        for (uint256 c; c < 2; c++) {
            for (uint256 i; i < 12; i++) {
                vm.prank(callers[c]);
                (bool ok,) = address(s).call(probes[i]);
                assertFalse(ok, "a setter exists");
            }
        }
        vm.prank(attacker);
        (bool cb,) = address(s).call(abi.encodeWithSignature("unlockCallback(bytes)", bytes("")));
        assertFalse(cb, "callback reachable outside the PoolManager");
        assertEq(_stateHash(s), before, "state changed");

        (, uint64 lastAt0,,, uint128 maxIn0) = s.routes(rid);
        s.reseed(route, uint160((uint256(SQRT1) * 9700) / BPS)); // never converted, so not gated by the stall
        (uint160 sd, uint64 lastAt1, uint160 ref1, uint64 at1, uint128 maxIn1) = s.routes(rid);
        assertEq(sd, ref1, "seed follows the reference");
        assertEq(lastAt1, lastAt0, "conversion clock untouched");
        assertEq(maxIn1, maxIn0, "ceiling untouched");
        assertEq(at1, block.timestamp);
        assertEq(keccak256(abi.encode(s.params(), s.authority())), keccak256(abi.encode(_cfg(true, 200), address(this))));
    }

    function _stateHash(GuardedSweeper s) internal view returns (bytes32) {
        (uint160 a, uint64 b, uint160 c, uint64 d, uint128 e) = s.routes(rid);
        return keccak256(abi.encode(s.params(), a, b, c, d, e, s.authority(), s.tokenIn(), s.tokenOut()));
    }

    /// @dev A sweeper on an arbitrary route, converting currency0 into currency1.
    function _sweeperOn(PoolKey memory key, SweepGuard.Params memory p, uint128 maxIn) internal returns (GuardedSweeper) {
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = key;
        uint160[] memory seeds = new uint160[](1);
        seeds[0] = SQRT1;
        uint128[] memory caps = new uint128[](1);
        caps[0] = maxIn;
        return new GuardedSweeper(manager, currency0, currency1, keys, seeds, caps, p, address(this), _walls());
    }

    // =====================================================================
    // helpers
    // =====================================================================

    function _jitAttack(uint128 ceiling) internal returns (int256 pnl) {
        uint256 snap = vm.snapshotState();
        SweepGuard.Params memory p = _cfg(false, 0);
        p.maxImpactBps = 15;
        GuardedSweeper s = _sweeper(p, true, ceiling);
        _fund(s, 1e19);
        uint256 v0 = _value(attacker);

        uint160 edge = _edge(s);
        _moveTo(edge);
        int24 t = TickMath.getTickAtSqrtPrice(edge);
        int24 lower = (t / 60) * 60;
        if (t < 0 && t % 60 != 0) lower -= 60;
        lower -= 60;
        ModifyLiquidityParams memory jit =
            ModifyLiquidityParams({tickLower: lower, tickUpper: lower + 180, liquidityDelta: 1e23, salt: bytes32(uint256(0xBAD))});
        vm.prank(attacker);
        modifyLiquidityRouter.modifyLiquidity(route, jit, "");
        _keeperSweep(s);
        jit.liquidityDelta = -1e23;
        vm.prank(attacker);
        modifyLiquidityRouter.modifyLiquidity(route, jit, "");
        _moveTo(SQRT1);

        pnl = int256(_value(attacker)) - int256(v0);
        vm.revertToState(snap);
    }
}
