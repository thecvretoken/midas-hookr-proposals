// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SweepGuard} from "../src/libraries/SweepGuard.sol";
import {GuardedSweeper} from "./utils/GuardedSweeper.sol";
import {SweepGuardBase} from "./utils/SweepGuardBase.sol";

/// @notice The actions the fuzzer strings together: an attacker moving the route anywhere within
///         15% per trade, arbitrage back to fair, keeper sweeps, time jumps of up to three hours,
///         fees arriving in the bucket, and reseed attempts toward any target. It owns the sweeper, so it is the reseed
///         authority, and it records everything the invariants check.
contract GuardHandler is Test {
    using PoolIdLibrary for PoolKey;

    uint128 public constant MAX_IN = 1.5e18;
    uint256 constant BPS = 10_000;

    IPoolManager immutable pm;
    PoolSwapTest immutable router;
    PoolKey route;
    PoolId rid;
    uint160 immutable sqrt1;
    address immutable attacker;
    address public constant KEEPER = address(0xC0FFEE);
    GuardedSweeper public s;

    // ghosts
    uint256 public funded;
    uint256 public taken;
    uint256 public bountiesOwed;
    uint256 public admitted;
    uint256 public maxTake;
    uint256 public minGap = type(uint256).max;
    uint256 public lastAdmitAt;
    uint256 public reseeds;
    uint256 public maxStepBps;
    uint256 public minReseedGap = type(uint256).max;
    uint256 public minStall = type(uint256).max;
    uint256 public refusedReseeds;

    constructor(IPoolManager pm_, PoolSwapTest router_, PoolKey memory route_, uint160 sqrt1_, address attacker_) {
        pm = pm_;
        router = router_;
        route = route_;
        rid = route_.toId();
        sqrt1 = sqrt1_;
        attacker = attacker_;
        SweepGuard.Params memory p = SweepGuard.Params({
            interval: 1 hours,
            bandBps: 1000,
            floorBps: 300,
            smoothing: 4,
            anchorFloor: true,
            maxDriftBps: 200,
            maxImpactBps: 15
        });
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = route_;
        uint160[] memory seeds = new uint160[](1);
        seeds[0] = sqrt1_;
        uint128[] memory caps = new uint128[](1);
        caps[0] = MAX_IN;
        s = new GuardedSweeper(
            pm_,
            route_.currency0,
            route_.currency1,
            keys,
            seeds,
            caps,
            p,
            address(this),
            SweepGuard.ReseedWalls({maxStepBps: 500, minInterval: 1 hours, minStall: 6 hours})
        );
    }

    function trade(uint256 seed) external {
        (uint160 sp,,,) = StateLibrary.getSlot0(pm, rid);
        int256 moveBps = int256(bound(seed, 0, 3000)) - 1500;
        uint256 target = (uint256(sp) * uint256(int256(BPS) + moveBps)) / BPS;
        if (target < sqrt1 / 2) target = sqrt1 / 2;
        if (target > uint256(sqrt1) * 2) target = uint256(sqrt1) * 2;
        if (target == sp) return;
        vm.prank(attacker);
        router.swap(
            route,
            SwapParams({zeroForOne: target < sp, amountSpecified: -1e36, sqrtPriceLimitX96: uint160(target)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Arbitrage returning the route to fair, as it does between attacks on a real market.
    function arb() external {
        (uint160 sp,,,) = StateLibrary.getSlot0(pm, rid);
        if (sp == sqrt1) return;
        vm.prank(attacker);
        router.swap(
            route,
            SwapParams({zeroForOne: sqrt1 < sp, amountSpecified: -1e36, sqrtPriceLimitX96: sqrt1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function sweep() external {
        uint256 before = route.currency0.balanceOf(address(s));
        vm.prank(KEEPER);
        try s.sweep(route, 0) {
            uint256 took = before - route.currency0.balanceOf(address(s));
            taken += took;
            bountiesOwed += (took * 50) / BPS;
            admitted++;
            if (took > maxTake) maxTake = took;
            if (lastAdmitAt != 0 && block.timestamp - lastAdmitAt < minGap) minGap = block.timestamp - lastAdmitAt;
            lastAdmitAt = block.timestamp;
        } catch {}
    }

    function wait(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 3 hours));
    }

    function fund(uint256 amt) external {
        amt = bound(amt, 0, 1e19);
        MockERC20(Currency.unwrap(route.currency0)).mint(address(s), amt);
        funded += amt;
    }

    /// @dev Half the attempts re-anchor to the market, as an honest operator would; the other half
    ///      aim anywhere from half to double the reference, as one acting in bad faith might.
    function reseed(uint256 seed) external {
        (, uint64 lastAt, uint160 ref0, uint64 at0,) = s.routes(rid);
        (uint160 sp,,,) = StateLibrary.getSlot0(pm, rid);
        uint160 target = seed % 2 == 0 ? sp : uint160(bound(seed >> 1, ref0 / 2, uint256(ref0) * 2));
        try s.reseed(route, target) returns (uint160 nr) {
            reseeds++;
            uint256 step = ((nr > ref0 ? nr - ref0 : ref0 - nr) * BPS) / ref0;
            if (step > maxStepBps) maxStepBps = step;
            if (at0 != 0 && block.timestamp - at0 < minReseedGap) minReseedGap = block.timestamp - at0;
            if (lastAt != 0 && block.timestamp - lastAt < minStall) minStall = block.timestamp - lastAt;
        } catch {
            refusedReseeds++;
        }
    }
}

/// @notice Random sequences of the handler's actions against a live PoolManager, with the guard's
///         promises checked after every step. Configuration: anchored floor, 2% drift cap, impact
///         cap 15 bps, ceiling 1.5 tokens, reseed walls 5% / 1 hour / 6 hours.
contract SweepGuardInvariants is SweepGuardBase {
    GuardHandler h;

    function setUp() public override {
        super.setUp();
        h = new GuardHandler(manager, swapRouter, route, SQRT1, attacker);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](6);
        sel[0] = GuardHandler.trade.selector;
        sel[1] = GuardHandler.arb.selector;
        sel[2] = GuardHandler.sweep.selector;
        sel[3] = GuardHandler.wait.selector;
        sel[4] = GuardHandler.fund.selector;
        sel[5] = GuardHandler.reseed.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(h), selectors: sel}));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_noConversionExceedsTheCeiling() public view {
        assertLe(h.maxTake(), h.MAX_IN());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_conversionsAreAnIntervalApart() public view {
        if (h.admitted() > 1) assertGe(h.minGap(), 1 hours);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_referenceStaysInsideTheDriftCap() public view {
        (uint160 sd,, uint160 ref,,) = h.s().routes(rid);
        assertLe(ref, (uint256(sd) * 10_200) / BPS);
        assertGe(ref, (uint256(sd) * 9800) / BPS);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_reseedsStayInsideTheirWalls() public view {
        if (h.reseeds() == 0) return;
        assertLe(h.maxStepBps(), 500, "step");
        if (h.reseeds() > 1) assertGe(h.minReseedGap(), 1 hours, "interval");
        if (h.minStall() != type(uint256).max) assertGe(h.minStall(), 6 hours, "stall");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_everyTokenIsAccountedFor() public view {
        GuardedSweeper s = h.s();
        assertEq(currency0.balanceOf(address(s)) + h.taken(), h.funded(), "bucket: only sweeps take from it");
        assertEq(currency0.balanceOf(h.KEEPER()), h.bountiesOwed(), "keeper: exactly the bounty");
        assertEq(currency1.balanceOf(address(s)), 0, "sweeper never holds output");
    }

    /// @dev One long seeded sequence, every invariant checked after every step, totals reported.
    function test_sixHundredRandomSteps_everyInvariantHoldsAtEveryStep() public {
        for (uint256 i; i < 600; i++) {
            uint256 r = uint256(keccak256(abi.encode("sweepguard", i)));
            uint256 a = r % 6;
            if (a == 0) h.trade(r >> 8);
            else if (a == 1) h.arb();
            else if (a == 2) h.sweep();
            else if (a == 3) h.wait(r >> 8);
            else if (a == 4) h.fund(r >> 8);
            else h.reseed(r >> 8);
            invariant_noConversionExceedsTheCeiling();
            invariant_conversionsAreAnIntervalApart();
            invariant_referenceStaysInsideTheDriftCap();
            invariant_reseedsStayInsideTheirWalls();
            invariant_everyTokenIsAccountedFor();
        }
        emit log_named_uint("steps", 600);
        emit log_named_uint("admitted conversions", h.admitted());
        emit log_named_decimal_uint("largest single conversion (tokens)", h.maxTake(), 18);
        emit log_named_decimal_uint("total converted (tokens)", h.taken(), 18);
        emit log_named_uint("reseeds allowed", h.reseeds());
        emit log_named_uint("reseeds refused by the walls", h.refusedReseeds());
        emit log_named_uint("largest reseed step, bps", h.maxStepBps());
        assertGt(h.admitted(), 10, "sequence should exercise conversions");
        assertGt(h.reseeds(), 2, "sequence should exercise reseeds");
    }

    function afterInvariant() external {
        emit log_named_uint("admitted conversions", h.admitted());
        emit log_named_uint("reseeds allowed", h.reseeds());
        emit log_named_uint("reseeds refused", h.refusedReseeds());
    }
}
