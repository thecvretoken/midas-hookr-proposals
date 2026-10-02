// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title  SweepGuard
/// @author Midas
/// @notice Bounds for a contract that converts its own balance through a pool it does not
///         control and cannot read a time-weighted price from: fee conversion, buybacks,
///         buy-and-burn. These are the three sweep rails from MidasRWAHook, lifted out of the
///         hook, with the 09-22 change built in. A route has no reference until it is sealed
///         with a seed, and an unsealed route is refused. There is no adopt-spot path.
///
///         Each conversion, in order:
///           cooldown  one admitted conversion per route per `interval` seconds
///           band      route spot within `bandBps` of the stored reference, compared on
///                     sqrtPriceX96 (1000 bps is 10% in sqrt, about +21% / -19% in price)
///           size      at most `capIn`: the route's absolute ceiling `maxIn`, and the amount
///                     whose own impact on sqrt price at the pool's active liquidity is
///                     `maxImpactBps`, whichever is lower
///           floor     realised output at least (1 - floorBps) of the quote at spot, or of the
///                     quote at the stored reference when `anchorFloor` is set, whichever is
///                     higher
///         After an admitted conversion the reference moves toward the spot it used,
///         ref' = ((smoothing - 1) * ref + spot) / smoothing. With `maxDriftBps` set it is
///         clamped to within that distance of the seed.
///
///         Size. A sandwich around one conversion pays only when the conversion is larger
///         than roughly the route fee times the route's depth, whatever the band, because
///         the attacker's two legs cost about fee x depth x push and the take is about
///         size x 2 x push. So `maxImpactBps` at or under the route fee (in bps) makes the
///         sandwich a loss. Active liquidity can be inflated just in time by anyone, which
///         is why `maxIn`, fixed at seal, is the ceiling that actually holds.
///
///         Recovery. A real move past the band or the floor stalls conversions, because the
///         reference only learns from admitted conversions. `reseed` is the way through: it
///         moves the reference and the seed toward a target by at most `maxStepBps`, no more
///         often than `minInterval`, and only on a route that has admitted nothing for
///         `minStall`. Who may call it is the consumer's decision. Spot alone cannot tell a
///         real move from a staged one, so recovery needs an authority, kept inside walls.
///
///         The core (`next`, `capIn`, `minOut`, `reseedNext`, `quote`) is pure over caller-held
///         state. A read-only caller can evaluate it; whatever settles stores the result.
/// @dev    UNAUDITED.
library SweepGuard {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    struct Params {
        uint32 interval; // seconds between admitted conversions on one route
        uint16 bandBps; // max |spot - ref| / ref on sqrtPriceX96, 0 < bandBps < 10_000
        uint16 floorBps; // max shortfall of realised output under the quote, < 10_000
        uint8 smoothing; // >= 1; 4 moves the reference a quarter of the way per conversion
        bool anchorFloor; // also quote the floor at the stored reference and take the stricter
        uint16 maxDriftBps; // 0 = unbounded; otherwise the reference stays this close to the seed
        uint16 maxImpactBps; // 0 = off; per-conversion size whose own sqrt impact stays within this
    }

    struct Route {
        uint160 seed; // anchor; zero means the route is not permitted
        uint64 lastAt; // last admitted conversion, 0 = never
        uint160 ref; // current reference sqrtPriceX96
        uint64 reseededAt; // last reseed, 0 = never
        uint128 maxIn; // absolute per-conversion ceiling, 0 = none
    }

    struct ReseedWalls {
        uint16 maxStepBps; // largest move of the reference per reseed, on sqrtPriceX96
        uint32 minInterval; // seconds between reseeds
        uint32 minStall; // seconds with no admitted conversion before a reseed is allowed
    }

    error BadParams();
    error BadWalls();
    error ZeroSeed();
    error AlreadySeeded();
    error RouteNotSeeded();
    error RouteNotInitialized();
    error TooSoon();
    error OutOfBand();
    error BelowFloor();
    error ReseedTooSoon();
    error RouteNotStalled();

    function validate(Params memory p) internal pure {
        if (
            p.bandBps == 0 || p.bandBps >= BPS || p.floorBps >= BPS || p.smoothing == 0 || p.maxDriftBps >= BPS
                || p.maxImpactBps >= BPS
        ) revert BadParams();
    }

    function validate(ReseedWalls memory w) internal pure {
        if (w.maxStepBps == 0 || w.maxStepBps >= BPS) revert BadWalls();
    }

    /// @notice Seeds a route, once, with its reference and absolute size ceiling. Call it from a
    ///         constructor over a fixed route list and expose no setter; that seals the route set.
    function seal(Route storage r, uint160 sqrtPriceX96, uint128 maxIn) internal {
        if (sqrtPriceX96 == 0) revert ZeroSeed();
        if (r.seed != 0) revert AlreadySeeded();
        r.seed = sqrtPriceX96;
        r.ref = sqrtPriceX96;
        r.maxIn = maxIn;
    }

    /// @notice Pure admission. Reverts if the conversion must not happen, otherwise returns the
    ///         route state to store. Quote the floor against `r.ref` as passed in, never against
    ///         the returned reference, which has already moved toward this spot.
    function next(Route memory r, Params memory p, uint160 spot, uint256 nowTs) internal pure returns (Route memory) {
        if (r.seed == 0) revert RouteNotSeeded();
        if (spot == 0) revert RouteNotInitialized();
        if (r.lastAt != 0 && nowTs < uint256(r.lastAt) + p.interval) revert TooSoon();

        uint256 ref = r.ref;
        if (spot > (ref * (BPS + p.bandBps)) / BPS || spot < (ref * (BPS - p.bandBps)) / BPS) revert OutOfBand();

        uint256 nr = (ref * (p.smoothing - 1) + spot) / p.smoothing;
        if (p.maxDriftBps != 0) {
            uint256 hi = (uint256(r.seed) * (BPS + p.maxDriftBps)) / BPS;
            uint256 lo = (uint256(r.seed) * (BPS - p.maxDriftBps)) / BPS;
            if (nr > hi) nr = hi;
            else if (nr < lo) nr = lo;
        }
        // nr is a weighted mean of two uint160 values, or a clamp inside one, so it fits.
        return Route({seed: r.seed, lastAt: uint64(nowTs), ref: uint160(nr), reseededAt: r.reseededAt, maxIn: r.maxIn});
    }

    /// @notice Storage form of `next`. Returns the reference the floor must be quoted against.
    function admit(Route storage r, Params memory p, uint160 spot) internal returns (uint160 refUsed) {
        Route memory cur = r;
        Route memory upd = next(cur, p, spot, block.timestamp);
        r.ref = upd.ref;
        r.lastAt = upd.lastAt;
        return cur.ref;
    }

    /// @notice Largest input for one conversion: the route's `maxIn` and the amount whose own
    ///         impact on sqrt price at `liquidity` is `maxImpactBps`, whichever is lower. Assumes
    ///         constant liquidity across the move; the floor still checks the realised fill.
    ///         Returns type(uint256).max when neither bound is set. Convert the lesser of this
    ///         and the balance, and leave the rest for the next interval.
    function capIn(Route memory r, Params memory p, uint128 liquidity, uint160 spot, bool zeroForOne)
        internal
        pure
        returns (uint256 cap)
    {
        cap = type(uint256).max;
        if (r.maxIn != 0) cap = r.maxIn;
        if (p.maxImpactBps != 0) {
            uint256 c;
            if (zeroForOne) {
                uint160 lower = uint160((uint256(spot) * (BPS - p.maxImpactBps)) / BPS);
                c = SqrtPriceMath.getAmount0Delta(lower, spot, liquidity, false);
            } else {
                uint160 upper = uint160((uint256(spot) * (BPS + p.maxImpactBps)) / BPS);
                c = SqrtPriceMath.getAmount1Delta(spot, upper, liquidity, false);
            }
            if (c < cap) cap = c;
        }
    }

    /// @notice Minimum acceptable output for `amountIn`.
    function minOut(Params memory p, uint256 amountIn, bool zeroForOne, uint160 spot, uint160 refUsed)
        internal
        pure
        returns (uint256)
    {
        uint256 q = quote(amountIn, zeroForOne, spot);
        if (p.anchorFloor) {
            uint256 qr = quote(amountIn, zeroForOne, refUsed);
            if (qr > q) q = qr;
        }
        return FullMath.mulDiv(q, BPS - p.floorBps, BPS);
    }

    function enforce(uint256 out, uint256 floorOut) internal pure {
        if (out < floorOut) revert BelowFloor();
    }

    /// @notice Pure recovery step. Moves the reference and the seed toward `target` by at most
    ///         `maxStepBps`, no sooner than `minInterval` after the last reseed, and only once the
    ///         route has admitted nothing for `minStall` (a never-converted route qualifies).
    function reseedNext(Route memory r, ReseedWalls memory w, uint160 target, uint256 nowTs)
        internal
        pure
        returns (Route memory)
    {
        if (r.seed == 0) revert RouteNotSeeded();
        if (target == 0) revert ZeroSeed();
        if (r.reseededAt != 0 && nowTs < uint256(r.reseededAt) + w.minInterval) revert ReseedTooSoon();
        if (r.lastAt != 0 && nowTs < uint256(r.lastAt) + w.minStall) revert RouteNotStalled();
        uint256 ref = r.ref;
        uint256 hi = (ref * (BPS + w.maxStepBps)) / BPS;
        uint256 lo = (ref * (BPS - w.maxStepBps)) / BPS;
        uint256 nr = target > hi ? hi : (target < lo ? lo : target);
        return Route({seed: uint160(nr), lastAt: r.lastAt, ref: uint160(nr), reseededAt: uint64(nowTs), maxIn: r.maxIn});
    }

    /// @notice Storage form of `reseedNext`. The consumer decides who may call it.
    function reseed(Route storage r, ReseedWalls memory w, uint160 target) internal returns (uint160 newRef) {
        Route memory upd = reseedNext(r, w, target, block.timestamp);
        r.seed = upd.seed;
        r.ref = upd.ref;
        r.reseededAt = upd.reseededAt;
        return upd.ref;
    }

    /// @notice Output of `amountIn` at `sqrtPriceX96`, ignoring fee and curve impact. It is an
    ///         upper bound, so the floor has to absorb the route fee and the trade's own impact.
    function quote(uint256 amountIn, bool zeroForOne, uint160 sqrtPriceX96) internal pure returns (uint256) {
        if (zeroForOne) {
            return FullMath.mulDiv(FullMath.mulDiv(amountIn, sqrtPriceX96, Q96), sqrtPriceX96, Q96);
        }
        return FullMath.mulDiv(FullMath.mulDiv(amountIn, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
    }

    function spotOf(IPoolManager pm, PoolKey memory route) internal view returns (uint160 s) {
        (s,,,) = pm.getSlot0(route.toId());
        if (s == 0) revert RouteNotInitialized();
    }

    function liquidityOf(IPoolManager pm, PoolKey memory route) internal view returns (uint128) {
        return pm.getLiquidity(route.toId());
    }
}
