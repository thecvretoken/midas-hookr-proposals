// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {AdvisoryConformance} from "hookr-test/kit/AdvisoryConformance.sol";
import {MidasSizeCapAdvisory} from "../src/MidasSizeCapAdvisory.sol";

/// @notice Hookr's AdvisoryConformance kit, unmodified, run against MidasSizeCapAdvisory on a real HookrRoot (with
///         HookrRules, the launcher, router and quoter) on one PoolManager and one HookrRegistry.
/// @dev Only the kit's author hooks are filled in. The block serves HookrRoot pools only: a pair root's advisory
///      returns a surcharge and cannot refuse, so the eight pair checks are skipped. It is admitted with the cap,
///      gas limit and phases it declares: LP-fee cap 0, ADVISORY_GAS, BEFORE_SWAP. The kit builds the admission
///      itself and always sets failOpen true, since it launches a fail-open pool; the block declares failOpen false
///      (MidasSizeCapAdvisory.t.sol: test_declaredAdmission_refusesAFailOpenPool), and this run keeps the kit's.
///
///      Expected result: every root check passes except testFuzz_kit_root_surchargeWithinCap, which fails on its
///      `assertFalse(advice.reject, "reject")`. The kit is written for fee advisories and asserts that advice never
///      refuses; this block's advice is a refusal whenever a swap is over the cap.
///
///      The size cap reads no state of its own on the swap path. Its state is the pool's depth, so `_kitStress`
///      moves that: it withdraws a seed-picked share of the kit pool's launch position, leaving from all of it down
///      to a hundred-thousandth. At the kit pool's full depth (L = 1e24) no size in the fuzz's range (1e9 to 1e18)
///      reaches a 50 bps cap, so without the stress the fuzz would never meet a refusal. `_kitWorstCase` keeps the
///      default: the kit pools open exactly on tick 0's boundary, the state where a swap down reads one more slot.
contract MidasSizeCapConformanceTest is AdvisoryConformance {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev The kit pools' size cap: 50 bps of sqrt impact, 1e22 of either token per swap.
    uint256 internal constant KIT_IMPACT_BPS = 50;
    uint256 internal constant KIT_MAX_IN = 1e22;

    /// @dev The launcher family of the kit's fail-closed HookrRoot pool, read from its FamilyLaunched event.
    bytes32 internal kitRootFamily;

    function setUp() public override {
        vm.recordLogs();
        super.setUp();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("FamilyLaunched(bytes32,address,address,address)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(launcher) || logs[i].topics[0] != topic) continue;
            bytes32 family = logs[i].topics[1];
            if (PoolId.unwrap(launcher.position(family, 0).key.toId()) == PoolId.unwrap(kitRootKey.toId())) {
                kitRootFamily = family;
            }
        }
        require(kitRootFamily != bytes32(0), "kit root family not found");
    }

    function _kitDeploy() internal override returns (address) {
        return address(new MidasSizeCapAdvisory(manager));
    }

    function _kitRootData() internal pure override returns (bytes memory) {
        return abi.encode(KIT_IMPACT_BPS, KIT_MAX_IN, KIT_MAX_IN);
    }

    /// @dev Unused: the block serves no pair roots.
    function _kitPairData(uint24) internal pure override returns (bytes memory) {
        return "";
    }

    function _kitArtifact() internal pure override returns (string memory) {
        return "out/MidasSizeCapAdvisory.sol/MidasSizeCapAdvisory.json";
    }

    function _kitOwnBuild() internal pure override returns (bool) {
        return true;
    }

    function _kitSupportsPair() internal pure override returns (bool) {
        return false;
    }

    /// @dev The declared LP-fee cap: the block never surcharges, and `bind` refuses an admission with any other.
    function _kitRootCapPips() internal pure override returns (uint24) {
        return 0;
    }

    function _kitRootGasLimit() internal view override returns (uint32) {
        return MidasSizeCapAdvisory(kitAdvisory).ADVISORY_GAS();
    }

    function _kitRootPhases() internal view override returns (uint8) {
        return MidasSizeCapAdvisory(kitAdvisory).PHASES();
    }

    /// @dev Unused: the block serves no pair roots. The registry's floor.
    function _kitPairGasLimit() internal pure override returns (uint32) {
        return 25_000;
    }

    /// @dev The block reads the PoolManager's storage on every swap, so the gas check cools it too.
    function _kitCold() internal override {
        vm.cool(kitAdvisory);
        vm.cool(address(manager));
    }

    /// @dev Withdraws all but 1 / 10^(seed % 6) of the kit root pool's launch position, then advances the clock by up
    ///      to 8 days as the default does.
    function _kitStress(address binder, PoolId id, uint256 seed) internal override {
        if (binder == address(root) && PoolId.unwrap(id) == PoolId.unwrap(kitRootKey.toId())) {
            uint128 held = launcher.position(kitRootFamily, 0).liquidity;
            uint128 keep = uint128(held / 10 ** (seed % 6));
            if (keep < held) {
                launcher.withdraw(kitRootFamily, 0, held - keep, 0, 0, address(this), vm.getBlockTimestamp());
            }
            assertEq(manager.getLiquidity(id), keep, "stressed depth");
        }
        super._kitStress(binder, id, seed >> 8);
    }
}
