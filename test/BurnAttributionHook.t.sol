// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
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
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {BurnAttributionHook} from "../src/BurnAttributionHook.sol";

/// @notice Tests for BurnAttributionHook. Run with `forge test --offline -vv`.
///
/// Every invariant in the spec (I1..I9) has a test that fails if it is broken, plus fuzz
/// on conservation (I1) and wash resistance (I4).
contract BurnAttributionHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    BurnAttributionHook hook;
    PoolId id;

    // NOTE: `key` is inherited from Deployers — do not redeclare it here.

    address constant SINK = 0x000000000000000000000000000000000000dEaD;
    uint256 constant WINDOW = 7 days;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address stranger = makeAddr("stranger");

    uint256 constant PIPS = 1_000_000;
    uint256 constant HOOK_PIPS = 5_000;
    uint256 constant BURN_PIPS = 4_000;
    uint256 constant LP_PIPS = 5_000;

    uint256 epoch0; // the epoch setUp leaves us in

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        deployCodeTo(
            "BurnAttributionHook.sol:BurnAttributionHook",
            abi.encode(manager, currency0, SINK, WINDOW),
            address(flags)
        );
        hook = BurnAttributionHook(address(flags));

        // currency0 is QUOTE.
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        id = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        // Deep, wide liquidity so test-size swaps have negligible price impact.
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e24, salt: 0}), ""
        );

        // Land at the start of a clean epoch.
        vm.warp(WINDOW * 100);
        epoch0 = hook.currentEpoch();

        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    function _fund(address who) internal {
        MockERC20(Currency.unwrap(currency0)).mint(who, 1e27);
        MockERC20(Currency.unwrap(currency1)).mint(who, 1e27);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    function _params(bool zeroForOne, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    /// @dev Swap as `who`, attributing to `who` via hookData.
    function _swapAs(address who, bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        vm.prank(who);
        return swapRouter.swap(key, _params(zeroForOne, amount), _settings(), abi.encode(who));
    }

    /// @dev Swap as `who` with empty hookData (router gets the attribution).
    function _swapAsNoData(address who, bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        vm.prank(who);
        return swapRouter.swap(key, _params(zeroForOne, amount), _settings(), "");
    }

    function _abs(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(uint128(-x)) : uint256(uint128(x));
    }

    /// @dev What the hook actually holds in QUOTE claims on the PoolManager.
    function _hookHeld() internal view returns (uint256) {
        return manager.balanceOf(address(hook), currency0.toId());
    }

    /// @dev Everything the hook owes: burn bucket + every epoch's outstanding rebate.
    function _hookOwed(uint256 fromEpoch, uint256 toEpoch) internal view returns (uint256 owed) {
        owed = hook.burnBucket(id);
        for (uint256 e = fromEpoch; e <= toEpoch; e++) {
            owed += hook.rebateOutstanding(key, e);
        }
    }

    function _nextEpoch() internal {
        vm.warp((hook.currentEpoch() + 1) * WINDOW);
    }

    // -----------------------------------------------------------------
    // Guards / constructor bounds
    // -----------------------------------------------------------------

    function test_revertsOnStaticFeePool() public {
        PoolKey memory bad = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(bad, TickMath.getSqrtPriceAtTick(0));
    }

    /// @dev A pool that does not contain QUOTE cannot open. Conservative fallback: closed.
    function test_revertsWhenPoolLacksQuote() public {
        Currency third = deployMintAndApproveCurrency();
        (Currency a, Currency b) = currency1 < third ? (currency1, third) : (third, currency1);
        PoolKey memory bad = PoolKey(a, b, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(bad, TickMath.getSqrtPriceAtTick(0));
    }

    /// @dev WINDOW must sit inside [MIN_WINDOW, MAX_WINDOW]; the sink cannot be zero.
    function test_constructorBounds() public {
        _expectConstructorRevert(SINK, 1 days - 1, "window out of bounds");
        _expectConstructorRevert(SINK, 30 days + 1, "window out of bounds");
        _expectConstructorRevert(address(0), 7 days, "sink zero");
        // And the bounds themselves are accepted.
        (bool okLo,) = _tryDeploy(SINK, 1 days);
        (bool okHi,) = _tryDeploy(SINK, 30 days);
        assertTrue(okLo && okHi, "bounds inclusive");
    }

    /// @dev BaseHook validates the flag bits in its constructor, so a plain `new` reverts
    ///      with HookAddressNotValid before our checks run. Run the creation code at a
    ///      flag-valid address instead, the way deployCodeTo does.
    function _tryDeploy(address sink, uint256 window) internal returns (bool ok, bytes memory ret) {
        address where = address(uint160(address(hook)) | (1 << 40));
        bytes memory creation = abi.encodePacked(
            vm.getCode("BurnAttributionHook.sol:BurnAttributionHook"), abi.encode(manager, currency0, sink, window)
        );
        vm.etch(where, creation);
        (ok, ret) = where.call("");
        vm.etch(where, "");
    }

    function _expectConstructorRevert(address sink, uint256 window, string memory reason) internal {
        (bool ok, bytes memory ret) = _tryDeploy(sink, window);
        assertFalse(ok, "constructor should revert");
        assertEq(ret, abi.encodeWithSignature("Error(string)", reason), reason);
    }

    /// @dev The rate constants are what the pitch says they are.
    function test_constants() public view {
        assertEq(hook.TOTAL_FEE(), 10_000);
        assertEq(hook.LP_SHARE(), 5_000);
        assertEq(hook.BURN_SHARE(), 4_000);
        assertEq(hook.REBATE_SHARE(), 1_000);
        assertEq(hook.REBATE_CAP_BPS(), 5_000);
        assertEq(hook.MAX_TOTAL_FEE(), 10_000);
        assertEq(hook.WINDOW(), WINDOW);
        assertEq(hook.BURN_SINK(), SINK);
        assertEq(Currency.unwrap(hook.QUOTE()), Currency.unwrap(currency0));
    }

    // -----------------------------------------------------------------
    // I9: fee split conserves
    // -----------------------------------------------------------------

    /// @dev Exact-input, QUOTE in. Hook fee == 0.50% of input to the wei, burn + rebate ==
    ///      hook fee to the wei, LP fee == 0.50% of what reaches the pool (v4's own
    ///      rounding), and the trader paid exactly the specified input.
    function test_feeSplit_conserves() public {
        uint256 amt = 123_456_789e9;
        uint256 quoteBefore = currency0.balanceOf(alice);
        _swapAs(alice, true, -int256(amt));

        uint256 hookFee = (amt * HOOK_PIPS) / PIPS;
        uint256 burn = (hookFee * BURN_PIPS) / HOOK_PIPS;
        uint256 rebate = hookFee - burn;

        assertEq(quoteBefore - currency0.balanceOf(alice), amt, "exact input charged");
        assertEq(hook.burnBucket(id), burn, "burn == 0.40%");
        assertEq(hook.rebatePoolOf(key, epoch0), rebate, "rebate == 0.10%");
        assertEq(hook.burnBucket(id) + hook.rebatePoolOf(key, epoch0), hookFee, "burn + rebate == hook fee");
        assertEq(_hookHeld(), hookFee, "hook holds exactly the hook fee");

        // LP fee: v4 levies LP_SHARE on the amount that reaches the pool after the hook take.
        uint256 toPool = amt - hookFee;
        uint256 expectedLp = toPool - (toPool * (PIPS - LP_PIPS)) / PIPS;
        (uint256 fg0,) = manager.getFeeGrowthGlobals(id);
        uint256 lpFee = FullMath.mulDiv(fg0, manager.getLiquidity(id), 1 << 128);
        assertApproxEqAbs(lpFee, expectedLp, 1, "LP fee == 0.50% of pool input");

        // Whole stack: 1.00% of input, less the 0.50%-of-0.50% the LP fee does not see.
        uint256 total = hookFee + expectedLp;
        assertLe(total, (amt * 10_000) / PIPS, "never above 1.00%");
        assertGe(total + 1, (amt * 10_000) / PIPS - (hookFee * LP_PIPS) / PIPS, "0.9975% floor");
    }

    /// @dev Exact-input, base in: the hook fee comes off the QUOTE output in afterSwap and
    ///      equals 0.50% of the pool's output to the wei.
    function test_feeSplit_afterSwapPath_quoteOut() public {
        BalanceDelta d = _swapAs(alice, false, -1e18);
        uint256 received = _abs(d.amount0());
        uint256 fee = _hookHeld();
        assertGt(fee, 0, "fee taken");
        assertEq(fee, ((received + fee) * HOOK_PIPS) / PIPS, "fee == 0.50% of pool output");
        assertEq(hook.burnBucket(id) + hook.rebatePoolOf(key, epoch0), fee, "burn + rebate == fee");
        assertEq(hook.attributedOf(key, epoch0, alice), hook.burnBucket(id), "attributed in QUOTE");
    }

    /// @dev Exact-output in both directions. The trader receives exactly what was asked,
    ///      the hook fee is 0.50% of the QUOTE leg, and it is fully accounted.
    function test_feeSplit_exactOutputPaths() public {
        // Buy exactly 1e18 base with QUOTE (QUOTE is the unspecified input -> afterSwap).
        uint256 b0 = currency1.balanceOf(alice);
        BalanceDelta d = _swapAs(alice, true, 1e18);
        assertEq(currency1.balanceOf(alice) - b0, 1e18, "exact output delivered");
        uint256 paidQuote = _abs(d.amount0());
        uint256 fee1 = _hookHeld();
        assertGt(fee1, 0);
        assertEq(fee1, ((paidQuote - fee1) * HOOK_PIPS) / PIPS, "fee == 0.50% of pool input");

        // Sell base for exactly 1e18 QUOTE (QUOTE is the specified output -> beforeSwap).
        uint256 q0 = currency0.balanceOf(bob);
        _swapAs(bob, false, 1e18);
        assertEq(currency0.balanceOf(bob) - q0, 1e18, "exact QUOTE output delivered");
        uint256 fee2 = _hookHeld() - fee1;
        assertEq(fee2, (1e18 * HOOK_PIPS) / PIPS, "fee == 0.50% of specified output");

        assertEq(hook.burnBucket(id) + hook.rebatePoolOf(key, epoch0), fee1 + fee2, "all accounted");
    }

    // -----------------------------------------------------------------
    // I1: conservation
    // -----------------------------------------------------------------

    function test_conservation_threeTraders() public {
        _swapAs(alice, true, -7e18);
        _swapAs(bob, false, -3e18);
        _swapAs(carol, true, 5e17);
        _swapAs(alice, false, 11e17);

        uint256 sum = hook.attributedOf(key, epoch0, alice) + hook.attributedOf(key, epoch0, bob)
            + hook.attributedOf(key, epoch0, carol);
        assertGt(sum, 0);
        assertEq(sum, hook.epochTotal(key, epoch0), "sum of attributions == epoch total");
        assertEq(hook.epochTotal(key, epoch0), hook.burnBucket(id), "epoch total == burn bucket");
        assertEq(hook.entriesOf(key), 4, "one entry per fee-bearing swap");
    }

    function testFuzz_conservation(uint256 a, uint256 b, uint256 c, bool dirA, bool dirB, bool dirC) public {
        a = bound(a, 1, 1e21);
        b = bound(b, 1, 1e21);
        c = bound(c, 1, 1e21);
        _swapAs(alice, dirA, -int256(a));
        _swapAs(bob, dirB, -int256(b));
        _swapAs(carol, dirC, -int256(c));
        _swapAs(bob, !dirB, -int256(b / 2 + 1));

        uint256 sum = hook.attributedOf(key, epoch0, alice) + hook.attributedOf(key, epoch0, bob)
            + hook.attributedOf(key, epoch0, carol);
        assertEq(sum, hook.epochTotal(key, epoch0), "conservation to the wei");
        assertEq(hook.epochTotal(key, epoch0), hook.burnBucket(id), "ledger == bucket");
        assertEq(_hookHeld(), hook.burnBucket(id) + hook.rebatePoolOf(key, epoch0), "held == owed");
    }

    // -----------------------------------------------------------------
    // I2: ledger is append-only
    // -----------------------------------------------------------------

    /// @dev Attribution and the entry counter only ever go up, and none of the value-moving
    ///      paths (claim, sweep, rollover) touch them. There is no function in the ABI
    ///      that writes `attributed` other than the swap hooks — see the contract: the only
    ///      writes are `+=` in `_accrue`.
    function test_ledgerMonotonic() public {
        _swapAs(alice, true, -1e18);
        uint256 a1 = hook.attributedOf(key, epoch0, alice);
        uint256 t1 = hook.epochTotal(key, epoch0);
        uint256 n1 = hook.entriesOf(key);
        assertGt(a1, 0);

        _swapAs(bob, false, -1e18);
        _swapAs(alice, false, -1e18);
        uint256 a2 = hook.attributedOf(key, epoch0, alice);
        assertGt(a2, a1, "alice only grows");
        assertGt(hook.epochTotal(key, epoch0), t1, "total only grows");
        assertEq(hook.entriesOf(key), n1 + 2, "entries +1 per swap");

        // Value-moving paths leave the ledger alone.
        hook.sweepBurn(key);
        _nextEpoch();
        vm.prank(alice);
        hook.claimRebate(key, epoch0);
        vm.warp((epoch0 + 4) * WINDOW);
        hook.rollover(key, epoch0);

        assertEq(hook.attributedOf(key, epoch0, alice), a2, "claim/sweep/rollover do not reattribute");
        assertEq(hook.attributedOf(key, epoch0, bob), hook.epochTotal(key, epoch0) - a2, "bob intact");
        assertEq(hook.entriesOf(key), n1 + 2, "entries unchanged by non-swap paths");
    }

    // -----------------------------------------------------------------
    // I3: rebate solvency
    // -----------------------------------------------------------------

    function test_rebateSolvency_threeClaimants() public {
        _swapAs(alice, true, -5e18);
        _swapAs(bob, true, -3e18);
        _swapAs(carol, false, -2e18);
        uint256 pool = hook.rebatePoolOf(key, epoch0);
        assertGt(pool, 0);

        _nextEpoch();
        uint256 e1 = hook.currentEpoch();

        uint256 paid;
        address[3] memory who = [alice, bob, carol];
        for (uint256 i = 0; i < 3; i++) {
            uint256 before = currency0.balanceOf(who[i]);
            vm.prank(who[i]);
            uint256 p = hook.claimRebate(key, epoch0);
            assertEq(currency0.balanceOf(who[i]) - before, p, "paid what it says");
            paid += p;
            assertLe(paid, pool, "never pays more than the epoch pool");
            assertGe(_hookHeld(), _hookOwed(epoch0, e1), "hook always holds >= it owes");
        }
        assertLe(hook.rebateOut(id, epoch0), pool, "out <= pool");
        // Pro-rata shares under the cap: the three claims exhaust the pool up to rounding.
        assertLe(pool - paid, 3, "pool fully distributed up to rounding");

        // Over-claim attempts.
        vm.prank(alice);
        vm.expectRevert(BurnAttributionHook.AlreadyClaimed.selector);
        hook.claimRebate(key, epoch0);
        vm.prank(stranger);
        vm.expectRevert(BurnAttributionHook.NothingToClaim.selector);
        hook.claimRebate(key, epoch0);

        assertEq(_hookHeld(), _hookOwed(epoch0, e1), "held == owed after all claims");
    }

    // -----------------------------------------------------------------
    // I4: wash resistance
    // -----------------------------------------------------------------

    function _roundTrip(address who, uint256 amt) internal returns (uint256 startQuote, uint256 endQuote) {
        startQuote = currency0.balanceOf(who);
        BalanceDelta d = _swapAs(who, true, -int256(amt)); // buy base with QUOTE
        uint256 gotBase = _abs(d.amount1());
        _swapAs(who, false, -int256(gotBase)); // sell all of it back
        _nextEpoch();
        uint256 closed = hook.currentEpoch() - 1;
        vm.prank(who);
        hook.claimRebate(key, closed); // sole contributor: max rebate
        endQuote = currency0.balanceOf(who);
    }

    function test_washNetsNegative() public {
        (uint256 s, uint256 e) = _roundTrip(alice, 10e18);
        assertLt(e, s, "round trip loses money even after max rebate");
        // Loss is at least the 2x hook fee (1.00%) minus the 0.20% cap.
        assertGe(s - e, (10e18 * 8_000) / PIPS, "loss >= 0.80% of volume");
    }

    function testFuzz_washNetsNegative(uint256 amt) public {
        amt = bound(amt, 1e12, 1e21);
        (uint256 s, uint256 e) = _roundTrip(alice, amt);
        assertLt(e, s, "round trip always nets negative");
    }

    // -----------------------------------------------------------------
    // I5: rebate cap and rollover
    // -----------------------------------------------------------------

    /// @dev Bob funds a big pool in epoch0 and never claims. It rolls into a later epoch
    ///      where alice is the sole contributor. Her share would be the whole pool; she is
    ///      capped at 50% of her attributed burn and the rest rolls to the next epoch.
    function test_rebateCap_remainderRollsForward() public {
        _swapAs(bob, true, -1000e18);
        uint256 bobPool = hook.rebatePoolOf(key, epoch0);

        vm.warp((epoch0 + 3) * WINDOW); // epoch0's claim window has lapsed
        uint256 eA = hook.currentEpoch();
        vm.prank(stranger);
        uint256 rolled = hook.rollover(key, epoch0);
        assertEq(rolled, bobPool, "unclaimed pool rolled in full");
        assertEq(hook.rebatePoolOf(key, eA), bobPool, "landed in the open epoch");
        assertEq(hook.rebateOutstanding(key, epoch0), 0, "old epoch drained");

        _swapAs(alice, true, -1e18);
        uint256 mine = hook.attributedOf(key, eA, alice);
        uint256 poolA = hook.rebatePoolOf(key, eA);
        uint256 cap = (mine * 5_000) / 10_000;
        assertGt(poolA, cap, "pool is large relative to alice's burn");

        _nextEpoch();
        uint256 eB = hook.currentEpoch();
        assertEq(hook.claimableRebate(key, eA, alice), cap, "view reports the cap");

        uint256 before = currency0.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = hook.claimRebate(key, eA);
        assertEq(paid, cap, "paid exactly the cap");
        assertEq(currency0.balanceOf(alice) - before, cap);
        assertLe(paid, (mine * 5_000) / 10_000, "rebate <= 50% of attributed burn");
        assertEq(hook.rebatePoolOf(key, eB), poolA - cap, "next epoch pool grew by exactly the remainder");
        assertEq(hook.rebateOutstanding(key, eA), 0, "sole contributor: epoch fully settled");
        assertEq(_hookHeld(), _hookOwed(epoch0, eB), "held == owed");
    }

    /// @dev Cap never binds from the fee alone: a sole contributor's pro-rata share is
    ///      0.10% of volume, below the 0.20% cap, so it pays in full.
    function test_rebate_belowCap_paysFullShare() public {
        _swapAs(alice, true, -1e18);
        uint256 pool = hook.rebatePoolOf(key, epoch0);
        _nextEpoch();
        vm.prank(alice);
        assertEq(hook.claimRebate(key, epoch0), pool, "full share");
    }

    // -----------------------------------------------------------------
    // I6: claims are one-shot, closed epochs only, and lapse
    // -----------------------------------------------------------------

    function test_claim_openEpochReverts() public {
        _swapAs(alice, true, -1e18);
        vm.prank(alice);
        vm.expectRevert(BurnAttributionHook.EpochOpen.selector);
        hook.claimRebate(key, epoch0);
        assertEq(hook.claimableRebate(key, epoch0, alice), 0, "view agrees");
    }

    function test_claim_isOneShot() public {
        _swapAs(alice, true, -1e18);
        _nextEpoch();
        vm.prank(alice);
        hook.claimRebate(key, epoch0);
        assertEq(hook.claimableRebate(key, epoch0, alice), 0);
        vm.prank(alice);
        vm.expectRevert(BurnAttributionHook.AlreadyClaimed.selector);
        hook.claimRebate(key, epoch0);
    }

    function test_claim_expiredReverts_andRolloverGates() public {
        _swapAs(alice, true, -1e18);
        _nextEpoch();
        vm.expectRevert(BurnAttributionHook.EpochNotExpired.selector);
        hook.rollover(key, epoch0);

        vm.warp((epoch0 + 3) * WINDOW);
        vm.prank(alice);
        vm.expectRevert(BurnAttributionHook.EpochExpired.selector);
        hook.claimRebate(key, epoch0);

        hook.rollover(key, epoch0);
        vm.expectRevert(BurnAttributionHook.NothingToRoll.selector);
        hook.rollover(key, epoch0);
    }

    // -----------------------------------------------------------------
    // I7: sweepBurn
    // -----------------------------------------------------------------

    function test_sweepBurn_sendsBucketToSink_leavesRebate() public {
        _swapAs(alice, true, -4e18);
        _swapAs(bob, false, -2e18);
        uint256 burn = hook.burnBucket(id);
        uint256 rebate = hook.rebatePoolOf(key, epoch0);
        uint256 sinkBefore = currency0.balanceOf(SINK);
        uint256 strangerBefore = currency0.balanceOf(stranger);

        vm.prank(stranger); // permissionless
        uint256 swept = hook.sweepBurn(key);

        assertEq(swept, burn);
        assertEq(currency0.balanceOf(SINK) - sinkBefore, burn, "sink received exactly the bucket");
        assertEq(currency0.balanceOf(stranger), strangerBefore, "keeper gets nothing");
        assertEq(hook.burnBucket(id), 0, "bucket drained");
        assertEq(hook.burnedCumulative(id), burn);
        assertEq(hook.rebatePoolOf(key, epoch0), rebate, "rebate pool untouched");
        assertEq(_hookHeld(), rebate, "hook retains only the rebate pool");

        vm.expectRevert(BurnAttributionHook.NothingToSweep.selector);
        hook.sweepBurn(key);
    }

    // -----------------------------------------------------------------
    // I8: attribution follows hookData, not the router
    // -----------------------------------------------------------------

    function test_attribution_goesToHookDataTrader() public {
        _swapAs(alice, true, -1e18);
        assertGt(hook.attributedOf(key, epoch0, alice), 0, "alice credited");
        assertEq(hook.attributedOf(key, epoch0, address(swapRouter)), 0, "router not credited");

        // Without hookData the router (the swap sender) is credited — never a third party.
        uint256 before = hook.epochTotal(key, epoch0);
        _swapAsNoData(bob, true, -1e18);
        assertEq(hook.attributedOf(key, epoch0, bob), 0, "bob not credited without hookData");
        assertEq(hook.attributedOf(key, epoch0, address(swapRouter)), hook.epochTotal(key, epoch0) - before);
    }

    // -----------------------------------------------------------------
    // Epoch mechanics
    // -----------------------------------------------------------------

    function test_epochs_areFixedWindows() public {
        assertEq(hook.currentEpoch(), block.timestamp / WINDOW);
        vm.warp(block.timestamp + WINDOW - 1);
        assertEq(hook.currentEpoch(), epoch0, "still same epoch at window end");
        vm.warp(block.timestamp + 1);
        assertEq(hook.currentEpoch(), epoch0 + 1, "rolls on the boundary");

        _swapAs(alice, true, -1e18);
        assertEq(hook.attributedOf(key, epoch0, alice), 0, "old epoch untouched");
        assertGt(hook.attributedOf(key, epoch0 + 1, alice), 0, "new epoch credited");
    }

    /// @dev Multi-epoch: pools are per epoch and claims for different epochs are independent.
    function test_multiEpoch_independentPools() public {
        _swapAs(alice, true, -1e18);
        uint256 p0 = hook.rebatePoolOf(key, epoch0);
        _nextEpoch();
        _swapAs(alice, true, -2e18);
        uint256 p1 = hook.rebatePoolOf(key, epoch0 + 1);
        assertEq(p1, 2 * p0);
        _nextEpoch();
        vm.startPrank(alice);
        assertEq(hook.claimRebate(key, epoch0), p0);
        assertEq(hook.claimRebate(key, epoch0 + 1), p1);
        vm.stopPrank();
        assertEq(_hookHeld(), hook.burnBucket(id), "only burn remains");
    }
}
