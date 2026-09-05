// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {PolicyEnvelopeHook} from "../src/PolicyEnvelopeHook.sol";

/// @notice Tests for PolicyEnvelopeHook. Run with `forge test -vv`.
///
/// One test per invariant I1..I10 in the spec, plus a fuzz over random step sequences.
contract PolicyEnvelopeHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PolicyEnvelopeHook hook;
    PoolId id;

    // NOTE: `key` is inherited from Deployers — do not redeclare it here.

    address royalty = address(0xFEE5);
    address stranger = address(0xBEEF);
    address agent = address(0xA6E7);

    // Default pitch: 0.05% .. 0.60%, 0.10% step, 1h cooldown, start at 0.30%.
    uint24 constant MIN = 500;
    uint24 constant MAX = 6_000;
    uint24 constant STEP = 1_000;
    uint256 constant INTERVAL = 3600;
    uint24 constant DEFAULT = 3_000;

    uint160 flags;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        deployCodeTo(
            "PolicyEnvelopeHook.sol:PolicyEnvelopeHook",
            abi.encode(manager, MIN, MAX, STEP, INTERVAL, DEFAULT, royalty),
            address(flags)
        );
        hook = PolicyEnvelopeHook(address(flags));

        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        id = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amount) internal {
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings(),
            ""
        );
    }

    function _seedLiquidity(PoolKey memory k) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e18, salt: 0}), ""
        );
    }

    /// @dev Walk the fee to `target` in legal steps, warping past the cooldown each time.
    function _moveTo(uint24 target) internal {
        uint24 cur = hook.feeOf(key);
        while (cur != target) {
            uint24 next;
            if (target > cur) next = target - cur > STEP ? cur + STEP : target;
            else next = cur - target > STEP ? cur - STEP : target;
            vm.warp(vm.getBlockTimestamp() + INTERVAL);
            hook.setFee(key, next);
            cur = next;
        }
    }

    /// @dev BaseHook validates its own address in the constructor, so a plain `new` at an
    ///      unflagged address reverts with HookAddressNotValid before our checks run.
    ///      Instead: etch creation code + args at a second flag-valid address and run it,
    ///      returning the raw (ok, data) so tests can assert on the exact revert selector.
    function _tryDeploy(uint24 minFee, uint24 maxFee, uint24 maxStep, uint256 interval, uint24 def, address r)
        internal
        returns (bool ok, bytes memory ret, address where)
    {
        where = address(flags | (uint160(0x1234) << 20));
        bytes memory creation = vm.getCode("PolicyEnvelopeHook.sol:PolicyEnvelopeHook");
        vm.etch(where, abi.encodePacked(creation, abi.encode(manager, minFee, maxFee, maxStep, interval, def, r)));
        (ok, ret) = where.call("");
        if (ok) vm.etch(where, ret);
    }

    function _deployHook(uint24 minFee, uint24 maxFee, uint24 maxStep, uint256 interval, uint24 def, address r)
        internal
        returns (PolicyEnvelopeHook)
    {
        (bool ok,, address where) = _tryDeploy(minFee, maxFee, maxStep, interval, def, r);
        require(ok, "deploy failed");
        return PolicyEnvelopeHook(where);
    }

    function _assertDeployReverts(
        bytes4 sel,
        uint24 minFee,
        uint24 maxFee,
        uint24 maxStep,
        uint256 interval,
        uint24 def,
        address r
    ) internal {
        (bool ok, bytes memory ret,) = _tryDeploy(minFee, maxFee, maxStep, interval, def, r);
        assertFalse(ok, "constructor must revert");
        assertEq(bytes4(ret), sel, "wrong revert selector");
    }

    // -----------------------------------------------------------------
    // Init
    // -----------------------------------------------------------------

    function test_init_recordsDeployerCapsuleAndDefaultFee() public view {
        assertEq(hook.deployerOf(key), address(this), "deployer is initializer");
        assertEq(hook.capsuleOf(key), address(this), "capsule is initializer");
        assertEq(hook.feeOf(key), DEFAULT, "fee starts at default");
        assertEq(hook.nextChangeAllowedAt(key), 0, "first move not gated");
    }

    function test_init_revertsOnStaticFeePool() public {
        PoolKey memory bad = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(bad, TickMath.getSqrtPriceAtTick(0));
    }

    // -----------------------------------------------------------------
    // I1 — fee never leaves [MIN_FEE, MAX_FEE]
    // -----------------------------------------------------------------

    function test_I1_setFee_rejectsOutsideEnvelope() public {
        _moveTo(MIN);
        vm.warp(vm.getBlockTimestamp() + INTERVAL);
        vm.expectRevert(PolicyEnvelopeHook.FeeOutsideEnvelope.selector);
        hook.setFee(key, MIN - 1);
        assertEq(hook.feeOf(key), MIN);

        _moveTo(MAX);
        vm.warp(vm.getBlockTimestamp() + INTERVAL);
        vm.expectRevert(PolicyEnvelopeHook.FeeOutsideEnvelope.selector);
        hook.setFee(key, MAX + 1);
        assertEq(hook.feeOf(key), MAX);

        // Even a zero fee (which v4 would accept as an LP fee) is refused.
        vm.expectRevert(PolicyEnvelopeHook.FeeOutsideEnvelope.selector);
        hook.setFee(key, 0);
    }

    /// @dev Random sequence of signed steps applied by the capsule. Whatever happens,
    ///      the fee stays inside the envelope, and a call succeeds iff its target is legal.
    function testFuzz_I1_feeStaysInEnvelope(uint256 seed, uint8 n) public {
        n = uint8(bound(n, 1, 40));
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint24 cur = hook.feeOf(key);

            // Signed step in [-2*STEP, +2*STEP] so ~half the attempts are illegal.
            int256 step = int256(r % (4 * uint256(STEP) + 1)) - int256(2 * uint256(STEP));
            int256 target = int256(uint256(cur)) + step;
            if (target < 0) target = 0;
            uint24 newFee = uint24(uint256(target));

            bool legal = newFee >= MIN && newFee <= MAX && (newFee > cur ? newFee - cur : cur - newFee) <= STEP;

            // Sometimes skip the cooldown to exercise the rate limit too.
            bool waited = (r >> 200) % 3 != 0;
            if (waited) vm.warp(vm.getBlockTimestamp() + INTERVAL);
            bool gated = !waited && hook.nextChangeAllowedAt(key) > vm.getBlockTimestamp();

            if (legal && !gated) {
                hook.setFee(key, newFee);
                assertEq(hook.feeOf(key), newFee, "legal move applied");
            } else {
                vm.expectRevert();
                hook.setFee(key, newFee);
                assertEq(hook.feeOf(key), cur, "illegal move rejected");
            }

            uint24 f = hook.feeOf(key);
            assertGe(f, MIN, "fee below envelope");
            assertLe(f, MAX, "fee above envelope");
        }
    }

    // -----------------------------------------------------------------
    // I2 — single step bounded by MAX_STEP
    // -----------------------------------------------------------------

    function test_I2_stepBounded() public {
        vm.expectRevert(PolicyEnvelopeHook.StepTooLarge.selector);
        hook.setFee(key, DEFAULT + STEP + 1);

        vm.expectRevert(PolicyEnvelopeHook.StepTooLarge.selector);
        hook.setFee(key, DEFAULT - STEP - 1);

        hook.setFee(key, DEFAULT + STEP); // exactly MAX_STEP is allowed
        assertEq(hook.feeOf(key), DEFAULT + STEP);
    }

    // -----------------------------------------------------------------
    // I3 — rate limited by MIN_INTERVAL
    // -----------------------------------------------------------------

    function test_I3_rateLimited() public {
        hook.setFee(key, DEFAULT + 100);
        uint256 t0 = vm.getBlockTimestamp();
        assertEq(hook.nextChangeAllowedAt(key), t0 + INTERVAL);

        vm.expectRevert(PolicyEnvelopeHook.TooSoon.selector);
        hook.setFee(key, DEFAULT + 200);

        vm.warp(t0 + INTERVAL - 1);
        vm.expectRevert(PolicyEnvelopeHook.TooSoon.selector);
        hook.setFee(key, DEFAULT + 200);

        vm.warp(t0 + INTERVAL);
        hook.setFee(key, DEFAULT + 200);
        assertEq(hook.feeOf(key), DEFAULT + 200);
    }

    // -----------------------------------------------------------------
    // I4 — only the capsule holder can setFee
    // -----------------------------------------------------------------

    function test_I4_onlyCapsuleCanSetFee() public {
        vm.prank(stranger);
        vm.expectRevert(PolicyEnvelopeHook.NotCapsule.selector);
        hook.setFee(key, DEFAULT + 100);

        // The author / royalty recipient has no special standing either.
        vm.prank(royalty);
        vm.expectRevert(PolicyEnvelopeHook.NotCapsule.selector);
        hook.setFee(key, DEFAULT + 100);

        // Nor does the hook's own address.
        vm.prank(address(hook));
        vm.expectRevert(PolicyEnvelopeHook.NotCapsule.selector);
        hook.setFee(key, DEFAULT + 100);

        assertEq(hook.feeOf(key), DEFAULT, "fee untouched");
    }

    // -----------------------------------------------------------------
    // I5 — renounce is permanent
    // -----------------------------------------------------------------

    function test_I5_renounceFreezesForever() public {
        hook.setFee(key, DEFAULT + 500);
        hook.renounceCapsule(key);
        assertEq(hook.capsuleOf(key), address(0), "capsule destroyed");
        assertEq(hook.feeOf(key), DEFAULT + 500, "fee frozen at last value");

        vm.warp(vm.getBlockTimestamp() + 365 days);

        vm.expectRevert(PolicyEnvelopeHook.CapsuleRenouncedForever.selector);
        hook.setFee(key, DEFAULT);

        vm.expectRevert(PolicyEnvelopeHook.CapsuleRenouncedForever.selector);
        hook.transferCapsule(key, agent);

        vm.expectRevert(PolicyEnvelopeHook.CapsuleRenouncedForever.selector);
        hook.renounceCapsule(key);

        // Nobody can accept a capsule that no longer exists.
        vm.prank(agent);
        vm.expectRevert(PolicyEnvelopeHook.CapsuleRenouncedForever.selector);
        hook.acceptCapsule(key);

        vm.prank(stranger);
        vm.expectRevert(PolicyEnvelopeHook.CapsuleRenouncedForever.selector);
        hook.setFee(key, DEFAULT);

        assertEq(hook.feeOf(key), DEFAULT + 500, "still frozen");
    }

    function test_I5_renounceClearsPendingTransfer() public {
        hook.transferCapsule(key, agent);
        hook.renounceCapsule(key);
        assertEq(hook.pendingCapsuleOf(key), address(0));

        vm.prank(agent);
        vm.expectRevert(PolicyEnvelopeHook.CapsuleRenouncedForever.selector);
        hook.acceptCapsule(key);
    }

    function test_I5_onlyCapsuleCanRenounce() public {
        vm.prank(stranger);
        vm.expectRevert(PolicyEnvelopeHook.NotCapsule.selector);
        hook.renounceCapsule(key);
        assertEq(hook.capsuleOf(key), address(this));
    }

    // -----------------------------------------------------------------
    // I6 — two-step transfer
    // -----------------------------------------------------------------

    function test_I6_twoStepTransfer() public {
        // Stranger cannot propose.
        vm.prank(stranger);
        vm.expectRevert(PolicyEnvelopeHook.NotCapsule.selector);
        hook.transferCapsule(key, stranger);

        hook.transferCapsule(key, agent);
        assertEq(hook.pendingCapsuleOf(key), agent);
        assertEq(hook.capsuleOf(key), address(this), "holder unchanged until accept");

        // Old holder keeps full rights while the offer is pending.
        hook.setFee(key, DEFAULT + 100);

        // The proposed agent has none yet.
        vm.warp(vm.getBlockTimestamp() + INTERVAL);
        vm.prank(agent);
        vm.expectRevert(PolicyEnvelopeHook.NotCapsule.selector);
        hook.setFee(key, DEFAULT + 200);

        // A third party cannot accept.
        vm.prank(stranger);
        vm.expectRevert(PolicyEnvelopeHook.NotPendingCapsule.selector);
        hook.acceptCapsule(key);

        // The holder itself cannot "accept" on the agent's behalf.
        vm.expectRevert(PolicyEnvelopeHook.NotPendingCapsule.selector);
        hook.acceptCapsule(key);

        vm.prank(agent);
        hook.acceptCapsule(key);
        assertEq(hook.capsuleOf(key), agent);
        assertEq(hook.pendingCapsuleOf(key), address(0));

        // Old holder has lost its rights; agent has gained them.
        vm.expectRevert(PolicyEnvelopeHook.NotCapsule.selector);
        hook.setFee(key, DEFAULT + 200);

        vm.prank(agent);
        hook.setFee(key, DEFAULT + 200);
        assertEq(hook.feeOf(key), DEFAULT + 200);

        // Accept is single-use.
        vm.prank(agent);
        vm.expectRevert(PolicyEnvelopeHook.NotPendingCapsule.selector);
        hook.acceptCapsule(key);
    }

    function test_I6_proposeZeroCancelsOffer() public {
        hook.transferCapsule(key, agent);
        hook.transferCapsule(key, address(0));
        assertEq(hook.pendingCapsuleOf(key), address(0));

        vm.prank(agent);
        vm.expectRevert(PolicyEnvelopeHook.NotPendingCapsule.selector);
        hook.acceptCapsule(key);
        assertEq(hook.capsuleOf(key), address(this));
    }

    // -----------------------------------------------------------------
    // I7 — split is proportional and conserves, to the wei
    // -----------------------------------------------------------------

    function _assertSplitAtFee(uint24 fee) internal {
        _moveTo(fee);
        assertEq(hook.feeOf(key), fee, "precondition: fee set");

        (uint24 lp, uint24 dep, uint24 roy) = hook.splitOf(fee);
        assertEq(uint256(lp) + dep + roy, fee, "pips: lp + deployer + royalty == fee");
        assertEq(lp, uint24((uint256(fee) * hook.LP_SHARE()) / 10_000), "lp is 70% (floor)");
        assertGt(lp, dep, "lp > deployer");
        assertGt(dep, roy, "deployer > royalty");

        uint256 depBefore = hook.deployerBucket(id, currency0);
        uint256 royBefore = hook.royaltyBucket(currency0);

        uint256 amountIn = 1e18 + 12345; // odd amount to force rounding
        uint256 hookBefore = manager.balanceOf(address(hook), currency0.toId());
        _swap(key, true, -int256(amountIn));
        uint256 taken = manager.balanceOf(address(hook), currency0.toId()) - hookBefore;

        uint256 expectedTaken = (amountIn * uint256(dep + roy)) / 1_000_000;
        assertEq(taken, expectedTaken, "hook took exactly deployer+royalty pips of input");

        uint256 depGot = hook.deployerBucket(id, currency0) - depBefore;
        uint256 royGot = hook.royaltyBucket(currency0) - royBefore;
        assertEq(depGot + royGot, taken, "wei: deployer + royalty == fee taken");
        assertEq(depGot, (taken * 2_500) / 3_000, "deployer gets 25/30 of hook share");
    }

    function test_I7_splitConservesAtSeveralFeeLevels() public {
        _seedLiquidity(key);
        _assertSplitAtFee(MIN);
        _assertSplitAtFee(1_234);
        _assertSplitAtFee(DEFAULT);
        _assertSplitAtFee(4_999);
        _assertSplitAtFee(MAX);
    }

    function testFuzz_I7_splitPipsConserve(uint24 fee) public view {
        fee = uint24(bound(fee, hook.ABS_MIN_FEE(), hook.ABS_MAX_FEE()));
        (uint24 lp, uint24 dep, uint24 roy) = hook.splitOf(fee);
        assertEq(uint256(lp) + dep + roy, fee);
        assertLe(lp, fee);
    }

    /// @dev The LP share actually reaches the pool as the override fee: moving the fee
    ///      changes what the swapper pays. Same input, higher fee -> less output.
    function test_I7_lpShareAppliedViaOverride() public {
        _seedLiquidity(key);

        _moveTo(MIN);
        uint256 b0 = currency1.balanceOf(address(this));
        _swap(key, true, -1e16);
        uint256 outLow = currency1.balanceOf(address(this)) - b0;

        _moveTo(MAX);
        b0 = currency1.balanceOf(address(this));
        _swap(key, true, -1e16);
        uint256 outHigh = currency1.balanceOf(address(this)) - b0;

        assertGt(outLow, outHigh, "higher fee yields less output");
    }

    // -----------------------------------------------------------------
    // I8 — royalty always pays ROYALTY_RECIPIENT
    // -----------------------------------------------------------------

    function test_I8_royaltyAlwaysPaysFixedRecipient() public {
        _seedLiquidity(key);
        _swap(key, true, -1e18);
        uint256 owed = hook.royaltyBucket(currency0);
        assertGt(owed, 0, "precondition: royalty accrued");

        uint256 recipientBefore = currency0.balanceOf(royalty);
        uint256 strangerBefore = currency0.balanceOf(stranger);

        vm.prank(stranger);
        hook.claimRoyalty(currency0);

        assertEq(currency0.balanceOf(royalty) - recipientBefore, owed, "recipient paid in full");
        assertEq(currency0.balanceOf(stranger), strangerBefore, "caller gets nothing");
        assertEq(hook.royaltyBucket(currency0), 0, "bucket drained");

        vm.expectRevert(PolicyEnvelopeHook.NothingToClaim.selector);
        hook.claimRoyalty(currency0);

        // Second round, called by the deployer this time — same destination.
        _swap(key, true, -1e18);
        owed = hook.royaltyBucket(currency0);
        recipientBefore = currency0.balanceOf(royalty);
        hook.claimRoyalty(currency0);
        assertEq(currency0.balanceOf(royalty) - recipientBefore, owed);
    }

    function test_I8_claimDeployer_onlyDeployerAndFullAmount() public {
        _seedLiquidity(key);
        _swap(key, true, -1e18);
        uint256 owed = hook.deployerBucket(id, currency0);
        assertGt(owed, 0);

        vm.prank(stranger);
        vm.expectRevert(PolicyEnvelopeHook.NotDeployer.selector);
        hook.claimDeployer(id, currency0);

        vm.prank(royalty);
        vm.expectRevert(PolicyEnvelopeHook.NotDeployer.selector);
        hook.claimDeployer(id, currency0);

        // Transferring the capsule does NOT transfer the deployer share.
        hook.transferCapsule(key, agent);
        vm.prank(agent);
        hook.acceptCapsule(key);
        vm.prank(agent);
        vm.expectRevert(PolicyEnvelopeHook.NotDeployer.selector);
        hook.claimDeployer(id, currency0);

        uint256 before = currency0.balanceOf(address(this));
        hook.claimDeployer(id, currency0);
        assertEq(currency0.balanceOf(address(this)) - before, owed);
        assertEq(hook.deployerBucket(id, currency0), 0);

        vm.expectRevert(PolicyEnvelopeHook.NothingToClaim.selector);
        hook.claimDeployer(id, currency0);
    }

    /// @dev After both claims the hook holds no residual claims on the manager.
    function test_I8_claimsDrainHookCompletely() public {
        _seedLiquidity(key);
        _swap(key, true, -1e18);
        _swap(key, false, -1e18);

        hook.claimDeployer(id, currency0);
        hook.claimDeployer(id, currency1);
        hook.claimRoyalty(currency0);
        hook.claimRoyalty(currency1);

        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
        assertEq(currency0.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(hook)), 0);
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(PolicyEnvelopeHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
    }

    // -----------------------------------------------------------------
    // I9 — constructor rejects envelopes outside absolute ceilings
    // -----------------------------------------------------------------

    function test_I9_constructorRejectsBadEnvelopes() public {
        uint24 floor_ = hook.ABS_MIN_FEE();
        uint24 cap = hook.ABS_MAX_FEE();

        _assertDeployReverts(
            PolicyEnvelopeHook.EnvelopeBelowFloor.selector, floor_ - 1, MAX, STEP, INTERVAL, DEFAULT, royalty
        );
        _assertDeployReverts(
            PolicyEnvelopeHook.EnvelopeAboveCap.selector, MIN, cap + 1, STEP, INTERVAL, DEFAULT, royalty
        );
        _assertDeployReverts(PolicyEnvelopeHook.EnvelopeInverted.selector, MAX, MIN, STEP, INTERVAL, DEFAULT, royalty);
        _assertDeployReverts(PolicyEnvelopeHook.ZeroStep.selector, MIN, MAX, 0, INTERVAL, DEFAULT, royalty);
        _assertDeployReverts(
            PolicyEnvelopeHook.DefaultOutsideEnvelope.selector, MIN, MAX, STEP, INTERVAL, MIN - 1, royalty
        );
        _assertDeployReverts(
            PolicyEnvelopeHook.DefaultOutsideEnvelope.selector, MIN, MAX, STEP, INTERVAL, MAX + 1, royalty
        );
        _assertDeployReverts(PolicyEnvelopeHook.RoyaltyZero.selector, MIN, MAX, STEP, INTERVAL, DEFAULT, address(0));

        // Boundary values are accepted.
        PolicyEnvelopeHook edge = _deployHook(floor_, cap, 1, 0, floor_, royalty);
        assertEq(edge.MIN_FEE(), floor_);
        assertEq(edge.MAX_FEE(), cap);
    }

    function testFuzz_I9_constructorNeverAcceptsEnvelopeOutsideCeilings(
        uint24 minFee,
        uint24 maxFee,
        uint24 maxStep,
        uint24 def
    ) public {
        bool valid = minFee >= hook.ABS_MIN_FEE() && maxFee <= hook.ABS_MAX_FEE() && minFee <= maxFee && maxStep != 0
            && def >= minFee && def <= maxFee;

        if (valid) {
            PolicyEnvelopeHook h = _deployHook(minFee, maxFee, maxStep, INTERVAL, def, royalty);
            assertGe(h.MIN_FEE(), h.ABS_MIN_FEE());
            assertLe(h.MAX_FEE(), h.ABS_MAX_FEE());
        } else {
            (bool ok,,) = _tryDeploy(minFee, maxFee, maxStep, INTERVAL, def, royalty);
            assertFalse(ok, "invalid envelope must be refused");
        }
    }

    // -----------------------------------------------------------------
    // I10 — envelope is immutable, no setter
    // -----------------------------------------------------------------

    function test_I10_envelopeReadsBackAndIsImmutable() public {
        PolicyEnvelopeHook.Envelope memory e = hook.envelope();
        assertEq(e.minFee, MIN);
        assertEq(e.maxFee, MAX);
        assertEq(e.maxStep, STEP);
        assertEq(e.minInterval, INTERVAL);
        assertEq(e.defaultFee, DEFAULT);
        assertEq(e.lpShare, 7_000);
        assertEq(e.deployerShare, 2_500);
        assertEq(e.royaltyShare, 500);
        assertEq(e.royaltyRecipient, royalty);
        assertEq(hook.ROYALTY_RECIPIENT(), royalty);

        // Exercise every mutating path the contract has, then re-read the envelope.
        hook.setFee(key, DEFAULT + STEP);
        hook.transferCapsule(key, agent);
        vm.prank(agent);
        hook.acceptCapsule(key);
        vm.prank(agent);
        hook.renounceCapsule(key);

        PolicyEnvelopeHook.Envelope memory e2 = hook.envelope();
        assertEq(keccak256(abi.encode(e)), keccak256(abi.encode(e2)), "envelope unchanged by any action");
    }

    /// @dev There is no setter. Every plausible setter selector hits a contract with no
    ///      fallback and reverts, and the envelope is untouched afterwards.
    function test_I10_noSetterSelectorsExist() public {
        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeWithSignature("setMinFee(uint24)", uint24(100));
        calls[1] = abi.encodeWithSignature("setMaxFee(uint24)", uint24(60_000));
        calls[2] = abi.encodeWithSignature("setMaxStep(uint24)", uint24(60_000));
        calls[3] = abi.encodeWithSignature("setMinInterval(uint256)", uint256(0));
        calls[4] = abi.encodeWithSignature("setEnvelope(uint24,uint24,uint24,uint256)", 100, 60_000, 60_000, 0);
        calls[5] = abi.encodeWithSignature("setRoyaltyRecipient(address)", stranger);
        calls[6] = abi.encodeWithSignature("setDeployer(bytes32,address)", PoolId.unwrap(id), stranger);
        calls[7] = abi.encodeWithSignature("transferOwnership(address)", stranger);
        calls[8] = abi.encodeWithSignature("upgradeTo(address)", stranger);

        PolicyEnvelopeHook.Envelope memory e = hook.envelope();
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok,) = address(hook).call(calls[i]);
            assertFalse(ok, "setter must not exist");
        }
        assertEq(keccak256(abi.encode(hook.envelope())), keccak256(abi.encode(e)));
        assertEq(hook.deployerOf(key), address(this));
        assertEq(hook.ROYALTY_RECIPIENT(), royalty);
    }

    // -----------------------------------------------------------------
    // Pools are independent
    // -----------------------------------------------------------------

    function test_poolsHaveIndependentCapsulesAndFees() public {
        PoolKey memory k2 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(address(hook)));
        vm.prank(agent);
        manager.initialize(k2, TickMath.getSqrtPriceAtTick(0));

        assertEq(hook.capsuleOf(k2), agent);
        assertEq(hook.deployerOf(k2), agent);

        // Our capsule doesn't reach the agent's pool and vice versa.
        vm.expectRevert(PolicyEnvelopeHook.NotCapsule.selector);
        hook.setFee(k2, DEFAULT + 100);
        vm.prank(agent);
        vm.expectRevert(PolicyEnvelopeHook.NotCapsule.selector);
        hook.setFee(key, DEFAULT + 100);

        hook.setFee(key, DEFAULT + 100);
        assertEq(hook.feeOf(key), DEFAULT + 100);
        assertEq(hook.feeOf(k2), DEFAULT, "other pool untouched");
        assertEq(hook.nextChangeAllowedAt(k2), 0, "other pool's cooldown untouched");
    }

    function test_uninitializedPoolHasNoCapsule() public {
        PoolKey memory k3 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        assertEq(hook.capsuleOf(k3), address(0));
        vm.expectRevert(PolicyEnvelopeHook.NotCapsule.selector);
        hook.setFee(k3, DEFAULT);
    }
}
