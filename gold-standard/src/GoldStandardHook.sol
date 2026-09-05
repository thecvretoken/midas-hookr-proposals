// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

/// @title Gold Standard Hook
/// @notice A reusable Uniswap v4 hook template for pools quoted in a fixed
///         RESERVE asset — PAXG, in the deployment this was written for, so
///         that an adopting token trades against gold rather than against ETH.
///
///         ANY ERC-20 may adopt it. Open a pool whose pair includes RESERVE,
///         and every exact-input swap pays a fee denominated in RESERVE,
///         in both directions:
///
///           RESERVE is the input  -> fee taken from the input  (beforeSwap)
///           RESERVE is the output -> fee taken from the output (afterSwap)
///
///         So both the template author and the adopter are paid in the reserve
///         asset, never in the adopting token.
///
/// @dev    CURRENCY ORDERING. v4 sorts pool currencies by address, so whether
///         RESERVE lands in currency0 or currency1 depends entirely on the
///         adopting token's address. PAXG sits at ~78% of the address space,
///         meaning roughly four out of five tokens sort BELOW it. A hook that
///         assumed RESERVE == currency0 would reject most of them. This one
///         records the slot per pool at initialize and reads it on every swap.
///
/// @dev    FEE SPLIT. The RESERVE fee divides into:
///           ROYALTY_SHARE          -> ROYALTY_RECIPIENT (this template's
///                                     author, identical for every pool)
///           FEE - ROYALTY_SHARE    -> that pool's adopter
///         Rounding dust goes to the adopter, not the royalty.
///
/// @dev    FEE UNITS are hundredths of a bip (1_000_000 = 100%), matching
///         Uniswap's own LP-fee units, so HOOK fee and pool LP fee are
///         directly comparable and can be summed to a target total cost.
///
/// @dev    ADOPTER IDENTITY. Whoever calls PoolManager.initialize for a pool
///         becomes that pool's fee recipient, permanently. There is no setter.
///         Initialize DIRECTLY from the wallet that should be paid — through a
///         router or factory and that contract is the recipient instead, with
///         the fees unreachable. Check adopterOf(poolId) before adding
///         liquidity.
///
/// @dev    ANTI-SNIPE is optional. Deploy with SNIPE_EXTRA = 0 to disable it
///         entirely. When enabled it surcharges BUYS of the adopting token
///         only — never sells, which would make it a honeypot — decaying
///         linearly to zero across a wall-clock window from pool opening.
///
/// @dev    NOT AUDITED.
contract GoldStandardHook is IHooks {
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    error ExactOutputNotSupported();
    error NativeCurrencyNotSupported();
    error NotPoolManager();
    error HookNotImplemented();
    error Reentrancy();
    error InvalidAdopter();
    error PoolMustIncludeReserve();
    error TokenNotSupported();
    error TokenNotERC20();

    string public constant NAME = "Gold Standard Hook";

    string public constant DESCRIPTION =
        "Pools quoted in a fixed reserve asset. Every exact-input swap pays a "
        "fee denominated in the reserve, split between this template's author "
        "and the pool's adopter. An optional launch surcharge applies to buys "
        "only and decays to zero; sells are never surcharged or blocked. "
        "Fee-on-transfer and rebasing tokens are rejected.";

    /// @notice The quote asset every adopting pool must include.
    Currency public immutable RESERVE;

    /// @notice Fixed royalty recipient across every adopting pool.
    /// @dev    IMMUTABLE AND UNROTATABLE by design — a mutable fee recipient
    ///         is the standard rug vector. The cost: if this key is lost the
    ///         royalty is stranded with no recovery, and if it is compromised
    ///         every adopting pool's royalty flows to the attacker forever.
    address public immutable ROYALTY_RECIPIENT;

    /// @notice Total reserve-side fee, in hundredths of a bip.
    uint256 public immutable FEE;

    /// @notice Portion of FEE routed to ROYALTY_RECIPIENT.
    uint256 public immutable ROYALTY_SHARE;

    /// @notice Length of the launch window in SECONDS from pool opening.
    /// @dev    Wall-clock, not blocks: block rate is not a stable unit across
    ///         chains or over time, so a block count would silently redefine
    ///         the window.
    uint256 public immutable SNIPE_SECONDS;

    /// @notice Extra buy-side fee at the opening instant, decaying linearly
    ///         to zero at SNIPE_SECONDS. Zero disables the mechanism.
    uint256 public immutable SNIPE_EXTRA;

    uint256 internal constant FEE_DENOMINATOR = 1_000_000;
    /// @dev 1% ceiling on the standing fee. A deploy-time typo in a unit
    ///      system with a million as its denominator is otherwise easy.
    uint256 internal constant MAX_FEE = 10_000;
    /// @dev 10% ceiling on the launch surcharge.
    uint256 internal constant MAX_SNIPE_EXTRA = 100_000;
    /// @dev One hour. Past that a "launch guard" is just a permanent buy tax.
    uint256 internal constant MAX_SNIPE_SECONDS = 3600;

    IPoolManager public immutable poolManager;

    /// @notice Per-pool fee recipient, set once at initialize.
    mapping(PoolId => address) public adopterOf;

    /// @notice Which slot RESERVE occupies in each pool's key.
    mapping(PoolId => bool) public reserveIsCurrency0;

    /// @notice Timestamp each pool opened, anchoring the launch window.
    mapping(PoolId => uint256) public startTimeOf;

    bool private _locked;

    event PoolAdopted(PoolId indexed poolId, address indexed adopter, address token, bool reserveIsCurrency0);
    event FeePaid(PoolId indexed poolId, uint256 royalty, uint256 adopterShare);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @dev Guards against a hostile adopting token reentering via a callback.
    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(
        IPoolManager _poolManager,
        Currency _reserve,
        address _royaltyRecipient,
        uint256 _fee,
        uint256 _royaltyShare,
        uint256 _snipeSeconds,
        uint256 _snipeExtra
    ) {
        require(!_reserve.isAddressZero(), "reserve must be ERC20");
        require(_royaltyRecipient != address(0), "royalty recipient = 0");
        require(_fee <= MAX_FEE, "fee too high");
        require(_royaltyShare <= _fee, "royalty exceeds fee");
        require(_snipeExtra <= MAX_SNIPE_EXTRA, "surcharge too high");
        require(_snipeSeconds <= MAX_SNIPE_SECONDS, "window too long");

        poolManager = _poolManager;
        RESERVE = _reserve;
        ROYALTY_RECIPIENT = _royaltyRecipient;
        FEE = _fee;
        ROYALTY_SHARE = _royaltyShare;
        SNIPE_SECONDS = _snipeSeconds;
        SNIPE_EXTRA = _snipeExtra;

        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false, // never blocks an LP exit
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

    // ------------------------------------------------------------- active

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (key.currency0.isAddressZero()) revert NativeCurrencyNotSupported();
        if (sender == address(0)) revert InvalidAdopter();

        bool isC0 = Currency.unwrap(key.currency0) == Currency.unwrap(RESERVE);
        bool isC1 = Currency.unwrap(key.currency1) == Currency.unwrap(RESERVE);
        if (!isC0 && !isC1) revert PoolMustIncludeReserve();

        Currency other = isC0 ? key.currency1 : key.currency0;
        _requireSaneErc20(Currency.unwrap(other));

        PoolId id = key.toId();
        adopterOf[id] = sender;
        reserveIsCurrency0[id] = isC0;
        startTimeOf[id] = block.timestamp;

        emit PoolAdopted(id, sender, Currency.unwrap(other), isC0);
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Cheap up-front screen only. Cannot detect fee-on-transfer or
    ///      rebasing — that needs an actual transfer, which is what
    ///      _takeChecked does on the first swap.
    function _requireSaneErc20(address token) internal view {
        if (token.code.length == 0) revert TokenNotERC20();
        (bool okDec, bytes memory dec) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!okDec || dec.length < 32) revert TokenNotERC20();
        (bool okSup, bytes memory sup) = token.staticcall(abi.encodeWithSignature("totalSupply()"));
        if (!okSup || sup.length < 32) revert TokenNotERC20();
    }

    /// @notice True when this swap sells the reserve into the pool.
    function _reserveIsInput(PoolId id, bool zeroForOne) internal view returns (bool) {
        return reserveIsCurrency0[id] == zeroForOne;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified >= 0) revert ExactOutputNotSupported();

        PoolId id = key.toId();
        // Reserve on the output side is handled in afterSwap.
        if (!_reserveIsInput(id, params.zeroForOne)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Selling reserve INTO the pool means buying the adopting token, so
        // the launch surcharge applies here and only here.
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 effectiveFee = FEE + _snipeExtra(id);
        uint256 cut = (amountIn * effectiveFee) / FEE_DENOMINATOR;
        if (cut == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        _payFee(key, id, cut);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(cut.toInt128(), 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager nonReentrant returns (bytes4, int128) {
        PoolId id = key.toId();
        if (_reserveIsInput(id, params.zeroForOne)) return (IHooks.afterSwap.selector, 0);

        // Reserve is the output leg. Never surcharged: this is a SELL of the
        // adopting token, and taxing exits is what makes a honeypot.
        int128 outputAmount = params.zeroForOne ? delta.amount1() : delta.amount0();
        if (outputAmount <= 0) return (IHooks.afterSwap.selector, 0);

        // safe: int128, checked > 0 above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 output = uint256(int256(outputAmount));
        uint256 cut = (output * FEE) / FEE_DENOMINATOR;
        if (cut == 0) return (IHooks.afterSwap.selector, 0);

        _payFee(key, id, cut);
        return (IHooks.afterSwap.selector, cut.toInt128());
    }

    /// @notice Extra buy-side fee currently in force, in hundredths of a bip.
    function currentSnipeExtra(PoolKey calldata key) external view returns (uint256) {
        return _snipeExtra(key.toId());
    }

    function _snipeExtra(PoolId id) internal view returns (uint256) {
        if (SNIPE_EXTRA == 0 || SNIPE_SECONDS == 0) return 0;
        uint256 start = startTimeOf[id];
        if (start == 0) return 0;
        uint256 elapsed = block.timestamp - start;
        if (elapsed >= SNIPE_SECONDS) return 0;
        return (SNIPE_EXTRA * (SNIPE_SECONDS - elapsed)) / SNIPE_SECONDS;
    }

    /// @dev Splits a reserve-denominated cut and pays both parties. Each take
    ///      is balance-checked: the reserve is fixed at deployment, but a
    ///      reserve whose transfer semantics change (PAXG's own contract has a
    ///      settable transfer fee) would otherwise silently short-pay.
    function _payFee(PoolKey calldata key, PoolId id, uint256 cut) internal {
        uint256 royalty = (cut * ROYALTY_SHARE) / FEE;
        uint256 adopterShare = cut - royalty;

        if (royalty > 0) _takeChecked(RESERVE, ROYALTY_RECIPIENT, royalty);

        address adopter = adopterOf[id];
        if (adopterShare > 0) {
            _takeChecked(RESERVE, adopter == address(0) ? ROYALTY_RECIPIENT : adopter, adopterShare);
        }

        emit FeePaid(id, royalty, adopterShare);
        // silence unused-parameter warning while keeping the signature stable
        key;
    }

    function _takeChecked(Currency token, address to, uint256 amount) internal {
        uint256 before = token.balanceOf(to);
        poolManager.take(token, to, amount);
        if (token.balanceOf(to) - before != amount) revert TokenNotSupported();
    }

    // ----------------------------------------------------------- disabled

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4) { revert HookNotImplemented(); }

    function afterAddLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4) { revert HookNotImplemented(); }

    function afterRemoveLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) { revert HookNotImplemented(); }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) { revert HookNotImplemented(); }
}
