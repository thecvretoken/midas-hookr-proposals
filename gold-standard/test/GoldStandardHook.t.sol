// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title GoldStandardHook test suite
/// @notice Tests the DEPLOYED, verified GoldStandardHook. src/ is a bit-exact
///         reproduction of mainnet bytecode and is never modified here.
///
///         Harness: v4-core @ a22414e4 (Dec 2024). At this commit SwapParams and
///         ModifyLiquidityParams live in IPoolManager, and hook reverts surface
///         from the PoolManager as ERC-7751 `WrappedError(target, selector,
///         reason, details)` where details == HookCallFailed().
///
///         Main instance ("hook A") uses the MAINNET constructor params:
///           fee 1200, royaltyShare 360, snipeSeconds 60, snipeExtra 10000.
///         RESERVE = currency0 for hook A, RESERVE = currency1 for hook B
///         (v4 sorts currencies by address, so both orderings must work),
///         and hook C has snipeExtra = 0 (anti-snipe disabled).
///
///         Constructor-arg validation is tested by etching the creation code at
///         a flag-valid address and calling it (what StdCheats.deployCodeTo does
///         internally), so the raw `Error(string)` revert data can be decoded
///         instead of being swallowed by deployCodeTo's own require.
///
///         Fee-on-transfer protection (TokenNotSupported) is exercised by
///         etching a short-paying ERC20 runtime (same storage layout as the
///         solmate MockERC20 the reserve was deployed as) over the RESERVE
///         address mid-test. This mirrors the exact scenario the NatSpec warns
///         about: PAXG's own contract has a settable transfer fee.

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

import {GoldStandardHook} from "../src/GoldStandardHook.sol";

/// @dev A reserve whose transfer silently short-pays by 1 wei. Same storage
///      layout as MockERC20 (adds no state), so it can be etched over the
///      live reserve address and keep every balance / allowance.
contract ShortPayERC20 is MockERC20 {
    constructor() MockERC20("ShortPay", "SP", 18) {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        return super.transfer(to, amount - 1);
    }
}

