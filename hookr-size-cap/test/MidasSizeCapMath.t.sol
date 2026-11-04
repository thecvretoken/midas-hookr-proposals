// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrAdvisory} from "hookr/interfaces/IHookrAdvisory.sol";
import {MidasSizeCapAdvisory} from "../src/MidasSizeCapAdvisory.sol";
import {MidasSizeCapAdvisoryPrev} from "./fixtures/MidasSizeCapAdvisoryPrev.sol";

/// @dev A stand-in PoolManager whose storage a test writes directly, read through the same extsload StateLibrary uses.
contract RawPoolManager {
    function extsload(bytes32 slot) external view returns (bytes32 value) {
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }
}

/// @notice The block's arithmetic on arbitrary PoolManager states, which the fixture pools cannot reach: any price,
///         prices exactly on a tick boundary from either side, the price extremes, any active liquidity, any
///         liquidityNet on the boundary tick, any amount, base fee, terms and floors. Adapted from the independent
///         review's probe. beforeSwap never reverts, always answers four words within ADVISORY_GAS, and at zero depth
///         admits exactly the exact inputs within the ceiling. The block as it stood before the floor (80fbd9f, kept
///         verbatim as a fixture) runs beside it: with floors of 0 the two decide every swap identically, and a floor
///         only ever adds swaps at or under it to what the cap admits.
contract MidasSizeCapMathTest is Test {
    /// @dev v4-core's pools mapping slot (StateLibrary.POOLS_SLOT).
    uint256 internal constant POOLS_SLOT = 6;

    RawPoolManager internal pm;
    MidasSizeCapAdvisory internal cap;
    MidasSizeCapAdvisoryPrev internal prev;
    address internal root = address(0xA11CE);
    PoolId internal id = PoolId.wrap(keccak256("pool"));
    uint32 internal gasLimit;

    function setUp() public {
        pm = new RawPoolManager();
        cap = new MidasSizeCapAdvisory(IPoolManager(address(pm)));
        prev = new MidasSizeCapAdvisoryPrev(IPoolManager(address(pm)));
        gasLimit = cap.ADVISORY_GAS();
    }

    /// @notice Any state, any swap, any floors: no revert, four clean words, no surcharge or take, within
    ///         ADVISORY_GAS. At zero depth (no liquidity and no net on the boundary tick) the advice is a reject exactly
    ///         when the swap is an exact output or an exact input over its ceiling, whatever the floors.
    function testFuzz_neverRevertsOnAnyPoolState(
        uint256 spotSeed,
        uint8 placement,
        uint128 liquidity,
        int128 net,
        int256 amount,
        uint24 fee,
        uint16 bps,
        uint120 quoteIn,
        uint120 subjectIn,
        uint256 floorSeed,
        bool zeroForOne,
        bool isBuy
    ) public {
        bps = uint16(bound(bps, 1, cap.MAX_IMPACT_BPS()));
        quoteIn = uint120(bound(quoteIn, 1, cap.MAX_IN()));
        subjectIn = uint120(bound(subjectIn, 1, cap.MAX_IN()));
        (uint160 spot, int24 tick) = _place(spotSeed, placement);
        _setPool(spot, tick, liquidity, zeroForOne ? tick : tick + 1, net);
        _setTerms(bps, quoteIn, subjectIn, _pickFloor(floorSeed, quoteIn), _pickFloor(floorSeed >> 128, subjectIn));
        HookrTypes.SwapContext memory x = _ctx(isBuy, zeroForOne, amount, fee);
        (HookrTypes.Advice memory a, uint256 used) = _ask(x);
        assertLt(used, gasLimit, "gas");
        if (liquidity == 0 && net == 0) {
            uint256 ceiling = isBuy ? quoteIn : subjectIn;
            bool within = amount < 0 && amount != type(int256).min && uint256(-amount) <= ceiling;
            assertEq(a.reject, !within, "zero depth: the ceiling alone");
        }
    }

    /// @notice Floor 0 is the block as it was. On any state and swap, the current block bound with floors of 0 and
    ///         the 80fbd9f block bound with the same three terms return the same beforeSwap bytes, the same
    ///         explainSwap (allowed, reason, amountIn, limitIn) and the same maxExactInput in both directions.
    function testFuzz_floorZeroDecidesAsBefore(
        uint256 spotSeed,
        uint8 placement,
        uint128 liquidity,
        int128 net,
        int256 amount,
        uint24 fee,
        uint16 bps,
        uint120 quoteIn,
        uint120 subjectIn,
        bool zeroForOne,
        bool isBuy
    ) public {
        bps = uint16(bound(bps, 1, cap.MAX_IMPACT_BPS()));
        quoteIn = uint120(bound(quoteIn, 1, cap.MAX_IN()));
        subjectIn = uint120(bound(subjectIn, 1, cap.MAX_IN()));
        (uint160 spot, int24 tick) = _place(spotSeed, placement);
        _setPool(spot, tick, liquidity, zeroForOne ? tick : tick + 1, net);
        _setTerms(bps, quoteIn, subjectIn, 0, 0);
        _setPrevTerms(bps, quoteIn, subjectIn);
        _assertSameAsPrev(_ctx(isBuy, zeroForOne, amount, fee));
    }

    /// @notice The same, aimed at the boundaries the old block drew: exact inputs and exact outputs at and one past
    ///         the impact cap and the ceiling, at any state.
    function testFuzz_floorZeroDecidesAsBefore_atTheBoundaries(
        uint256 spotSeed,
        uint8 placement,
        uint128 liquidity,
        uint16 bps,
        uint120 ceiling,
        uint8 which,
        bool zeroForOne,
        bool isBuy
    ) public {
        bps = uint16(bound(bps, 1, cap.MAX_IMPACT_BPS()));
        ceiling = uint120(bound(ceiling, 1, cap.MAX_IN()));
        (uint160 spot, int24 tick) = _place(spotSeed, placement);
        _setPool(spot, tick, liquidity, zeroForOne ? tick : tick + 1, 0);
        _setTerms(bps, ceiling, ceiling, 0, 0);
        _setPrevTerms(bps, ceiling, ceiling);
        uint256 maxIn = prev.maxExactInput(root, id, zeroForOne, isBuy);
        uint256 out = liquidity == 0 ? 1 : _outTo(spot, _targetOf(spot, bps, zeroForOne), liquidity, zeroForOne);
        uint256[4] memory sizes = [maxIn, maxIn + 1, out, out + 1];
        uint256 size = sizes[which % 4];
        if (size == 0 || size > uint256(type(int256).max)) return;
        bool exactIn = which % 4 < 2;
        _assertSameAsPrev(_ctx(isBuy, zeroForOne, exactIn ? -int256(size) : int256(size), 3000));
    }

    /// @notice What a floor changes, on any state: it only ever admits more, never anything over the ceiling, and
    ///         everything it adds is at or under it. Against the 80fbd9f block on the same three terms: whatever that
    ///         block admits is still admitted; a swap admitted now and refused then was refused for impact, and its
    ///         input (the specified input, or the output's cost) is within the floor. For an exact input at nonzero
    ///         depth the rule is exact: admitted now if and only if admitted then or the input is at or under the
    ///         floor.
    function testFuzz_floorOnlyAddsSwapsWithinIt(
        uint256 spotSeed,
        uint8 placement,
        uint128 liquidity,
        int128 net,
        uint256 amountSeed,
        uint24 fee,
        uint16 bps,
        uint120 ceiling,
        uint256 floorSeed,
        bool zeroForOne,
        bool isBuy
    ) public {
        bps = uint16(bound(bps, 1, cap.MAX_IMPACT_BPS()));
        ceiling = uint120(bound(ceiling, 1, cap.MAX_IN()));
        uint120 floor = _pickFloor(floorSeed, ceiling);
        int256 amount = _pickAmount(amountSeed, floor, ceiling);
        (uint160 spot, int24 tick) = _place(spotSeed, placement);
        _setPool(spot, tick, liquidity, zeroForOne ? tick : tick + 1, net);
        _setTerms(bps, ceiling, ceiling, floor, floor);
        _setPrevTerms(bps, ceiling, ceiling);
        HookrTypes.SwapContext memory x = _ctx(isBuy, zeroForOne, amount, fee);
        (bool nowOk, MidasSizeCapAdvisory.Reason nowWhy, uint256 nowIn,) = cap.explainSwap(root, x);
        (bool thenOk, MidasSizeCapAdvisoryPrev.Reason thenWhy,,) = prev.explainSwap(root, x);
        (HookrTypes.Advice memory a,) = _ask(x);
        assertEq(a.reject, !nowOk, "beforeSwap agrees with explainSwap");
        if (thenOk) assertTrue(nowOk, "a floor never refuses what the cap admits");
        if (nowOk) assertLe(nowIn, ceiling, "never over the ceiling");
        if (nowOk && !thenOk) {
            assertEq(uint8(thenWhy), uint8(MidasSizeCapAdvisoryPrev.Reason.OVER_IMPACT), "added only over impact");
            assertLe(nowIn, floor, "added only within the floor");
        }
        // A refusal keeps its reason, except that the floor's costing of an exact output reaches the base-fee check
        // the impact refusal used to stop before.
        if (!nowOk && !(nowWhy == MidasSizeCapAdvisory.Reason.BAD_FEE && fee >= 1_000_000)) {
            assertEq(uint8(nowWhy), uint8(thenWhy), "same reason for a refusal");
        }
        (, uint128 depth) = _readDepth(zeroForOne);
        if (amount < 0 && amount != type(int256).min && depth != 0) {
            uint256 amountIn = uint256(-amount);
            assertEq(nowOk, thenOk || (amountIn <= floor && amountIn <= ceiling), "exact input: cap or floor");
        }
        uint256 maxNow = cap.maxExactInput(root, id, zeroForOne, isBuy);
        uint256 maxThen = prev.maxExactInput(root, id, zeroForOne, isBuy);
        assertEq(maxNow, depth == 0 || spot == 0 ? maxThen : (maxThen > floor ? maxThen : floor), "maxExactInput");
    }

    /// @notice An exact output over the impact cap, inside what active liquidity pays out before the price extreme, at
    ///         any price and depth: the floor path costs it without reverting, admits it exactly when its cost is
    ///         within the floor (and so the ceiling), and refuses it as OVER_IMPACT otherwise.
    function testFuzz_exactOutputOverTheImpactCap_floorCostsItWithoutReverting(
        uint256 spotSeed,
        uint128 liquidity,
        uint256 outSeed,
        uint16 bps,
        uint24 fee,
        uint120 floor,
        bool zeroForOne
    ) public {
        bps = uint16(bound(bps, 1, cap.MAX_IMPACT_BPS()));
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        floor = uint120(bound(floor, 1, cap.MAX_IN()));
        fee = uint24(bound(fee, 0, 999_999));
        uint160 spot = uint160(bound(spotSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        int24 tick = TickMath.getTickAtSqrtPrice(spot);
        _setPool(spot, tick, liquidity, zeroForOne ? tick : tick + 1, 0);
        _setTerms(bps, cap.MAX_IN(), cap.MAX_IN(), floor, floor);
        uint256 impactOut = _outTo(spot, _targetOf(spot, bps, zeroForOne), liquidity, zeroForOne);
        uint160 extreme = zeroForOne ? TickMath.MIN_SQRT_PRICE : TickMath.MAX_SQRT_PRICE;
        uint256 extremeOut = _outTo(spot, extreme, liquidity, zeroForOne);
        if (extremeOut <= impactOut) return;
        uint256 out = bound(outSeed, impactOut + 1, extremeOut);
        if (out > uint256(type(int256).max)) return;
        HookrTypes.SwapContext memory x = _ctx(zeroForOne, zeroForOne, int256(out), fee);
        (HookrTypes.Advice memory a, uint256 used) = _ask(x);
        assertLt(used, gasLimit, "gas");
        (bool ok, MidasSizeCapAdvisory.Reason why, uint256 costIn,) = cap.explainSwap(root, x);
        assertEq(a.reject, !ok, "agree");
        uint160 next = SqrtPriceMath.getNextSqrtPriceFromOutput(spot, liquidity, out, zeroForOne);
        uint256 c = zeroForOne
            ? SqrtPriceMath.getAmount0Delta(next, spot, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(spot, next, liquidity, true);
        c = FullMath.mulDivRoundingUp(c, 1_000_000, 1_000_000 - fee);
        assertEq(costIn, c, "the cost, as the ceiling costs it");
        assertEq(ok, c <= floor, "admitted exactly within the floor");
        if (!ok) assertEq(uint8(why), uint8(MidasSizeCapAdvisory.Reason.OVER_IMPACT), "reason");
    }

    /// @notice Exact output inside the impact budget, at any price and depth: the costing path, never reverting.
    function testFuzz_exactOutputWithinTheBudgetNeverReverts(
        uint256 spotSeed,
        uint128 liquidity,
        uint256 outSeed,
        uint16 bps,
        uint24 fee,
        bool zeroForOne
    ) public {
        bps = uint16(bound(bps, 1, cap.MAX_IMPACT_BPS()));
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        uint160 spot = uint160(bound(spotSeed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        int24 tick = TickMath.getTickAtSqrtPrice(spot);
        _setPool(spot, tick, liquidity, zeroForOne ? tick : tick + 1, 0);
        _setTerms(bps, cap.MAX_IN(), cap.MAX_IN());
        uint256 t = zeroForOne ? (uint256(spot) * (10_000 - bps)) / 10_000 : (uint256(spot) * (10_000 + bps)) / 10_000;
        if (t < TickMath.MIN_SQRT_PRICE) t = TickMath.MIN_SQRT_PRICE;
        if (t > TickMath.MAX_SQRT_PRICE) t = TickMath.MAX_SQRT_PRICE;
        uint256 impactOut = zeroForOne
            ? SqrtPriceMath.getAmount1Delta(uint160(t), spot, liquidity, false)
            : SqrtPriceMath.getAmount0Delta(spot, uint160(t), liquidity, false);
        if (impactOut == 0) return;
        uint256 out = bound(outSeed, 1, impactOut);
        if (out > uint256(type(int256).max)) out = uint256(type(int256).max);
        (, uint256 used) = _ask(_ctx(zeroForOne, zeroForOne, int256(out), fee));
        assertLt(used, gasLimit, "gas");
    }

    /// @notice The extremes: the smallest and largest prices, the most liquidity and the most negative net, the
    ///         largest amounts of both signs, both directions.
    function test_extremes() public {
        uint160[4] memory spots =
            [TickMath.MIN_SQRT_PRICE, TickMath.MIN_SQRT_PRICE + 1, TickMath.MAX_SQRT_PRICE - 1, uint160(1 << 96)];
        int256[6] memory amounts = [
            type(int256).min,
            -int256(uint256(type(uint128).max)),
            int256(-1),
            int256(1),
            int256(uint256(type(uint128).max)),
            type(int256).max
        ];
        uint256 worst;
        for (uint256 s; s < spots.length; ++s) {
            for (uint256 i; i < amounts.length; ++i) {
                for (uint256 d; d < 2; ++d) {
                    int24 tick = TickMath.getTickAtSqrtPrice(spots[s]);
                    _setPool(spots[s], tick, type(uint128).max, d == 0 ? tick : tick + 1, type(int128).min);
                    _setTerms(cap.MAX_IMPACT_BPS(), cap.MAX_IN(), cap.MAX_IN());
                    (, uint256 used) = _ask(_ctx(d == 0, d == 0, amounts[i], 999_999));
                    if (used > worst) worst = used;
                }
            }
        }
        console2.log("extremes, worst gas", worst);
    }

    function _place(uint256 seed, uint8 placement) internal pure returns (uint160 spot, int24 tick) {
        placement %= 4;
        if (placement == 0) {
            spot = uint160(bound(seed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
            tick = TickMath.getTickAtSqrtPrice(spot);
        } else if (placement == 1) {
            // On tick t's boundary with slot0 tick t: arrived from below, or opened there.
            tick = int24(bound(int256(seed % 4_000_000), TickMath.MIN_TICK, int256(TickMath.MAX_TICK) - 1));
            spot = TickMath.getSqrtPriceAtTick(tick);
        } else if (placement == 2) {
            // On tick t's boundary with slot0 tick t - 1: crossed down onto it.
            tick = int24(bound(int256(seed % 4_000_000), int256(TickMath.MIN_TICK) + 1, int256(TickMath.MAX_TICK) - 1));
            spot = TickMath.getSqrtPriceAtTick(tick);
            tick = tick - 1;
        } else {
            spot = seed % 2 == 0 ? TickMath.MIN_SQRT_PRICE : TickMath.MAX_SQRT_PRICE - 1;
            tick = TickMath.getTickAtSqrtPrice(spot);
        }
    }

    function _setPool(uint160 spot, int24 tick, uint128 liquidity, int24 netTick, int128 net) internal {
        bytes32 state = keccak256(abi.encodePacked(PoolId.unwrap(id), bytes32(POOLS_SLOT)));
        vm.store(address(pm), state, bytes32(uint256(spot) | (uint256(uint24(tick)) << 160)));
        vm.store(address(pm), bytes32(uint256(state) + 3), bytes32(uint256(liquidity)));
        bytes32 ticks = keccak256(abi.encodePacked(int256(netTick), bytes32(uint256(state) + 4)));
        vm.store(address(pm), ticks, bytes32((uint256(uint128(net)) << 128) | 1));
    }

    /// @dev Writes `root`'s binding of `id` straight into the block's storage, as bind would: the cap in the
    ///      binding's first slot, the floors in its second.
    function _setTerms(uint16 bps, uint120 quoteIn, uint120 subjectIn) internal {
        _setTerms(bps, quoteIn, subjectIn, 0, 0);
    }

    function _setTerms(uint16 bps, uint120 quoteIn, uint120 subjectIn, uint120 floorQuote, uint120 floorSubject)
        internal
    {
        bytes32 slot = _bindingSlot();
        vm.store(address(cap), slot, bytes32(uint256(bps) | (uint256(quoteIn) << 16) | (uint256(subjectIn) << 136)));
        vm.store(
            address(cap), bytes32(uint256(slot) + 1), bytes32(uint256(floorQuote) | (uint256(floorSubject) << 120))
        );
        MidasSizeCapAdvisory.Config memory c = cap.config(root, id);
        assertEq(c.maxImpactBps, bps);
        assertEq(c.maxQuoteIn, quoteIn);
        assertEq(c.maxSubjectIn, subjectIn);
        assertEq(c.floorQuoteIn, floorQuote);
        assertEq(c.floorSubjectIn, floorSubject);
    }

    /// @dev The same binding in the 80fbd9f block, whose one slot has the layout of the cap's.
    function _setPrevTerms(uint16 bps, uint120 quoteIn, uint120 subjectIn) internal {
        vm.store(
            address(prev),
            _bindingSlot(),
            bytes32(uint256(bps) | (uint256(quoteIn) << 16) | (uint256(subjectIn) << 136))
        );
        MidasSizeCapAdvisoryPrev.Config memory c = prev.config(root, id);
        assertEq(c.maxImpactBps, bps);
        assertEq(c.maxQuoteIn, quoteIn);
        assertEq(c.maxSubjectIn, subjectIn);
    }

    function _bindingSlot() internal view returns (bytes32) {
        return keccak256(abi.encode(PoolId.unwrap(id), keccak256(abi.encode(root, uint256(0)))));
    }

    /// @dev A floor up to `ceiling`, weighted to the cases that matter: none, the ceiling itself, small, or anywhere.
    function _pickFloor(uint256 seed, uint120 ceiling) internal pure returns (uint120) {
        uint256 kind = seed % 4;
        if (kind == 0) return 0;
        if (kind == 1) return ceiling;
        if (kind == 2) return uint120(bound(seed >> 8, 0, ceiling < 1e24 ? ceiling : 1e24));
        return uint120(bound(seed >> 8, 0, ceiling));
    }

    /// @dev An amount of either sign, weighted to the floor: anything at all, one either side of the floor, within the
    ///      floor, or within the ceiling.
    function _pickAmount(uint256 seed, uint256 floor, uint256 ceiling) internal pure returns (int256 amount) {
        uint256 kind = seed % 8;
        uint256 size;
        if (kind == 0) return int256(seed >> 8) * (seed & 8 == 0 ? int256(1) : int256(-1));
        if (kind < 4) size = floor + kind > 2 ? floor + kind - 2 : 1;
        else if (kind < 6) size = bound(seed >> 8, 1, floor > 0 ? floor : 1);
        else size = bound(seed >> 8, 1, ceiling);
        if (size == 0) size = 1;
        amount = seed & 8 == 0 ? int256(size) : -int256(size);
    }

    /// @dev Both blocks asked the same swap from the root: identical beforeSwap bytes, explainSwap and maxExactInput.
    function _assertSameAsPrev(HookrTypes.SwapContext memory x) internal {
        bytes memory input = abi.encodeCall(IHookrAdvisory.beforeSwap, (x));
        vm.prank(root);
        (bool okNow, bytes memory outNow) = address(cap).staticcall{gas: gasLimit}(input);
        vm.prank(root);
        (bool okThen, bytes memory outThen) = address(prev).staticcall{gas: gasLimit}(input);
        assertTrue(okNow && okThen, "both answer");
        assertEq(outNow, outThen, "beforeSwap");
        (bool a0, MidasSizeCapAdvisory.Reason r0, uint256 in0, uint256 lim0) = cap.explainSwap(root, x);
        (bool a1, MidasSizeCapAdvisoryPrev.Reason r1, uint256 in1, uint256 lim1) = prev.explainSwap(root, x);
        assertEq(a0, a1, "allowed");
        assertEq(uint8(r0), uint8(r1), "reason");
        assertEq(in0, in1, "amountIn");
        assertEq(lim0, lim1, "limitIn");
        for (uint256 d; d < 4; ++d) {
            assertEq(
                cap.maxExactInput(root, id, d % 2 == 0, d < 2),
                prev.maxExactInput(root, id, d % 2 == 0, d < 2),
                "maxExactInput"
            );
        }
    }

    /// @dev The depth the block reads for a swap in this direction, written out as _depth does it.
    function _readDepth(bool zeroForOne) internal view returns (uint160 spot, uint128 liquidity) {
        bytes32 state = keccak256(abi.encodePacked(PoolId.unwrap(id), bytes32(POOLS_SLOT)));
        uint256 slot0 = uint256(pm.extsload(state));
        spot = uint160(slot0);
        if (spot == 0) return (0, 0);
        int24 tick = int24(uint24(slot0 >> 160));
        liquidity = uint128(uint256(pm.extsload(bytes32(uint256(state) + 3))));
        int24 edge;
        if (zeroForOne) {
            edge = tick;
        } else {
            if (tick >= TickMath.MAX_TICK) return (spot, liquidity);
            edge = tick + 1;
        }
        if (spot != TickMath.getSqrtPriceAtTick(edge)) return (spot, liquidity);
        bytes32 ticks = keccak256(abi.encodePacked(int256(edge), bytes32(uint256(state) + 4)));
        int128 net = int128(int256(uint256(pm.extsload(ticks)) >> 128));
        int256 crossed = zeroForOne ? int256(uint256(liquidity)) - net : int256(uint256(liquidity)) + net;
        if (crossed <= 0) return (spot, 0);
        liquidity = crossed > int256(uint256(type(uint128).max)) ? type(uint128).max : uint128(uint256(crossed));
    }

    function _targetOf(uint160 spot, uint16 bps, bool zeroForOne) internal pure returns (uint160) {
        uint256 t = zeroForOne ? (uint256(spot) * (10_000 - bps)) / 10_000 : (uint256(spot) * (10_000 + bps)) / 10_000;
        if (t < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (t > TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE;
        return uint160(t);
    }

    function _outTo(uint160 spot, uint160 target, uint128 liquidity, bool zeroForOne) internal pure returns (uint256) {
        return zeroForOne
            ? SqrtPriceMath.getAmount1Delta(target, spot, liquidity, false)
            : SqrtPriceMath.getAmount0Delta(spot, target, liquidity, false);
    }

    function _ctx(bool isBuy, bool zeroForOne, int256 amount, uint24 fee)
        internal
        view
        returns (HookrTypes.SwapContext memory x)
    {
        x.id = id;
        x.isBuy = isBuy;
        x.zeroForOne = zeroForOne;
        x.exactInput = amount < 0;
        x.amountSpecified = amount;
        x.baseLpFeePips = fee;
    }

    /// @dev beforeSwap from the root with exactly ADVISORY_GAS: must succeed with four words, no surcharge, no take.
    function _ask(HookrTypes.SwapContext memory x) internal returns (HookrTypes.Advice memory a, uint256 used) {
        bytes memory input = abi.encodeCall(IHookrAdvisory.beforeSwap, (x));
        vm.prank(root);
        uint256 g = gasleft();
        (bool ok, bytes memory out) = address(cap).staticcall{gas: gasLimit}(input);
        used = g - gasleft();
        assertTrue(ok, "reverted");
        assertEq(out.length, 128, "four words");
        a = abi.decode(out, (HookrTypes.Advice));
        assertEq(a.lpFeeSurchargePips, 0, "surcharge");
        assertEq(a.quoteTakePips, 0, "take");
        assertEq(a.recipient, address(0), "recipient");
    }
}
