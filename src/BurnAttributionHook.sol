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
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title  IBurnLedger
/// @author Midas
/// @notice The read side of a per-trader burn ledger. Anything that records "this address's
///         swap funded this much burn in this window" can expose this interface; Hookr's Hook
///         Blocks already log burn buys in aggregate, and this is the per-address extension.
///         The ledger is append-only by construction: an implementer MUST NOT expose any
///         function that decreases `attributedOf` or `epochTotal` for a past or present epoch.
interface IBurnLedger {
    /// @notice One ledger entry. `cumulativeEpochTotal` is the epoch total after this entry.
    event BurnAttributed(
        PoolId indexed id, uint256 indexed epoch, address indexed trader, uint256 amount, uint256 cumulativeEpochTotal
    );

    function attributedOf(PoolKey calldata key, uint256 epoch, address trader) external view returns (uint256);
    function epochTotal(PoolKey calldata key, uint256 epoch) external view returns (uint256);
    function entriesOf(PoolKey calldata key) external view returns (uint256);
    function currentEpoch() external view returns (uint256);
}

/// @title  BurnAttributionHook
/// @author Midas
/// @notice A Hookr block proposal: burn attribution with a capped loyalty rebate.
///
///         Hookr's Hook Blocks log every burn buy in aggregate. This block attributes each
///         burn contribution to the address whose swap funded it, keeps a rolling-window
///         (epoch) total per address, and rebates a slice of fees to contributors in
///         proportion to what they funded. The incinerator counter becomes a loyalty curve:
///         routing through the pool beats routing around it, and the largest contributors
///         in a window get the most back, but never enough to make a wash trade pay.
///
///         Constant 1.00% swap fee, split three ways:
///
///             LP          0.50%   concentrated liquidity providers (native v4 LP fee)
///             BURN        0.40%   accrued in the QUOTE currency, swept to BURN_SINK
///             REBATE      0.10%   accrued in the QUOTE currency, funds the epoch rebate pool
///
///         This is a block, not a template: there is no deployer share and no royalty.
///         Every rate is a compile-time constant. The contract has no owner, no setters,
///         no upgrade path. The only value-moving paths are the two documented ones , 
///         `sweepBurn` (permissionless, to the immutable sink) and `claimRebate` (to the
///         attributed trader, capped, one-shot).
///
///         Mechanism
///         ---------
///         * Fee currency. The hook is deployed for one QUOTE currency (ETH, a stable, or an
///           RWA). Pools that do not contain QUOTE cannot initialize. The hook's 0.50% is
///           always taken in QUOTE: in `beforeSwap` when QUOTE is the specified leg (the
///           amount is known up front), in `afterSwap` when it is the unspecified leg. The
///           LP 0.50% is levied by v4 on the input currency as usual.
///         * Attribution. The burn part (0.40%) of every swap is credited to the trader , 
///           `abi.encode(address)` in hookData, falling back to the swap `sender` (the
///           router) when hookData is absent, in `attributed[pool][epoch][trader]` and
///           `attributedTotal[pool][epoch]`. Epochs are fixed windows of WINDOW seconds
///           counted from the Unix epoch. The ledger is append-only: nothing decrements or
///           reassigns attribution.
///         * Rebate. Once an epoch closes, each contributor may claim once:
///               share  = rebatePool[e] * attributed[e][trader] / attributedTotal[e]
///               rebate = min(share, attributed[e][trader] * REBATE_CAP_BPS / 10_000)
///           The cap (50% of attributed burn = 0.20% of volume) is strictly below the
///           2.00% a round trip pays, so no rebate can turn a wash trade profitable.
///           Whatever a claim does not pay (cap remainder) and whatever is never claimed
///           before the claim window lapses rolls into the epoch that is open at the time.
///           Rolled value never goes to a privileged address, only back to future traders.
///         * Burn. `sweepBurn` is permissionless and sends the accrued QUOTE burn bucket to
///           BURN_SINK. In Hookr's stack the sink is the incinerator; deployed standalone it
///           is 0x...dEaD. Swap-to-token logic is the incinerator's job, not this block's.
///
///         Failure modes
///         -------------
///         * A router that does not forward the trader in hookData attributes to itself.
///           That is conservative (the router, not a stranger, holds the claim) and is the
///           router's bug to fix, not a fund-safety issue.
///         * A trader who never claims within CLAIM_EPOCHS epochs after close forfeits to the
///           open epoch's pool. Nothing is ever stuck: `rollover` is permissionless.
///         * Dust: a swap whose 0.50% rounds to zero attributes zero and pays no hook fee.
///
/// @dev    UNAUDITED.
contract BurnAttributionHook is BaseHook, IUnlockCallback, IBurnLedger {
    using CurrencySettler for Currency;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;

    // ---------------------------------------------------------------------
    // Fee constants, pips (1_000_000 = 100%)
    // ---------------------------------------------------------------------

    uint24 internal constant PIPS = 1_000_000;

    uint24 public constant TOTAL_FEE    = 10_000; // 1.00%
    uint24 public constant LP_SHARE     =  5_000; // 0.50%  native dynamic LP fee
    uint24 public constant BURN_SHARE   =  4_000; // 0.40%  hook-taken, in QUOTE
    uint24 public constant REBATE_SHARE =  1_000; // 0.10%  hook-taken, in QUOTE
    uint24 public constant HOOK_SHARE   = BURN_SHARE + REBATE_SHARE;

    /// @notice Hard ceiling. Nothing here can ever charge more than the constant total.
    uint24 public constant MAX_TOTAL_FEE = 10_000; // 1.00%

    /// @notice Rebate cap as a fraction of the trader's attributed burn, in bps.
    ///         5_000 = 50% of 0.40% = 0.20% of volume, versus 2.00% paid on a round trip.
    uint256 public constant REBATE_CAP_BPS = 5_000;
    uint256 internal constant BPS = 10_000;

    /// @notice Bounds on the epoch length, enforced in the constructor.
    uint256 public constant MIN_WINDOW = 1 days;
    uint256 public constant MAX_WINDOW = 30 days;
    uint256 public constant DEFAULT_WINDOW = 7 days;

    /// @notice How many epochs after an epoch closes its rebates stay claimable.
    ///         Epoch e is claimable while e < currentEpoch() <= e + CLAIM_EPOCHS.
    uint256 public constant CLAIM_EPOCHS = 2;

    // ---------------------------------------------------------------------
    // Immutables, no setters anywhere in this contract
    // ---------------------------------------------------------------------

    /// @notice The currency every hook fee is denominated in and every pool must contain.
    Currency public immutable QUOTE;

    /// @notice Where swept burn goes. 0x...dEaD standalone; the incinerator in Hookr's stack.
    address public immutable BURN_SINK;

    /// @notice Epoch length in seconds. Between MIN_WINDOW and MAX_WINDOW.
    uint256 public immutable WINDOW;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    struct PoolConfig {
        bool initialized;
        bool quoteIsZero;
    }

    mapping(PoolId => PoolConfig) public poolConfig;

    /// @notice Burn accrued in QUOTE and not yet swept, per pool.
    mapping(PoolId => uint256) public burnBucket;

    /// @notice Total QUOTE ever swept to BURN_SINK, per pool.
    mapping(PoolId => uint256) public burnedCumulative;

    /// @notice Monotonic ledger entry counter, per pool.
    mapping(PoolId => uint256) public entries;

    /// @notice Burn funded by `trader` in `epoch`. Append-only.
    mapping(PoolId => mapping(uint256 => mapping(address => uint256))) public attributed;

    /// @notice Sum of `attributed` over all traders in `epoch`. Append-only.
    mapping(PoolId => mapping(uint256 => uint256)) public attributedTotal;

    /// @notice Rebate accrued for `epoch`. Frozen once the epoch closes.
    mapping(PoolId => mapping(uint256 => uint256)) public rebatePool;

    /// @notice Rebate paid out of or rolled forward from `epoch`'s pool. Never exceeds rebatePool.
    mapping(PoolId => mapping(uint256 => uint256)) public rebateOut;

    /// @notice One-shot claim marker per (epoch, trader).
    mapping(PoolId => mapping(uint256 => mapping(address => bool))) public claimed;

    // ---------------------------------------------------------------------
    // Events / Errors
    // ---------------------------------------------------------------------

    event PoolOpened(PoolId indexed id, bool quoteIsZero);
    event FeeAccrued(PoolId indexed id, uint256 indexed epoch, address indexed trader, uint256 burnAmt, uint256 rebateAmt);
    event BurnSwept(PoolId indexed id, uint256 amount, uint256 cumulative);
    event RebateClaimed(PoolId indexed id, uint256 indexed epoch, address indexed trader, uint256 paid, uint256 rolledForward);
    event RebateRolled(PoolId indexed id, uint256 indexed fromEpoch, uint256 indexed toEpoch, uint256 amount);

    error NotDynamicFee();
    error PoolLacksQuote();
    error AlreadyInitialized();
    error NothingToSweep();
    error EpochOpen();
    error EpochExpired();
    error EpochNotExpired();
    error AlreadyClaimed();
    error NothingToClaim();
    error NothingToRoll();
    error OnlyPoolManager();

    // ---------------------------------------------------------------------

    constructor(IPoolManager _poolManager, Currency _quote, address _burnSink, uint256 _window)
        BaseHook(_poolManager)
    {
        require(LP_SHARE + BURN_SHARE + REBATE_SHARE == TOTAL_FEE, "share mismatch");
        require(TOTAL_FEE <= MAX_TOTAL_FEE, "total > ceiling");
        require(REBATE_CAP_BPS < BPS, "cap >= 100%");
        // The cap must sit strictly below what a round trip pays: 2 * TOTAL_FEE of volume
        // versus BURN_SHARE * cap of volume.
        require(uint256(BURN_SHARE) * REBATE_CAP_BPS < uint256(TOTAL_FEE) * 2 * BPS, "cap not wash-safe");
        require(_burnSink != address(0), "sink zero");
        require(_window >= MIN_WINDOW && _window <= MAX_WINDOW, "window out of bounds");

        QUOTE = _quote;
        BURN_SINK = _burnSink;
        WINDOW = _window;
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
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------
    // Initialize
    // ---------------------------------------------------------------------

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();

        bool quoteIsZero;
        if (key.currency0 == QUOTE) quoteIsZero = true;
        else if (key.currency1 == QUOTE) quoteIsZero = false;
        else revert PoolLacksQuote();

        PoolId id = key.toId();
        if (poolConfig[id].initialized) revert AlreadyInitialized();
        poolConfig[id] = PoolConfig({initialized: true, quoteIsZero: quoteIsZero});

        emit PoolOpened(id, quoteIsZero);
        return BaseHook.beforeInitialize.selector;
    }

    // ---------------------------------------------------------------------
    // Swap
    // ---------------------------------------------------------------------

    /// @dev True when the specified leg of the swap is QUOTE, i.e. the hook fee can be
    ///      taken here with a known amount. Otherwise it is taken in afterSwap.
    function _quoteIsSpecified(bool quoteIsZero, SwapParams calldata params) internal pure returns (bool) {
        bool exactInput = params.amountSpecified < 0;
        // exact input:  specified = input  = zeroForOne ? c0 : c1
        // exact output: specified = output = zeroForOne ? c1 : c0
        return exactInput ? (params.zeroForOne == quoteIsZero) : (params.zeroForOne != quoteIsZero);
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolConfig memory cfg = poolConfig[id];

        uint256 feeAmount;
        if (_quoteIsSpecified(cfg.quoteIsZero, params)) {
            uint256 specified = params.amountSpecified < 0
                ? uint256(-params.amountSpecified)
                : uint256(params.amountSpecified);
            feeAmount = (specified * HOOK_SHARE) / PIPS;
            if (feeAmount > 0) {
                poolManager.mint(address(this), QUOTE.toId(), feeAmount);
                _accrue(id, _trader(sender, hookData), feeAmount);
            }
        }

        // Checked cast: a silent wrap would mint claims the router is not charged for.
        return (
            BaseHook.beforeSwap.selector,
            toBeforeSwapDelta(feeAmount.toInt128(), 0),
            LP_SHARE | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId id = key.toId();
        PoolConfig memory cfg = poolConfig[id];
        if (_quoteIsSpecified(cfg.quoteIsZero, params)) return (BaseHook.afterSwap.selector, 0);

        // The unspecified leg is currency1 iff (zeroForOne == exactInput).
        bool exactInput = params.amountSpecified < 0;
        int128 unspecified = (params.zeroForOne == exactInput) ? delta.amount1() : delta.amount0();
        // casting to 'uint128' is safe because the branch only widens the magnitude of an
        // int128 (|x| <= 2^127), which fits in uint128 without truncation.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 magnitude = unspecified < 0 ? uint256(uint128(-unspecified)) : uint256(uint128(unspecified));

        uint256 feeAmount = (magnitude * HOOK_SHARE) / PIPS;
        if (feeAmount > 0) {
            poolManager.mint(address(this), QUOTE.toId(), feeAmount);
            _accrue(id, _trader(sender, hookData), feeAmount);
        }

        // Positive: the hook takes this much of the trader's unspecified leg.
        return (BaseHook.afterSwap.selector, feeAmount.toInt128());
    }

    /// @dev The address credited for this swap's burn. Routers pass abi.encode(trader);
    ///      absent that, the router itself is credited. Never a third party.
    function _trader(address sender, bytes calldata hookData) internal pure returns (address trader) {
        if (hookData.length == 32) {
            trader = abi.decode(hookData, (address));
            if (trader != address(0)) return trader;
        }
        return sender;
    }

    /// @dev Splits a hook fee into burn + rebate and appends the burn to the ledger.
    ///      Remainder rounds to the rebate pool so burn + rebate == fee to the wei.
    function _accrue(PoolId id, address trader, uint256 feeAmount) internal {
        uint256 toBurn = (feeAmount * BURN_SHARE) / HOOK_SHARE;
        uint256 toRebate = feeAmount - toBurn;
        uint256 epoch = currentEpoch();

        burnBucket[id] += toBurn;
        rebatePool[id][epoch] += toRebate;

        attributed[id][epoch][trader] += toBurn;
        uint256 total = attributedTotal[id][epoch] + toBurn;
        attributedTotal[id][epoch] = total;
        entries[id] += 1;

        emit BurnAttributed(id, epoch, trader, toBurn, total);
        emit FeeAccrued(id, epoch, trader, toBurn, toRebate);
    }

    // ---------------------------------------------------------------------
    // Burn sweep
    // ---------------------------------------------------------------------

    /// @notice Permissionless. Sends the whole accrued burn bucket to BURN_SINK.
    /// @dev    The rebate pool is untouched: it lives in separate accounting and the
    ///         sweep only ever moves `burnBucket[id]`.
    function sweepBurn(PoolKey calldata key) external returns (uint256 amount) {
        PoolId id = key.toId();
        amount = burnBucket[id];
        if (amount == 0) revert NothingToSweep();

        burnBucket[id] = 0;
        burnedCumulative[id] += amount;
        _payout(amount, BURN_SINK);

        emit BurnSwept(id, amount, burnedCumulative[id]);
    }

    // ---------------------------------------------------------------------
    // Rebates
    // ---------------------------------------------------------------------

    /// @notice Claim the caller's rebate for a closed epoch. One-shot per (trader, epoch).
    /// @dev    The cap remainder rolls into the currently open epoch's pool. Only closed
    ///         epochs can be claimed, so `rebatePool[epoch]` is frozen before any claim
    ///         reads it and every claimant sees the same denominator.
    function claimRebate(PoolKey calldata key, uint256 epoch) external returns (uint256 paid) {
        PoolId id = key.toId();
        uint256 now_ = currentEpoch();
        if (epoch >= now_) revert EpochOpen();
        if (now_ > epoch + CLAIM_EPOCHS) revert EpochExpired();
        if (claimed[id][epoch][msg.sender]) revert AlreadyClaimed();

        (uint256 share, uint256 rebate) = _rebateFor(id, epoch, msg.sender);
        if (share == 0) revert NothingToClaim();

        claimed[id][epoch][msg.sender] = true;
        rebateOut[id][epoch] += share;

        uint256 remainder = share - rebate;
        if (remainder > 0) {
            rebatePool[id][now_] += remainder;
            emit RebateRolled(id, epoch, now_, remainder);
        }
        if (rebate > 0) _payout(rebate, msg.sender);

        emit RebateClaimed(id, epoch, msg.sender, rebate, remainder);
        return rebate;
    }

    /// @notice Permissionless. Once an epoch's claim window has lapsed, moves whatever was
    ///         never claimed into the currently open epoch's pool.
    function rollover(PoolKey calldata key, uint256 epoch) external returns (uint256 amount) {
        PoolId id = key.toId();
        uint256 now_ = currentEpoch();
        if (now_ <= epoch + CLAIM_EPOCHS) revert EpochNotExpired();

        amount = rebatePool[id][epoch] - rebateOut[id][epoch];
        if (amount == 0) revert NothingToRoll();

        rebateOut[id][epoch] += amount;
        rebatePool[id][now_] += amount;

        emit RebateRolled(id, epoch, now_, amount);
    }

    /// @dev (pro-rata share, capped rebate). Share is what leaves the epoch's pool; the
    ///      difference rolls forward.
    function _rebateFor(PoolId id, uint256 epoch, address trader)
        internal
        view
        returns (uint256 share, uint256 rebate)
    {
        uint256 mine = attributed[id][epoch][trader];
        uint256 total = attributedTotal[id][epoch];
        if (mine == 0 || total == 0) return (0, 0);

        share = (rebatePool[id][epoch] * mine) / total;
        uint256 cap = (mine * REBATE_CAP_BPS) / BPS;
        rebate = share > cap ? cap : share;
    }

    // ---------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------

    /// @dev Redeems accrued ERC-6909 claims for real QUOTE and forwards them.
    function _payout(uint256 amount, address recipient) internal {
        poolManager.unlock(abi.encode(amount, recipient));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (uint256 amount, address recipient) = abi.decode(data, (uint256, address));
        QUOTE.settle(poolManager, address(this), amount, true);
        QUOTE.take(poolManager, recipient, amount, false);
        return "";
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IBurnLedger
    function currentEpoch() public view returns (uint256) {
        // block.timestamp is safe here: epochs are day-scale and validator drift is seconds.
        return block.timestamp / WINDOW;
    }

    /// @inheritdoc IBurnLedger
    function attributedOf(PoolKey calldata key, uint256 epoch, address trader) external view returns (uint256) {
        return attributed[key.toId()][epoch][trader];
    }

    /// @inheritdoc IBurnLedger
    function epochTotal(PoolKey calldata key, uint256 epoch) external view returns (uint256) {
        return attributedTotal[key.toId()][epoch];
    }

    /// @inheritdoc IBurnLedger
    function entriesOf(PoolKey calldata key) external view returns (uint256) {
        return entries[key.toId()];
    }

    /// @notice Rebate accrued for `epoch` (frozen once the epoch closes).
    function rebatePoolOf(PoolKey calldata key, uint256 epoch) external view returns (uint256) {
        return rebatePool[key.toId()][epoch];
    }

    /// @notice Rebate still held for `epoch`: pool minus everything paid or rolled.
    function rebateOutstanding(PoolKey calldata key, uint256 epoch) external view returns (uint256) {
        PoolId id = key.toId();
        return rebatePool[id][epoch] - rebateOut[id][epoch];
    }

    /// @notice What `claimRebate(key, epoch)` would pay `trader` right now. Zero if the
    ///         epoch is open, expired, or already claimed.
    function claimableRebate(PoolKey calldata key, uint256 epoch, address trader) external view returns (uint256) {
        PoolId id = key.toId();
        uint256 now_ = currentEpoch();
        if (epoch >= now_ || now_ > epoch + CLAIM_EPOCHS) return 0;
        if (claimed[id][epoch][trader]) return 0;
        (, uint256 rebate) = _rebateFor(id, epoch, trader);
        return rebate;
    }
}
