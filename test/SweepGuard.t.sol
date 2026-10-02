// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SweepGuard} from "../src/libraries/SweepGuard.sol";

/// @notice External wrapper so reverts from the internal library surface at call depth.
contract GuardHarness {
    using SweepGuard for SweepGuard.Route;

    SweepGuard.Route public r;

    function seed(uint160 s) external {
        r.seal(s);
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
            interval: 3600, bandBps: 1000, floorBps: 300, smoothing: 4, anchorFloor: anchor, maxDriftBps: drift
        });
    }

    function _r(uint160 ref, uint64 lastAt) internal pure returns (SweepGuard.Route memory) {
        return SweepGuard.Route({seed: Q, ref: ref, lastAt: lastAt});
    }

    function _sqrtAt(uint256 bpsOfQ) internal pure returns (uint160) {
        return uint160((uint256(Q) * bpsOfQ) / 10_000);
    }

    /// @dev The 09-22 property, generalised: a route nobody seeded has no reference to adopt,
    ///      so it is refused outright instead of taking the caller's spot on first use.
    function test_unseededRouteRefused() public {
        vm.expectRevert(SweepGuard.RouteNotSeeded.selector);
        h.next(SweepGuard.Route({seed: 0, ref: 0, lastAt: 0}), _p(false, 0), Q, 1);
    }

    function test_seed_isOneShotAndNonZero() public {
        vm.expectRevert(SweepGuard.ZeroSeed.selector);
        h.seed(0);
        h.seed(Q);
        vm.expectRevert(SweepGuard.AlreadySeeded.selector);
        h.seed(Q);
        (uint160 s, uint160 ref, uint64 lastAt) = h.r();
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
    }

    function testFuzz_referenceStaysBetweenRefAndSpot(uint256 spotBps) public view {
        uint160 spot = _sqrtAt(bound(spotBps, 9000, 11_000));
        SweepGuard.Route memory n = h.next(_r(Q, 0), _p(false, 0), spot, 1);
        (uint160 a, uint160 b) = spot < Q ? (spot, Q) : (Q, spot);
        assertGe(n.ref, a);
        assertLe(n.ref, b);
    }
}
