// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrAdvisory} from "hookr/interfaces/IHookrAdvisory.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";

/// @title  MidasSizeCapAdvisory
/// @author Midas
/// @notice A Hookr advisory (IHookrAdvisory) that refuses a swap larger than its pool's size cap. The cap is
///         SweepGuard's `capIn`: the smaller of an absolute ceiling on what one swap pays in (`maxQuoteIn` for a buy,
///         `maxSubjectIn` for a sell, raw units) and the amount whose own move of sqrt price at the pool's active
///         liquidity is `maxImpactBps`. Under that sits an always-admitted floor per direction (`floorQuoteIn` for a
///         buy, `floorSubjectIn` for a sell, raw units, each at most its ceiling): a swap whose input is at or under
///         its direction's floor is admitted even when the impact cap would refuse it, so dust liquidity cannot hold
///         a pool to dust-sized swaps. The ceiling still applies to it. All five are frozen per pool at bind; a floor
///         of 0 is the cap without a floor. Over the cap the advice is `reject`; it never charges an LP surcharge and
///         never takes quote.
///
///         Declared to Hookr: phases BEFORE_SWAP only; LP-fee cap 0, quote-take cap 0 and subject-take cap 0; gas
///         limit ADVISORY_GAS, which covers `bind` and the heaviest `beforeSwap` with room to spare; fee-only; and
///         failOpen false, so the root refuses to open a fail-open pool on it (HookrLane.initializePool). `bind`
///         refuses a pool or an admission that disagrees on phases, gas or caps. It does not check the pool's fail
///         mode, because Hookr's conformance kit admits every advisory fail-open and launches a fail-open pool.
///
///         Exact input is checked on the specified amount, which is all the swap pays in, so the ceiling and the
///         floor are exact for it and the fees only make the real move smaller. Exact output is checked on the move
///         the output itself makes at active liquidity, and against the ceiling (and, when it is over the impact cap,
///         the floor) on the input that output costs at active liquidity grossed up by the pool's base LP fee,
///         rounded up. The context carries no other charge, so for exact output the ceiling and the floor are
///         approximate: the Rules' LP surcharge, quote take and dynamic fee, and the reservation the root adds to the
///         output after the advice (Auto Burn on a buy, the quote take on a sell), let an exact output pay and move
///         more than the cap by those charges. The cost also assumes the active liquidity holds across the move: an
///         output whose move crosses into thinner liquidity pays and moves more than it was costed at, and the floor
///         admits larger costed moves than the impact cap does. An exact output larger than active liquidity pays
///         out before the price reaches MIN_SQRT_PRICE or MAX_SQRT_PRICE cannot be costed and is not admitted by the
///         floor. sqrtPriceLimitX96 is not read.
///
///         Active liquidity is the PoolManager's, read at the start of the swap. A price exactly on a tick boundary
///         is read on the side the swap moves into: a swap down from a price at tick t's boundary crosses t before it
///         trades anything, so its depth is the liquidity below t (the same for up across t + 1). Like SweepGuard,
///         the impact cap assumes that depth holds across the move, so a swap whose budget reaches past the edge of
///         its range can leave the range. Liquidity added just in time inflates the impact cap; the ceilings and
///         floors do not move.
///
///         With no active liquidity at the price, a swap moves through empty ticks to the next range before it
///         trades, and its move at zero depth says nothing about what it trades. There the impact cap does not
///         apply: an exact input is bounded by the direction's ceiling alone, which is how a pool run out of its
///         range trades back in. An exact output cannot be costed at zero depth and is refused. The floor changes
///         neither: it is never above the ceiling.
///
///         The cap and the floor are per swap and the block keeps no state on the swap path, so it cannot see
///         repetition: N floor-sized swaps in one transaction move the price about as far as one swap of N times the
///         floor would, and cost about as much. Where depth is below the level at which the impact cap equals the
///         floor, each floor-sized swap moves the price more than maxImpactBps.
///
///         In a fail-closed slot a refusal reverts the swap with the root's SwapRejected. In a fail-open slot the
///         root treats any refusal from a fail-open advisory as InvalidModuleResult and reverts the swap too
///         (HookrRoot._advice); what differs is a failed call, which a fail-open slot lets through at the admitted
///         LP-fee cap, here zero.
/// @dev    UNAUDITED. No owner, no setter, no upgrade path, no DELEGATECALL. Storage is two slots per bound pool,
///         keyed by the binding root, written once in `bind`: the cap, and the floors when either is set. Every other
///         function is view or pure; the swap path reads the floors' slot only for a swap over the impact cap. The
///         only external calls are view reads: the PoolManager's storage on the swap path, and in `bind` the root's
///         PoolManager and registry and the registry's admission for this contract.
contract MidasSizeCapAdvisory is IHookrAdvisory {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice A pool's frozen cap. Two storage slots: the cap in the first, the floors in the second (left unwritten
    ///         when both are zero). `maxImpactBps` is never zero for a bound pool.
    /// @param maxImpactBps Largest move of sqrt price, in bps, one swap may make at active liquidity.
    /// @param maxQuoteIn Largest quote a buy may pay in, raw units.
    /// @param maxSubjectIn Largest subject a sell may pay in, raw units.
    /// @param floorQuoteIn Quote a buy may always pay in, whatever the impact cap says; at most maxQuoteIn. 0: none.
    /// @param floorSubjectIn Subject a sell may always pay in, whatever the impact cap says; at most maxSubjectIn.
    ///        0: none.
    struct Config {
        uint16 maxImpactBps;
        uint120 maxQuoteIn;
        uint120 maxSubjectIn;
        uint120 floorQuoteIn;
        uint120 floorSubjectIn;
    }

    /// @notice Why `explainSwap` admits or refuses a swap. NO_LIQUIDITY: an exact output at zero active liquidity.
    enum Reason {
        OK,
        NO_PRICE,
        NO_LIQUIDITY,
        OVER_CEILING,
        OVER_IMPACT,
        BAD_FEE
    }

    uint256 internal constant BPS = 10_000;
    uint256 internal constant PIPS = 1_000_000;

    /// @notice The advisory gas limit this block declares: the admission's gasLimit and every pool's
    ///         advisoryGasLimit. The root forwards it to `bind` too. `bind` refuses a lower one. Measured cold
    ///         (test_gas_everyPathUnderTheDeclaredLimit): `bind` 52,069 with floors of 0 and 74,218 with a floor set,
    ///         the heaviest `beforeSwap` path 23,669.
    uint32 public constant ADVISORY_GAS = 100_000;
    /// @notice The phases this block declares: before the swap only. `bind` refuses any other.
    uint8 public constant PHASES = HookrTypes.BEFORE_SWAP;
    /// @notice Ceiling on `maxImpactBps`: 20% in sqrt, about +44% / -36% in price.
    uint16 public constant MAX_IMPACT_BPS = 2_000;
    /// @notice Ceiling on `maxQuoteIn` and `maxSubjectIn`, the largest the packed slot holds. Each floor's ceiling is
    ///         its direction's ceiling.
    uint120 public constant MAX_IN = type(uint120).max;

    /// @notice The PoolManager whose pools this block reads. Fixed at deploy.
    IPoolManager public immutable poolManager;

    mapping(address root => mapping(PoolId => Config)) private _configs;

    /// @notice A root bound a pool.
    event Bound(
        address indexed root,
        PoolId indexed id,
        uint16 maxImpactBps,
        uint120 maxQuoteIn,
        uint120 maxSubjectIn,
        uint120 floorQuoteIn,
        uint120 floorSubjectIn
    );

    /// @notice The PoolManager has no code.
    error InvalidManager(address manager);
    /// @notice The caller already bound this pool.
    error AlreadyBound(address root, PoolId id);
    /// @notice The caller has not bound this pool.
    error UnknownPool(address root, PoolId id);
    /// @notice The bind data is out of range. 1: not exactly five words. 2: maxImpactBps zero or above
    ///         MAX_IMPACT_BPS. 3: maxQuoteIn zero or above MAX_IN. 4: maxSubjectIn zero or above MAX_IN.
    ///         5: floorQuoteIn above maxQuoteIn. 6: floorSubjectIn above maxSubjectIn.
    error InvalidTerms(uint8 code);
    /// @notice The pool or its admission does not match what this block declares. 1: the pool's hook is not the
    ///         caller. 2: the pool's advisory is not this contract. 3: phases other than BEFORE_SWAP. 4: gas limit
    ///         below ADVISORY_GAS. 5: the root's PoolManager is not this block's. 6: the admission is not an ADVISORY
    ///         admission of this contract with every cap zero.
    error InvalidPoolConfig(uint8 code);

    constructor(IPoolManager manager) {
        if (address(manager).code.length == 0) revert InvalidManager(address(manager));
        poolManager = manager;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev The type string of the five bind words.
    function configSchemaHash() external pure returns (bytes32) {
        return keccak256(
            "MidasSizeCap(uint16 maxImpactBps,uint120 maxQuoteIn,uint120 maxSubjectIn,uint120 floorQuoteIn,uint120 floorSubjectIn)"
        );
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev `data` is `abi.encode(maxImpactBps, maxQuoteIn, maxSubjectIn, floorQuoteIn, floorSubjectIn)`: the first
    ///      three nonzero and within their ceilings, each floor zero or up to its direction's ceiling. The caller must
    ///      be the pool's hook, binding with this contract as advisory, phases exactly BEFORE_SWAP, a gas limit of at
    ///      least ADVISORY_GAS and this block's PoolManager, under an ADVISORY admission of this contract whose caps
    ///      are all zero. Keyed by the caller: one write for the cap, and a second for the floors when either is set.
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data)
        external
        returns (bytes32 configHash)
    {
        Config memory c = _decode(data);
        PoolId id = key.toId();
        Config storage entry = _configs[msg.sender][id];
        if (entry.maxImpactBps != 0) revert AlreadyBound(msg.sender, id);
        if (address(key.hooks) != msg.sender) revert InvalidPoolConfig(1);
        if (pc.advisory != address(this)) revert InvalidPoolConfig(2);
        if (pc.advisoryPhases != PHASES) revert InvalidPoolConfig(3);
        if (pc.advisoryGasLimit < ADVISORY_GAS) revert InvalidPoolConfig(4);
        IHookrRoot root = IHookrRoot(msg.sender);
        if (address(root.poolManager()) != address(poolManager)) revert InvalidPoolConfig(5);
        IHookrRegistry.Admission memory a = root.registry().admission(msg.sender, address(this));
        if (
            a.kind != IHookrRegistry.Kind.ADVISORY || a.implementation != address(this) || a.caps.maxLpFeePips != 0
                || a.caps.maxQuoteTakePips != 0 || a.caps.maxSubjectTakeBps != 0
        ) revert InvalidPoolConfig(6);
        entry.maxImpactBps = c.maxImpactBps;
        entry.maxQuoteIn = c.maxQuoteIn;
        entry.maxSubjectIn = c.maxSubjectIn;
        if (c.floorQuoteIn != 0 || c.floorSubjectIn != 0) {
            entry.floorQuoteIn = c.floorQuoteIn;
            entry.floorSubjectIn = c.floorSubjectIn;
        }
        emit Bound(msg.sender, id, c.maxImpactBps, c.maxQuoteIn, c.maxSubjectIn, c.floorQuoteIn, c.floorSubjectIn);
        return keccak256(data);
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Liquidity is never restricted.
    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Rejects a swap over the cap. Never a surcharge, never a take. Reverts for a pool the caller has not
    ///      bound; a root only asks about pools it bound.
    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory advice) {
        Config storage c = _configs[msg.sender][x.id];
        if (c.maxImpactBps == 0) revert UnknownPool(msg.sender, x.id);
        (Reason reason,,) = _check(c, x);
        advice.reject = reason != Reason.OK;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Never called: `bind` accepts only the BEFORE_SWAP phase. Empty advice.
    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        pure
        returns (HookrTypes.Advice memory advice)
    {
        return advice;
    }

    /// @notice The cap `root` bound for `id`; all zero when unbound.
    function config(address root, PoolId id) external view returns (Config memory) {
        return _configs[root][id];
    }

    /// @notice What `beforeSwap` decides for `x` on `root`'s pool, and why. `amountIn` is the input the check used
    ///         (the specified input, or the grossed-up cost of the specified output) and `limitIn` the direction's
    ///         ceiling; both zero when the check stopped before them. A swap the floor admits over the impact cap is
    ///         OK; one over both is OVER_IMPACT. Reverts for an unbound pool, as beforeSwap does.
    function explainSwap(address root, HookrTypes.SwapContext calldata x)
        external
        view
        returns (bool allowed, Reason reason, uint256 amountIn, uint256 limitIn)
    {
        Config storage c = _configs[root][x.id];
        if (c.maxImpactBps == 0) revert UnknownPool(root, x.id);
        (reason, amountIn, limitIn) = _check(c, x);
        allowed = reason == Reason.OK;
    }

    /// @notice The largest exact-input swap `root`'s pool admits now in one direction: the direction's ceiling and the
    ///         larger of the floor and the input whose own move at active liquidity is maxImpactBps, whichever is
    ///         lower; the ceiling alone at zero active liquidity. Zero when unbound or uninitialized.
    function maxExactInput(address root, PoolId id, bool zeroForOne, bool isBuy) external view returns (uint256) {
        Config memory c = _configs[root][id];
        if (c.maxImpactBps == 0) return 0;
        (uint160 spot, uint128 liquidity) = _depth(id, zeroForOne);
        if (spot == 0) return 0;
        uint256 ceiling = isBuy ? c.maxQuoteIn : c.maxSubjectIn;
        if (liquidity == 0) return ceiling;
        uint256 impact = _impactIn(spot, _target(spot, c.maxImpactBps, zeroForOne), liquidity, zeroForOne);
        uint256 floor = isBuy ? c.floorQuoteIn : c.floorSubjectIn;
        if (floor > impact) impact = floor;
        return impact < ceiling ? impact : ceiling;
    }

    /// @dev The size check. Total for any context: nothing in it reverts, so a fail-open slot never sees a failure
    ///      it would let through. Returns OK or the first bound the swap breaks. The floors' slot is read only for a
    ///      swap over the impact cap, the one case a floor can change.
    function _check(Config storage c, HookrTypes.SwapContext calldata x)
        private
        view
        returns (Reason, uint256 amountIn, uint256 limitIn)
    {
        bool zeroForOne = x.zeroForOne;
        (uint160 spot, uint128 liquidity) = _depth(x.id, zeroForOne);
        if (spot == 0) return (Reason.NO_PRICE, 0, 0);
        limitIn = x.isBuy ? c.maxQuoteIn : c.maxSubjectIn;
        int256 specified = x.amountSpecified;
        if (specified < 0) {
            amountIn = specified == type(int256).min ? type(uint256).max : uint256(-specified);
            if (amountIn > limitIn) return (Reason.OVER_CEILING, amountIn, limitIn);
            // At zero depth the swap crosses empty ticks before it trades: the ceiling alone bounds it.
            if (liquidity != 0) {
                uint160 edge = _target(spot, c.maxImpactBps, zeroForOne);
                if (amountIn > _impactIn(spot, edge, liquidity, zeroForOne) && amountIn > _floor(c, x.isBuy)) {
                    return (Reason.OVER_IMPACT, amountIn, limitIn);
                }
            }
            return (Reason.OK, amountIn, limitIn);
        }
        // An exact output's cost cannot be read at zero depth.
        if (liquidity == 0) return (Reason.NO_LIQUIDITY, 0, limitIn);
        uint160 target = _target(spot, c.maxImpactBps, zeroForOne);
        uint256 amountOut = uint256(specified);
        uint256 floor;
        if (amountOut > _impactOut(spot, target, liquidity, zeroForOne)) {
            // Over the impact cap: only the floor can admit it, on its cost, and only when that cost can be read at
            // active liquidity, which needs the output within what the depth pays out before the price extreme.
            floor = _floor(c, x.isBuy);
            if (floor == 0) return (Reason.OVER_IMPACT, 0, limitIn);
            target = zeroForOne ? TickMath.MIN_SQRT_PRICE : TickMath.MAX_SQRT_PRICE;
            if (amountOut > _impactOut(spot, target, liquidity, zeroForOne)) return (Reason.OVER_IMPACT, 0, limitIn);
        }
        // Within the move to `target`, a price inside [MIN_SQRT_PRICE, MAX_SQRT_PRICE], so the next price stays
        // strictly inside (0, 2^160) and nothing reverts.
        uint160 next = SqrtPriceMath.getNextSqrtPriceFromOutput(spot, liquidity, amountOut, zeroForOne);
        amountIn = zeroForOne
            ? SqrtPriceMath.getAmount0Delta(next, spot, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(spot, next, liquidity, true);
        uint256 fee = x.baseLpFeePips;
        if (fee >= PIPS) return (Reason.BAD_FEE, amountIn, limitIn);
        amountIn = FullMath.mulDivRoundingUp(amountIn, PIPS, PIPS - fee);
        // `floor` is nonzero only for an output over the impact cap. It is at most the ceiling, so a cost within it is
        // within the ceiling too, and a cost over it stays refused for impact, as it was without a floor.
        if (floor != 0) return (amountIn > floor ? Reason.OVER_IMPACT : Reason.OK, amountIn, limitIn);
        if (amountIn > limitIn) return (Reason.OVER_CEILING, amountIn, limitIn);
        return (Reason.OK, amountIn, limitIn);
    }

    /// @dev The direction's floor, from the binding's second slot.
    function _floor(Config storage c, bool isBuy) private view returns (uint256) {
        return isBuy ? c.floorQuoteIn : c.floorSubjectIn;
    }

    /// @dev Spot and the active liquidity a swap in this direction trades against first. On a price exactly at the
    ///      boundary of the tick the swap moves into, the PoolManager crosses that tick before trading, so its
    ///      liquidityNet is applied here as the crossing would apply it. Zero spot for an uninitialized pool.
    function _depth(PoolId id, bool zeroForOne) private view returns (uint160 spot, uint128 liquidity) {
        int24 tick;
        (spot, tick,,) = poolManager.getSlot0(id);
        if (spot == 0) return (0, 0);
        liquidity = poolManager.getLiquidity(id);
        int24 edge;
        if (zeroForOne) {
            edge = tick;
        } else {
            if (tick >= TickMath.MAX_TICK) return (spot, liquidity);
            edge = tick + 1;
        }
        if (spot != TickMath.getSqrtPriceAtTick(edge)) return (spot, liquidity);
        (, int128 net) = poolManager.getTickLiquidity(id, edge);
        // Down across a tick subtracts its liquidityNet, up across it adds it. Clamped, never reverting.
        int256 crossed = zeroForOne ? int256(uint256(liquidity)) - net : int256(uint256(liquidity)) + net;
        if (crossed <= 0) return (spot, 0);
        liquidity = crossed > int256(uint256(type(uint128).max)) ? type(uint128).max : uint128(uint256(crossed));
    }

    /// @dev SweepGuard's target: spot moved by `bps` in sqrt, down for zeroForOne and up otherwise, kept inside the
    ///      PoolManager's price range so the uint160 cannot wrap.
    function _target(uint160 spot, uint16 bps, bool zeroForOne) private pure returns (uint160) {
        uint256 t = zeroForOne ? (uint256(spot) * (BPS - bps)) / BPS : (uint256(spot) * (BPS + bps)) / BPS;
        if (t < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (t > TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE;
        return uint160(t);
    }

    /// @dev The output the move to `target` pays out at `liquidity`, rounded down: token1 on the way down, token0 on
    ///      the way up.
    function _impactOut(uint160 spot, uint160 target, uint128 liquidity, bool zeroForOne)
        private
        pure
        returns (uint256)
    {
        return zeroForOne
            ? SqrtPriceMath.getAmount1Delta(target, spot, liquidity, false)
            : SqrtPriceMath.getAmount0Delta(spot, target, liquidity, false);
    }

    /// @dev SweepGuard's impact cap: the input that moves spot to `target` at `liquidity`, rounded down.
    function _impactIn(uint160 spot, uint160 target, uint128 liquidity, bool zeroForOne)
        private
        pure
        returns (uint256)
    {
        return zeroForOne
            ? SqrtPriceMath.getAmount0Delta(target, spot, liquidity, false)
            : SqrtPriceMath.getAmount1Delta(spot, target, liquidity, false);
    }

    /// @dev Exactly five words: the cap's three nonzero and within their ceilings, each floor at most its ceiling.
    function _decode(bytes calldata data) private pure returns (Config memory c) {
        if (data.length != 160) revert InvalidTerms(1);
        (uint256 impactBps, uint256 quoteIn, uint256 subjectIn, uint256 floorQuote, uint256 floorSubject) =
            abi.decode(data, (uint256, uint256, uint256, uint256, uint256));
        if (impactBps == 0 || impactBps > MAX_IMPACT_BPS) revert InvalidTerms(2);
        if (quoteIn == 0 || quoteIn > MAX_IN) revert InvalidTerms(3);
        if (subjectIn == 0 || subjectIn > MAX_IN) revert InvalidTerms(4);
        if (floorQuote > quoteIn) revert InvalidTerms(5);
        if (floorSubject > subjectIn) revert InvalidTerms(6);
        c = Config(uint16(impactBps), uint120(quoteIn), uint120(subjectIn), uint120(floorQuote), uint120(floorSubject));
    }
}
