// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @title  TimeWeightedExitHook
/// @author Midas
/// @notice A Uniswap v4 hook that prices the EXIT, not the entry.
///
///         Anti-snipe launch windows make the first buyers pay; nothing makes the
///         first sellers pay. This hook stamps each address on its first buy in a
///         pool and charges a sell fee that starts at EXIT_FEE_START at that address's
///         own minute zero and decays linearly to BASE_FEE over DECAY_SECONDS of
///         holding. Buys always pay BASE_FEE.
///
///         The entire sell surcharge is returned as the pool's native dynamic LP fee.
///         The hook never mints claims, never holds a balance, and has no bucket,
///         no claim function and no recipient. Flipping is not banned; it pays the
///         people who stayed. This is meant to REPLACE a supply cap, not stack on one.
///
///         Defaults: BASE_FEE 1.00% ceiling, EXIT_FEE_START 8.00%, DECAY 3 days.
///         Every rate is a constructor immutable checked against a hardcoded ceiling.
///         There is no owner, no setter, no upgrade path.
///
/// @dev    TRADER IDENTITY. beforeSwap receives `sender` = the router, not the EOA.
///         Routers that forward the real trader do so in `hookData` as
///         abi.encode(address). When hookData is empty the hook falls back to `sender`,
///         i.e. the router itself. Consequence: every user of a router that does NOT
///         forward the trader shares ONE stamp. That router's first buyer stamps it;
///         everyone who later sells through it pays a fee based on that first stamp,
///         which decays toward BASE_FEE over DECAY_SECONDS and can be lower than a
///         fresh wallet would pay. This is the permissive edge of the design and the
///         one thing an integrator must get right. A router may also lie about the
///         trader; there is no way to verify it from inside a hook. The fee is an
///         economic nudge, not an access control.
///
/// @dev    FALLBACK. An address that sells without ever having bought through this
///         pool (tokens received by transfer, airdrop, or bought via an opaque router)
///         has no stamp. It pays the FULL EXIT_FEE_START and is stamped at that moment,
///         so its clock starts on the first sell rather than never.
///
/// @dev    Fee units are pips (1_000_000 = 100%). Time is block.timestamp only.
///
/// @dev    No royalty, no deployer share, no author share. There is no fee interest to
///         disclose.
///
/// @dev    UNAUDITED.
contract TimeWeightedExitHook is BaseHook {
    using LPFeeLibrary for uint24;

    // ---------------------------------------------------------------------
    // Hardcoded ceilings, the constructor cannot exceed these
    // ---------------------------------------------------------------------

    uint24 internal constant PIPS = 1_000_000;

    /// @notice Base fee may never exceed 1.00%.
    uint24 public constant MAX_BASE_FEE = 10_000;

    /// @notice Launch-moment exit fee may never exceed 10.00%.
    uint24 public constant MAX_EXIT_FEE_START = 100_000;

    /// @notice Holding period bounds.
    uint256 public constant MIN_DECAY_SECONDS = 1 hours;
    uint256 public constant MAX_DECAY_SECONDS = 30 days;

    // ---------------------------------------------------------------------
    // Immutables, no setters anywhere in this contract
    // ---------------------------------------------------------------------

    /// @notice Fee every buy pays, and the floor every sell decays to.
    uint24 public immutable BASE_FEE;

    /// @notice Sell fee at an address's own minute zero.
    uint24 public immutable EXIT_FEE_START;

    /// @notice Holding time over which the sell fee decays from EXIT_FEE_START to BASE_FEE.
    uint256 public immutable DECAY_SECONDS;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    struct PoolConfig {
        address deployer;
        bool tokenIsZero;
        bool launchSideSet;
        bool initialized;
    }

    mapping(PoolId => PoolConfig) public poolConfig;

    /// @notice Timestamp of an address's first buy (or fallback first sell) per pool.
    ///         Zero means unstamped.
    mapping(PoolId => mapping(address => uint64)) public firstBuy;

    // ---------------------------------------------------------------------
    // Events / Errors
    // ---------------------------------------------------------------------

    event PoolOpened(PoolId indexed id, address indexed deployer);
    event LaunchSideSet(PoolId indexed id, bool tokenIsZero);
    event Stamped(PoolId indexed id, address indexed trader, uint64 timestamp);
    event ExitFeeCharged(PoolId indexed id, address indexed trader, uint24 fee, uint256 elapsed);

    error BaseFeeAboveCeiling();
    error ExitFeeAboveCeiling();
    error ExitFeeBelowBase();
    error DecayOutOfBounds();
    error NotDynamicFee();
    error AlreadyInitialized();
    error NotDeployer();
    error LaunchSideAlreadySet();
    error LaunchSideNotSet();

    // ---------------------------------------------------------------------

    constructor(IPoolManager _poolManager, uint24 _baseFee, uint24 _exitFeeStart, uint256 _decaySeconds)
        BaseHook(_poolManager)
    {
        if (_baseFee > MAX_BASE_FEE) revert BaseFeeAboveCeiling();
        if (_exitFeeStart > MAX_EXIT_FEE_START) revert ExitFeeAboveCeiling();
        if (_exitFeeStart < _baseFee) revert ExitFeeBelowBase();
        if (_decaySeconds < MIN_DECAY_SECONDS || _decaySeconds > MAX_DECAY_SECONDS) revert DecayOutOfBounds();

        BASE_FEE = _baseFee;
        EXIT_FEE_START = _exitFeeStart;
        DECAY_SECONDS = _decaySeconds;
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
            beforeRemoveLiquidity: false, // never blocks LP exits
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false, // the hook takes nothing; fee is native LP fee
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------
    // Initialize
    // ---------------------------------------------------------------------

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();

        PoolId id = key.toId();
        if (poolConfig[id].initialized) revert AlreadyInitialized();

        poolConfig[id] = PoolConfig({deployer: sender, tokenIsZero: false, launchSideSet: false, initialized: true});

        emit PoolOpened(id, sender);
        return BaseHook.beforeInitialize.selector;
    }

    /// @notice One-shot declaration of which leg is the launched token.
    /// @dev    v4's initialize() carries no hookData, so this cannot live in
    ///         _beforeInitialize. Single-use, deployer-only, and swaps revert until it is
    ///         set, a pool whose sell side is undefined must not trade (conservative
    ///         fallback: closed, not open).
    function setLaunchSide(PoolKey calldata key, bool tokenIsZero) external {
        PoolId id = key.toId();
        PoolConfig storage cfg = poolConfig[id];

        if (msg.sender != cfg.deployer) revert NotDeployer();
        if (cfg.launchSideSet) revert LaunchSideAlreadySet();

        cfg.tokenIsZero = tokenIsZero;
        cfg.launchSideSet = true;

        emit LaunchSideSet(id, tokenIsZero);
    }

    // ---------------------------------------------------------------------
    // Swap
    // ---------------------------------------------------------------------

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolConfig memory cfg = poolConfig[id];
        if (!cfg.launchSideSet) revert LaunchSideNotSet();

        address trader = _trader(sender, hookData);

        // A sell moves the launched token out of the trader's hands (token is the input).
        bool isSell = cfg.tokenIsZero ? params.zeroForOne : !params.zeroForOne;

        uint24 fee;
        if (isSell) {
            uint64 stamp = firstBuy[id][trader];
            uint256 elapsed;
            if (stamp == 0) {
                // Fresh wallet selling tokens it did not buy here. Conservative: full
                // launch-level exit fee, and the clock starts now.
                _stamp(id, trader);
                elapsed = 0;
                fee = EXIT_FEE_START;
            } else {
                elapsed = block.timestamp - stamp;
                fee = _exitFee(elapsed);
            }
            emit ExitFeeCharged(id, trader, fee, elapsed);
        } else {
            if (firstBuy[id][trader] == 0) _stamp(id, trader);
            fee = BASE_FEE;
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Router-forwarded trader in hookData, else the router itself. See the
    ///      TRADER IDENTITY note at the top of the contract.
    function _trader(address sender, bytes calldata hookData) internal pure returns (address) {
        if (hookData.length == 32) return abi.decode(hookData, (address));
        return sender;
    }

    function _stamp(PoolId id, address trader) internal {
        uint64 ts = uint64(block.timestamp);
        firstBuy[id][trader] = ts;
        emit Stamped(id, trader, ts);
    }

    /// @dev Linear decay EXIT_FEE_START -> BASE_FEE over DECAY_SECONDS, flat after.
    function _exitFee(uint256 elapsed) internal view returns (uint24) {
        if (elapsed >= DECAY_SECONDS) return BASE_FEE;
        uint256 span = EXIT_FEE_START - BASE_FEE;
        // casting to 'uint24' is safe because the expression is bounded by
        // [BASE_FEE, EXIT_FEE_START], both uint24.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(EXIT_FEE_START - (span * elapsed) / DECAY_SECONDS);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Sell fee `trader` would pay right now on this pool. An unstamped
    ///         trader is quoted the full EXIT_FEE_START (the fallback it would pay).
    function exitFeeFor(PoolKey calldata key, address trader) external view returns (uint24) {
        uint64 stamp = firstBuy[key.toId()][trader];
        if (stamp == 0) return EXIT_FEE_START;
        return _exitFee(block.timestamp - stamp);
    }

    /// @notice First-buy timestamp of `trader` on this pool; zero if unstamped.
    function firstBuyOf(PoolKey calldata key, address trader) external view returns (uint64) {
        return firstBuy[key.toId()][trader];
    }

    /// @notice The immutable schedule: (baseFee, exitFeeStart, decaySeconds).
    function feeSchedule() external view returns (uint24 baseFee, uint24 exitFeeStart, uint256 decaySeconds) {
        return (BASE_FEE, EXIT_FEE_START, DECAY_SECONDS);
    }
}
