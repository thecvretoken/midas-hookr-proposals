// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SweepGuard} from "../src/libraries/SweepGuard.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice External wrapper so reverts from the internal library surface at call depth.
contract GuardHarness {
    using SweepGuard for SweepGuard.Route;

    SweepGuard.Route public r;

    function seed(uint160 s) external {
        r.seal(s, 0);
    }

    function capIn(SweepGuard.Route memory cur, SweepGuard.Params memory p, uint128 l, uint160 spot, bool z)
        external
        pure
        returns (uint256)
    {
        return SweepGuard.capIn(cur, p, l, spot, z);
    }

    function reseedNext(SweepGuard.Route memory cur, SweepGuard.ReseedWalls memory w, uint160 t, uint256 nowTs)
        external
        pure
        returns (SweepGuard.Route memory)
    {
        return SweepGuard.reseedNext(cur, w, t, nowTs);
    }

    function validateWalls(SweepGuard.ReseedWalls memory w) external pure {
        SweepGuard.validate(w);
    }

    function next(SweepGuard.Route memory cur, SweepGuard.Params memory p, uint160 spot, uint256 nowTs)
        external
        pure
        returns (SweepGuard.Route memory)
    {
        return SweepGuard.next(cur, p, spot, nowTs);
    }

    function minOut(SweepGuard.Params memory p, uint256 a, bool z, uint160 spot, uint160 ref)
        external
        pure
        returns (uint256)
    {
        return SweepGuard.minOut(p, a, z, spot, ref);
    }

    function quote(uint256 a, bool z, uint160 s) external pure returns (uint256) {
        return SweepGuard.quote(a, z, s);
    }

    function validate(SweepGuard.Params memory p) external pure {
        SweepGuard.validate(p);
    }
}

