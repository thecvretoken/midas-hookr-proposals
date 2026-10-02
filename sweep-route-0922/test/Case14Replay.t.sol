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

/// @notice Step-by-step replay of the 09-22 "14%" run (SweepRoute.t.sol,
///         test_scenario_manipulateAroundEachSweep). Same setup, same helpers, same order,
///         with every intermediate value logged and the two totals pinned to the figures
///         reported on 09-22. Read the -vv log for the case write-up.
contract Case14ReplayTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    MidasRWAHook hook;
    PoolId id;
    Currency gold;
    uint256 constant WINDOW = 120;
    uint256 constant Q96 = 2 ** 96;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        gold = deployMintAndApproveCurrency();
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        PoolKey[] memory routes = new PoolKey[](1);
        routes[0] = _honestRouteKey();
        uint160[] memory seeds = new uint160[](1);
        seeds[0] = TickMath.getSqrtPriceAtTick(0);
        deployCodeTo("MidasRWAHook.sol:MidasRWAHook", abi.encode(manager, gold, address(0xFEE5), routes, seeds), address(flags));
        hook = MidasRWAHook(address(flags));
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        id = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        hook.setQuoteSide(key, true);
    }

    function test_case14_replay() public {
        PoolKey memory route = _honestRouteKey();
        manager.initialize(route, TickMath.getSqrtPriceAtTick(0));
        _seedLiquidity(route, 1e18);
        PoolId rid = route.toId();

        bool goldIsToken1 = Currency.unwrap(route.currency1) == Currency.unwrap(gold);
        emit log_named_string("GOLD sorts as", goldIsToken1 ? "token1 (adverse edge = LOWER sqrt edge)" : "token0 (adverse edge = UPPER sqrt edge)");
        emit log_named_uint("route fee (pips)", route.fee);
        emit log_named_uint("route liquidity L, ticks -60000..60000", 1e18);
        emit log_named_decimal_uint("seed sqrtP / 2^96", _r(TickMath.getSqrtPriceAtTick(0)), 18);

        // ---- clean baseline, identical to the 09-22 test ----
        uint256 cleanBurn; uint256 clean1; uint256 clean2;
        {
            uint256 snap = vm.snapshotState();
            _accrueFees();
            emit log_named_uint("bucket per sweep (currency0)", hook.burnBucket(currency0));
            uint256 d0 = gold.balanceOf(hook.DEAD());
            hook.sweepAndBurn(currency0, route, 0);
            clean1 = gold.balanceOf(hook.DEAD()) - d0;
            vm.warp(block.timestamp + hook.MIN_SWEEP_INTERVAL());
            _swap(key, true, -1e16);
            hook.sweepAndBurn(currency0, route, 0);
            cleanBurn = gold.balanceOf(hook.DEAD()) - d0;
            clean2 = cleanBurn - clean1;
            vm.revertToState(snap);
        }
        emit log_named_uint("clean sweep 1 GOLD out", clean1);
        emit log_named_uint("clean sweep 2 GOLD out", clean2);

        // ---- manipulated run, identical order ----
        _accrueFees();
        uint256 dStart = gold.balanceOf(hook.DEAD());

        uint256 out1 = _stepAndLog(route, rid, 1, dStart);
        vm.warp(block.timestamp + hook.MIN_SWEEP_INTERVAL());
        _swap(key, true, -1e16);
        uint256 out2 = _stepAndLog(route, rid, 2, dStart + out1);

        uint256 manipBurn = out1 + out2;
        emit log_named_uint("clean two-sweep burn", cleanBurn);
        emit log_named_uint("manip two-sweep burn", manipBurn);
        emit log_named_decimal_uint("sweep 1 shortfall vs clean (%)", (clean1 - out1) * 1e20 / clean1, 18);
        emit log_named_decimal_uint("sweep 2 shortfall vs clean (%)", (clean2 - out2) * 1e20 / clean2, 18);
        emit log_named_decimal_uint("two-sweep shortfall (%)", (cleanBurn - manipBurn) * 1e20 / cleanBurn, 18);
        emit log_named_decimal_uint("route sqrtP / 2^96 left after run", _r(_slot0(rid)), 18);

        assertEq(cleanBurn, 104150726496290, "clean total as reported 09-22");
        assertEq(manipBurn, 89480918986838, "manipulated total as reported 09-22");
    }

    function _stepAndLog(PoolKey memory route, PoolId rid, uint256 n, uint256 deadBefore) internal returns (uint256 out) {
        uint160 refBefore = hook.refSqrtPriceX96(rid);
        uint256 lo = (uint256(refBefore) * 9_000) / 10_000;
        uint160 startSpot = _slot0(rid);
        int256 nudge = _nudgeWithinBand(route, rid);
        uint160 spot = _slot0(rid);
        uint256 amountIn = hook.burnBucket(currency0) - (hook.burnBucket(currency0) * hook.KEEPER_BOUNTY()) / 1_000_000;
        hook.sweepAndBurn(currency0, route, 0);
        out = gold.balanceOf(hook.DEAD()) - deadBefore;
        uint160 afterSweep = _slot0(rid);
        _restore(route, rid);

        string memory p = n == 1 ? "sweep 1: " : "sweep 2: ";
        emit log_named_decimal_uint(string.concat(p, "ref before / 2^96"), _r(refBefore), 18);
        emit log_named_decimal_uint(string.concat(p, "lower band edge / 2^96"), _r(uint160(lo)), 18);
        emit log_named_decimal_uint(string.concat(p, "route spot before nudge / 2^96"), _r(startSpot), 18);
        emit log_named_int(string.concat(p, "attacker nudge (currency0 in, wei)"), -nudge);
        emit log_named_decimal_uint(string.concat(p, "spot at sweep / 2^96"), _r(spot), 18);
        emit log_named_decimal_uint(string.concat(p, "spot price at sweep (sqrt^2)"), _r(spot) * _r(spot) / 1e18, 18);
        emit log_named_uint(string.concat(p, "amountIn after bounty"), amountIn);
        emit log_named_uint(string.concat(p, "GOLD out"), out);
        emit log_named_decimal_uint(string.concat(p, "spot after sweep / 2^96"), _r(afterSweep), 18);
        emit log_named_decimal_uint(string.concat(p, "ref after / 2^96"), _r(hook.refSqrtPriceX96(rid)), 18);
        emit log_named_decimal_uint(string.concat(p, "spot after 'restore' / 2^96"), _r(_slot0(rid)), 18);
    }

    // ---- helpers copied verbatim from SweepRoute.t.sol (nudge returns its size here) ----
    function _r(uint160 s) internal pure returns (uint256) { return uint256(s) * 1e18 / Q96; }
    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }
    function _swap(PoolKey memory k, bool zeroForOne, int256 amount) internal {
        swapRouter.swap(k, SwapParams({zeroForOne: zeroForOne, amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}), _settings(), "");
    }
    function _seedLiquidity(PoolKey memory k, uint128 L) internal {
        modifyLiquidityRouter.modifyLiquidity(k, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: int128(L), salt: 0}), "");
    }
    function _accrueFees() internal {
        vm.warp(block.timestamp + WINDOW);
        _seedLiquidity(key, 1e18);
        _swap(key, true, -1e16);
    }
    function _slot0(PoolId pid) internal view returns (uint160 s) { (s,,,) = StateLibrary.getSlot0(manager, pid); }
    function _honestRouteKey() internal view returns (PoolKey memory) {
        (Currency a, Currency b) = currency0 < gold ? (currency0, gold) : (gold, currency0);
        return PoolKey(a, b, 3000, 60, IHooks(address(0)));
    }
    function _nudgeWithinBand(PoolKey memory route, PoolId rid) internal returns (int256) {
        uint160 ref = hook.refSqrtPriceX96(rid);
        uint256 lo = (uint256(ref) * (10_000 - hook.MAX_REF_DEVIATION_BPS())) / 10_000;
        uint256 sizeSnap = vm.snapshotState();
        int256 size = -1e15;
        for (uint256 i = 0; i < 12; i++) {
            vm.revertToState(sizeSnap);
            sizeSnap = vm.snapshotState();
            _swap(route, true, size);
            if (_slot0(rid) > uint160(lo + (lo / 200))) {
                size = size * 2;
            } else {
                vm.revertToState(sizeSnap);
                sizeSnap = vm.snapshotState();
                break;
            }
        }
        _swap(route, true, size / 2);
        return size / 2;
    }
    function _restore(PoolKey memory route, PoolId rid) internal {
        uint160 s = _slot0(rid);
        if (s < TickMath.getSqrtPriceAtTick(0)) _swap(route, false, -1e15);
    }
}