contract GoldStandardHookTest is Deployers {
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------------------ mainnet params
    uint256 constant FEE = 1200;
    uint256 constant ROYALTY_SHARE = 360;
    uint256 constant SNIPE_SECONDS = 60;
    uint256 constant SNIPE_EXTRA = 10_000;
    uint256 constant DENOM = 1_000_000;

    uint256 constant MAX_FEE = 10_000;
    uint256 constant MAX_SNIPE_EXTRA = 100_000;
    uint256 constant MAX_SNIPE_SECONDS = 3600;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    ); // == 0x20cc

    uint256 constant T0 = 1_700_000_000;
    int128 constant LIQ = 1e27; // ~6e24 of each token in the +-120 tick range

    // ------------------------------------------------------------ actors
    address royalty = makeAddr("royaltyRecipient");
    address adopterA = makeAddr("adopterA");
    address adopterB = makeAddr("adopterB");
    address adopterC = makeAddr("adopterC");
    address stranger = makeAddr("stranger");

    // ------------------------------------------------------------ instances
    GoldStandardHook hookA; // RESERVE = currency0, mainnet params
    GoldStandardHook hookB; // RESERVE = currency1, mainnet params
    GoldStandardHook hookC; // RESERVE = currency0, snipeExtra = 0

    PoolKey keyA;
    PoolKey keyB;
    PoolKey keyC;
    PoolKey refKey; // identical pool, no hook: reference for raw AMM output
    PoolId idA;
    PoolId idB;
    PoolId idC;

    // ================================================================ setUp

    function setUp() public {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        hookA = _deployHook(address((uint160(0xA) << 152) | FLAGS), currency0, SNIPE_EXTRA);
        hookB = _deployHook(address((uint160(0xB) << 152) | FLAGS), currency1, SNIPE_EXTRA);
        hookC = _deployHook(address((uint160(0xC) << 152) | FLAGS), currency0, 0);

        keyA = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hookA)));
        keyB = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hookB)));
        keyC = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hookC)));
        refKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        idA = keyA.toId();
        idB = keyB.toId();
        idC = keyC.toId();

        // The adopter is whoever calls PoolManager.initialize: prank the EOAs.
        vm.prank(adopterA);
        manager.initialize(keyA, SQRT_PRICE_1_1);
        vm.prank(adopterB);
        manager.initialize(keyB, SQRT_PRICE_1_1);
        vm.prank(adopterC);
        manager.initialize(keyC, SQRT_PRICE_1_1);
        manager.initialize(refKey, SQRT_PRICE_1_1);

        _addLiquidity(keyA);
        _addLiquidity(keyB);
        _addLiquidity(keyC);
        _addLiquidity(refKey);
    }

    function _deployHook(address where, Currency reserve, uint256 snipeExtra) internal returns (GoldStandardHook) {
        deployCodeTo(
            "GoldStandardHook.sol:GoldStandardHook",
            abi.encode(manager, reserve, royalty, FEE, ROYALTY_SHARE, SNIPE_SECONDS, snipeExtra),
            where
        );
        return GoldStandardHook(where);
    }

    function _addLiquidity(PoolKey memory k) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: LIQ, salt: 0}),
            ZERO_BYTES
        );
    }

    /// @dev Etch creation code + args at a flag-valid address and run it, returning
    ///      the raw success flag / revert data so require strings can be decoded.
    function _tryConstruct(
        Currency reserve,
        address royaltyRecipient,
        uint256 fee,
        uint256 royaltyShare,
        uint256 snipeSeconds,
        uint256 snipeExtra
    ) internal returns (bool ok, bytes memory ret) {
        return _tryConstructAt(
            address((uint160(0xD) << 152) | FLAGS), reserve, royaltyRecipient, fee, royaltyShare, snipeSeconds, snipeExtra
        );
    }

    function _tryConstructAt(
        address where,
        Currency reserve,
        address royaltyRecipient,
        uint256 fee,
        uint256 royaltyShare,
        uint256 snipeSeconds,
        uint256 snipeExtra
    ) internal returns (bool ok, bytes memory ret) {
        bytes memory initCode = abi.encodePacked(
            type(GoldStandardHook).creationCode,
            abi.encode(manager, reserve, royaltyRecipient, fee, royaltyShare, snipeSeconds, snipeExtra)
        );
        vm.etch(where, initCode);
        (ok, ret) = where.call("");
        vm.etch(where, "");
    }

    function _err(string memory s) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", s);
    }

    /// @dev ERC-7751 wrapper the PoolManager produces when a hook call reverts.
    function _wrapped(address hook, bytes4 fn, bytes4 inner) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            hook,
            fn,
            abi.encodeWithSelector(inner),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(who);
    }

    function _swapParams(bool zeroForOne, int256 amountSpecified) internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
    }

    function _buyCut(uint256 amountIn, uint256 extra) internal pure returns (uint256 cut, uint256 roy, uint256 adp) {
        cut = (amountIn * (FEE + extra)) / DENOM;
        roy = (cut * ROYALTY_SHARE) / FEE;
        adp = cut - roy;
    }

    function _sellCut(uint256 rawOut) internal pure returns (uint256 cut, uint256 roy, uint256 adp) {
        cut = (rawOut * FEE) / DENOM;
        roy = (cut * ROYALTY_SHARE) / FEE;
        adp = cut - roy;
    }

    // ================================================================ 1. constructor

    function test_constructor_storesMainnetParams() public view {
        assertEq(Currency.unwrap(hookA.RESERVE()), Currency.unwrap(currency0));
        assertEq(Currency.unwrap(hookB.RESERVE()), Currency.unwrap(currency1));
        assertEq(hookA.ROYALTY_RECIPIENT(), royalty);
        assertEq(hookA.FEE(), FEE);
        assertEq(hookA.ROYALTY_SHARE(), ROYALTY_SHARE);
        assertEq(hookA.SNIPE_SECONDS(), SNIPE_SECONDS);
        assertEq(hookA.SNIPE_EXTRA(), SNIPE_EXTRA);
        assertEq(hookC.SNIPE_EXTRA(), 0);
        assertEq(address(hookA.poolManager()), address(manager));
        assertEq(hookA.NAME(), "Gold Standard Hook");
    }

    function test_constructor_rejectsFeeAboveMax() public {
        (bool ok, bytes memory ret) = _tryConstruct(currency0, royalty, MAX_FEE + 1, 0, 60, 0);
        assertFalse(ok);
        assertEq(ret, _err("fee too high"));
    }

    function test_constructor_rejectsRoyaltyShareAboveFee() public {
        (bool ok, bytes memory ret) = _tryConstruct(currency0, royalty, FEE, FEE + 1, 60, 0);
        assertFalse(ok);
        assertEq(ret, _err("royalty exceeds fee"));
    }

    function test_constructor_rejectsSnipeExtraAboveMax() public {
        (bool ok, bytes memory ret) = _tryConstruct(currency0, royalty, FEE, ROYALTY_SHARE, 60, MAX_SNIPE_EXTRA + 1);
        assertFalse(ok);
        assertEq(ret, _err("surcharge too high"));
    }

    function test_constructor_rejectsSnipeWindowAboveMax() public {
        (bool ok, bytes memory ret) =
            _tryConstruct(currency0, royalty, FEE, ROYALTY_SHARE, MAX_SNIPE_SECONDS + 1, SNIPE_EXTRA);
        assertFalse(ok);
        assertEq(ret, _err("window too long"));
    }

    function test_constructor_rejectsZeroReserve() public {
        (bool ok, bytes memory ret) =
            _tryConstruct(CurrencyLibrary.ADDRESS_ZERO, royalty, FEE, ROYALTY_SHARE, SNIPE_SECONDS, SNIPE_EXTRA);
        assertFalse(ok);
        assertEq(ret, _err("reserve must be ERC20"));
    }

    function test_constructor_rejectsZeroRoyaltyRecipient() public {
        (bool ok, bytes memory ret) =
            _tryConstruct(currency0, address(0), FEE, ROYALTY_SHARE, SNIPE_SECONDS, SNIPE_EXTRA);
        assertFalse(ok);
        assertEq(ret, _err("royalty recipient = 0"));
    }

    function test_constructor_acceptsBoundaryValues() public {
        // every limit inclusive: fee == MAX_FEE, royaltyShare == fee, extra == MAX, window == MAX
        (bool ok, bytes memory runtime) =
            _tryConstruct(currency0, royalty, MAX_FEE, MAX_FEE, MAX_SNIPE_SECONDS, MAX_SNIPE_EXTRA);
        assertTrue(ok);
        assertGt(runtime.length, 0, "runtime bytecode returned");

        // zero fee / zero window / zero extra are also legal
        (ok,) = _tryConstruct(currency0, royalty, 0, 0, 0, 0);
        assertTrue(ok);
    }

    function test_constructor_rejectsAddressWithoutFlags() public {
        // Hooks.validateHookPermissions: low 14 bits must equal 0x20cc exactly.
        address bad = address(uint160(0xE) << 152); // no flag bits set
        (bool ok, bytes memory ret) =
            _tryConstructAt(bad, currency0, royalty, FEE, ROYALTY_SHARE, SNIPE_SECONDS, SNIPE_EXTRA);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, bad));

        // one extra flag (afterInitialize) is also rejected
        address extra = address((uint160(0xE) << 152) | FLAGS | Hooks.AFTER_INITIALIZE_FLAG);
        (ok, ret) = _tryConstructAt(extra, currency0, royalty, FEE, ROYALTY_SHARE, SNIPE_SECONDS, SNIPE_EXTRA);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, extra));
    }

    // ================================================================ 2. permissions

    function test_getHookPermissions_matchesMask0x20cc() public view {
        Hooks.Permissions memory p = hookA.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertTrue(p.beforeSwapReturnDelta);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);

        assertEq(uint256(FLAGS), 0x20cc);
        assertEq(uint160(address(hookA)) & Hooks.ALL_HOOK_MASK, 0x20cc);
        assertEq(uint160(address(hookB)) & Hooks.ALL_HOOK_MASK, 0x20cc);
        assertEq(uint160(address(hookC)) & Hooks.ALL_HOOK_MASK, 0x20cc);
    }

    // ================================================================ 3. beforeInitialize

    function test_beforeInitialize_recordsAdopterSlotAndStart_reserveIsCurrency0() public view {
        assertEq(hookA.adopterOf(idA), adopterA);
        assertTrue(hookA.reserveIsCurrency0(idA));
        assertEq(hookA.startTimeOf(idA), T0);
    }

    function test_beforeInitialize_recordsAdopterSlotAndStart_reserveIsCurrency1() public view {
        assertEq(hookB.adopterOf(idB), adopterB);
        assertFalse(hookB.reserveIsCurrency0(idB));
        assertEq(hookB.startTimeOf(idB), T0);
    }

    function test_beforeInitialize_emitsPoolAdopted() public {
        vm.warp(T0 + 12345);
        PoolKey memory k = PoolKey(currency0, currency1, 500, 10, IHooks(address(hookA)));
        PoolId id = k.toId();

        vm.expectEmit(true, true, true, true, address(hookA));
        emit GoldStandardHook.PoolAdopted(id, stranger, Currency.unwrap(currency1), true);
        vm.prank(stranger);
        manager.initialize(k, SQRT_PRICE_1_1);

        assertEq(hookA.adopterOf(id), stranger);
        assertEq(hookA.startTimeOf(id), T0 + 12345);

        // and the other ordering reports the adopting token as currency0
        PoolKey memory kb = PoolKey(currency0, currency1, 500, 10, IHooks(address(hookB)));
        vm.expectEmit(true, true, true, true, address(hookB));
        emit GoldStandardHook.PoolAdopted(kb.toId(), stranger, Currency.unwrap(currency0), false);
        vm.prank(stranger);
        manager.initialize(kb, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_revertsPoolMustIncludeReserve() public {
        MockERC20[] memory t = deployTokens(2, 1e30);
        (Currency x, Currency y) = address(t[0]) < address(t[1])
            ? (Currency.wrap(address(t[0])), Currency.wrap(address(t[1])))
            : (Currency.wrap(address(t[1])), Currency.wrap(address(t[0])));

        PoolKey memory k = PoolKey(x, y, 3000, 60, IHooks(address(hookA)));
        vm.expectRevert(
            _wrapped(address(hookA), IHooks.beforeInitialize.selector, GoldStandardHook.PoolMustIncludeReserve.selector)
        );
        manager.initialize(k, SQRT_PRICE_1_1);

        k.hooks = IHooks(address(hookB));
        vm.expectRevert(
            _wrapped(address(hookB), IHooks.beforeInitialize.selector, GoldStandardHook.PoolMustIncludeReserve.selector)
        );
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_revertsNativeCurrencyNotSupported() public {
        PoolKey memory k = PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency0, 3000, 60, IHooks(address(hookA)));
        vm.expectRevert(
            _wrapped(
                address(hookA), IHooks.beforeInitialize.selector, GoldStandardHook.NativeCurrencyNotSupported.selector
            )
        );
        manager.initialize(k, SQRT_PRICE_1_1);

        // native / RESERVE pool where RESERVE is currency1: still rejected, native check comes first
        PoolKey memory kb = PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, 3000, 60, IHooks(address(hookB)));
        vm.expectRevert(
            _wrapped(
                address(hookB), IHooks.beforeInitialize.selector, GoldStandardHook.NativeCurrencyNotSupported.selector
            )
        );
        manager.initialize(kb, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_revertsTokenNotERC20_forEOA() public {
        // EOA "token" above RESERVE (hook A, RESERVE = currency0)
        Currency eoaHigh = Currency.wrap(address(type(uint160).max));
        assertEq(Currency.unwrap(eoaHigh).code.length, 0);
        PoolKey memory k = PoolKey(currency0, eoaHigh, 3000, 60, IHooks(address(hookA)));
        vm.expectRevert(
            _wrapped(address(hookA), IHooks.beforeInitialize.selector, GoldStandardHook.TokenNotERC20.selector)
        );
        manager.initialize(k, SQRT_PRICE_1_1);

        // EOA "token" below RESERVE (hook B, RESERVE = currency1)
        Currency eoaLow = Currency.wrap(address(0x1234));
        assertEq(Currency.unwrap(eoaLow).code.length, 0);
        PoolKey memory kb = PoolKey(eoaLow, currency1, 3000, 60, IHooks(address(hookB)));
        vm.expectRevert(
            _wrapped(address(hookB), IHooks.beforeInitialize.selector, GoldStandardHook.TokenNotERC20.selector)
        );
        manager.initialize(kb, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_revertsTokenNotERC20_forContractWithoutDecimals() public {
        // A contract with code but no decimals()/totalSupply(): the swap router.
        address notToken = address(swapRouter);
        PoolKey memory k;
        GoldStandardHook h;
        if (notToken > Currency.unwrap(currency0)) {
            h = hookA;
            k = PoolKey(currency0, Currency.wrap(notToken), 3000, 60, IHooks(address(hookA)));
        } else {
            h = hookB;
            k = PoolKey(Currency.wrap(notToken), currency1, 3000, 60, IHooks(address(hookB)));
        }
        vm.expectRevert(_wrapped(address(h), IHooks.beforeInitialize.selector, GoldStandardHook.TokenNotERC20.selector));
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    // ================================================================ 4. buy fee (RESERVE input)

    struct Snap {
        uint256 roy;
        uint256 adp;
        uint256 meReserve;
        uint256 meOther;
    }

    function _snap(Currency reserve, Currency other, address adopter) internal view returns (Snap memory s) {
        s.roy = _bal(reserve, royalty);
        s.adp = _bal(reserve, adopter);
        s.meReserve = _bal(reserve, address(this));
        s.meOther = _bal(other, address(this));
    }

    function _rawOut(bool zeroForOne, uint256 amountIn) internal returns (uint256) {
        BalanceDelta ref = swap(refKey, zeroForOne, -int256(amountIn), ZERO_BYTES);
        return uint256(int256(zeroForOne ? ref.amount1() : ref.amount0()));
    }

    struct Exp {
        uint256 cut;
        uint256 roy;
        uint256 adp;
        uint256 rawOut;
    }

    /// @dev Buy of the adopting token (reserve is the input). zeroForOne is true
    ///      when reserve = currency0 (pool A / C), false when reserve = currency1 (pool B).
    function _assertBuy(PoolKey memory k, GoldStandardHook h, bool zeroForOne, address adopter, uint256 amountIn, uint256 extra)
        internal
    {
        assertEq(h.currentSnipeExtra(k), extra, "snipe extra precondition");
        Exp memory e;
        (e.cut, e.roy, e.adp) = _buyCut(amountIn, extra);
        // reference: the pool only sees amountIn - cut, so the same swap on the
        // hookless twin with (amountIn - cut) yields the exact token output
        e.rawOut = _rawOut(zeroForOne, amountIn - e.cut);

        Snap memory b = _snap(h.RESERVE(), zeroForOne ? k.currency1 : k.currency0, adopter);
        vm.expectEmit(true, true, true, true, address(h));
        emit GoldStandardHook.FeePaid(k.toId(), e.roy, e.adp);
        BalanceDelta d = swap(k, zeroForOne, -int256(amountIn), ZERO_BYTES);
        Snap memory a = _snap(h.RESERVE(), zeroForOne ? k.currency1 : k.currency0, adopter);

        assertEq(a.roy - b.roy, e.roy, "royalty");
        assertEq(a.adp - b.adp, e.adp, "adopter share");
        assertEq(b.meReserve - a.meReserve, amountIn, "user pays exactly amountIn");
        assertEq(a.meOther - b.meOther, e.rawOut, "token out == ref(amountIn - cut)");
        assertEq(int256(zeroForOne ? d.amount0() : d.amount1()), -int256(amountIn));
    }

    function test_buyFee_atT0_fullSnipeExtra() public {
        _assertBuy(keyA, hookA, true, adopterA, 1e18, SNIPE_EXTRA);
        // 1e18 * 11200 / 1e6 = 1.12e16; royalty 3.36e15; adopter 7.84e15
        (uint256 cut, uint256 roy, uint256 adp) = _buyCut(1e18, SNIPE_EXTRA);
        assertEq(cut, 1.12e16);
        assertEq(roy, 3.36e15);
        assertEq(adp, 7.84e15);
    }

    function test_buyFee_at30s_halfSnipeExtra() public {
        vm.warp(T0 + 30);
        _assertBuy(keyA, hookA, true, adopterA, 1e18, SNIPE_EXTRA / 2);
    }

    function test_buyFee_at60s_noSnipeExtra() public {
        vm.warp(T0 + 60);
        _assertBuy(keyA, hookA, true, adopterA, 1e18, 0);
        (uint256 cut,,) = _buyCut(1e18, 0);
        assertEq(cut, 1.2e15);
    }

    function test_buyFee_wellAfterWindow_noSnipeExtra() public {
        vm.warp(T0 + 30 days);
        _assertBuy(keyA, hookA, true, adopterA, 5e18, 0);
    }

    function test_buyFee_reserveIsCurrency1() public {
        // hook B: reserve = currency1, so a buy is oneForZero
        _assertBuy(keyB, hookB, false, adopterB, 1e18, SNIPE_EXTRA);
        vm.warp(T0 + 30);
        _assertBuy(keyB, hookB, false, adopterB, 3e18, SNIPE_EXTRA / 2);
    }

    function test_buyFee_dustAmountPaysNothing() public {
        // amountIn * 11200 / 1e6 == 0 for amountIn < 90 wei: no fee, no take, no event
        uint256 royBefore = _bal(currency0, royalty);
        uint256 adpBefore = _bal(currency0, adopterA);
        swap(keyA, true, -int256(50), ZERO_BYTES);
        assertEq(_bal(currency0, royalty), royBefore);
        assertEq(_bal(currency0, adopterA), adpBefore);
    }

    // ================================================================ 5/6. sell fee (RESERVE output)

    /// @dev Sell of the adopting token (reserve is the output). zeroForOne is false
    ///      when reserve = currency0 (pool A), true when reserve = currency1 (pool B).
    function _assertSell(PoolKey memory k, GoldStandardHook h, bool zeroForOne, address adopter, uint256 amountIn)
        internal
    {
        Exp memory e;
        // raw AMM output from the hookless twin
        e.rawOut = _rawOut(zeroForOne, amountIn);
        assertGt(e.rawOut, 0);
        (e.cut, e.roy, e.adp) = _sellCut(e.rawOut);

        Snap memory b = _snap(h.RESERVE(), zeroForOne ? k.currency0 : k.currency1, adopter);
        vm.expectEmit(true, true, true, true, address(h));
        emit GoldStandardHook.FeePaid(k.toId(), e.roy, e.adp);
        BalanceDelta d = swap(k, zeroForOne, -int256(amountIn), ZERO_BYTES);
        Snap memory a = _snap(h.RESERVE(), zeroForOne ? k.currency0 : k.currency1, adopter);

        assertEq(a.roy - b.roy, e.roy, "royalty");
        assertEq(a.adp - b.adp, e.adp, "adopter share");
        assertEq(a.meReserve - b.meReserve, e.rawOut - e.cut, "user gets output minus cut");
        assertEq(b.meOther - a.meOther, amountIn, "user pays exactly amountIn of the adopting token");
        assertEq(int256(zeroForOne ? d.amount1() : d.amount0()), int256(e.rawOut - e.cut), "net delta");
    }

    function test_sellFee_takesFeeFromReserveOutput_reserveIsCurrency0() public {
        vm.warp(T0 + 120); // outside the window; plain FEE either way
        _assertSell(keyA, hookA, false, adopterA, 1e18);
    }

    function test_sellFee_takesFeeFromReserveOutput_reserveIsCurrency1() public {
        vm.warp(T0 + 120);
        _assertSell(keyB, hookB, true, adopterB, 1e18);
    }

    /// @notice Anti-honeypot property: during the launch window a SELL pays FEE
    ///         only, never FEE + snipeExtra. (One hooked POOL per test: the
    ///         hookless reference pool mirrors exactly one hooked pool's state.)
    function _assertSellNotSurcharged(PoolKey memory k, GoldStandardHook h, bool zeroForOne, address adopter) internal {
        assertEq(h.currentSnipeExtra(k), SNIPE_EXTRA, "window fully active");

        uint256 rawOut = _rawOut(zeroForOne, 2e18);
        uint256 surcharged = (rawOut * (FEE + SNIPE_EXTRA)) / DENOM;
        uint256 plain = (rawOut * FEE) / DENOM;
        assertGt(surcharged, plain);

        Currency reserve = h.RESERVE();
        uint256 royBefore = _bal(reserve, royalty);
        uint256 adpBefore = _bal(reserve, adopter);
        uint256 meBefore = _bal(reserve, address(this));
        swap(k, zeroForOne, -int256(2e18), ZERO_BYTES);

        uint256 paid = (_bal(reserve, royalty) - royBefore) + (_bal(reserve, adopter) - adpBefore);
        assertEq(paid, plain, "sell paid plain FEE");
        assertLt(paid, surcharged, "sell not surcharged");
        assertEq(_bal(reserve, address(this)) - meBefore, rawOut - plain, "user got output minus plain FEE");
    }

    function test_sellsAreNeverSurcharged_antiHoneypot_reserveIsCurrency0() public {
        _assertSellNotSurcharged(keyA, hookA, false, adopterA);
    }

    function test_sellsAreNeverSurcharged_antiHoneypot_reserveIsCurrency1() public {
        _assertSellNotSurcharged(keyB, hookB, true, adopterB);
    }

    function test_sellAtT0_paysExactlyFee_withEventSplit() public {
        // full _assertSell (event + split + net delta) at the opening instant
        _assertSell(keyA, hookA, false, adopterA, 1e18);
    }

    // ================================================================ 7/8. snipe decay

    function testFuzz_currentSnipeExtraDecaysLinearly(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 2 * SNIPE_SECONDS);
        vm.warp(T0 + elapsed);
        uint256 expected = elapsed < SNIPE_SECONDS ? (SNIPE_EXTRA * (SNIPE_SECONDS - elapsed)) / SNIPE_SECONDS : 0;
        uint256 got = hookA.currentSnipeExtra(keyA);
        assertEq(got, expected);
        assertEq(hookB.currentSnipeExtra(keyB), expected);

        // monotone non-increasing: one second earlier is >= now
        if (elapsed > 0) {
            vm.warp(vm.getBlockTimestamp() - 1);
            assertGe(hookA.currentSnipeExtra(keyA), got);
        }
    }

    function test_currentSnipeExtra_knownPoints() public {
        assertEq(hookA.currentSnipeExtra(keyA), 10_000);
        vm.warp(T0 + 15);
        assertEq(hookA.currentSnipeExtra(keyA), 7_500);
        vm.warp(T0 + 30);
        assertEq(hookA.currentSnipeExtra(keyA), 5_000);
        vm.warp(T0 + 59);
        assertEq(hookA.currentSnipeExtra(keyA), uint256(166)); // 10_000 * 1 / 60, floored
        vm.warp(T0 + 60);
        assertEq(hookA.currentSnipeExtra(keyA), 0);
        vm.warp(T0 + 365 days);
        assertEq(hookA.currentSnipeExtra(keyA), 0);

        // an uninitialized pool has no start time -> no surcharge
        PoolKey memory fresh = PoolKey(currency0, currency1, 500, 10, IHooks(address(hookA)));
        vm.warp(T0);
        assertEq(hookA.currentSnipeExtra(fresh), 0);
    }

    function test_snipeExtraZero_disablesMechanism() public {
        assertEq(hookC.SNIPE_EXTRA(), 0);
        for (uint256 i = 0; i <= 2 * SNIPE_SECONDS; i += 10) {
            vm.warp(T0 + i);
            assertEq(hookC.currentSnipeExtra(keyC), 0);
        }

        // and a buy at t=0 on hook C pays exactly FEE, no surcharge
        vm.warp(T0);
        _assertBuy(keyC, hookC, true, adopterC, 1e18, 0);
    }

    // ================================================================ 9. exact output

    function test_exactOutputSwapsRevert() public {
        bytes memory expected =
            _wrapped(address(hookA), IHooks.beforeSwap.selector, GoldStandardHook.ExactOutputNotSupported.selector);

        // both directions, both hook orderings
        vm.expectRevert(expected);
        swap(keyA, true, int256(1e18), ZERO_BYTES);
        vm.expectRevert(expected);
        swap(keyA, false, int256(1e18), ZERO_BYTES);

        bytes memory expectedB =
            _wrapped(address(hookB), IHooks.beforeSwap.selector, GoldStandardHook.ExactOutputNotSupported.selector);
        vm.expectRevert(expectedB);
        swap(keyB, true, int256(1e18), ZERO_BYTES);
        vm.expectRevert(expectedB);
        swap(keyB, false, int256(1e18), ZERO_BYTES);
    }

    // ================================================================ 10. rounding dust

    function test_roundingDustGoesToAdopter() public {
        vm.warp(T0 + 60); // no snipe extra: cut = amountIn * 1200 / 1e6
        uint256 amountIn = 1_002_500; // cut = 1203; 1203 * 360 / 1200 = 360.9 -> 360; adopter 843
        (uint256 cut, uint256 roy, uint256 adp) = _buyCut(amountIn, 0);
        assertEq(cut, 1203);
        assertEq(roy, 360);
        assertEq(adp, 843);
        assertTrue((cut * ROYALTY_SHARE) % FEE != 0, "chosen amount must truncate");

        uint256 royBefore = _bal(currency0, royalty);
        uint256 adpBefore = _bal(currency0, adopterA);
        swap(keyA, true, -int256(amountIn), ZERO_BYTES);
        assertEq(_bal(currency0, royalty) - royBefore, 360);
        assertEq(_bal(currency0, adopterA) - adpBefore, 843);
    }

    // ================================================================ 11. no authority

    function test_noAdminSurface_noSettersExist() public {
        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeWithSignature("setFee(uint256)", 1);
        calls[1] = abi.encodeWithSignature("setRoyaltyRecipient(address)", stranger);
        calls[2] = abi.encodeWithSignature("transferOwnership(address)", stranger);
        calls[3] = abi.encodeWithSignature("owner()");
        calls[4] = abi.encodeWithSignature("setAdopter(bytes32,address)", PoolId.unwrap(idA), stranger);
        calls[5] = abi.encodeWithSignature("upgradeTo(address)", stranger);
        calls[6] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", stranger, "");
        calls[7] = abi.encodeWithSignature("renounceOwnership()");
        calls[8] = abi.encodeWithSignature("setSnipeExtra(uint256)", 0);
        calls[9] = abi.encodeWithSignature("pause()");
        calls[10] = abi.encodeWithSignature("sweep(address,address)", Currency.unwrap(currency0), stranger);
        calls[11] = ""; // plain call, no fallback / receive

        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok,) = address(hookA).call(calls[i]);
            assertFalse(ok, "unexpected admin surface");
            (ok,) = address(hookA).call{value: 0}(calls[i]);
            assertFalse(ok);
        }

        // immutables untouched
        assertEq(hookA.ROYALTY_RECIPIENT(), royalty);
        assertEq(hookA.FEE(), FEE);
        assertEq(hookA.ROYALTY_SHARE(), ROYALTY_SHARE);
        assertEq(hookA.SNIPE_EXTRA(), SNIPE_EXTRA);
        assertEq(hookA.adopterOf(idA), adopterA);
    }

    function test_adopterCannotBeChangedByReinitializing() public {
        vm.warp(T0 + 500);
        vm.prank(stranger);
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        manager.initialize(keyA, SQRT_PRICE_1_1);

        assertEq(hookA.adopterOf(idA), adopterA);
        assertEq(hookA.startTimeOf(idA), T0);
        assertTrue(hookA.reserveIsCurrency0(idA));

        // fees keep flowing to the original adopter
        _assertBuy(keyA, hookA, true, adopterA, 1e18, 0);
    }

    // ================================================================ 12. onlyPoolManager

    function test_onlyPoolManager_beforeInitialize() public {
        vm.expectRevert(GoldStandardHook.NotPoolManager.selector);
        hookA.beforeInitialize(address(this), keyA, SQRT_PRICE_1_1);

        vm.prank(adopterA);
        vm.expectRevert(GoldStandardHook.NotPoolManager.selector);
        hookA.beforeInitialize(adopterA, keyA, SQRT_PRICE_1_1);
    }

    function test_onlyPoolManager_beforeSwap() public {
        vm.expectRevert(GoldStandardHook.NotPoolManager.selector);
        hookA.beforeSwap(address(this), keyA, _swapParams(true, -1e18), ZERO_BYTES);
    }

    function test_onlyPoolManager_afterSwap() public {
        vm.expectRevert(GoldStandardHook.NotPoolManager.selector);
        hookA.afterSwap(address(this), keyA, _swapParams(false, -1e18), toBalanceDelta(1e18, -1e18), ZERO_BYTES);
    }

    // ================================================================ 13. disabled hooks

    function test_disabledHooks_revertHookNotImplemented() public {
        IPoolManager.ModifyLiquidityParams memory lp =
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1, salt: 0});
        BalanceDelta z = toBalanceDelta(0, 0);

        vm.expectRevert(GoldStandardHook.HookNotImplemented.selector);
        hookA.afterInitialize(address(this), keyA, SQRT_PRICE_1_1, 0);
        vm.expectRevert(GoldStandardHook.HookNotImplemented.selector);
        hookA.beforeAddLiquidity(address(this), keyA, lp, ZERO_BYTES);
        vm.expectRevert(GoldStandardHook.HookNotImplemented.selector);
        hookA.afterAddLiquidity(address(this), keyA, lp, z, z, ZERO_BYTES);
        vm.expectRevert(GoldStandardHook.HookNotImplemented.selector);
        hookA.beforeRemoveLiquidity(address(this), keyA, lp, ZERO_BYTES);
        vm.expectRevert(GoldStandardHook.HookNotImplemented.selector);
        hookA.afterRemoveLiquidity(address(this), keyA, lp, z, z, ZERO_BYTES);
        vm.expectRevert(GoldStandardHook.HookNotImplemented.selector);
        hookA.beforeDonate(address(this), keyA, 1, 1, ZERO_BYTES);
        vm.expectRevert(GoldStandardHook.HookNotImplemented.selector);
        hookA.afterDonate(address(this), keyA, 1, 1, ZERO_BYTES);
    }

    function test_liquidityAndDonateNeverTouchTheHook() public {
        // Permissions are off for these, so the PoolManager never calls the
        // reverting stubs: LPs can always enter and exit.
        _addLiquidity(keyA);
        modifyLiquidityRouter.modifyLiquidity(
            keyA,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -LIQ, salt: 0}),
            ZERO_BYTES
        );
        donateRouter.donate(keyA, 1e18, 1e18, ZERO_BYTES);
    }

    // ================================================================ 14. fee-on-transfer protection

    function test_feeOnTransferReserve_revertsTokenNotSupported_onBuy() public {
        // Sanity: a normal buy works before the reserve's transfer semantics change.
        swap(keyA, true, -int256(1e18), ZERO_BYTES);

        // Now the reserve starts short-paying (PAXG-style settable transfer fee).
        // Etch a short-paying runtime over the reserve address; storage is kept.
        ShortPayERC20 impl = new ShortPayERC20();
        vm.etch(Currency.unwrap(currency0), address(impl).code);

        vm.expectRevert(_wrapped(address(hookA), IHooks.beforeSwap.selector, GoldStandardHook.TokenNotSupported.selector));
        swap(keyA, true, -int256(1e18), ZERO_BYTES);
    }

    function test_feeOnTransferReserve_revertsTokenNotSupported_onSell() public {
        ShortPayERC20 impl = new ShortPayERC20();
        vm.etch(Currency.unwrap(currency0), address(impl).code);

        // reserve is the OUTPUT here, so the check fires in afterSwap
        vm.expectRevert(_wrapped(address(hookA), IHooks.afterSwap.selector, GoldStandardHook.TokenNotSupported.selector));
        swap(keyA, false, -int256(1e18), ZERO_BYTES);
    }

    // ================================================================ 15. independent pools

    function test_twoPoolsOnSameHook_keepIndependentAdoptersAndStartTimes() public {
        PoolKey memory k2 = PoolKey(currency0, currency1, 500, 10, IHooks(address(hookA)));
        PoolId id2 = k2.toId();
        assertTrue(PoolId.unwrap(id2) != PoolId.unwrap(idA));

        vm.warp(T0 + 1000);
        vm.prank(stranger);
        manager.initialize(k2, SQRT_PRICE_1_1);
        _addLiquidity(k2);

        assertEq(hookA.adopterOf(idA), adopterA);
        assertEq(hookA.adopterOf(id2), stranger);
        assertEq(hookA.startTimeOf(idA), T0);
        assertEq(hookA.startTimeOf(id2), T0 + 1000);

        // pool A is long past its window, pool 2 is at its opening instant
        assertEq(hookA.currentSnipeExtra(keyA), 0);
        assertEq(hookA.currentSnipeExtra(k2), SNIPE_EXTRA);

        // fees route to each pool's own adopter
        (, uint256 royA, uint256 adpA) = _buyCut(1e18, 0);
        (, uint256 roy2, uint256 adp2) = _buyCut(1e18, SNIPE_EXTRA);

        uint256 aBefore = _bal(currency0, adopterA);
        uint256 sBefore = _bal(currency0, stranger);
        uint256 rBefore = _bal(currency0, royalty);
        swap(keyA, true, -int256(1e18), ZERO_BYTES);
        swap(k2, true, -int256(1e18), ZERO_BYTES);
        assertEq(_bal(currency0, adopterA) - aBefore, adpA);
        assertEq(_bal(currency0, stranger) - sBefore, adp2);
        assertEq(_bal(currency0, royalty) - rBefore, royA + roy2);
    }

    // ================================================================ 16. fuzz fee split

    function testFuzz_buyFeeSplit(uint256 amountIn, uint256 elapsed) public {
        amountIn = bound(amountIn, 1e6, 1e24);
        elapsed = bound(elapsed, 0, 4 * SNIPE_SECONDS);
        vm.warp(T0 + elapsed);

        uint256 extra = elapsed < SNIPE_SECONDS ? (SNIPE_EXTRA * (SNIPE_SECONDS - elapsed)) / SNIPE_SECONDS : 0;
        assertEq(hookA.currentSnipeExtra(keyA), extra);

        uint256 cut = (amountIn * (FEE + extra)) / DENOM;
        uint256 roy = (cut * ROYALTY_SHARE) / FEE;
        uint256 adp = cut - roy;

        uint256 royBefore = _bal(currency0, royalty);
        uint256 adpBefore = _bal(currency0, adopterA);
        uint256 meBefore = _bal(currency0, address(this));

        swap(keyA, true, -int256(amountIn), ZERO_BYTES);

        uint256 royGot = _bal(currency0, royalty) - royBefore;
        uint256 adpGot = _bal(currency0, adopterA) - adpBefore;
        assertEq(royGot, roy, "royalty == cut * ROYALTY_SHARE / FEE");
        assertEq(adpGot, adp, "adopter == cut - royalty");
        assertEq(royGot + adpGot, cut, "royalty + adopterShare == cut");
        assertEq(cut, (amountIn * (FEE + extra)) / DENOM);
        assertEq(meBefore - _bal(currency0, address(this)), amountIn, "user pays exactly amountIn");
        assertLe(royGot, adpGot, "dust never favours the royalty (30/70 split)");
    }
}
