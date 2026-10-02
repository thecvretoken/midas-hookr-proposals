// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title  MidasRWAHook
/// @author Midas
/// @notice A Uniswap v4 hook for tokens launched against a real-world-asset quote token —
///         Robinhood Chain Stock Tokens (NVDA, AAPL, TSLA, ...), stablecoins, or ETH.
///
///         Steady-state 1.00% swap fee, split four ways:
///
///             LP           0.35%   concentrated liquidity providers (native v4 LP fee)
///             GOLD burn    0.35%   accrued, swapped to GOLD, sent to the dead address
///             Deployer     0.22%   whoever opened the pool with this hook
///             Royalty      0.08%   immutable template royalty
///
///         A launch window charges 8.00% decaying linearly to 1.00% over 120 seconds,
///         and sells pay 1.5x the buy fee. Every rate above is a compile-time constant
///         and the contract has no owner, no setters, and no upgrade path.
///
///         The GOLD share is a genuine buy-and-burn. Converted GOLD goes to 0x...dEaD and
///         is unrecoverable by anyone, including the author. Supply reduction accrues to
///         every GOLD holder.
///
/// @dev    FEE INTEREST DISCLOSURE: the author of this contract receives ROYALTY_SHARE of
///         swap volume on every pool that uses it, and holds GOLD, which the burn share
///         buys. Anyone deploying a pool with this hook should price that in.
///
/// @dev    UNAUDITED.
contract MidasRWAHook is BaseHook, IUnlockCallback {
    using CurrencySettler for Currency;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    // ---------------------------------------------------------------------
    // Fee constants — pips (1_000_000 = 100%)
    // ---------------------------------------------------------------------

    uint24 internal constant PIPS = 1_000_000;

    uint24 public constant STEADY_TOTAL_FEE = 10_000; // 1.00%
    uint24 public constant LP_SHARE         =  3_500; // 0.35%
    uint24 public constant BURN_SHARE       =  3_500; // 0.35%
    uint24 public constant DEPLOYER_SHARE   =  2_200; // 0.22%
    uint24 public constant ROYALTY_SHARE    =    800; // 0.08%

    uint24 public constant LAUNCH_FEE       = 80_000; // 8.00%
    uint256 public constant LAUNCH_SECONDS  =    120;

    /// @notice Hard ceiling. Nothing here can ever charge more.
    uint24 public constant MAX_TOTAL_FEE    = 80_000; // 8.00%

    /// @notice Sell-side multiplier in bps. 15_000 = 1.5x.
    uint256 public constant SELL_MULTIPLIER_BPS = 15_000;
    uint256 internal constant BPS = 10_000;

    /// @notice Bounty to whoever calls sweepAndBurn(), in pips of the swept amount.
    uint24 public constant KEEPER_BOUNTY = 5_000; // 0.50%

    // --- Sweep hardening -------------------------------------------------
    // The route pool is not this hook's own pool, so it cannot read v4 observations
    // from it. Instead the hook keeps its own slow-moving reference price, sampled
    // once per sweep and rate-limited, and refuses to trade far away from it.

    /// @notice Minimum time between sweeps of the same route.
    uint256 public constant MIN_SWEEP_INTERVAL = 1 hours;

    /// @notice Max deviation of route spot from the stored reference, in bps.
    uint256 public constant MAX_REF_DEVIATION_BPS = 1_000; // 10%

    /// @notice Max shortfall of realised output vs. the pre-swap spot quote, in bps.
    uint256 public constant MAX_SWEEP_SLIPPAGE_BPS = 300; // 3%

    /// @dev Reference update weight: ref = (3*ref + spot) / 4.
    uint256 internal constant REF_SMOOTHING = 4;

    uint256 internal constant Q96 = 0x1000000000000000000000000;

    /// @notice Burn destination. GOLD sent here is unrecoverable.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ---------------------------------------------------------------------
    // Immutables — no setters anywhere in this contract
    // ---------------------------------------------------------------------

    Currency public immutable GOLD;
    address public immutable ROYALTY_RECIPIENT;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    struct PoolConfig {
        address deployer;
        uint64 launchedAt;
        bool quoteIsZero;
        bool quoteSet;
        bool initialized;
    }

    mapping(PoolId => PoolConfig) public poolConfig;

    /// @notice Fee accrued in-kind, awaiting conversion to GOLD and burn.
    mapping(Currency => uint256) public burnBucket;

    /// @notice Royalty accrued in-kind.
    mapping(Currency => uint256) public royaltyBucket;

    /// @notice Per-pool deployer accrual, in-kind.
    mapping(PoolId => mapping(Currency => uint256)) public deployerBucket;

    /// @notice Slow-moving reference sqrt price per burn route, updated on each sweep.
    mapping(PoolId => uint160) public refSqrtPriceX96;

    /// @notice Timestamp of the last sweep through each route.
    mapping(PoolId => uint64) public lastSweepAt;

    /// @notice Burn routes permitted at deploy. Written once in the constructor and never
    ///         again — there is no setter. A sweep may only route through a pool on this
    ///         list, so a caller cannot substitute a pool they deployed and priced.
    mapping(PoolId => bool) public allowedRoute;

    // ---------------------------------------------------------------------
    // Events / Errors
    // ---------------------------------------------------------------------

    event PoolOpened(PoolId indexed id, address indexed deployer);
    event QuoteSideSet(PoolId indexed id, bool quoteIsZero);
    event FeeAccrued(PoolId indexed id, Currency indexed c, uint256 burnAmt, uint256 deployerAmt, uint256 royaltyAmt);
    event GoldBurned(Currency indexed from, uint256 amountIn, uint256 goldBurned, address indexed keeper);
    event DeployerClaimed(PoolId indexed id, Currency indexed c, uint256 amount);
    event RoyaltyClaimed(Currency indexed c, uint256 amount);

    error NotDynamicFee();
    error AlreadyInitialized();
    error NotDeployer();
    error QuoteAlreadySet();
    error QuoteNotSet();
    error NothingToSweep();
    error InsufficientGoldOut();
    error RouteNotGold();
    error RouteIsGold();
    error OnlyPoolManager();
    error SweepTooSoon();
    error RouteNotInitialized();
    error RoutePriceDeviates();
    error SweepSlippage();
    error RouteNotAllowed();

    // ---------------------------------------------------------------------

    constructor(
        IPoolManager _poolManager,
        Currency _gold,
        address _royaltyRecipient,
        PoolKey[] memory _routes,
        uint160[] memory _seeds
    )
        BaseHook(_poolManager)
    {
        require(
            LP_SHARE + BURN_SHARE + DEPLOYER_SHARE + ROYALTY_SHARE == STEADY_TOTAL_FEE,
            "share mismatch"
        );
        require(LAUNCH_FEE <= MAX_TOTAL_FEE, "launch > ceiling");
        require(!_gold.isAddressZero(), "gold zero");
        require(_royaltyRecipient != address(0), "royalty zero");

        GOLD = _gold;
        ROYALTY_RECIPIENT = _royaltyRecipient;

        // Seal the burn routes at deploy. Each permitted route must touch GOLD and must
        // carry a non-zero seed reference, so the very first sweep on it has a real anchor
        // to fail against rather than adopting whatever spot the caller presents. With no
        // setter anywhere, this list is fixed for the life of the contract.
        require(_routes.length == _seeds.length, "routes/seeds length");
        for (uint256 i = 0; i < _routes.length; i++) {
            require(_routes[i].currency0 == _gold || _routes[i].currency1 == _gold, "route not gold");
            require(_seeds[i] != 0, "seed zero");
            PoolId rid = _routes[i].toId();
            allowedRoute[rid] = true;
            refSqrtPriceX96[rid] = _seeds[i];
        }
    }

    // ---------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false, // never blocks exits
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------
    // Initialize
    // ---------------------------------------------------------------------

    function _beforeInitialize(address sender, PoolKey calldata key, uint160)
        internal
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();

        PoolId id = key.toId();
        if (poolConfig[id].initialized) revert AlreadyInitialized();

        poolConfig[id] = PoolConfig({
            deployer: sender,
            launchedAt: uint64(block.timestamp),
            quoteIsZero: false,
            quoteSet: false,
            initialized: true
        });

        emit PoolOpened(id, sender);
        return BaseHook.beforeInitialize.selector;
    }

    /// @notice One-shot declaration of which leg is the RWA quote asset.
    /// @dev    v4's initialize() carries no hookData, so this cannot live in
    ///         _beforeInitialize. Single-use, deployer-only, and swaps revert until it is
    ///         set — a pool whose sell side is undefined must not trade.
    function setQuoteSide(PoolKey calldata key, bool quoteIsZero) external {
        PoolId id = key.toId();
        PoolConfig storage cfg = poolConfig[id];

        if (msg.sender != cfg.deployer) revert NotDeployer();
        if (cfg.quoteSet) revert QuoteAlreadySet();

        cfg.quoteIsZero = quoteIsZero;
        cfg.quoteSet = true;

        emit QuoteSideSet(id, quoteIsZero);
    }

    // ---------------------------------------------------------------------
    // Swap
    // ---------------------------------------------------------------------

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolConfig memory cfg = poolConfig[id];
        if (!cfg.quoteSet) revert QuoteNotSet();

        uint24 totalFee = _currentTotalFee(cfg, params.zeroForOne);

        // Scale every bucket pro-rata so the launch window lifts the whole stack
        // rather than distorting the split.
        uint24 hookFeePips =
            uint24((uint256(totalFee) * (BURN_SHARE + DEPLOYER_SHARE + ROYALTY_SHARE)) / STEADY_TOTAL_FEE);
        uint24 lpFeePips = totalFee - hookFeePips;

        bool exactInput = params.amountSpecified < 0;
        uint256 specifiedAmount =
            exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        Currency feeCurrency = exactInput
            ? (params.zeroForOne ? key.currency0 : key.currency1)
            : (params.zeroForOne ? key.currency1 : key.currency0);

        uint256 feeAmount = (specifiedAmount * hookFeePips) / PIPS;

        if (feeAmount > 0) {
            // Hold the hook's share as an ERC-6909 claim on the PoolManager.
            poolManager.mint(address(this), feeCurrency.toId(), feeAmount);
            _accrue(id, feeCurrency, feeAmount);
        }

        // Checked cast, not a raw truncation. A silent wrap here would mint the full
        // fee as 6909 claims while returning a smaller delta to the router, leaving the
        // difference unaccounted. Reverting the swap is the correct failure.
        return (
            BaseHook.beforeSwap.selector,
            toBeforeSwapDelta(feeAmount.toInt128(), 0),
            lpFeePips | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @dev Linear decay LAUNCH_FEE -> STEADY_TOTAL_FEE, then the sell multiplier.
    function _currentTotalFee(PoolConfig memory cfg, bool zeroForOne) internal view returns (uint24) {
        uint24 base;
        uint256 elapsed = block.timestamp - cfg.launchedAt;

        if (elapsed >= LAUNCH_SECONDS) {
            base = STEADY_TOTAL_FEE;
        } else {
            uint256 span = LAUNCH_FEE - STEADY_TOTAL_FEE;
            // casting to 'uint24' is safe because the expression is bounded by
            // [STEADY_TOTAL_FEE, LAUNCH_FEE] = [10_000, 80_000], well inside uint24.
            // forge-lint: disable-next-line(unsafe-typecast)
            base = uint24(LAUNCH_FEE - (span * elapsed) / LAUNCH_SECONDS);
        }

        // A sell moves the launched token into the quote asset.
        bool isSell = cfg.quoteIsZero ? zeroForOne : !zeroForOne;
        if (isSell) {
            uint256 scaled = (uint256(base) * SELL_MULTIPLIER_BPS) / BPS;
            // casting to 'uint24' is safe because the ternary only reaches the cast
            // when scaled <= MAX_TOTAL_FEE (80_000).
            // forge-lint: disable-next-line(unsafe-typecast)
            base = scaled > MAX_TOTAL_FEE ? MAX_TOTAL_FEE : uint24(scaled);
        }

        return base;
    }

    function _accrue(PoolId id, Currency c, uint256 amount) internal {
        uint256 denom = BURN_SHARE + DEPLOYER_SHARE + ROYALTY_SHARE;
        uint256 toBurn = (amount * BURN_SHARE) / denom;
        uint256 toDeployer = (amount * DEPLOYER_SHARE) / denom;
        uint256 toRoyalty = amount - toBurn - toDeployer; // remainder absorbs rounding

        burnBucket[c] += toBurn;
        deployerBucket[id][c] += toDeployer;
        royaltyBucket[c] += toRoyalty;

        emit FeeAccrued(id, c, toBurn, toDeployer, toRoyalty);
    }

    // ---------------------------------------------------------------------
    // Buy and burn
    // ---------------------------------------------------------------------

    enum Action {
        SWEEP,
        PAYOUT
    }

    struct CallbackData {
        Action action;
        Currency c;
        PoolKey route;
        uint256 amountIn;
        uint256 payout;
        address recipient;
    }

    /// @notice Permissionless. Converts an accrued fee currency into GOLD and burns it.
    /// @dev    Batched deliberately: an inline swap on every trade would add gas to every
    ///         swap and make the buy predictable enough to sandwich every time.
    ///
    ///         Three guards make the permissionless entry point safe to leave open:
    ///           1. rate limit — one sweep per route per MIN_SWEEP_INTERVAL;
    ///           2. reference band — route spot must sit within MAX_REF_DEVIATION_BPS of
    ///              a slow reference the hook maintains itself, so moving the route pool
    ///              in one block does not create a sweepable price;
    ///           3. slippage floor — realised output must be within
    ///              MAX_SWEEP_SLIPPAGE_BPS of the pre-swap spot quote.
    ///
    ///         minGoldOut is an additional caller-supplied floor on top of these.
    function sweepAndBurn(Currency c, PoolKey calldata route, uint256 minGoldOut)
        external
        returns (uint256 goldOut)
    {
        if (c == GOLD) revert RouteIsGold();
        if (!(route.currency0 == GOLD) && !(route.currency1 == GOLD)) revert RouteNotGold();

        uint256 amount = burnBucket[c];
        if (amount == 0) revert NothingToSweep();

        PoolId routeId = route.toId();
        // The route must be one sealed at deploy. Without this a caller could name a GOLD
        // pool they deployed and priced: its PoolId is unknown here, so its reference and
        // cooldown are unset, and the sweep would trade the bucket into their pool at their
        // price. The allowlist is what makes the reference and cooldown mean anything.
        if (!allowedRoute[routeId]) revert RouteNotAllowed();
        // Guard on != 0 so the first-ever sweep is not gated by the interval. Without
        // this the check reads `block.timestamp < MIN_SWEEP_INTERVAL`, which is false on
        // any real chain but blocks the first sweep on a fresh test chain.
        uint64 last = lastSweepAt[routeId];
        // block.timestamp is safe here: the guard is hour-scale and validator drift is
        // seconds. Shaving a few seconds off a one-hour cooldown gains nothing.
        // forge-lint: disable-next-line(block-timestamp)
        if (last != 0 && block.timestamp < uint256(last) + MIN_SWEEP_INTERVAL) revert SweepTooSoon();

        (uint160 spot,,,) = poolManager.getSlot0(routeId);
        if (spot == 0) revert RouteNotInitialized();

        uint160 ref = refSqrtPriceX96[routeId];
        if (ref != 0) {
            // Compare in sqrt space; the bound is intentionally generous because a
            // sqrt-price band of N% corresponds to roughly 2N% in price terms.
            uint256 hi = (uint256(ref) * (BPS + MAX_REF_DEVIATION_BPS)) / BPS;
            uint256 lo = (uint256(ref) * (BPS - MAX_REF_DEVIATION_BPS)) / BPS;
            if (spot > hi || spot < lo) revert RoutePriceDeviates();
        }

        lastSweepAt[routeId] = uint64(block.timestamp);
        // ref = (3*ref + spot) / 4 — a single sweep can only drag the reference a
        // quarter of the way, so holding a manipulated price is expensive over time.
        // casting to 'uint160' is safe because a weighted average of two uint160 values
        // cannot exceed max(ref, spot), both of which are already uint160.
        // forge-lint: disable-next-line(unsafe-typecast)
        refSqrtPriceX96[routeId] =
            ref == 0 ? spot : uint160((uint256(ref) * (REF_SMOOTHING - 1) + uint256(spot)) / REF_SMOOTHING);

        burnBucket[c] = 0;
        uint256 bounty = (amount * KEEPER_BOUNTY) / PIPS;

        // Floor the realised output against the pre-swap spot quote.
        uint256 floorOut = (_quoteAtSpot(route, c, amount - bounty, spot) * (BPS - MAX_SWEEP_SLIPPAGE_BPS)) / BPS;

        bytes memory result = poolManager.unlock(
            abi.encode(
                CallbackData({
                    action: Action.SWEEP,
                    c: c,
                    route: route,
                    amountIn: amount - bounty,
                    payout: bounty,
                    recipient: msg.sender
                })
            )
        );

        goldOut = abi.decode(result, (uint256));
        if (goldOut < floorOut) revert SweepSlippage();
        if (goldOut < minGoldOut) revert InsufficientGoldOut();

        emit GoldBurned(c, amount - bounty, goldOut, msg.sender);
    }

    /// @dev Expected output of `amountIn` of `c` at the route's spot sqrt price.
    ///      Ignores fees and curve impact, so it is an upper bound — the slippage
    ///      band below it absorbs both.
    function _quoteAtSpot(PoolKey calldata route, Currency c, uint256 amountIn, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256)
    {
        if (route.currency0 == c) {
            // token0 -> token1: out = in * (sqrtP / 2^96)^2
            uint256 step = FullMath.mulDiv(amountIn, sqrtPriceX96, Q96);
            return FullMath.mulDiv(step, sqrtPriceX96, Q96);
        } else {
            // token1 -> token0: out = in * (2^96 / sqrtP)^2
            uint256 step = FullMath.mulDiv(amountIn, Q96, sqrtPriceX96);
            return FullMath.mulDiv(step, Q96, sqrtPriceX96);
        }
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        CallbackData memory d = abi.decode(data, (CallbackData));

        // Simple payout: redeem our 6909 claims for real tokens and forward them.
        if (d.action == Action.PAYOUT) {
            d.c.settle(poolManager, address(this), d.payout, true);
            d.c.take(poolManager, d.recipient, d.payout, false);
            return abi.encode(uint256(0));
        }

        bool zeroForOne = d.route.currency0 == d.c;

        BalanceDelta delta = poolManager.swap(
            d.route,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(d.amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // Pay the swap's input side by burning our 6909 claims.
        d.c.settle(poolManager, address(this), d.amountIn, true);

        int128 out = zeroForOne ? delta.amount1() : delta.amount0();
        // casting is safe because the branch only widens a strictly positive int128.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 goldOut = out > 0 ? uint256(uint128(out)) : 0;

        // Burn the GOLD.
        GOLD.take(poolManager, DEAD, goldOut, false);

        // Pay the keeper bounty out of the remaining claims.
        d.c.settle(poolManager, address(this), d.payout, true);
        d.c.take(poolManager, d.recipient, d.payout, false);

        return abi.encode(goldOut);
    }

    // ---------------------------------------------------------------------
    // Claims
    // ---------------------------------------------------------------------

    function claimDeployer(PoolId id, Currency c) external {
        if (msg.sender != poolConfig[id].deployer) revert NotDeployer();

        uint256 amount = deployerBucket[id][c];
        if (amount == 0) revert NothingToSweep();

        deployerBucket[id][c] = 0;
        _payout(c, amount, msg.sender);

        emit DeployerClaimed(id, c, amount);
    }

    /// @notice Permissionless push to the immutable royalty recipient.
    function claimRoyalty(Currency c) external {
        uint256 amount = royaltyBucket[c];
        if (amount == 0) revert NothingToSweep();

        royaltyBucket[c] = 0;
        _payout(c, amount, ROYALTY_RECIPIENT);

        emit RoyaltyClaimed(c, amount);
    }

    /// @dev Redeems accrued 6909 claims for real tokens and forwards them.
    function _payout(Currency c, uint256 amount, address recipient) internal {
        PoolKey memory empty;
        poolManager.unlock(
            abi.encode(
                CallbackData({
                    action: Action.PAYOUT,
                    c: c,
                    route: empty,
                    amountIn: 0,
                    payout: amount,
                    recipient: recipient
                })
            )
        );
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Total fee a swap would pay right now, for UI display.
    function quoteFee(PoolId id, bool zeroForOne) external view returns (uint24) {
        return _currentTotalFee(poolConfig[id], zeroForOne);
    }

    /// @notice Seconds remaining in the launch window.
    function launchWindowRemaining(PoolId id) external view returns (uint256) {
        uint256 elapsed = block.timestamp - poolConfig[id].launchedAt;
        return elapsed >= LAUNCH_SECONDS ? 0 : LAUNCH_SECONDS - elapsed;
    }
}
