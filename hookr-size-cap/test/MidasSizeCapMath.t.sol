// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrAdvisory} from "hookr/interfaces/IHookrAdvisory.sol";
import {MidasSizeCapAdvisory} from "../src/MidasSizeCapAdvisory.sol";

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
///         liquidityNet on the boundary tick, any amount, base fee and terms. Adapted from the independent review's
///         probe. beforeSwap never reverts, always answers four words within ADVISORY_GAS, and at zero depth admits
///         exactly the exact inputs within the ceiling.
contract MidasSizeCapMathTest is Test {
    /// @dev v4-core's pools mapping slot (StateLibrary.POOLS_SLOT).
    uint256 internal constant POOLS_SLOT = 6;

    RawPoolManager internal pm;
    MidasSizeCapAdvisory internal cap;
    address internal root = address(0xA11CE);
    PoolId internal id = PoolId.wrap(keccak256("pool"));
    uint32 internal gasLimit;

    function setUp() public {
        pm = new RawPoolManager();
        cap = new MidasSizeCapAdvisory(IPoolManager(address(pm)));
        gasLimit = cap.ADVISORY_GAS();
    }

    /// @notice Any state, any swap: no revert, four clean words, no surcharge or take, within ADVISORY_GAS. At zero
    ///         depth (no liquidity and no net on the boundary tick) the advice is a reject exactly when the swap is an
    ///         exact output or an exact input over its ceiling.
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
        bool zeroForOne,
        bool isBuy
    ) public {
        bps = uint16(bound(bps, 1, cap.MAX_IMPACT_BPS()));
        quoteIn = uint120(bound(quoteIn, 1, cap.MAX_IN()));
        subjectIn = uint120(bound(subjectIn, 1, cap.MAX_IN()));
        (uint160 spot, int24 tick) = _place(spotSeed, placement);
        _setPool(spot, tick, liquidity, zeroForOne ? tick : tick + 1, net);
        _setTerms(bps, quoteIn, subjectIn);
        HookrTypes.SwapContext memory x = _ctx(isBuy, zeroForOne, amount, fee);
        (HookrTypes.Advice memory a, uint256 used) = _ask(x);
        assertLt(used, gasLimit, "gas");
        if (liquidity == 0 && net == 0) {
            uint256 ceiling = isBuy ? quoteIn : subjectIn;
            bool within = amount < 0 && amount != type(int256).min && uint256(-amount) <= ceiling;
            assertEq(a.reject, !within, "zero depth: the ceiling alone");
        }
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

    /// @dev Writes `root`'s binding of `id` straight into the block's storage, as bind would.
    function _setTerms(uint16 bps, uint120 quoteIn, uint120 subjectIn) internal {
        bytes32 slot = keccak256(abi.encode(PoolId.unwrap(id), keccak256(abi.encode(root, uint256(0)))));
        vm.store(address(cap), slot, bytes32(uint256(bps) | (uint256(quoteIn) << 16) | (uint256(subjectIn) << 136)));
        MidasSizeCapAdvisory.Config memory c = cap.config(root, id);
        assertEq(c.maxImpactBps, bps);
        assertEq(c.maxQuoteIn, quoteIn);
        assertEq(c.maxSubjectIn, subjectIn);
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
