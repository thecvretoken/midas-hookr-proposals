// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HookrToken} from "hookr/support/HookrToken.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrAdvisory} from "hookr/interfaces/IHookrAdvisory.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {PartnerShapedFixture} from "hookr-test/lane/utils/PartnerShapedFixture.sol";
import {LaneRootFixture} from "hookr-test/lane/utils/LaneRootFixture.sol";
import {TwoVenueExecutor} from "hookr-test/lane/mocks/TwoVenueExecutor.sol";
import {MidasSizeCapAdvisory} from "../src/MidasSizeCapAdvisory.sol";

/// @dev The admission the block declares: ADVISORY, every cap zero, ADVISORY_GAS, BEFORE_SWAP, fee-only, failOpen
///      false.
function capAdmission(MidasSizeCapAdvisory cap) view returns (IHookrRegistry.Admission memory) {
    return IHookrRegistry.Admission({
        kind: IHookrRegistry.Kind.ADVISORY,
        implementation: address(cap),
        codeHash: address(cap).codehash,
        schemaHash: cap.configSchemaHash(),
        caps: HookrTypes.Caps(0, 0, 0),
        gasLimit: cap.ADVISORY_GAS(),
        phaseMask: cap.PHASES(),
        feeOnly: true,
        failOpen: false
    });
}

function decimalString(uint256 x) pure returns (string memory) {
    if (x == 0) return "0";
    uint256 n;
    for (uint256 y = x; y != 0; y /= 10) {
        ++n;
    }
    bytes memory b = new bytes(n);
    for (; x != 0; x /= 10) {
        b[--n] = bytes1(uint8(48 + x % 10));
    }
    return string(b);
}

/// @dev `x` in hundredths: 9984 reads "99.84".
function hundredths(uint256 x) pure returns (string memory) {
    string memory frac = decimalString(x % 100);
    return string.concat(decimalString(x / 100), ".", bytes(frac).length == 1 ? string.concat("0", frac) : frac);
}