/// @notice Unit tests for the pure core. Scenario tests against a live v4 pool are in
///         SweepGuardScenarios.t.sol.
contract SweepGuardTest is Test {
    GuardHarness h;
    uint160 constant Q = uint160(1 << 96); // sqrt price 1

    function setUp() public {
        h = new GuardHarness();
    }

    function _p(bool anchor, uint16 drift) internal pure returns (SweepGuard.Params memory) {
        return SweepGuard.Params({
            interval: 3600,
            bandBps: 1000,
            floorBps: 300,
            smoothing: 4,
            anchorFloor: anchor,
            maxDriftBps: drift,
            maxImpactBps: 0
        });
    }

    function _r(uint160 ref, uint64 lastAt) internal pure returns (SweepGuard.Route memory) {
        return SweepGuard.Route({seed: Q, lastAt: lastAt, ref: ref, reseededAt: 0, maxIn: 0});
    }

    function _sqrtAt(uint256 bpsOfQ) internal pure returns (uint160) {
        return uint160((uint256(Q) * bpsOfQ) / 10_000);
    }

    /// @dev The 09-22 property, generalised: a route nobody seeded has no reference to adopt,
    ///      so it is refused outright instead of taking the caller's spot on first use.
    function test_unseededRouteRefused() public {
        vm.expectRevert(SweepGuard.RouteNotSeeded.selector);
        h.next(SweepGuard.Route({seed: 0, lastAt: 0, ref: 0, reseededAt: 0, maxIn: 0}), _p(false, 0), Q, 1);
    }

    function test_seed_isOneShotAndNonZero() public {
        vm.expectRevert(SweepGuard.ZeroSeed.selector);
        h.seed(0);
        h.seed(Q);
        vm.expectRevert(SweepGuard.AlreadySeeded.selector);
        h.seed(Q);
        (uint160 s, uint64 lastAt, uint160 ref,,) = h.r();
        assertEq(s, Q, "seed");
        assertEq(ref, Q, "reference starts at the seed");
        assertEq(lastAt, 0, "never converted");
    }

    function test_cooldown() public {
        vm.expectRevert(SweepGuard.TooSoon.selector);
        h.next(_r(Q, 1000), _p(false, 0), Q, 1000 + 3599);
        SweepGuard.Route memory n = h.next(_r(Q, 1000), _p(false, 0), Q, 1000 + 3600);
        assertEq(n.lastAt, 1000 + 3600, "admitted exactly at the interval");
    }

    /// @dev lastAt == 0 means never converted, so the first conversion is not gated even when
    ///      the clock is near zero (the trap the deployed hook guards with `last != 0`).
    function test_firstConversionNotGatedByCooldown() public view {
        SweepGuard.Route memory n = h.next(_r(Q, 0), _p(false, 0), Q, 1);
        assertEq(n.lastAt, 1);
    }

    function test_bandEdgesInclusive() public {
        h.next(_r(Q, 0), _p(false, 0), _sqrtAt(9000), 1);
        h.next(_r(Q, 0), _p(false, 0), _sqrtAt(11_000), 1);
        vm.expectRevert(SweepGuard.OutOfBand.selector);
        h.next(_r(Q, 0), _p(false, 0), _sqrtAt(9000) - 1, 1);
        vm.expectRevert(SweepGuard.OutOfBand.selector);
        h.next(_r(Q, 0), _p(false, 0), _sqrtAt(11_000) + 1, 1);
    }

    function test_referenceMovesAQuarterStep() public view {
        uint160 spot = _sqrtAt(9200);
        SweepGuard.Route memory n = h.next(_r(Q, 0), _p(false, 0), spot, 1);
        assertEq(n.ref, uint160((uint256(Q) * 3 + spot) / 4));
    }

    function test_driftCapClampsReference() public view {
        SweepGuard.Route memory capped = h.next(_r(Q, 0), _p(false, 200), _sqrtAt(9000), 1);
        assertEq(capped.ref, _sqrtAt(9800), "clamped at seed minus 2%");
        SweepGuard.Route memory free = h.next(_r(Q, 0), _p(false, 0), _sqrtAt(9000), 1);
        assertEq(free.ref, uint160((uint256(Q) * 3 + _sqrtAt(9000)) / 4), "uncapped quarter step");
    }

    function test_quote_bothDirections() public view {
        assertEq(h.quote(1e18, true, Q), 1e18);
        assertEq(h.quote(1e18, false, Q), 1e18);
        uint160 two = uint160(2 * uint256(Q)); // sqrt 2, price 4
        assertEq(h.quote(1e18, true, two), 4e18);
        assertEq(h.quote(1e18, false, two), 0.25e18);
    }

    /// @dev The floor quoted at a moved spot moves with it: at the -10% sqrt edge it accepts
    ///      0.81 * 0.97 of fair. Anchored, it is quoted at the reference and accepts 0.97.
    function test_minOut_spotFloorTracksMovedSpot_anchorDoesNot() public view {
        uint256 spotFloor = h.minOut(_p(false, 0), 1e18, true, _sqrtAt(9000), Q);
        assertApproxEqRel(spotFloor, 0.7857e18, 1e12, "3% under the moved quote");
        uint256 anchored = h.minOut(_p(true, 0), 1e18, true, _sqrtAt(9000), Q);
        assertApproxEqRel(anchored, 0.97e18, 1e12, "3% under the reference quote");
    }

    function test_validate_rejectsBadParams() public {
        h.validate(_p(false, 0));
        SweepGuard.Params memory p = _p(false, 0);
        p.bandBps = 0;
        vm.expectRevert(SweepGuard.BadParams.selector);
        h.validate(p);
        p = _p(false, 0);
        p.bandBps = 10_000;
        vm.expectRevert(SweepGuard.BadParams.selector);
        h.validate(p);
        p = _p(false, 0);
        p.floorBps = 10_000;
        vm.expectRevert(SweepGuard.BadParams.selector);
        h.validate(p);
        p = _p(false, 0);
        p.smoothing = 0;
        vm.expectRevert(SweepGuard.BadParams.selector);
        h.validate(p);
        p = _p(false, 0);
        p.maxDriftBps = 10_000;
        vm.expectRevert(SweepGuard.BadParams.selector);
        h.validate(p);
        p = _p(false, 0);
        p.maxImpactBps = 10_000;
        vm.expectRevert(SweepGuard.BadParams.selector);
        h.validate(p);
    }

    function testFuzz_referenceStaysBetweenRefAndSpot(uint256 spotBps) public view {
        uint160 spot = _sqrtAt(bound(spotBps, 9000, 11_000));
        SweepGuard.Route memory n = h.next(_r(Q, 0), _p(false, 0), spot, 1);
        (uint160 a, uint160 b) = spot < Q ? (spot, Q) : (Q, spot);
        assertGe(n.ref, a);
        assertLe(n.ref, b);
    }

    // ---------------------------------------------------------------------
    // Size cap
    // ---------------------------------------------------------------------

    /// @dev Converting exactly the cap moves sqrt price by maxImpactBps at constant liquidity,
    ///      in both directions.
    function test_capIn_impactMatchesTarget() public view {
        SweepGuard.Params memory p = _p(false, 0);
        p.maxImpactBps = 15;
        uint128 L = 1e21;
        uint256 down = h.capIn(_r(Q, 0), p, L, Q, true);
        uint160 afterDown = SqrtPriceMath.getNextSqrtPriceFromInput(Q, L, down, true);
        assertApproxEqRel(afterDown, (uint256(Q) * 9985) / 10_000, 1e12, "token0 in: -0.15% sqrt");
        uint256 up = h.capIn(_r(Q, 0), p, L, Q, false);
        uint160 afterUp = SqrtPriceMath.getNextSqrtPriceFromInput(Q, L, up, false);
        assertApproxEqRel(afterUp, (uint256(Q) * 10_015) / 10_000, 1e12, "token1 in: +0.15% sqrt");
        assertApproxEqRel(down, 1.5e18, 2e15, "about 0.15% of depth");
    }

    function test_capIn_ceilingAndOff() public view {
        SweepGuard.Params memory p = _p(false, 0);
        SweepGuard.Route memory r = _r(Q, 0);
        assertEq(h.capIn(r, p, 1e21, Q, true), type(uint256).max, "no bounds set");
        r.maxIn = 1e17;
        assertEq(h.capIn(r, p, 1e21, Q, true), 1e17, "ceiling alone");
        p.maxImpactBps = 15;
        assertEq(h.capIn(r, p, 1e21, Q, true), 1e17, "ceiling below the impact cap wins");
        assertLt(h.capIn(r, p, 1e19, Q, true), 1e17, "thin pool: impact cap wins");
    }

    // ---------------------------------------------------------------------
    // Recovery
    // ---------------------------------------------------------------------

    function _w() internal pure returns (SweepGuard.ReseedWalls memory) {
        return SweepGuard.ReseedWalls({maxStepBps: 500, minInterval: 3600, minStall: 6 hours});
    }

    function test_reseed_stepIsClampedAndReanchors() public view {
        SweepGuard.Route memory n = h.reseedNext(_r(Q, 0), _w(), _sqrtAt(8000), 1);
        assertEq(n.ref, _sqrtAt(9500), "clamped to a 5% step down");
        assertEq(n.seed, n.ref, "seed re-anchored with it");
        assertEq(n.reseededAt, 1);
        SweepGuard.Route memory u = h.reseedNext(_r(Q, 0), _w(), _sqrtAt(10_200), 1);
        assertEq(u.ref, _sqrtAt(10_200), "inside the step: moves all the way");
    }

    function test_reseed_wallsHold() public {
        SweepGuard.Route memory r = _r(Q, 10_000); // converted at t = 10_000
        vm.expectRevert(SweepGuard.RouteNotStalled.selector);
        h.reseedNext(r, _w(), _sqrtAt(9000), 10_000 + 6 hours - 1);
        SweepGuard.Route memory n = h.reseedNext(r, _w(), _sqrtAt(9000), 10_000 + 6 hours);
        vm.expectRevert(SweepGuard.ReseedTooSoon.selector);
        h.reseedNext(n, _w(), _sqrtAt(9000), 10_000 + 6 hours + 3599);
        h.reseedNext(n, _w(), _sqrtAt(9000), 10_000 + 6 hours + 3600);
        vm.expectRevert(SweepGuard.RouteNotSeeded.selector);
        h.reseedNext(SweepGuard.Route({seed: 0, lastAt: 0, ref: 0, reseededAt: 0, maxIn: 0}), _w(), Q, 1);
        vm.expectRevert(SweepGuard.ZeroSeed.selector);
        h.reseedNext(r, _w(), 0, 10_000 + 6 hours);
        SweepGuard.ReseedWalls memory bad = _w();
        bad.maxStepBps = 0;
        vm.expectRevert(SweepGuard.BadWalls.selector);
        h.validateWalls(bad);
    }

    // ---------------------------------------------------------------------
    // Properties
    // ---------------------------------------------------------------------

    /// @dev For any liquidity, price, direction and cap, converting exactly capIn never moves
    ///      sqrt price past maxImpactBps at constant liquidity.
    function testFuzz_capIn_neverExceedsItsImpact(uint128 L, uint160 spot, uint16 bps, bool zeroForOne) public view {
        L = uint128(bound(L, 1e6, 1e30));
        spot = uint160(bound(spot, uint256(TickMath.MIN_SQRT_PRICE) * 1e3, uint256(TickMath.MAX_SQRT_PRICE) / 1e3));
        bps = uint16(bound(bps, 1, 2000));
        SweepGuard.Params memory p = _p(false, 0);
        p.maxImpactBps = bps;
        uint256 cap = h.capIn(_r(Q, 0), p, L, spot, zeroForOne);
        if (cap == 0) return;
        uint160 after_ = SqrtPriceMath.getNextSqrtPriceFromInput(spot, L, cap, zeroForOne);
        if (zeroForOne) assertGe(after_, (uint256(spot) * (10_000 - bps)) / 10_000);
        else assertLe(after_, (uint256(spot) * (10_000 + bps)) / 10_000);
    }

    /// @dev Thirty-two reseed attempts at random times toward random targets. Every one that
    ///      succeeds respects all three walls, and every one that fails had a wall in force.
    function testFuzz_reseed_wallsHoldOverAnySequence(uint256 salt) public view {
        SweepGuard.ReseedWalls memory w = _w();
        SweepGuard.Route memory r = _r(Q, 1);
        uint256 t = 1;
        for (uint256 i; i < 32; i++) {
            t += uint256(keccak256(abi.encode(salt, i, "dt"))) % 4 hours;
            uint160 target = uint160(bound(uint256(keccak256(abi.encode(salt, i, "tg"))), Q / 4, uint256(Q) * 4));
            bool wall = t < uint256(r.lastAt) + w.minStall || (r.reseededAt != 0 && t < uint256(r.reseededAt) + w.minInterval);
            try h.reseedNext(r, w, target, t) returns (SweepGuard.Route memory n) {
                assertFalse(wall, "succeeded through a wall");
                assertLe(n.ref, (uint256(r.ref) * 10_500) / 10_000, "step up past 5%");
                assertGe(n.ref, (uint256(r.ref) * 9500) / 10_000, "step down past 5%");
                assertEq(n.seed, n.ref, "seed re-anchored");
                assertEq(n.lastAt, r.lastAt, "reseed never counts as a conversion");
                assertEq(n.maxIn, r.maxIn, "reseed never touches the ceiling");
                r = n;
            } catch {
                assertTrue(wall, "refused with no wall in force");
            }
        }
    }
}
