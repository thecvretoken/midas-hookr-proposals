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

import {SweepGuard} from "../../src/libraries/SweepGuard.sol";
import {GuardedSweeper} from "./GuardedSweeper.sol";

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

/// @notice Shared fixture for the SweepGuard scenario suites: a real v4 PoolManager and a
///         hookless 0.30% route holding L = 1e21 in ticks -60000..60000 at price 1 (about 1e21 of
///         each token in range), an attacker with its own balances, and the helpers that push
///         the route, sandwich a sweep and value the attacker's position at price 1.
abstract contract SweepGuardBase is Test, Deployers {
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
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
    }

    // =====================================================================
    // helpers
    // =====================================================================

    function _cfg(bool anchor, uint16 drift) internal pure returns (SweepGuard.Params memory) {
        return SweepGuard.Params({
            interval: 1 hours,
            bandBps: 1000,
            floorBps: 300,
            smoothing: 4,
            anchorFloor: anchor,
            maxDriftBps: drift,
            maxImpactBps: 0
        });
    }

    function _walls() internal pure returns (SweepGuard.ReseedWalls memory) {
        return SweepGuard.ReseedWalls({maxStepBps: 500, minInterval: 1 hours, minStall: 6 hours});
    }

    function _sweeper(SweepGuard.Params memory p, bool outIsToken1) internal returns (GuardedSweeper) {
        return _sweeper(p, outIsToken1, 0);
    }

    /// @dev The test contract is the reseed authority.
    function _sweeper(SweepGuard.Params memory p, bool outIsToken1, uint128 maxIn) internal returns (GuardedSweeper) {
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = route;
        uint160[] memory seeds = new uint160[](1);
        seeds[0] = SQRT1;
        uint128[] memory caps = new uint128[](1);
        caps[0] = maxIn;
        return new GuardedSweeper(
            manager,
            outIsToken1 ? currency0 : currency1,
            outIsToken1 ? currency1 : currency0,
            keys,
            seeds,
            caps,
            p,
            address(this),
            _walls()
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
        (,, r,,) = s.routes(rid);
    }

    function _seed(GuardedSweeper s) internal view returns (uint160 sd) {
        (sd,,,,) = s.routes(rid);
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
        vm.warp(vm.getBlockTimestamp() + 1 hours);
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
        uint256 t = block.timestamp; // tracked locally: via-IR may cache block.timestamp across vm.warp
        for (uint256 n = 1; n <= 24; n++) {
            if (n > 1) {
                t += 1 hours;
                vm.warp(t);
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