/// @notice The size cap on lane pools with arb recapture on, the way new Hookr pools launch, with Hookr's own
///         partner-shaped fixture (PartnerShapedFixture, unmodified) and its CyclingExecutor, set up the way
///         hookr-1/test/lane/AdvisoryBypass.t.sol sets up its refusing advisory: a two-member family of one subject,
///         member A on ETH bound to the size cap, member B on tokenB with no advisory, a hookless 0.3% venue for each
///         member's pair at 1e24 liquidity and an ETH/tokenB connector, and the executor routing each member against
///         its venue and through the other member. The root asks the cap about every executor leg on A as an
///         unauthenticated swap of the executor (HookrLane._enter, bit 24), and a refusal reverts the leg. The
///         CyclingExecutor runs each chunk in its own self-call, so a refused leg unwinds its chunk alone and the
///         route's chunk halves.
///
///         Every scenario runs twice from the same state, with the same addresses: once with the cap's terms under
///         test, once with permissive terms that refuse nothing these scenarios do (impact cap at MAX_IMPACT_BPS, 20%
///         in sqrt; ceilings at MAX_IN). `asked` counts the executor's legs on A that reached the cap, read from the
///         state diff (the trader's own swap excluded), and `unwound` those whose chunk was reverted. `refused` is the
///         cap's own verdict on each asked leg, recomputed from the pool state the cap read inside that call (the
///         PoolManager's slot0 and liquidity words) and the pool's terms. Every scenario asserts that the legs the cap
///         refused are exactly the legs that unwound, so no unwind is put down to the cap that came from elsewhere. The
///         lane refuses some legs itself (a cycle's leg on A against the direction the frame already set, LegDirection
///         in HookrLane._enter); those revert before the cap is asked and are not counted. `arbs` and `cycles` are the
///         venue and cycle chunks the executor kept.
contract MidasSizeCapLaneTest is PartnerShapedFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint128 internal constant DEEP = 1e24;
    uint128 internal constant MID = 2.5e23;
    uint128 internal constant THIN = 1e23;
    uint128 internal constant SHALLOW = 2.5e22;
    /// @dev The floor the "typical" runs bind in both directions: the 50 bps impact cap at a tenth of DEEP, which is
    ///      how SIZE-CAP-ADVISORY.md says to pick one (the impact cap at the thinnest depth still counted as real).
    uint256 internal constant TYPICAL_FLOOR = 5e20;

    struct Fam {
        HookrToken subject;
        Currency s;
        PoolKey a;
        PoolKey b;
        PoolKey refA;
        PoolKey refB;
    }

    struct Run {
        bool traded;
        uint256 traderOut;
        uint256 pushed;
        uint256 failed;
        uint256 asked;
        uint256 unwound;
        uint256 kept;
        uint256 refused;
        uint256 arbs;
        uint256 cycles;
        uint256 largestLeg;
        uint256 gapBefore;
        uint256 gapAfter;
        uint160 aAfter;
        uint256 admitBuy;
    }

    /// @dev The five bind words.
    struct Terms {
        uint256 bps;
        uint256 maxQuote;
        uint256 maxSubject;
        uint256 floorQuote;
        uint256 floorSubject;
    }

    MidasSizeCapAdvisory internal cap;
    Currency internal qb;
    PoolKey internal conn;

    function setUp() public {
        _setUpPartnerShaped();
        cap = new MidasSizeCapAdvisory(manager);
        IHookrRegistry.Admission memory adm = capAdmission(cap);
        registry.queue(registry.ADMIT(), abi.encode(address(root), adm));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), adm);
        qb = Currency.wrap(address(tokenB));
        conn = _hookless(ETH, qb);
    }

    // ------------------------------------------------------------------------------------------------------------
    // A refused leg fails its recapture, not the trade
    // ------------------------------------------------------------------------------------------------------------

    /// A whale's buy of 1% of A's depth, admitted (buy ceiling at MAX_IN, impact cap at its ceiling), leaves A about
    /// 2% over its venue. Every leg that closes it sells the subject into A, and the sell ceiling is 1 subject, so
    /// the cap refuses each one. Each refused chunk unwinds alone: no correction fails, nothing is pushed, and the
    /// trade settles exactly as it does with the lane stopped, same output and same price. With a sell ceiling that
    /// admits the legs, the same buy is recaptured.
    function test_lane_refusedLegsUnwindAndTheTradeSettles() public {
        bytes memory refusing = abi.encode(uint256(2000), uint256(cap.MAX_IN()), uint256(1e18), uint256(0), uint256(0));
        uint256 snap = vm.snapshotState();

        // The trade alone: the lane stopped on the root.
        Fam memory f = _family(refusing, DEEP);
        registry.stopExecutorLane(address(root), address(ex));
        uint256 aloneOut = _buy(f.a, ETH, whale, 1e22);
        (uint160 alone,,,) = manager.getSlot0(f.a.toId());
        vm.revertToState(snap);

        (Run memory c, Run memory p) = _pair(refusing, _permissive(), DEEP, 1e22, false, 0);
        console2.log("whale buys 1e22 on A, sell ceiling 1 subject");
        console2.log("  legs on A asked / refused / kept", c.asked, c.unwound, c.kept);
        console2.log("  pushed with the cap / without", c.pushed, p.pushed);
        assertTrue(c.traded, "the trade went through");
        assertEq(c.traderOut, aloneOut, "the trader got what the trade alone pays");
        assertEq(c.aAfter, alone, "A ends where the trade alone leaves it");
        assertGt(c.asked, 0, "the executor tried legs on A");
        assertEq(c.unwound, c.asked, "every one unwound");
        assertEq(c.refused, c.asked, "the cap refused every one");
        assertEq(c.kept, 0);
        assertEq(c.pushed, 0, "nothing recaptured");
        assertEq(c.failed, 0, "no correction failed: each refused chunk unwound alone");
        assertEq(p.unwound, 0);
        assertGt(p.pushed, 0, "without the refusals the same buy is recaptured");
        assertEq(p.traderOut, c.traderOut, "the after-phase recapture does not change what the trader got");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Gaps a trade under the cap made
    // ------------------------------------------------------------------------------------------------------------

    /// Buys of 0.2%, 0.45% and 0.9% of A's depth at A depths of 1e24 and 1e23 (its venue stays at 1e24), under caps
    /// of 25, 50 and 100 bps, ceilings at MAX_IN and floors of 0, so the impact cap alone decides. The cap admits a
    /// buy iff it is within maxExactInput, and every buy it admits is recaptured exactly as without the cap: no leg
    /// refused, same push, same gap left, same output. Six of the admitted buys leave a gap the executor closes; a
    /// 0.2% buy leaves one under the route's threshold. The legs that close a trade's gap run the other way and close
    /// only the part above the route's fees, so they are smaller than the trade the cap already admitted. (A sell
    /// ceiling below the trade refuses them, as test_lane_refusedLegsUnwindAndTheTradeSettles shows.)
    function test_lane_tradeGapsAreRecapturedAsIfUncapped() public {
        uint16[3] memory levels = [uint16(25), 50, 100];
        uint128[2] memory depths = [DEEP, THIN];
        uint256[3] memory sizeBps = [uint256(20), 45, 90];
        uint256 recaptured;
        for (uint256 d; d < depths.length; ++d) {
            for (uint256 j; j < levels.length; ++j) {
                for (uint256 i; i < sizeBps.length; ++i) {
                    uint256 size = uint256(depths[d]) * sizeBps[i] / 10_000;
                    (Run memory c, Run memory p) = _pair(_terms(levels[j], 0), _permissive(), depths[d], size, false, 0);
                    _row("trade", levels[j], depths[d], 0, size, false, c, p);
                    assertTrue(p.traded);
                    assertEq(p.unwound, 0, "the permissive run unwinds nothing");
                    assertEq(c.traded, size <= c.admitBuy, "the trade is admitted iff within maxExactInput");
                    if (!c.traded) continue;
                    assertEq(c.unwound, 0, "no leg closing an admitted trade's gap is unwound");
                    assertEq(c.refused, 0, "or refused");
                    assertEq(c.pushed, p.pushed, "same push");
                    assertEq(c.gapAfter, p.gapAfter, "same gap left");
                    assertEq(c.traderOut, p.traderOut, "same output");
                    if (c.asked != 0) ++recaptured;
                }
            }
        }
        // 0.45% at 50 and 100 bps and 0.9% at 100 bps, at both depths. A 0.2% buy leaves a gap under the route's
        // threshold, and at 25 bps nothing larger is admitted.
        assertEq(recaptured, 6, "six admitted buys left a gap the executor closed");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Gaps the price made elsewhere
    // ------------------------------------------------------------------------------------------------------------

    /// A's venue moves 2%, 4%, 8% and 16% either way; a 1e15 buy on A then runs the before-phase recapture. Cap at
    /// 50 bps, A at 1e24, floors of 0 and of TYPICAL_FLOOR. (The thinner depths take one test per floor: a test's
    /// memory holds only so many decoded state diffs.)
    function test_lane_venueGaps_deep() public {
        _venueGrid(50, DEEP, 0);
        _venueGrid(50, DEEP, TYPICAL_FLOOR);
    }

    /// The same at A depth 2.5e23, floors of 0.
    function test_lane_venueGaps_mid_noFloor() public {
        _venueGrid(50, MID, 0);
    }

    /// The same at A depth 2.5e23, floors of TYPICAL_FLOOR.
    function test_lane_venueGaps_mid_typicalFloor() public {
        _venueGrid(50, MID, TYPICAL_FLOOR);
    }

    /// The same at A depth 1e23, where the 50 bps impact cap is about TYPICAL_FLOOR, floors of 0.
    function test_lane_venueGaps_thin_noFloor() public {
        _venueGrid(50, THIN, 0);
    }

    /// The same at A depth 1e23, floors of TYPICAL_FLOOR.
    function test_lane_venueGaps_thin_typicalFloor() public {
        _venueGrid(50, THIN, TYPICAL_FLOOR);
    }

    /// Below the depth the typical floor is sized for: A at 2.5e22, where the 50 bps impact cap is about 1.25e20,
    /// floors of 0. The CyclingExecutor sizes a chunk from the gap and the route's shallowest pool, halves it on a
    /// refusal, and drops the route once it is under firstChunk / 64 (1e22 / 64, about 1.56e20). A 2% gap's chunks
    /// fit under the cap and are recaptured as without it. From 4% the venue route's first chunk is over the cap, its
    /// half is under the executor's minimum, and the route stops, in the before-phase and again in the after-phase.
    /// The cycle route never opens, since nothing moves A away from B, so nothing is recaptured, while the uncapped
    /// run recaptures.
    function test_lane_venueGaps_shallow_noFloor() public {
        uint256[4] memory moves = [uint256(200), 400, 800, 1600];
        for (uint256 i; i < moves.length; ++i) {
            for (uint256 up; up < 2; ++up) {
                (Run memory c, Run memory p) = _venueCase(50, SHALLOW, 0, moves[i], up == 1);
                assertGt(p.pushed, 0);
                if (moves[i] == 200) {
                    assertEq(c.unwound, 0);
                    assertEq(c.pushed, p.pushed);
                } else {
                    assertGt(c.asked, 0);
                    assertEq(c.unwound, c.asked, "every leg asked was refused");
                    assertEq(c.cycles, 0, "the cycle route never ran");
                    assertEq(c.pushed, 0, "nothing recaptured");
                }
            }
        }
    }

    /// The same with floors of TYPICAL_FLOOR: the floor admits those chunks whatever the impact cap says, and every
    /// gap is recaptured within 0.1% of the uncapped run.
    function test_lane_venueGaps_shallow_typicalFloor() public {
        uint256[4] memory moves = [uint256(200), 400, 800, 1600];
        for (uint256 i; i < moves.length; ++i) {
            for (uint256 up; up < 2; ++up) {
                (Run memory c, Run memory p) = _venueCase(50, SHALLOW, TYPICAL_FLOOR, moves[i], up == 1);
                assertGe(c.pushed * 1000, p.pushed * 999, "within 0.1% of uncapped");
            }
        }
    }

    /// Caps of 25 and 100 bps at A depth 1e24, floors of 0.
    function test_lane_venueGaps_capLevels() public {
        uint16[2] memory levels = [uint16(25), 100];
        uint256[4] memory moves = [uint256(200), 400, 800, 1600];
        for (uint256 j; j < levels.length; ++j) {
            for (uint256 i; i < moves.length; ++i) {
                for (uint256 up; up < 2; ++up) {
                    (Run memory c, Run memory p) = _venueCase(levels[j], DEEP, 0, moves[i], up == 1);
                    if (p.pushed != 0) assertGt(c.pushed, 0, "the capped run still recaptured");
                    if (moves[i] <= 400) assertGe(c.pushed * 1000, p.pushed * 995, "within 0.5% of uncapped");
                }
            }
        }
    }

    /// @dev Gaps of 2%, 4%, 8% and 16% either way: whenever the uncapped run recaptured, the capped run recaptured
    ///      too, and at 2% and 4% within 0.5% of it.
    function _venueGrid(uint16 level, uint128 depth, uint256 floor) internal {
        uint256[4] memory moves = [uint256(200), 400, 800, 1600];
        for (uint256 i; i < moves.length; ++i) {
            for (uint256 up; up < 2; ++up) {
                (Run memory c, Run memory p) = _venueCase(level, depth, floor, moves[i], up == 1);
                if (p.pushed != 0) assertGt(c.pushed, 0, "the capped run still recaptured");
                if (moves[i] <= 400) assertGe(c.pushed * 1000, p.pushed * 995, "within 0.5% of uncapped");
            }
        }
    }

    /// @dev What holds in every venue scenario: the trade goes through, no correction fails (a refused chunk unwinds
    ///      alone), and the permissive run unwinds nothing.
    function _venueCase(uint16 level, uint128 depth, uint256 floor, uint256 moveBps, bool up)
        internal
        returns (Run memory c, Run memory p)
    {
        (c, p) = _pair(_terms(level, floor), _permissive(), depth, 1e15, up, moveBps);
        _row("venue", level, depth, floor, moveBps, up, c, p);
        assertTrue(c.traded && p.traded, "the trade went through");
        assertEq(p.unwound, 0, "the permissive run unwinds nothing");
        assertEq(c.failed, 0, "no correction failed");
        assertEq(c.refused, c.unwound, "the legs the cap refused are exactly the legs that unwound");
        assertEq(p.refused, 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _terms(uint256 impactBps, uint256 floor) internal view returns (bytes memory) {
        return abi.encode(impactBps, uint256(cap.MAX_IN()), uint256(cap.MAX_IN()), floor, floor);
    }

    function _permissive() internal view returns (bytes memory) {
        return _terms(cap.MAX_IMPACT_BPS(), 0);
    }

    /// @dev One scenario under `capped` and `open` terms, from the same state with the same addresses. A launches at
    ///      `depth`. With `moveBps` nonzero, A's venue first moves so the subject is `moveBps` dearer there (`up`) or
    ///      cheaper. Then the whale buys `buy` quote of A.
    function _pair(bytes memory capped, bytes memory open, uint128 depth, uint256 buy, bool up, uint256 moveBps)
        internal
        returns (Run memory c, Run memory p)
    {
        uint256 snap = vm.snapshotState();
        c = _scenario(capped, depth, buy, up, moveBps);
        vm.revertToState(snap);
        p = _scenario(open, depth, buy, up, moveBps);
        vm.revertToState(snap);
    }

    function _scenario(bytes memory terms, uint128 depth, uint256 buy, bool up, uint256 moveBps)
        internal
        returns (Run memory r)
    {
        Fam memory f = _family(terms, depth);
        if (moveBps != 0) {
            _moveVenue(f.refA, up ? 1e18 * (10_000 + moveBps) / 10_000 : 1e18 * 10_000 / (10_000 + moveBps));
        }
        r.gapBefore = _gapBps(_px(f.a, f.s), _px(f.refA, f.s));
        // ETH is currency0, so a buy on A is zeroForOne.
        r.admitBuy = cap.maxExactInput(address(root), f.a.toId(), true, true);
        _trade(f, buy, r, _decode(terms));
    }

    function _trade(Fam memory f, uint256 buy, Run memory r, Terms memory t) internal {
        uint256 arbs0 = ex.totalArbs();
        uint256 cycles0 = ex.totalCycles();
        vm.recordLogs();
        vm.startStateDiffRecording();
        try this.buyAs(f.a, whale, buy) returns (uint256 out) {
            r.traded = true;
            r.traderOut = out;
        } catch {}
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (r.traded) {
            Outcome memory o = _outcome(logs);
            r.pushed = o.pushedBefore + o.pushedAfter;
            r.failed = o.failed;
            r.arbs = ex.totalArbs() - arbs0;
            r.cycles = ex.totalCycles() - cycles0;
            r.kept = r.arbs + r.cycles;
            for (uint256 i; i < acc.length; ++i) {
                if (acc[i].account != address(cap) || acc[i].data.length < 4) continue;
                if (bytes4(acc[i].data) != IHookrAdvisory.beforeSwap.selector) continue;
                HookrTypes.SwapContext memory x = _ctx(acc[i].data);
                // The trader's swap is the one authenticated swap; every executor leg is unauthenticated.
                if (x.authenticated) continue;
                r.asked++;
                if (acc[i].reverted) r.unwound++;
                if (_refusedBy(acc, i, x, t)) r.refused++;
                uint256 amt = x.amountSpecified < 0 ? uint256(-x.amountSpecified) : uint256(x.amountSpecified);
                if (amt > r.largestLeg) r.largestLeg = amt;
            }
        }
        (r.aAfter,,,) = manager.getSlot0(f.a.toId());
        r.gapAfter = _gapBps(_px(f.a, f.s), _px(f.refA, f.s));
    }

    function _decode(bytes memory terms) internal pure returns (Terms memory t) {
        (t.bps, t.maxQuote, t.maxSubject, t.floorQuote, t.floorSubject) =
            abi.decode(terms, (uint256, uint256, uint256, uint256, uint256));
    }

    /// @dev The cap's verdict on the leg whose call is acc[i], recomputed from what that call read and with
    ///      MidasSizeCapAdvisory._check's exact-input arithmetic (every executor leg is an exact input): the pool's
    ///      slot0 (Pool.State at keccak256(id, 6)), its liquidity (three slots on) and, for a price exactly on a tick
    ///      boundary, the liquidityNet of the tick the swap crosses first, which the cap reads to take the depth on the
    ///      side the swap moves into (MidasSizeCapAdvisory._depth).
    function _refusedBy(Vm.AccountAccess[] memory acc, uint256 i, HookrTypes.SwapContext memory x, Terms memory t)
        internal
        view
        returns (bool)
    {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(x.id), bytes32(uint256(6))));
        uint256[3] memory word; // slot0, liquidity, the crossed tick's first word
        bool[3] memory seen;
        bytes32[3] memory slots = [stateSlot, bytes32(uint256(stateSlot) + 3), bytes32(0)];
        for (uint256 j = i + 1; j < acc.length && acc[j].depth > acc[i].depth; ++j) {
            if (acc[j].account != address(manager)) continue;
            for (uint256 k; k < acc[j].storageAccesses.length; ++k) {
                Vm.StorageAccess memory a = acc[j].storageAccesses[k];
                require(!a.isWrite, "the cap wrote PoolManager storage");
                uint256 w = a.slot == slots[0] ? 0 : a.slot == slots[1] ? 1 : 2;
                if (w == 2) {
                    // Only the tick the swap crosses first, at a price on its boundary.
                    int24 tick = int24(int256(uint256(word[0]) >> 160));
                    int24 edgeTick = x.zeroForOne ? tick : tick + 1;
                    slots[2] = keccak256(abi.encode(edgeTick, bytes32(uint256(stateSlot) + 4)));
                    require(a.slot == slots[2], "the cap read an unexpected slot");
                }
                if (!seen[w]) (word[w], seen[w]) = (uint256(a.previousValue), true);
            }
        }
        require(seen[0] && seen[1] && x.amountSpecified < 0, "leg not read as expected");
        uint160 spot = uint160(word[0]);
        uint256 liquidity = uint128(word[1]);
        if (seen[2]) {
            int256 net = int256(int128(uint128(word[2] >> 128)));
            int256 crossed = x.zeroForOne ? int256(liquidity) - net : int256(liquidity) + net;
            liquidity = crossed <= 0 ? 0 : uint256(crossed);
        }
        uint256 amountIn = uint256(-x.amountSpecified);
        if (amountIn > (x.isBuy ? t.maxQuote : t.maxSubject)) return true;
        if (liquidity == 0) return false;
        uint160 edge = uint160(
            x.zeroForOne ? uint256(spot) * (10_000 - t.bps) / 10_000 : uint256(spot) * (10_000 + t.bps) / 10_000
        );
        uint256 impact = x.zeroForOne
            ? SqrtPriceMath.getAmount0Delta(edge, spot, uint128(liquidity), false)
            : SqrtPriceMath.getAmount1Delta(spot, edge, uint128(liquidity), false);
        return amountIn > impact && amountIn > (x.isBuy ? t.floorQuote : t.floorSubject);
    }

    function buyAs(PoolKey memory key, address who, uint256 amount) external returns (uint256) {
        require(msg.sender == address(this));
        return _buy(key, ETH, who, amount);
    }

    function _ctx(bytes memory data) internal pure returns (HookrTypes.SwapContext memory x) {
        bytes memory body = new bytes(data.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = data[i + 4];
        }
        x = abi.decode(body, (HookrTypes.SwapContext));
    }

    /// @dev A two-member family of a fresh subject: A on ETH at `depth`, bound to the cap with `terms`, B on tokenB at
    ///      1e24 unadvised, each with a hookless 0.3% venue of its pair at 1e24, and the executor's routes as
    ///      AdvisoryBypass sets them.
    function _family(bytes memory terms, uint128 depth) internal returns (Fam memory f) {
        f.subject = _newSubject();
        f.subject.approve(address(venue), type(uint256).max);
        f.s = Currency.wrap(address(f.subject));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _laneMemberAt(ETH);
        members[0].liquidity = depth;
        members[0].config.advisory = address(cap);
        members[0].config.advisoryGasLimit = cap.ADVISORY_GAS();
        members[0].config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        members[1] = _laneMemberAt(qb);
        bytes[] memory data = new bytes[](2);
        data[0] = terms;
        (bytes32 family,) = launcher.launchAdvised{value: 1e24}(
            IHookrLauncher.Token(address(f.subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            data,
            vm.getBlockTimestamp()
        );
        f.a = launcher.position(family, 0).key;
        f.b = launcher.position(family, 1).key;
        assertEq(manager.getLiquidity(f.a.toId()), depth, "A at its depth");
        f.refA = _hookless(f.a.currency0, f.a.currency1);
        f.refB = _hookless(f.b.currency0, f.b.currency1);
        ex.setTrigger(f.a, 1e22);
        ex.addVenue(f.a, f.refA, PAIR_GAP);
        ex.addCycle(f.a, f.b, conn, CYCLE_GAP);
        ex.setTrigger(f.b, 1e22);
        ex.addVenue(f.b, f.refB, PAIR_GAP);
        ex.addCycle(f.b, f.a, conn, CYCLE_GAP);
        _nextBlock();
    }

    /// @dev Moves `ref` (ETH/subject, the subject currency1) so the subject is `subjectPriceWad` ETH there.
    function _moveVenue(PoolKey memory ref, uint256 subjectPriceWad) internal {
        uint160 target = uint160(Math.sqrt(1e36 / subjectPriceWad * 1e18) * (1 << 96) / 1e18);
        (uint160 now_,,,) = manager.getSlot0(ref.toId());
        mover.directSwap(ref, target < now_, -int256(1e26), target);
        (now_,,,) = manager.getSlot0(ref.toId());
        assertEq(now_, target, "venue at its target");
    }

    function _row(
        string memory what,
        uint256 level,
        uint128 depth,
        uint256 floor,
        uint256 size,
        bool up,
        Run memory c,
        Run memory p
    ) internal pure {
        string memory head = string.concat(
            what,
            " | cap ",
            decimalString(level),
            " bps | A depth ",
            depth == DEEP ? "1e24" : depth == MID ? "2.5e23" : depth == THIN ? "1e23" : "2.5e22",
            " | floor ",
            floor == 0 ? "0" : "5e20",
            keccak256(bytes(what)) == keccak256("trade")
                ? string.concat(" | buy ", hundredths(size * 10_000 / depth), "% of depth")
                : string.concat(" | venue ", up ? "+" : "-", hundredths(size), "%")
        );
        if (!c.traded) {
            console2.log(string.concat(head, " | trade refused by the cap"));
            return;
        }
        console2.log(
            string.concat(
                head,
                " | legs asked ",
                decimalString(c.asked),
                " (uncapped ",
                decimalString(p.asked),
                "), refused ",
                decimalString(c.refused),
                " | chunks kept: venue ",
                decimalString(c.arbs),
                ", cycle ",
                decimalString(c.cycles),
                " (uncapped ",
                decimalString(p.arbs),
                ", ",
                decimalString(p.cycles),
                ") | largest leg ",
                decimalString(c.largestLeg),
                " | pushed ",
                p.pushed == 0 ? "0 (uncapped 0)" : string.concat(hundredths(c.pushed * 10_000 / p.pushed), "% of uncapped"),
                " | gap ",
                decimalString(c.gapBefore),
                " -> ",
                decimalString(c.gapAfter),
                " bps (uncapped ",
                decimalString(p.gapAfter),
                ")"
            )
        );
    }
}

/// @notice The same refusal with an executor that does not catch it: Hookr's TwoVenueExecutor test mock (unmodified),
///         which closes the whole gap in one pair of legs and reverts when a leg does. The root then records
///         CorrectionFailed with the PoolManager's WrappedError and the trade completes on the pool as it was. One
///         lane pool of a fresh subject on ETH, bound to the cap, against the executor's hookless 0.3% reference venue,
///         both at 1e24; a 1e15 buy runs the before-phase recapture. The mock's first leg is an exact input of its
///         maxQuoteIn, 1e22, stopped at the fee-adjusted meeting price.
contract MidasSizeCapOneShotLaneTest is LaneRootFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    MidasSizeCapAdvisory internal cap;
    TwoVenueExecutor internal arb;

    struct Phase {
        uint256 failed;
        uint256 succeeded;
        uint256 pushed;
        bytes4 reason;
        uint256 hookrBuyIn;
        bool hookrBuy;
        bool otherReason;
        uint256 out;
        uint160 after_;
    }

    function setUp() public {
        _setUpLane();
        arb = _twoVenueExecutor(1e22);
        _openLane(address(arb));
        cap = new MidasSizeCapAdvisory(manager);
        IHookrRegistry.Admission memory adm = capAdmission(cap);
        registry.queue(registry.ADMIT(), abi.encode(address(root), adm));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), adm);
    }

    /// The subject is 4% cheaper on the venue. The executor buys it there and sells it into the pool, a leg bigger
    /// than the 50 bps cap: CorrectionFailed with WrappedError in both phases, nothing pushed, and the trade pays
    /// exactly what it pays with the lane stopped, on a pool the executor never moved. Under a 2,000 bps cap the
    /// same gap is recaptured.
    function test_oneShot_refusedLegFailsTheCorrectionAndTheTradeSettles() public {
        uint256 snap = vm.snapshotState();
        (PoolKey memory key, PoolKey memory ref) = _pool(50);
        _moveRef(ref, uint256(1e18) * 10_000 / 10_400);
        registry.stopExecutorLane(address(root), address(arb));
        uint256 aloneOut = _buy(key, ETH, whale, 1e15);
        (uint160 alone,,,) = manager.getSlot0(key.toId());
        vm.revertToState(snap);

        Phase memory c = _case(50, 400, false);
        Phase memory p = _case(2000, 400, false);
        assertEq(c.failed, 2, "both phases' corrections failed");
        assertEq(c.succeeded, 0);
        assertEq(c.reason, CustomRevert.WrappedError.selector, "the PoolManager's wrap of the root's refusal");
        assertFalse(c.otherReason, "both failures were WrappedError");
        assertEq(c.pushed, 0);
        assertEq(c.out, aloneOut, "the trade paid what it pays with the lane stopped");
        assertEq(c.after_, alone, "the executor never moved the pool");
        assertGt(p.succeeded, 0, "a wider cap admits the leg");
        assertGt(p.pushed, 0);
    }

    /// The subject is 1.5% dearer on the venue, so the executor buys it on the pool first: an exact input of 1e22
    /// quote, stopped by its price limit at the meeting price. The cap judges the specified amount and ignores the
    /// limit (MidasSizeCapAdvisory: "sqrtPriceLimitX96 is not read"). At 50 bps it refuses the 1e22 and the
    /// recapture fails, although the before-phase leg's fill under a 2,000 bps cap, the fill the limit allows, is
    /// within what the 50 bps cap admits.
    function test_oneShot_buyLegIsJudgedOnItsAmountNotItsLimit() public {
        uint256 snap = vm.snapshotState();
        (PoolKey memory key, PoolKey memory ref) = _pool(50);
        _moveRef(ref, 1e18 * 10_150 / 10_000);
        uint256 admitted = cap.maxExactInput(address(root), key.toId(), true, true);
        vm.revertToState(snap);

        Phase memory c = _case(50, 150, true);
        Phase memory p = _case(2000, 150, true);
        console2.log("before-phase pool buy leg: specified 1e22, filled to the limit", p.hookrBuyIn);
        console2.log("the 50 bps cap admits up to", admitted);
        assertEq(c.failed, 2, "refused at 50 bps");
        assertEq(c.reason, CustomRevert.WrappedError.selector);
        assertFalse(c.otherReason);
        assertTrue(p.hookrBuy, "the executor bought on the pool");
        assertGt(p.pushed, 0);
        assertLt(p.hookrBuyIn, admitted, "the fill was within the cap");
        assertGt(1e22, admitted, "the specified amount was not");
    }

    /// Caps of 50, 100 and 2,000 bps against gaps of 1.5%, 2%, 4% and 8% either way. A correction either succeeds or
    /// fails with WrappedError and pushes nothing, and the trade always goes through.
    function test_oneShot_grid() public {
        uint16[3] memory levels = [uint16(50), 100, 2000];
        uint256[4] memory moves = [uint256(150), 200, 400, 800];
        for (uint256 j; j < levels.length; ++j) {
            for (uint256 i; i < moves.length; ++i) {
                for (uint256 up; up < 2; ++up) {
                    Phase memory r = _case(levels[j], moves[i], up == 1);
                    console2.log(
                        string.concat(
                            "one-shot | cap ",
                            decimalString(levels[j]),
                            " bps | venue ",
                            up == 1 ? "+" : "-",
                            hundredths(moves[i]),
                            "% | ",
                            up == 1 ? "pool leg: buy, 1e22 specified" : "pool leg: sell, the amount bought",
                            r.failed != 0
                                ? " | refused: CorrectionFailed, trade settled"
                                : string.concat(" | recaptured, pushed ", decimalString(r.pushed / 1e15), "e15")
                        )
                    );
                    assertTrue(r.out != 0, "the trade went through");
                    assertTrue(r.failed == 0 || !r.otherReason);
                    assertTrue(r.failed == 0 || r.pushed == 0);
                }
            }
        }
    }

    function _case(uint16 level, uint256 moveBps, bool up) internal returns (Phase memory r) {
        uint256 snap = vm.snapshotState();
        (PoolKey memory key, PoolKey memory ref) = _pool(level);
        _moveRef(ref, up ? 1e18 * (10_000 + moveBps) / 10_000 : 1e18 * 10_000 / (10_000 + moveBps));
        vm.recordLogs();
        r.out = _buy(key, ETH, whale, 1e15);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 recaptured = TwoVenueExecutor.ArbRecaptured.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(arb) && logs[i].topics[0] == recaptured) {
                (bool cheapOnHookr, uint256 quoteIn,,,) =
                    abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256));
                // The first recapture's buy leg on the pool: the before-phase's, which closes the gap.
                if (cheapOnHookr && !r.hookrBuy) (r.hookrBuy, r.hookrBuyIn) = (true, quoteIn);
            }
            if (logs[i].emitter != address(root)) continue;
            if (logs[i].topics[0] == FAILED) {
                r.failed++;
                r.reason = abi.decode(logs[i].data, (bytes4));
                if (r.reason != CustomRevert.WrappedError.selector) r.otherReason = true;
            } else if (logs[i].topics[0] == SUCCEEDED) {
                r.succeeded++;
                (, uint256 pushed) = abi.decode(logs[i].data, (uint256, uint256));
                r.pushed += pushed;
            }
        }
        (r.after_,,,) = manager.getSlot0(key.toId());
        vm.revertToState(snap);
    }

    /// @dev One lane pool of a fresh subject on ETH at 1e24, bound to the cap at `level` bps with no ceilings and no
    ///      floors, and the executor's reference venue.
    function _pool(uint256 level) internal returns (PoolKey memory key, PoolKey memory ref) {
        HookrToken subject = _newSubject();
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(ETH, true, false, 200);
        members[0].config.advisory = address(cap);
        members[0].config.advisoryGasLimit = cap.ADVISORY_GAS();
        members[0].config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(level, uint256(cap.MAX_IN()), uint256(cap.MAX_IN()), uint256(0), uint256(0));
        (bytes32 family,) = launcher.launchAdvised{value: 1e24}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            data,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
        ref = _seedReference(key);
        _nextBlock();
    }

    /// @dev Moves the reference venue so the subject (currency1 against ETH) is `subjectPriceWad` ETH there.
    function _moveRef(PoolKey memory ref, uint256 subjectPriceWad) internal {
        uint160 target = uint160(Math.sqrt(1e36 / subjectPriceWad * 1e18) * (1 << 96) / 1e18);
        (uint160 now_,,,) = manager.getSlot0(ref.toId());
        mover.directSwap(ref, target < now_, -int256(1e26), target);
    }
}
