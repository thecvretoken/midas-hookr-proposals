// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title  SweepGuard
/// @author Midas
/// @notice Bounds for a contract that converts its own balance through a pool it does not
///         control and cannot read a time-weighted price from: fee conversion, buybacks,
///         buy-and-burn. These are the three sweep rails from MidasRWAHook, lifted out of the
///         hook, with the 09-22 change built in. A route has no reference until it is seeded,
///         and an unseeded route is refused. There is no adopt-spot-on-first-use path.
///
///         Each conversion, in order:
///           cooldown  one admitted conversion per route per `interval` seconds
///           band      route spot within `bandBps` of the stored reference, compared on
///                     sqrtPriceX96 (1000 bps is 10% in sqrt, about +21% / -19% in price)
///           floor     realised output at least (1 - floorBps) of the quote at spot, or of the
///                     quote at the stored reference when `anchorFloor` is set, whichever is
///                     higher
///         After an admitted conversion the reference moves toward the spot it used,
///         ref' = ((smoothing - 1) * ref + spot) / smoothing. With `maxDriftBps` set it is
///         clamped to within that distance of the seed.
///
///         The core (`next`, `minOut`, `quote`) is pure over caller-held state. A read-only
///         caller can evaluate it; whatever settles stores the returned state.
///
///         What it cannot do is tell a manipulated print from a real one. The reference only
///         learns from prices seen at conversion time, and anyone who can trigger a
///         conversion can choose that price inside the band. docs/SWEEP-GUARD.md has the
///         measured bounds, including the slow walk.
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
    }

    struct Route {
        uint160 seed; // fixed when seeded; zero means the route is not permitted
        uint160 ref; // current reference sqrtPriceX96
        uint64 lastAt; // timestamp of the last admitted conversion, 0 = never
    }

    error BadParams();
    error ZeroSeed();
    error AlreadySeeded();
    error RouteNotSeeded();
    error RouteNotInitialized();
    error TooSoon();
    error OutOfBand();
    error BelowFloor();

    function validate(Params memory p) internal pure {
        if (p.bandBps == 0 || p.bandBps >= BPS || p.floorBps >= BPS || p.smoothing == 0 || p.maxDriftBps >= BPS) {
            revert BadParams();
        }
    }

    /// @notice Seeds a route, once. Call it from a constructor over a fixed route list and
    ///         expose no setter; that is what seals the route set.
    function seal(Route storage r, uint160 sqrtPriceX96) internal {
        if (sqrtPriceX96 == 0) revert ZeroSeed();
        if (r.seed != 0) revert AlreadySeeded();
        r.seed = sqrtPriceX96;
        r.ref = sqrtPriceX96;
    }

    /// @notice Pure admission. Reverts if the conversion must not happen, otherwise returns
    ///         the route state to store. Quote the floor against `r.ref` as passed in, never
    ///         against the returned reference, which has already moved toward this spot.
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
        return Route({seed: r.seed, ref: uint160(nr), lastAt: uint64(nowTs)});
    }

    /// @notice Storage form of `next`. Returns the reference the floor must be quoted against.
    function admit(Route storage r, Params memory p, uint160 spot) internal returns (uint160 refUsed) {
        Route memory cur = r;
        Route memory upd = next(cur, p, spot, block.timestamp);
        r.ref = upd.ref;
        r.lastAt = upd.lastAt;
        return cur.ref;
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
}
