// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
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
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {TimeWeightedExitHook} from "../src/TimeWeightedExitHook.sol";

/// @notice Tests for TimeWeightedExitHook. Run with `forge test -vv`.
///
/// Pool layout: currency0 is the launched TOKEN, currency1 is the quote.
///   BUY  = quote in, token out  = oneForZero = zeroForOne == false
///   SELL = token in, quote out  = zeroForOne == true
contract TimeWeightedExitHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    TimeWeightedExitHook hook;
    PoolId id;

    // NOTE: `key` is inherited from Deployers — do not redeclare it here.

    address stranger = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint24 constant BASE = 10_000; // 1.00%
    uint24 constant START = 80_000; // 8.00%
    uint256 constant DECAY = 3 days;

    uint160 constant FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

    function setUp() public {
        // Realistic clock. NOTE: tests read the clock via vm.getBlockTimestamp(), not
        // block.timestamp — under via_ir the optimizer may CSE the TIMESTAMP opcode
        // within one call frame, so `vm.warp(block.timestamp + x)` twice in a row
        // does not advance twice.
        vm.warp(1_700_000_000);
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        deployCodeTo(
            "TimeWeightedExitHook.sol:TimeWeightedExitHook", abi.encode(manager, BASE, START, DECAY), address(FLAGS)
        );
        hook = TimeWeightedExitHook(address(FLAGS));

        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        id = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        hook.setLaunchSide(key, true); // currency0 is the launched token

        _seedLiquidity(key);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    /// @dev Wide range so repeated swaps never hit the price limit.
    function _seedLiquidity(PoolKey memory k) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e25, salt: 0}), ""
        );
    }

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    /// @dev Exact-input swap of `amountIn`, trader forwarded in hookData. Returns
    ///      the output amount received.
    function _swapAs(PoolKey memory k, address trader, bool zeroForOne, uint256 amountIn)
        internal
        returns (uint256 out)
    {
        BalanceDelta d = swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings(),
            abi.encode(trader)
        );
        int128 o = zeroForOne ? d.amount1() : d.amount0();
        out = uint256(uint128(o));
    }

    /// @dev Same, but with empty hookData: the hook sees the router as the trader.
    function _swapRaw(PoolKey memory k, bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings(),
            ""
        );
    }

    function _buy(address trader, uint256 amountIn) internal returns (uint256) {
        return _swapAs(key, trader, false, amountIn);
    }

    function _sell(address trader, uint256 amountIn) internal returns (uint256) {
        return _swapAs(key, trader, true, amountIn);
    }

    function _expectedFee(uint256 elapsed) internal pure returns (uint24) {
        if (elapsed >= DECAY) return BASE;
        return uint24(START - ((START - BASE) * elapsed) / DECAY);
    }

    // -----------------------------------------------------------------
    // I9: constructor ceilings
    // -----------------------------------------------------------------

    function test_constructor_storesSchedule() public view {
        (uint24 b, uint24 s, uint256 d) = hook.feeSchedule();
        assertEq(b, BASE);
        assertEq(s, START);
        assertEq(d, DECAY);
    }

    /// @dev BaseHook validates the flag-encoded address before the body of our
    ///      constructor runs, so a plain `new` at a random address reverts with
    ///      HookAddressNotValid and never reaches the ceiling checks. Deploy the
    ///      creation code at a correctly flagged address by hand and capture the
    ///      revert data so the exact custom error can be asserted.
    function _tryDeploy(uint24 b, uint24 s, uint256 d) internal returns (bool ok, bytes4 err) {
        address where = address(FLAGS | (uint160(1) << 100)); // flagged, distinct from `hook`
        bytes memory creation = vm.getCode("TimeWeightedExitHook.sol:TimeWeightedExitHook");
        vm.etch(where, abi.encodePacked(creation, abi.encode(manager, b, s, d)));
        bytes memory ret;
        (ok, ret) = where.call("");
        if (!ok && ret.length >= 4) err = bytes4(ret);
        vm.etch(where, "");
    }

    function _assertRejected(uint24 b, uint24 s, uint256 d, bytes4 expected) internal {
        (bool ok, bytes4 err) = _tryDeploy(b, s, d);
        assertFalse(ok, "constructor must revert");
        assertEq(err, expected, "wrong revert reason");
    }

    function test_constructor_rejectsBaseAboveCeiling() public {
        _assertRejected(10_001, START, DECAY, TimeWeightedExitHook.BaseFeeAboveCeiling.selector);
    }

    function test_constructor_rejectsExitAboveCeiling() public {
        _assertRejected(BASE, 100_001, DECAY, TimeWeightedExitHook.ExitFeeAboveCeiling.selector);
    }

    function test_constructor_rejectsExitBelowBase() public {
        _assertRejected(BASE, BASE - 1, DECAY, TimeWeightedExitHook.ExitFeeBelowBase.selector);
    }

    function test_constructor_rejectsDecayOutOfBounds() public {
        _assertRejected(BASE, START, 1 hours - 1, TimeWeightedExitHook.DecayOutOfBounds.selector);
        _assertRejected(BASE, START, 30 days + 1, TimeWeightedExitHook.DecayOutOfBounds.selector);
    }

    /// @dev Boundary values are accepted (ceilings are inclusive).
    function test_constructor_acceptsBoundaryValues() public {
        (bool ok1,) = _tryDeploy(10_000, 100_000, 1 hours);
        assertTrue(ok1, "max fees, min decay accepted");
        (bool ok2,) = _tryDeploy(0, 0, 30 days);
        assertTrue(ok2, "zero fees, max decay accepted");
    }

    /// @dev Every rejected parameter set is rejected, every accepted one is inside
    ///      the ceilings. Complements the point tests above.
    function testFuzz_constructor_enforcesCeilings(uint24 b, uint24 s, uint256 d) public {
        b = uint24(bound(b, 0, 20_000));
        s = uint24(bound(s, 0, 200_000));
        d = bound(d, 0, 60 days);
        (bool ok,) = _tryDeploy(b, s, d);
        bool inBounds = b <= 10_000 && s <= 100_000 && s >= b && d >= 1 hours && d <= 30 days;
        assertEq(ok, inBounds, "accepted iff inside hardcoded ceilings");
    }

    // -----------------------------------------------------------------
    // I1 / I2: decay curve
    // -----------------------------------------------------------------

    function test_exitFee_atStampIsStart() public {
        _buy(alice, 1e18);
        assertEq(hook.exitFeeFor(key, alice), START, "fee at elapsed==0 must be EXIT_FEE_START");
    }

    function test_exitFee_atDecayIsBase() public {
        _buy(alice, 1e18);
        vm.warp(vm.getBlockTimestamp() + DECAY);
        assertEq(hook.exitFeeFor(key, alice), BASE, "fee at elapsed==DECAY must be BASE_FEE");
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertEq(hook.exitFeeFor(key, alice), BASE, "fee stays at BASE_FEE afterwards");
    }

    function test_exitFee_midpointIsLinear() public {
        _buy(alice, 1e18);
        vm.warp(vm.getBlockTimestamp() + DECAY / 2);
        assertEq(hook.exitFeeFor(key, alice), _expectedFee(DECAY / 2), "midpoint of the ramp");
    }

    /// @dev I1: monotonically non-increasing in holding time, always in [BASE, START].
    function testFuzz_exitFee_monotonicAndBounded(uint256 a, uint256 b) public {
        a = bound(a, 0, 2 * DECAY);
        b = bound(b, 0, 2 * DECAY);
        if (a > b) (a, b) = (b, a);

        _buy(alice, 1e18);
        uint256 t0 = vm.getBlockTimestamp();

        vm.warp(t0 + a);
        uint24 feeA = hook.exitFeeFor(key, alice);
        vm.warp(t0 + b);
        uint24 feeB = hook.exitFeeFor(key, alice);

        assertGe(feeA, feeB, "fee must never increase with holding time");
        assertGe(feeA, BASE, "never below BASE_FEE");
        assertLe(feeA, START, "never above EXIT_FEE_START");
        assertGe(feeB, BASE, "never below BASE_FEE");
        assertLe(feeB, START, "never above EXIT_FEE_START");
        assertEq(feeA, _expectedFee(a), "matches linear formula");
    }

    /// @dev The fee the hook actually charges on a real sell matches the view. Two
    ///      sells of equal size from a fresh pool state: a longer hold yields more
    ///      output. Proves the override reaches the pool, not just the view.
    function test_sell_realSwapPaysDecayedFee() public {
        _buy(alice, 1e18);
        _buy(bob, 1e18);

        // Alice sells at minute zero (8%); Bob sells after full decay (1%).
        uint256 outAlice = _sell(alice, 1e18);
        vm.warp(vm.getBlockTimestamp() + DECAY);
        uint256 outBob = _sell(bob, 1e18);

        // Price moved slightly against bob (alice sold first), yet bob still nets more.
        assertGt(outBob, outAlice, "held longer, kept more");

        // Bound: 8% vs 1% on the same input against deep liquidity => bob's output is
        // roughly 0.99/0.92 of alice's. Check we are inside a sane band.
        assertGt(outBob * 92, outAlice * 99 * 99 / 100, "gap consistent with 8% vs 1%");
    }

    /// @dev Events carry the fee and elapsed time actually used.
    function test_sell_emitsExitFeeCharged() public {
        _buy(alice, 1e18);
        vm.warp(vm.getBlockTimestamp() + DECAY / 4);

        vm.expectEmit(true, true, false, true, address(hook));
        emit TimeWeightedExitHook.ExitFeeCharged(id, alice, _expectedFee(DECAY / 4), DECAY / 4);
        _sell(alice, 1e17);
    }

    // -----------------------------------------------------------------
    // I3: buys always pay BASE_FEE
    // -----------------------------------------------------------------

    /// @dev A buy from an unstamped wallet and a buy from a just-stamped wallet return
    ///      the same output for the same input — no launch-side surcharge exists.
    function test_buy_alwaysBaseFee() public {
        uint256 outFresh = _buy(alice, 1e18); // stamps alice
        uint256 outStamped = _buy(bob, 1e18); // bob unstamped

        // Second buy at a marginally worse price; difference is price impact only
        // (well under 0.01% against 1e21 liquidity), not a fee tier.
        assertApproxEqRel(outFresh, outStamped, 1e14, "buys pay identical fee");

        // Buy from a long-held wallet is the same too.
        vm.warp(vm.getBlockTimestamp() + DECAY);
        uint256 outHeld = _buy(alice, 1e18);
        assertApproxEqRel(outFresh, outHeld, 1e14, "held wallet buys at same fee");

        // And a buy's output is what BASE fee implies: ~0.99e18 minus tiny impact.
        assertGt(outFresh, 0.989e18, "buy output reflects 1% fee, not 8%");
        assertLt(outFresh, 0.991e18, "buy output reflects 1% fee, not 0%");
    }

    /// @dev Buys never emit ExitFeeCharged.
    function test_buy_doesNotEmitExitFee() public {
        vm.recordLogs();
        _buy(alice, 1e18);
        // Stamped is emitted; ExitFeeCharged is not.
        bytes32 sig = TimeWeightedExitHook.ExitFeeCharged.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != sig, "buy must not charge an exit fee");
        }
    }

    // -----------------------------------------------------------------
    // I4: unstamped seller fallback
    // -----------------------------------------------------------------

    function test_unstampedSeller_paysStartAndGetsStamped() public {
        assertEq(hook.firstBuyOf(key, alice), 0, "precondition: unstamped");
        assertEq(hook.exitFeeFor(key, alice), START, "view quotes full start fee");

        vm.expectEmit(true, true, false, true, address(hook));
        emit TimeWeightedExitHook.Stamped(id, alice, uint64(vm.getBlockTimestamp()));
        vm.expectEmit(true, true, false, true, address(hook));
        emit TimeWeightedExitHook.ExitFeeCharged(id, alice, START, 0);
        _sell(alice, 1e18);

        assertEq(hook.firstBuyOf(key, alice), uint64(vm.getBlockTimestamp()), "stamped on first sell");

        // The clock started: after DECAY the same wallet sells at BASE.
        vm.warp(vm.getBlockTimestamp() + DECAY);
        assertEq(hook.exitFeeFor(key, alice), BASE);
    }

    /// @dev Output of an unstamped sell equals the output of a just-bought sell (both 8%).
    function test_unstampedSeller_outputMatchesFreshBuyer() public {
        uint256 outUnstamped = _sell(alice, 1e18);
        _buy(bob, 1e15); // stamp bob with a tiny buy so price barely moves
        uint256 outFresh = _sell(bob, 1e18);
        assertApproxEqRel(outUnstamped, outFresh, 1e14, "same fee tier");
        assertLt(outUnstamped, 0.925e18, "output reflects 8% fee");
        assertGt(outUnstamped, 0.915e18, "output reflects 8% fee");
    }

    // -----------------------------------------------------------------
    // I5: first buy wins
    // -----------------------------------------------------------------

    function test_secondBuy_doesNotResetStamp() public {
        _buy(alice, 1e18);
        uint64 first = hook.firstBuyOf(key, alice);
        assertEq(first, uint64(vm.getBlockTimestamp()));

        vm.warp(vm.getBlockTimestamp() + 1 days);
        _buy(alice, 1e18);
        assertEq(hook.firstBuyOf(key, alice), first, "second buy must not move the stamp");

        vm.warp(vm.getBlockTimestamp() + 1 days);
        _sell(alice, 1e17);
        assertEq(hook.firstBuyOf(key, alice), first, "sell must not move the stamp");
        assertEq(hook.exitFeeFor(key, alice), _expectedFee(2 days), "fee measured from FIRST buy");
    }

    // -----------------------------------------------------------------
    // I6: per pool per address
    // -----------------------------------------------------------------

    function test_stamps_arePerPool() public {
        PoolKey memory k2 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(address(hook)));
        manager.initialize(k2, TickMath.getSqrtPriceAtTick(0));
        hook.setLaunchSide(k2, true);
        _seedLiquidity(k2);

        _buy(alice, 1e18);
        assertGt(hook.firstBuyOf(key, alice), 0, "stamped on pool A");
        assertEq(hook.firstBuyOf(k2, alice), 0, "unstamped on pool B");
        assertEq(hook.exitFeeFor(k2, alice), START, "pool B quotes fallback");

        vm.warp(vm.getBlockTimestamp() + DECAY);
        assertEq(hook.exitFeeFor(key, alice), BASE, "pool A decayed");
        assertEq(hook.exitFeeFor(k2, alice), START, "pool B still fallback");

        // And per address: bob on pool A is unstamped.
        assertEq(hook.firstBuyOf(key, bob), 0, "bob unstamped on pool A");
    }

    // -----------------------------------------------------------------
    // I7: entire fee goes to LPs, hook holds nothing
    // -----------------------------------------------------------------

    function test_hookHoldsNothing_feeIsNativeLP() public {
        (uint256 g0Before, uint256 g1Before) = manager.getFeeGrowthGlobals(id);

        _buy(alice, 1e18);
        _sell(alice, 5e17);
        _sell(bob, 1e18); // unstamped fallback, 8%
        vm.warp(vm.getBlockTimestamp() + DECAY / 3);
        _sell(alice, 1e17);
        _buy(bob, 2e18);
        _swapRaw(key, true, 1e17); // router-as-trader path
        vm.warp(vm.getBlockTimestamp() + DECAY);
        _sell(alice, 1e17);

        // Hook: no ERC20, no ERC6909 claims, in either currency.
        assertEq(currency0.balanceOf(address(hook)), 0, "hook holds no token");
        assertEq(currency1.balanceOf(address(hook)), 0, "hook holds no quote");
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "hook holds no token claims");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, "hook holds no quote claims");

        // LPs: fee growth accrued in both currencies (sells pay in token, buys in quote).
        (uint256 g0After, uint256 g1After) = manager.getFeeGrowthGlobals(id);
        assertGt(g0After, g0Before, "LP fee growth in token from sells");
        assertGt(g1After, g1Before, "LP fee growth in quote from buys");
    }

    /// @dev The surcharge really lands with LPs: an LP's fee take from a sell at 8%
    ///      is ~8x the take from a sell at 1%.
    function test_lpEarnsTheSurcharge() public {
        _buy(alice, 1e18);
        (uint256 g0a,) = manager.getFeeGrowthGlobals(id);
        _sell(alice, 1e18); // 8%
        (uint256 g0b,) = manager.getFeeGrowthGlobals(id);

        vm.warp(vm.getBlockTimestamp() + DECAY);
        _sell(alice, 1e18); // 1%
        (uint256 g0c,) = manager.getFeeGrowthGlobals(id);

        uint256 takeAt8 = g0b - g0a;
        uint256 takeAt1 = g0c - g0b;
        assertApproxEqRel(takeAt8, takeAt1 * 8, 1e15, "LP take scales with the exit fee");
    }

    // -----------------------------------------------------------------
    // I8: setLaunchSide access control; no dynamic-fee => revert
    // -----------------------------------------------------------------

    function test_revertsOnStaticFeePool() public {
        PoolKey memory bad = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(bad, TickMath.getSqrtPriceAtTick(0));
    }

    function test_setLaunchSide_onlyDeployer() public {
        PoolKey memory k2 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 200, IHooks(address(hook)));
        manager.initialize(k2, TickMath.getSqrtPriceAtTick(0));

        vm.prank(stranger);
        vm.expectRevert(TimeWeightedExitHook.NotDeployer.selector);
        hook.setLaunchSide(k2, true);
    }

    function test_setLaunchSide_isOneShot() public {
        vm.expectRevert(TimeWeightedExitHook.LaunchSideAlreadySet.selector);
        hook.setLaunchSide(key, false);
        vm.expectRevert(TimeWeightedExitHook.LaunchSideAlreadySet.selector);
        hook.setLaunchSide(key, true);
    }

    function test_swapReverts_beforeLaunchSideSet() public {
        PoolKey memory k2 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        manager.initialize(k2, TickMath.getSqrtPriceAtTick(0));
        _seedLiquidity(k2);

        vm.expectRevert(); // wrapped by PoolManager as HookCallFailed
        _swapAs(k2, alice, true, 1e18);
        vm.expectRevert();
        _swapAs(k2, alice, false, 1e18);

        // Once set, it trades.
        hook.setLaunchSide(k2, true);
        _swapAs(k2, alice, false, 1e18);
    }

    /// @dev tokenIsZero flips which direction is the sell.
    function test_launchSide_flipsSellDirection() public {
        PoolKey memory k2 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(address(hook)));
        manager.initialize(k2, TickMath.getSqrtPriceAtTick(0));
        hook.setLaunchSide(k2, false); // currency1 is the token now
        _seedLiquidity(k2);

        // zeroForOne == true is now a BUY: stamps, no exit fee, ~1% output.
        uint256 out = _swapAs(k2, alice, true, 1e18);
        assertGt(out, 0.989e18, "buy on flipped pool pays base");
        assertGt(hook.firstBuyOf(k2, alice), 0, "stamped by buy");

        // zeroForOne == false is now a SELL at 8%.
        uint256 outSell = _swapAs(k2, alice, false, 1e18);
        assertLt(outSell, 0.925e18, "sell on flipped pool pays start fee");
    }

    // -----------------------------------------------------------------
    // I10: hookData trader identity
    // -----------------------------------------------------------------

    function test_hookData_stampsTraderNotRouter() public {
        _buy(alice, 1e18);
        assertEq(hook.firstBuyOf(key, alice), uint64(vm.getBlockTimestamp()), "trader from hookData stamped");
        assertEq(hook.firstBuyOf(key, address(swapRouter)), 0, "router not stamped");
        assertEq(hook.firstBuyOf(key, address(this)), 0, "EOA caller not stamped");
    }

    /// @dev Documented limitation: an opaque router is treated as one address.
    function test_emptyHookData_treatsRouterAsTrader() public {
        _swapRaw(key, false, 1e18);
        assertEq(hook.firstBuyOf(key, address(swapRouter)), uint64(vm.getBlockTimestamp()), "router stamped");
        assertEq(hook.firstBuyOf(key, alice), 0, "no real trader stamped");

        // Every later opaque-router sell shares that stamp.
        vm.warp(vm.getBlockTimestamp() + DECAY);
        assertEq(hook.exitFeeFor(key, address(swapRouter)), BASE, "shared stamp decays for everyone");
    }

    /// @dev Malformed hookData (not exactly 32 bytes) falls back to the router.
    function test_malformedHookData_fallsBackToRouter() public {
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            _settings(),
            hex"deadbeef"
        );
        assertEq(hook.firstBuyOf(key, address(swapRouter)), uint64(vm.getBlockTimestamp()), "router stamped");
    }

    // -----------------------------------------------------------------
    // Authority surface: the ABI has nothing that moves a rate or value
    // -----------------------------------------------------------------

    /// @dev Immutables are fixed post-deploy: a second hook with different params is
    ///      a different contract, and this one's schedule is unchanged. There is no
    ///      function whose selector could change them; this test documents the
    ///      surface by exercising every external call and checking the schedule after.
    function test_noSetter_scheduleImmutable() public {
        (uint24 b0, uint24 s0, uint256 d0) = hook.feeSchedule();
        _buy(alice, 1e18);
        _sell(alice, 1e17);
        PoolKey memory k2 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(address(hook)));
        manager.initialize(k2, TickMath.getSqrtPriceAtTick(0));
        hook.setLaunchSide(k2, false);
        (uint24 b1, uint24 s1, uint256 d1) = hook.feeSchedule();
        assertEq(b0, b1);
        assertEq(s0, s1);
        assertEq(d0, d1);
        assertEq(hook.BASE_FEE(), BASE);
        assertEq(hook.EXIT_FEE_START(), START);
        assertEq(hook.DECAY_SECONDS(), DECAY);
    }
}
