// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SweepGuard} from "../src/libraries/SweepGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @dev Calls every function in the library so each one is compiled and code-generated.
contract SweepGuardHarness {
    using SweepGuard for SweepGuard.Route;

    SweepGuard.Route internal r;

    function seal(uint160 s, uint128 m) external { r.seal(s, m); }
    function admit(SweepGuard.Params memory p, uint160 spot) external returns (uint160) { return r.admit(p, spot); }
    function reseed(SweepGuard.ReseedWalls memory w, uint160 t) external returns (uint160) { return r.reseed(w, t); }
    function status(SweepGuard.Route memory c, SweepGuard.Params memory p, uint160 s, uint256 t) external pure returns (SweepGuard.Status) { return SweepGuard.status(c, p, s, t); }
    function next(SweepGuard.Route memory c, SweepGuard.Params memory p, uint160 s, uint256 t) external pure returns (SweepGuard.Route memory) { return SweepGuard.next(c, p, s, t); }
    function preview(SweepGuard.Route memory c, SweepGuard.Params memory p, uint160 s, uint128 l, bool z, uint256 b, uint256 t) external pure returns (SweepGuard.Quote memory) { return SweepGuard.preview(c, p, s, l, z, b, t); }
    function capIn(SweepGuard.Route memory c, SweepGuard.Params memory p, uint128 l, uint160 s, bool z) external pure returns (uint256) { return SweepGuard.capIn(c, p, l, s, z); }
    function minOut(SweepGuard.Params memory p, uint256 a, bool z, uint160 s, uint160 ref) external pure returns (uint256) { return SweepGuard.minOut(p, a, z, s, ref); }
    function enforce(uint256 a, uint256 b) external pure { SweepGuard.enforce(a, b); }
    function reseedNext(SweepGuard.Route memory c, SweepGuard.ReseedWalls memory w, uint160 t, uint256 n) external pure returns (SweepGuard.Route memory) { return SweepGuard.reseedNext(c, w, t, n); }
    function quote(uint256 a, bool z, uint160 s) external pure returns (uint256) { return SweepGuard.quote(a, z, s); }
    function validateP(SweepGuard.Params memory p) external pure { SweepGuard.validate(p); }
    function validateW(SweepGuard.ReseedWalls memory w) external pure { SweepGuard.validate(w); }
    function spotOf(IPoolManager pm, PoolKey memory k) external view returns (uint160) { return SweepGuard.spotOf(pm, k); }
    function liquidityOf(IPoolManager pm, PoolKey memory k) external view returns (uint128) { return SweepGuard.liquidityOf(pm, k); }
}
