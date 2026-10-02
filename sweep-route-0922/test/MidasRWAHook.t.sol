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

/// @notice Tests for MidasRWAHook. Run with `forge test -vv`.
///
/// Covers the two things most likely to be wrong — the launch decay curve and the
/// asymmetric sell fee — plus the accrual split and the claim paths.
contract MidasRWAHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    MidasRWAHook hook;
    PoolId id;
    Currency gold;

    // NOTE: `key` is inherited from Deployers — do not redeclare it here.

    address royalty = address(0xFEE5);
    address stranger = address(0xBEEF);

    uint24 constant STEADY = 10_000;
    uint24 constant LAUNCH = 80_000;
    uint256 constant WINDOW = 120;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // GOLD stands in as a third currency for burn-route tests.
        gold = deployMintAndApproveCurrency();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        // Permit the canonical GOLD burn route at deploy, seeded at price 1 (tick 0), the
        // price the route pool is initialized at in the burn tests below.
        PoolKey[] memory routes = new PoolKey[](1);
        routes[0] = _goldRoute();
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

        hook.setQuoteSide(key, true); // currency0 is the quote asset
    }

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

    // -----------------------------------------------------------------
    // Fee curve
    // -----------------------------------------------------------------

    /// @dev At t=0 a buy pays the full launch fee.
    ///      quoteIsZero == true, so zeroForOne == true is a SELL and a BUY is false.
    function test_launchFee_atOpen() public view {
        assertEq(hook.quoteFee(id, false), LAUNCH, "buy at t=0 should be 8.00%");
    }

    /// @dev Halfway through the window the fee is halfway down the ramp.
    function test_launchFee_decaysLinearly() public {
        vm.warp(block.timestamp + WINDOW / 2);
        uint24 expected = uint24(LAUNCH - ((LAUNCH - STEADY) * (WINDOW / 2)) / WINDOW);
        assertEq(hook.quoteFee(id, false), expected, "midpoint of decay ramp");
    }

    /// @dev After the window the fee settles at steady state and stays there.
    function test_launchFee_settlesAtSteady() public {
        vm.warp(block.timestamp + WINDOW);
        assertEq(hook.quoteFee(id, false), STEADY, "steady at window close");

        vm.warp(block.timestamp + 365 days);
        assertEq(hook.quoteFee(id, false), STEADY, "still steady much later");
    }

    /// @dev Fee is monotonically non-increasing across the window.
    function testFuzz_launchFee_monotonic(uint256 a, uint256 b) public {
        a = bound(a, 0, WINDOW);
        b = bound(b, 0, WINDOW);
        vm.assume(a < b);

        uint256 t0 = block.timestamp;
        vm.warp(t0 + a);
        uint24 feeA = hook.quoteFee(id, false);
        vm.warp(t0 + b);
        uint24 feeB = hook.quoteFee(id, false);

        assertGe(feeA, feeB, "fee must never increase over time");
    }

    /// @dev Nothing, at any point, exceeds the hard ceiling.
    function testFuzz_neverExceedsCeiling(uint256 t, bool dir) public {
        vm.warp(block.timestamp + bound(t, 0, 400));
        assertLe(hook.quoteFee(id, dir), hook.MAX_TOTAL_FEE(), "ceiling breached");
    }

    // -----------------------------------------------------------------
    // Sell asymmetry
    // -----------------------------------------------------------------

    /// @dev A sell pays 1.5x the buy fee at steady state.
    function test_sellMultiplier_atSteady() public {
        vm.warp(block.timestamp + WINDOW);
        uint24 buy = hook.quoteFee(id, false);
        uint24 sell = hook.quoteFee(id, true);

        assertEq(buy, STEADY, "buy 1.00%");
        assertEq(sell, uint24((uint256(STEADY) * 15_000) / 10_000), "sell 1.50%");
        assertGt(sell, buy, "sell must cost more than buy");
    }

    /// @dev The sell multiplier clamps at the ceiling rather than running past it.
    ///      At t=0 buy is already 8.00%; 1.5x would be 12% and must clamp.
    function test_sellMultiplier_clampsAtCeiling() public view {
        assertEq(hook.quoteFee(id, true), hook.MAX_TOTAL_FEE(), "sell clamps to ceiling");
    }

    /// @dev quoteIsZero flips which direction counts as a sell.
    function test_quoteSide_flipsSellDirection() public {
        PoolKey memory k2 =
            PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(address(hook)));
        manager.initialize(k2, TickMath.getSqrtPriceAtTick(0));
        hook.setQuoteSide(k2, false); // currency1 is the quote now

        vm.warp(block.timestamp + WINDOW);
        assertGt(hook.quoteFee(k2.toId(), false), hook.quoteFee(k2.toId(), true), "direction inverted");
    }

    // -----------------------------------------------------------------
    // Guards
    // -----------------------------------------------------------------

    function test_revertsOnStaticFeePool() public {
        PoolKey memory bad = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(bad, TickMath.getSqrtPriceAtTick(0));
    }

    function test_setQuoteSide_onlyDeployer() public {
        PoolKey memory k2 =
            PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 200, IHooks(address(hook)));
        manager.initialize(k2, TickMath.getSqrtPriceAtTick(0));

        vm.prank(stranger);
        vm.expectRevert(MidasRWAHook.NotDeployer.selector);
        hook.setQuoteSide(k2, true);
    }

    function test_setQuoteSide_isOneShot() public {
        vm.expectRevert(MidasRWAHook.QuoteAlreadySet.selector);
        hook.setQuoteSide(key, false);
    }

    /// @dev A pool with no declared sell side must not trade.
    function test_swapReverts_beforeQuoteSideSet() public {
        PoolKey memory k2 =
            PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        manager.initialize(k2, TickMath.getSqrtPriceAtTick(0));

        vm.expectRevert();
        _swap(k2, true, -1e18);
    }

    // -----------------------------------------------------------------
    // Accrual
    // -----------------------------------------------------------------

    /// @dev All three hook buckets fund, and in the right proportions.
    function test_accrual_splitIsProportional() public {
        vm.warp(block.timestamp + WINDOW);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, "");
        _swap(key, true, -1e18);

        uint256 burnAmt = hook.burnBucket(currency0);
        uint256 royAmt = hook.royaltyBucket(currency0);
        uint256 depAmt = hook.deployerBucket(id, currency0);

        assertGt(burnAmt, 0, "burn bucket funded");
        assertGt(royAmt, 0, "royalty bucket funded");
        assertGt(depAmt, 0, "deployer bucket funded");

        // 0.35 > 0.22 > 0.08
        assertGt(burnAmt, depAmt, "burn > deployer");
        assertGt(depAmt, royAmt, "deployer > royalty");
    }

    function test_claimDeployer_onlyDeployer() public {
        vm.prank(stranger);
        vm.expectRevert(MidasRWAHook.NotDeployer.selector);
        hook.claimDeployer(id, currency0);
    }

    function test_claimRoyalty_paysImmutableRecipient() public {
        vm.warp(block.timestamp + WINDOW);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, "");
        _swap(key, true, -1e18);

        uint256 before = currency0.balanceOf(royalty);
        hook.claimRoyalty(currency0); // permissionless
        assertGt(currency0.balanceOf(royalty) - before, 0, "royalty recipient paid");
        assertEq(hook.royaltyBucket(currency0), 0, "bucket drained");
    }

    // -----------------------------------------------------------------
    // Buy and burn
    // -----------------------------------------------------------------

    /// @dev Rejects a route that doesn't touch GOLD.
    function test_sweep_rejectsNonGoldRoute() public {
        vm.expectRevert(MidasRWAHook.RouteNotGold.selector);
        hook.sweepAndBurn(currency0, key, 0);
    }

    /// @dev The GOLD burn route is a plain hookless pool, so it must carry a STATIC fee.
    ///      v4's isValidHookAddress rejects `hooks == address(0)` combined with
    ///      DYNAMIC_FEE_FLAG — with no hook there is nothing to set the fee per swap.
    ///      This mirrors reality: the GOLD/ETH and PAXG/GOLD routes are ordinary pools.
    function _goldRoute() internal view returns (PoolKey memory) {
        (Currency a, Currency b) = currency0 < gold ? (currency0, gold) : (gold, currency0);
        return PoolKey(a, b, 3000, 60, IHooks(address(0)));
    }

    function test_sweep_revertsWhenEmpty() public {
        vm.expectRevert(MidasRWAHook.NothingToSweep.selector);
        hook.sweepAndBurn(currency0, _goldRoute(), 0);
    }

    function test_sweep_rejectsGoldAsInput() public {
        vm.expectRevert(MidasRWAHook.RouteIsGold.selector);
        hook.sweepAndBurn(gold, _goldRoute(), 0);
    }

    /// @dev With fees accrued but the route pool never initialized, the spot read
    ///      returns zero and the sweep must refuse rather than divide by it.
    function test_sweep_revertsOnUninitializedRoute() public {
        vm.warp(block.timestamp + WINDOW);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, "");
        _swap(key, true, -1e18);

        assertGt(hook.burnBucket(currency0), 0, "burn bucket should be funded");

        vm.expectRevert(MidasRWAHook.RouteNotInitialized.selector);
        hook.sweepAndBurn(currency0, _goldRoute(), 0);
    }

    /// @dev A permitted route is seeded with its reference at deploy, so the first sweep
    ///      has a real anchor to fail against. The sweep timestamp still starts empty.
    function test_sweep_referenceSeededAtDeploy() public view {
        PoolId rid = _goldRoute().toId();
        assertEq(hook.refSqrtPriceX96(rid), TickMath.getSqrtPriceAtTick(0), "reference seeded at deploy");
        assertEq(hook.lastSweepAt(rid), 0, "never swept");
        assertTrue(hook.allowedRoute(rid), "route permitted at deploy");
    }

    // -----------------------------------------------------------------
    // Full burn simulation — funded GOLD route
    // -----------------------------------------------------------------

    /// @dev Deployers' LIQUIDITY_PARAMS is a ±120-tick band (~±1.2%). Any swap large
    ///      enough to matter here exhausts it and hits the sqrt price limit, so these
    ///      tests seed a wide range instead. ±60000 ticks, both multiples of the pool's
    ///      tickSpacing of 60.
    function _seedLiquidity(PoolKey memory k) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e18, salt: 0}), ""
        );
    }

    /// @dev Stands up a real currency0/GOLD pool with liquidity so sweepAndBurn can
    ///      actually execute. Hookless, so the assertions isolate this hook's behaviour.
    function _fundedGoldRoute() internal returns (PoolKey memory route) {
        route = _goldRoute();
        manager.initialize(route, TickMath.getSqrtPriceAtTick(0));
        _seedLiquidity(route);
    }

    /// @dev Accrues fees into the burn bucket by trading the hooked pool. Sized at 1% of
    ///      in-range liquidity so the price barely moves and the swap can be repeated.
    function _accrueFees() internal {
        vm.warp(block.timestamp + WINDOW);
        _seedLiquidity(key);
        _swap(key, true, -1e16);
    }

    /// @dev The headline path: fees convert to GOLD, GOLD lands at the dead address,
    ///      the caller is paid the bounty, and the bucket is emptied.
    function test_sweep_burnsToDeadAndPaysKeeper() public {
        PoolKey memory route = _fundedGoldRoute();
        _accrueFees();

        uint256 bucket = hook.burnBucket(currency0);
        assertGt(bucket, 0, "precondition: burn bucket funded");

        uint256 deadBefore = gold.balanceOf(hook.DEAD());
        uint256 keeperBefore = currency0.balanceOf(stranger);

        vm.prank(stranger);
        uint256 goldOut = hook.sweepAndBurn(currency0, route, 0);

        assertGt(goldOut, 0, "swap produced GOLD");
        assertEq(gold.balanceOf(hook.DEAD()) - deadBefore, goldOut, "all GOLD burned to dead address");
        assertEq(hook.burnBucket(currency0), 0, "burn bucket drained");

        uint256 expectedBounty = (bucket * hook.KEEPER_BOUNTY()) / 1_000_000;
        assertEq(currency0.balanceOf(stranger) - keeperBefore, expectedBounty, "keeper paid 0.50%");
    }

    /// @dev The burn is unrecoverable — nothing accrues to the royalty recipient or
    ///      the hook itself from the burn share.
    function test_sweep_hookRetainsNothing() public {
        PoolKey memory route = _fundedGoldRoute();
        _accrueFees();

        vm.prank(stranger);
        hook.sweepAndBurn(currency0, route, 0);

        assertEq(gold.balanceOf(address(hook)), 0, "hook holds no GOLD");
        assertEq(gold.balanceOf(royalty), 0, "royalty recipient gets none of the burn");
    }

    /// @dev First sweep bootstraps the reference from spot; the cooldown then bites.
    function test_sweep_setsReferenceAndRateLimits() public {
        PoolKey memory route = _fundedGoldRoute();
        PoolId rid = route.toId();
        _accrueFees();

        (uint160 spot,,,) = _slot0(rid);

        vm.prank(stranger);
        hook.sweepAndBurn(currency0, route, 0);

        assertEq(hook.refSqrtPriceX96(rid), spot, "first sweep seeds reference from spot");
        assertEq(hook.lastSweepAt(rid), uint64(block.timestamp), "sweep timestamp recorded");

        // Accrue again, then try to sweep inside the cooldown.
        _swap(key, true, -1e16);
        vm.expectRevert(MidasRWAHook.SweepTooSoon.selector);
        hook.sweepAndBurn(currency0, route, 0);

        // Past the cooldown it works again.
        vm.warp(block.timestamp + hook.MIN_SWEEP_INTERVAL());
        hook.sweepAndBurn(currency0, route, 0);
    }

    /// @dev minGoldOut above what the route can deliver must revert, not silently
    ///      under-burn. Uses a floor far above any achievable output.
    function test_sweep_respectsMinGoldOut() public {
        PoolKey memory route = _fundedGoldRoute();
        _accrueFees();

        vm.expectRevert();
        hook.sweepAndBurn(currency0, route, type(uint128).max);
    }

    /// @dev A route pushed far from the stored reference is refused.
    function test_sweep_rejectsDeviatedRoute() public {
        PoolKey memory route = _fundedGoldRoute();
        PoolId rid = route.toId();
        _accrueFees();

        vm.prank(stranger);
        hook.sweepAndBurn(currency0, route, 0); // seeds reference
        vm.warp(block.timestamp + hook.MIN_SWEEP_INTERVAL());

        // Shove the route pool out of band. For a zeroForOne swap of `x` against
        // in-range liquidity L starting at price 1:
        //     sqrt(P') = 1 / (1 + x/L)
        // so x = 0.3L gives sqrt(P') ≈ 0.77 — a ~23% drop, comfortably past the 10%
        // band and still far inside the ±60000 tick range. Deterministic, no vm.assume.
        _swap(route, true, -3e17);

        (uint160 moved,,,) = _slot0(rid);
        uint160 ref = hook.refSqrtPriceX96(rid);
        uint256 lo = (uint256(ref) * (10_000 - hook.MAX_REF_DEVIATION_BPS())) / 10_000;
        assertLt(moved, lo, "precondition: route must actually be out of band");

        _swap(key, true, -1e16); // refill the bucket
        vm.expectRevert(MidasRWAHook.RoutePriceDeviates.selector);
        hook.sweepAndBurn(currency0, route, 0);
    }

    function _slot0(PoolId pid) internal view returns (uint160, int24, uint24, uint24) {
        return StateLibrary.getSlot0(manager, pid);
    }
}
