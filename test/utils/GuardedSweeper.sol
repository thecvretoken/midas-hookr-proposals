// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SweepGuard} from "../../src/libraries/SweepGuard.sol";

/// @notice Reference consumer of SweepGuard used by the tests. Holds `tokenIn`, converts all of
///         it to `tokenOut` through one of a sealed set of routes, sends the output to SINK and
///         pays the caller a bounty. The shape of a permissionless fee-conversion or buyback path.
contract GuardedSweeper is IUnlockCallback {
    using SweepGuard for SweepGuard.Route;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address public constant SINK = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BOUNTY_BPS = 50;

    IPoolManager public immutable pm;
    Currency public immutable tokenIn;
    Currency public immutable tokenOut;
    address public immutable authority;
    SweepGuard.Params internal p_;
    SweepGuard.ReseedWalls internal w_;
    mapping(PoolId => SweepGuard.Route) public routes;

    error NotAuthority();
    error NothingConvertible();

    constructor(
        IPoolManager pm_,
        Currency in_,
        Currency out_,
        PoolKey[] memory keys,
        uint160[] memory seeds,
        uint128[] memory maxIns,
        SweepGuard.Params memory params_,
        address authority_,
        SweepGuard.ReseedWalls memory walls_
    ) {
        SweepGuard.validate(params_);
        SweepGuard.validate(walls_);
        require(keys.length == seeds.length && keys.length == maxIns.length, "len");
        pm = pm_;
        tokenIn = in_;
        tokenOut = out_;
        p_ = params_;
        w_ = walls_;
        authority = authority_;
        for (uint256 i; i < keys.length; i++) {
            bool pair = (keys[i].currency0 == in_ && keys[i].currency1 == out_)
                || (keys[i].currency0 == out_ && keys[i].currency1 == in_);
            require(pair, "route pair");
            routes[keys[i].toId()].seal(seeds[i], maxIns[i]);
        }
    }

    function params() external view returns (SweepGuard.Params memory) {
        return p_;
    }

    /// @notice The recovery path, held by one authority inside the walls fixed at deploy.
    function reseed(PoolKey calldata route, uint160 target) external returns (uint160) {
        if (msg.sender != authority) revert NotAuthority();
        return routes[route.toId()].reseed(w_, target);
    }

    /// @notice Converts min(balance, capIn) and leaves any remainder for the next interval.
    function sweep(PoolKey calldata route, uint256 callerMinOut) external returns (uint256 out) {
        uint256 bal = tokenIn.balanceOfSelf();
        require(bal > 0, "empty");
        SweepGuard.Params memory p = p_;
        PoolId id = route.toId();
        uint160 spot = SweepGuard.spotOf(pm, route);
        bool zeroForOne = route.currency0 == tokenIn;
        uint256 cap = SweepGuard.capIn(routes[id], p, SweepGuard.liquidityOf(pm, route), spot, zeroForOne);
        uint160 refUsed = routes[id].admit(p, spot);

        uint256 take = bal < cap ? bal : cap;
        uint256 bounty = (take * BOUNTY_BPS) / 10_000;
        uint256 amountIn = take - bounty;
        // A zero cap means no active liquidity at spot. Convert nothing rather than let the
        // swap jump the price to the next initialized tick.
        if (amountIn == 0) revert NothingConvertible();
        uint256 floorOut = SweepGuard.minOut(p, amountIn, zeroForOne, spot, refUsed);

        out = abi.decode(pm.unlock(abi.encode(route, zeroForOne, amountIn)), (uint256));
        SweepGuard.enforce(out, floorOut);
        require(out >= callerMinOut, "caller min");
        tokenIn.transfer(msg.sender, bounty);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (PoolKey memory route, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        BalanceDelta d = pm.swap(
            route,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        pm.sync(tokenIn);
        tokenIn.transfer(address(pm), amountIn);
        pm.settle();
        int128 o = zeroForOne ? d.amount1() : d.amount0();
        uint256 out = uint256(uint128(o));
        pm.take(tokenOut, SINK, out);
        return abi.encode(out);
    }
}
