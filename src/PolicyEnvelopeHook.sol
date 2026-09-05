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
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title  PolicyEnvelopeHook
/// @author Midas
/// @notice Parameters that move, inside walls that cannot.
///
///         A reusable Uniswap v4 hook block that lets a launch's swap fee float within an
///         immutable envelope. The envelope, floor, ceiling, largest single step, and
///         minimum time between steps, is fixed in the constructor, checked against
///         hardcoded absolute limits, and can never be changed afterwards. The fee itself
///         is moved per pool by whoever holds that pool's *policy capsule*: an address
///         recorded when the pool is initialised, transferable in two steps, and
///         renounceable (which freezes the fee forever).
///
///         This is the bridge between Hookr's immutable-rules launches and OpenZaps-style
///         policy capsules: an agent holding the capsule may decide *when* to move the fee;
///         it can never redefine *what* it is authorised to do. No one, deployer, capsule
///         holder, author, can exceed the envelope or redirect where fees land.
///
///         Whatever the current fee is, it is split by constant fractions:
///
///             LP        70%   concentrated liquidity providers (native v4 LP fee override)
///             Deployer  25%   whoever initialised the pool with this hook
///             Royalty    5%   immutable template royalty
///
///         Failure cases: a capsule handed to a dead address cannot be recovered, which is
///         why the hand-off is two-step, the recipient must accept. A renounced capsule
///         is gone for good; the fee is frozen at its last value. A pool that is not
///         dynamic-fee is refused at initialisation because the LP share is applied via
///         the override-fee path and would otherwise silently not apply.
///
/// @dev    FEE INTEREST DISCLOSURE: the author of this contract receives ROYALTY_SHARE
///         (5%) of the swap fee on every pool that uses it, paid to ROYALTY_RECIPIENT,
///         which is immutable and cannot be rotated. Anyone deploying a pool with this
///         hook should price that in.
///
/// @dev    UNAUDITED.
contract PolicyEnvelopeHook is BaseHook, IUnlockCallback {
    using CurrencySettler for Currency;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;

    // ---------------------------------------------------------------------
    // Absolute ceilings, compile-time, apply to every envelope ever built
    // ---------------------------------------------------------------------

    uint24 internal constant PIPS = 1_000_000;

    /// @notice No envelope may reach below 0.01%.
    uint24 public constant ABS_MIN_FEE = 100;

    /// @notice No envelope may reach above 6.00%.
    uint24 public constant ABS_MAX_FEE = 60_000;

    // ---------------------------------------------------------------------
    // Fee split, constant fractions of whatever the current fee is (bps)
    // ---------------------------------------------------------------------

    uint256 internal constant BPS = 10_000;
    uint256 public constant LP_SHARE = 7_000; // 70%
    uint256 public constant DEPLOYER_SHARE = 2_500; // 25%
    uint256 public constant ROYALTY_SHARE = 500; // 5%

    // ---------------------------------------------------------------------
    // Immutable envelope, no setters anywhere in this contract
    // ---------------------------------------------------------------------

    /// @notice Lowest fee any capsule can set, pips.
    uint24 public immutable MIN_FEE;

    /// @notice Highest fee any capsule can set, pips.
    uint24 public immutable MAX_FEE;

    /// @notice Largest change a single setFee call may make, pips.
    uint24 public immutable MAX_STEP;

    /// @notice Minimum seconds between two fee changes on the same pool.
    uint256 public immutable MIN_INTERVAL;

    /// @notice Fee every new pool starts at, pips. Inside [MIN_FEE, MAX_FEE].
    uint24 public immutable DEFAULT_FEE;

    /// @notice Royalty destination. Immutable, unrotatable.
    address public immutable ROYALTY_RECIPIENT;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    struct PoolPolicy {
        address deployer; // claims the deployer share; never changes
        address capsule; // may move the fee; address(0) once renounced
        address pendingCapsule; // proposed new holder awaiting accept
        uint24 fee; // current total fee, pips
        uint64 lastChangeAt; // 0 until the first setFee
        bool initialized;
    }

    mapping(PoolId => PoolPolicy) internal _policy;

    /// @notice Per-pool deployer accrual, in-kind.
    mapping(PoolId => mapping(Currency => uint256)) public deployerBucket;

    /// @notice Royalty accrual, in-kind, across all pools.
    mapping(Currency => uint256) public royaltyBucket;

    // ---------------------------------------------------------------------
    // Events / Errors
    // ---------------------------------------------------------------------

    event PoolOpened(PoolId indexed id, address indexed deployer, address indexed capsule, uint24 fee);
    event FeeMoved(PoolId indexed id, uint24 oldFee, uint24 newFee, address indexed by);
    event CapsuleProposed(PoolId indexed id, address indexed from, address indexed to);
    event CapsuleTransferred(PoolId indexed id, address indexed from, address indexed to);
    event CapsuleRenounced(PoolId indexed id, address indexed by, uint24 frozenFee);
    event FeeAccrued(PoolId indexed id, Currency indexed c, uint256 deployerAmt, uint256 royaltyAmt);
    event DeployerClaimed(PoolId indexed id, Currency indexed c, uint256 amount);
    event RoyaltyClaimed(Currency indexed c, uint256 amount);

    error EnvelopeBelowFloor();
    error EnvelopeAboveCap();
    error EnvelopeInverted();
    error ZeroStep();
    error DefaultOutsideEnvelope();
    error RoyaltyZero();

    error NotDynamicFee();
    error AlreadyInitialized();
    error NotCapsule();
    error NotPendingCapsule();
    error CapsuleRenouncedForever();
    error FeeOutsideEnvelope();
    error StepTooLarge();
    error TooSoon();
    error NotDeployer();
    error NothingToClaim();
    error OnlyPoolManager();

    // ---------------------------------------------------------------------

    /// @param _minFee      envelope floor, pips; >= ABS_MIN_FEE
    /// @param _maxFee      envelope ceiling, pips; <= ABS_MAX_FEE
    /// @param _maxStep     largest single change per setFee, pips; > 0
    /// @param _minInterval seconds between changes on one pool
    /// @param _defaultFee  starting fee for every pool; inside the envelope
    constructor(
        IPoolManager _poolManager,
        uint24 _minFee,
        uint24 _maxFee,
        uint24 _maxStep,
        uint256 _minInterval,
        uint24 _defaultFee,
        address _royaltyRecipient
    ) BaseHook(_poolManager) {
        if (_minFee < ABS_MIN_FEE) revert EnvelopeBelowFloor();
        if (_maxFee > ABS_MAX_FEE) revert EnvelopeAboveCap();
        if (_minFee > _maxFee) revert EnvelopeInverted();
        if (_maxStep == 0) revert ZeroStep();
        if (_defaultFee < _minFee || _defaultFee > _maxFee) revert DefaultOutsideEnvelope();
        if (_royaltyRecipient == address(0)) revert RoyaltyZero();
        require(LP_SHARE + DEPLOYER_SHARE + ROYALTY_SHARE == BPS, "share mismatch");

        MIN_FEE = _minFee;
        MAX_FEE = _maxFee;
        MAX_STEP = _maxStep;
        MIN_INTERVAL = _minInterval;
        DEFAULT_FEE = _defaultFee;
        ROYALTY_RECIPIENT = _royaltyRecipient;
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

    /// @dev The initializer becomes both the deployer (claims the deployer share, forever)
    ///      and the first capsule holder (moves the fee, transferable). The fee starts at
    ///      DEFAULT_FEE, which the constructor proved is inside the envelope.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();

        PoolId id = key.toId();
        if (_policy[id].initialized) revert AlreadyInitialized();

        _policy[id] = PoolPolicy({
            deployer: sender,
            capsule: sender,
            pendingCapsule: address(0),
            fee: DEFAULT_FEE,
            lastChangeAt: 0,
            initialized: true
        });

        emit PoolOpened(id, sender, sender, DEFAULT_FEE);
        return BaseHook.beforeInitialize.selector;
    }

    // ---------------------------------------------------------------------
    // Policy capsule, the only mutable surface, and it moves nothing but the fee
    // ---------------------------------------------------------------------

    function _requireCapsule(PoolPolicy storage p) internal view {
        if (p.initialized && p.capsule == address(0)) revert CapsuleRenouncedForever();
        if (msg.sender != p.capsule) revert NotCapsule();
    }

    /// @notice Move the pool's fee. Capsule holder only.
    /// @dev    Three walls, in order: inside [MIN_FEE, MAX_FEE]; |new - old| <= MAX_STEP;
    ///         at least MIN_INTERVAL since the last move. The first move after
    ///         initialisation is not interval-gated (lastChangeAt == 0), so the guard reads
    ///         `last != 0` like MidasRWAHook's sweep cooldown.
    function setFee(PoolKey calldata key, uint24 newFee) external {
        PoolId id = key.toId();
        PoolPolicy storage p = _policy[id];
        _requireCapsule(p);

        if (newFee < MIN_FEE || newFee > MAX_FEE) revert FeeOutsideEnvelope();

        uint24 oldFee = p.fee;
        uint24 delta = newFee > oldFee ? newFee - oldFee : oldFee - newFee;
        if (delta > MAX_STEP) revert StepTooLarge();

        uint64 last = p.lastChangeAt;
        // block.timestamp is fine here: the guard is minutes-to-hours scale, validator
        // drift is seconds, and shaving seconds off a cooldown gains nothing.
        if (last != 0 && block.timestamp < uint256(last) + MIN_INTERVAL) revert TooSoon();

        p.fee = newFee;
        p.lastChangeAt = uint64(block.timestamp);

        emit FeeMoved(id, oldFee, newFee, msg.sender);
    }

    /// @notice Step 1 of 2: offer the capsule to `to`. Capsule holder only.
    /// @dev    Proposing address(0) cancels a pending offer. The current holder keeps every
    ///         right until `to` accepts, so a typo'd or dead address costs nothing.
    function transferCapsule(PoolKey calldata key, address to) external {
        PoolId id = key.toId();
        PoolPolicy storage p = _policy[id];
        _requireCapsule(p);

        p.pendingCapsule = to;
        emit CapsuleProposed(id, msg.sender, to);
    }

    /// @notice Step 2 of 2: the proposed address claims the capsule.
    function acceptCapsule(PoolKey calldata key) external {
        PoolId id = key.toId();
        PoolPolicy storage p = _policy[id];

        if (p.capsule == address(0)) revert CapsuleRenouncedForever();
        if (msg.sender == address(0) || msg.sender != p.pendingCapsule) revert NotPendingCapsule();

        address from = p.capsule;
        p.capsule = msg.sender;
        p.pendingCapsule = address(0);

        emit CapsuleTransferred(id, from, msg.sender);
    }

    /// @notice Destroy the capsule. The fee is frozen at its current value forever.
    /// @dev    Irreversible by construction: capsule becomes address(0), which no caller
    ///         can be, so setFee / transferCapsule / acceptCapsule all revert thereafter.
    function renounceCapsule(PoolKey calldata key) external {
        PoolId id = key.toId();
        PoolPolicy storage p = _policy[id];
        _requireCapsule(p);

        p.capsule = address(0);
        p.pendingCapsule = address(0);

        emit CapsuleRenounced(id, msg.sender, p.fee);
    }

    // ---------------------------------------------------------------------
    // Swap
    // ---------------------------------------------------------------------

    /// @dev LP share is applied as the v4 LP fee override; deployer + royalty share is
    ///      taken on the specified currency as a BeforeSwapDelta and held as ERC-6909
    ///      claims on the PoolManager until claimed. Pattern copied from MidasRWAHook.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        uint24 totalFee = _policy[id].fee;

        (uint24 lpFeePips, uint24 hookFeePips) = _splitPips(totalFee);

        bool exactInput = params.amountSpecified < 0;
        uint256 specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        Currency feeCurrency = exactInput
            ? (params.zeroForOne ? key.currency0 : key.currency1)
            : (params.zeroForOne ? key.currency1 : key.currency0);

        uint256 feeAmount = (specifiedAmount * hookFeePips) / PIPS;

        if (feeAmount > 0) {
            poolManager.mint(address(this), feeCurrency.toId(), feeAmount);
            _accrue(id, feeCurrency, feeAmount);
        }

        // Checked cast: a silent wrap would mint more claims than the delta returned.
        return (
            BaseHook.beforeSwap.selector,
            toBeforeSwapDelta(feeAmount.toInt128(), 0),
            lpFeePips | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @dev lp + hook == total, exactly. LP takes the floor of its share; the hook takes
    ///      the remainder so rounding never leaks a pip.
    function _splitPips(uint24 totalFee) internal pure returns (uint24 lpFeePips, uint24 hookFeePips) {
        // casting to 'uint24' is safe because the product is bounded by totalFee <= ABS_MAX_FEE.
        // forge-lint: disable-next-line(unsafe-typecast)
        lpFeePips = uint24((uint256(totalFee) * LP_SHARE) / BPS);
        hookFeePips = totalFee - lpFeePips;
    }

    /// @dev deployer + royalty == amount, exactly. Royalty absorbs the rounding remainder.
    function _accrue(PoolId id, Currency c, uint256 amount) internal {
        uint256 toDeployer = (amount * DEPLOYER_SHARE) / (DEPLOYER_SHARE + ROYALTY_SHARE);
        uint256 toRoyalty = amount - toDeployer;

        deployerBucket[id][c] += toDeployer;
        royaltyBucket[c] += toRoyalty;

        emit FeeAccrued(id, c, toDeployer, toRoyalty);
    }

    // ---------------------------------------------------------------------
    // Claims, the only two paths value leaves this contract
    // ---------------------------------------------------------------------

    /// @notice Deployer-only pull of the pool's deployer share.
    function claimDeployer(PoolId id, Currency c) external {
        if (msg.sender != _policy[id].deployer) revert NotDeployer();

        uint256 amount = deployerBucket[id][c];
        if (amount == 0) revert NothingToClaim();

        deployerBucket[id][c] = 0;
        _payout(c, amount, msg.sender);

        emit DeployerClaimed(id, c, amount);
    }

    /// @notice Permissionless push to the immutable royalty recipient. Whoever calls,
    ///         funds only ever go to ROYALTY_RECIPIENT.
    function claimRoyalty(Currency c) external {
        uint256 amount = royaltyBucket[c];
        if (amount == 0) revert NothingToClaim();

        royaltyBucket[c] = 0;
        _payout(c, amount, ROYALTY_RECIPIENT);

        emit RoyaltyClaimed(c, amount);
    }

    struct CallbackData {
        Currency c;
        uint256 amount;
        address recipient;
    }

    /// @dev Redeems accrued 6909 claims for real tokens and forwards them.
    function _payout(Currency c, uint256 amount, address recipient) internal {
        poolManager.unlock(abi.encode(CallbackData({c: c, amount: amount, recipient: recipient})));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        CallbackData memory d = abi.decode(data, (CallbackData));
        d.c.settle(poolManager, address(this), d.amount, true);
        d.c.take(poolManager, d.recipient, d.amount, false);
        return "";
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    struct Envelope {
        uint24 minFee;
        uint24 maxFee;
        uint24 maxStep;
        uint256 minInterval;
        uint24 defaultFee;
        uint256 lpShare;
        uint256 deployerShare;
        uint256 royaltyShare;
        address royaltyRecipient;
    }

    /// @notice The immutable bounds every pool on this hook lives inside.
    function envelope() external view returns (Envelope memory) {
        return Envelope({
            minFee: MIN_FEE,
            maxFee: MAX_FEE,
            maxStep: MAX_STEP,
            minInterval: MIN_INTERVAL,
            defaultFee: DEFAULT_FEE,
            lpShare: LP_SHARE,
            deployerShare: DEPLOYER_SHARE,
            royaltyShare: ROYALTY_SHARE,
            royaltyRecipient: ROYALTY_RECIPIENT
        });
    }

    /// @notice Current total fee for the pool, pips.
    function feeOf(PoolKey calldata key) external view returns (uint24) {
        return _policy[key.toId()].fee;
    }

    /// @notice Current capsule holder; address(0) if renounced or never initialised.
    function capsuleOf(PoolKey calldata key) external view returns (address) {
        return _policy[key.toId()].capsule;
    }

    /// @notice Address offered the capsule and yet to accept; address(0) if none.
    function pendingCapsuleOf(PoolKey calldata key) external view returns (address) {
        return _policy[key.toId()].pendingCapsule;
    }

    /// @notice Address entitled to the deployer share of the pool.
    function deployerOf(PoolKey calldata key) external view returns (address) {
        return _policy[key.toId()].deployer;
    }

    /// @notice Earliest timestamp at which the next setFee may succeed. 0 = now.
    function nextChangeAllowedAt(PoolKey calldata key) external view returns (uint256) {
        uint64 last = _policy[key.toId()].lastChangeAt;
        return last == 0 ? 0 : uint256(last) + MIN_INTERVAL;
    }

    /// @notice How a total fee of `totalFee` pips divides, in pips. Always sums to totalFee.
    function splitOf(uint24 totalFee) external pure returns (uint24 lp, uint24 deployer, uint24 royalty) {
        (uint24 lpPips, uint24 hookPips) = _splitPips(totalFee);
        // casting to 'uint24' is safe because hookPips <= totalFee <= ABS_MAX_FEE.
        // forge-lint: disable-next-line(unsafe-typecast)
        deployer = uint24((uint256(hookPips) * DEPLOYER_SHARE) / (DEPLOYER_SHARE + ROYALTY_SHARE));
        royalty = hookPips - deployer;
        lp = lpPips;
    }
}
