# MidasSizeCapAdvisory

SweepGuard's size cap as a Hook Block for the Hook Blocks Market: an `IHookrAdvisory` that refuses a swap larger than its pool's cap. It never charges a surcharge and never takes quote.

Author: Midas. Status: unaudited, nothing deployed. Source `hookr-size-cap/src/MidasSizeCapAdvisory.sol`. Tests `hookr-size-cap/test/MidasSizeCapAdvisory.t.sol` (19, the refuse path) and `hookr-size-cap/test/MidasSizeCapConformance.t.sol` (Hookr's conformance kit, unmodified, driven against the block). Built against github.com/Hookr-fun/hookr-contracts at `5ba9dfc9cc3d1b463315518f17dda8bb07f48d3b`, the interfaces in `hookr-1/src/interfaces` as they stand there, with `lib/forge-std` at `c179529c` and `lib/v4-core` at `46c68346` as its `foundry.lock` records. `hookr-size-cap/pin.sh` checks out exactly those. Every figure below comes from the `-vv` logs of those two files.

## What it is

A pool binds three numbers at launch: `maxImpactBps`, `maxQuoteIn` and `maxSubjectIn`. Before every swap the root asks the block, and the block answers `reject` when the swap is over the smaller of two bounds:

- the direction's ceiling on what one swap pays in, `maxQuoteIn` for a buy and `maxSubjectIn` for a sell, in raw units;
- the amount whose own move of sqrt price at the pool's active liquidity is `maxImpactBps`.

That is `SweepGuard.capIn` with one change: SweepGuard's `maxIn` belongs to a one-way route, and a pool trades both ways in two different tokens, so the ceiling is split by direction. The impact term is the same expression. `test_boundary_impact_exactInput_bothDirections` computes SweepGuard's term independently on the pool's own slot0 and liquidity and checks the block returns the same amount.

Exact input is checked on the specified amount. That is what the swap pays in before any fee, so the fees only make the real move smaller. Exact output is checked twice: the move the output itself makes at active liquidity against `maxImpactBps`, and the input that output costs at active liquidity, grossed up by the pool's base LP fee and rounded up, against the ceiling.

Active liquidity is the PoolManager's, read at the start of the swap, with one correction. When the price sits exactly on the boundary of the tick a swap moves into, the PoolManager crosses that tick before it trades anything, so the block applies that tick's `liquidityNet` the way the crossing will. Without it, a launch whose single-sided range ends at the opening price (the shape of a new-token launch with the subject as currency1) reads zero liquidity at tick 0, and every swap on the pool would be refused from its first block. `test_priceOnTickBoundary_readsTheSideTheSwapMovesInto` covers both token orders.

The block has no state of its own on the swap path. It reads its binding and the PoolManager's storage, and nothing else.

```solidity
struct Config { uint16 maxImpactBps; uint120 maxQuoteIn; uint120 maxSubjectIn; } // one slot per bound pool
enum Reason { OK, NO_PRICE, NO_LIQUIDITY, OVER_CEILING, OVER_IMPACT, BAD_FEE }

function configSchemaHash() external pure returns (bytes32);
function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data) external returns (bytes32);
function beforeAddLiquidity(PoolId, address) external pure returns (bool);                 // always true
function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory);
function afterSwap(HookrTypes.SwapContext calldata, int128, int128) external pure returns (HookrTypes.Advice memory); // never called
function config(address root, PoolId id) external view returns (Config memory);
function explainSwap(address root, HookrTypes.SwapContext calldata x) external view
    returns (bool allowed, Reason reason, uint256 amountIn, uint256 limitIn);
function maxExactInput(address root, PoolId id, bool zeroForOne, bool isBuy) external view returns (uint256);
```

`explainSwap` and `maxExactInput` are for UIs and keepers, as HookrComplianceGuard's `explainSwap` is: what the block would decide, why, and the largest exact input it admits now.

## What it declares

The admission Hookr would queue through the timelock, and what `bind` holds every pool to:

| Admission field | Value | Why |
|---|---|---|
| `kind` | ADVISORY | |
| `schemaHash` | `keccak256("MidasSizeCap(uint16 maxImpactBps,uint120 maxQuoteIn,uint120 maxSubjectIn)")` = `0x0e448ae3bf2cb0518ecdca6f2d22ee6f331fc669cb69cb425b85a5fbfb9f2294` | `configSchemaHash()` returns it |
| `caps` | `(0, 0, 0)`: LP-fee cap 0, quote-take cap 0, subject-take cap 0 | The block never surcharges and never takes. A fail-open pool whose advisory call fails charges the admitted LP-fee cap, so zero there means a failure costs the trader nothing extra. `bind` refuses an admission with any cap above zero |
| `gasLimit` | `ADVISORY_GAS` = 100,000 | The root forwards it to `bind` as well as to every swap-path call. Cold `bind` measures 48,763 and the heaviest cold `beforeSwap` 16,509, so it covers `bind` about twice over and `beforeSwap` about six times over. `bind` refuses a pool with less |
| `phaseMask` | `PHASES` = BEFORE_SWAP (1) | The cap is decided before the swap. `bind` refuses any other phases, so `afterSwap` is never called |
| `feeOnly` | true | It takes no charge of any kind, and fail-open admission requires it |
| `failOpen` | true, if Hookr wants the block in fail-open slots | Run it fail-closed (below) |

`bind` also checks the caller is the pool's hook, the pool names this contract as its advisory, and the root's PoolManager is the block's. Every check has its own code in `InvalidPoolConfig(uint8)` and `InvalidTerms(uint8)`, listed in the NatSpec, in the same pattern as HookrComplianceGuard.

## Fail-closed and fail-open

Read from `HookrRoot._advice` and `beforeSwap` at the pinned commit, and asserted with the exact revert data:

- Fail-closed slot. A refusal reverts the swap with the root's `SwapRejected()` (`HookrRoot.sol` line 432 on the full path, 381 on the fee-only path), wrapped by the PoolManager in `WrappedError(root, beforeSwap, SwapRejected, HookCallFailed)`. `test_failClosed_overCapBuyRefused_atCapBuyFills`, `test_failClosed_overCapSellRefused_atCapSellFills`.
- Fail-open slot. `_advice` refuses `reject` or a take from any fail-open advisory (line 817), so the same refusal reverts the swap as `InvalidModuleResult(advisory)`. The block gives the same advice in both slots. `test_failOpen_refusalRevertsTheSwap`.
- What fail-open changes is a failed call. A revert or an out-of-gas lets the swap through at the admitted LP-fee cap (lines 805 to 811), here zero, so an over-cap swap fills unchecked. A fail-closed pool reverts it with the block's reason inside `ModuleCallReverted`. `test_failOpen_failedCallLetsAnOverCapSwapThrough` shows both with a mocked failure.

The block never reverts on a bound pool and never runs past its gas limit: `testFuzz_neverRevertsOnABoundPool` drives any specified amount (the int256 extremes included), any direction, any base fee and any pool price, out of range included, through a staticcall with exactly `ADVISORY_GAS`, and every answer is four clean words with no surcharge, no take and no recipient. So in practice both slots refuse the same swaps; they differ in the error and in what a failed call would do. Run it fail-closed, as Hookr asks of a block that refuses.

## Parameters and ceilings

`bind` takes `abi.encode(maxImpactBps, maxQuoteIn, maxSubjectIn)`, exactly three words, and enforces:

- `1 <= maxImpactBps <= MAX_IMPACT_BPS = 2,000`. 2,000 bps of sqrt is about +44% / -36% in price. Zero would refuse every swap.
- `1 <= maxQuoteIn, maxSubjectIn <= MAX_IN = 2^120 - 1`, the most the packed slot holds. Raw units, so the sane level depends on the tokens; size it from the depth the pool is expected to hold, as SweepGuard's `maxIn`.

A word with high bits set fails its range check. `test_bind_termsAtAndPastTheirCeilings` binds the ceilings themselves and the floor (1, 1, 1), and refuses zero, ceiling plus one, a dirty word and a wrong length. `test_bind_badTermsStopTheLaunch` sends bad terms through the real launcher and the pool does not open: the root reverts with `ModuleCallReverted(block, bind, InvalidTerms(2))`.

Choosing the numbers is SweepGuard's rule. A sandwich around one swap pays only when the swap is larger than about the pool's fee times its depth, so `maxImpactBps` at or under the lowest LP fee the pool can charge makes the sandwich a loss. Liquidity added just in time inflates the impact cap; the ceilings do not move, so they are the bound that holds against that.

## The conformance kit

`hookr-1/test/kit/AdvisoryConformance.sol` runs unmodified, from the pinned checkout. `MidasSizeCapConformanceTest` fills in only the author hooks:

| Hook | Value |
|---|---|
| `_kitDeploy` | `new MidasSizeCapAdvisory(manager)` |
| `_kitRootData` | 50 bps, 1e22, 1e22 |
| `_kitRootCapPips` | 0, the declared LP-fee cap |
| `_kitRootGasLimit`, `_kitRootPhases` | `ADVISORY_GAS`, `PHASES` read from the block |
| `_kitSupportsPair` | false: a pair root's advisory returns a surcharge and has no way to refuse |
| `_kitOwnBuild`, `_kitArtifact` | true, `out/MidasSizeCapAdvisory.sol/MidasSizeCapAdvisory.json` |
| `_kitCold` | cools the block and the PoolManager, since the block reads the PoolManager on every swap |
| `_kitStress` | withdraws a seed-picked share of the kit pool's launch position, leaving 1 / 10^(seed % 6) of it, then advances the clock as the default does |
| `_kitWorstCase` | default. The kit pools open exactly on tick 0's boundary, the state where a swap down reads one more slot |

The size cap's state is the pool's depth, so that is what the stress moves. At the kit pool's full depth (L = 1e24) no size in the fuzz's range (1e9 to 1e18) reaches a 50 bps cap; without the stress the fuzz would pass without meeting a single refusal.

Result: 7 pass, 1 fails, 8 skipped.

| Check | Result |
|---|---|
| `test_kit_root_bindsOnce` | pass |
| `test_kit_root_returnSizes` | pass |
| `test_kit_root_gasAtCap` | pass, cold `beforeSwap` 13,981 and 15,151 gas against the 100,000 limit, and the fail-closed pool trades 1e18 both ways |
| `test_kit_root_failOpen` | pass |
| `test_kit_root_launchBuy` | pass, the 1e21 dev buy fills on a fail-closed pool bound to the block |
| `test_kit_root_declarations` | pass: every IHookrAdvisory selector, BEFORE_SWAP admitted, codehash pinned, no DELEGATECALL, CALLCODE, SELFDESTRUCT or EIP-7702 designator |
| `test_kit_plainCodeIgnoresTheTrailingLength` | pass |
| `testFuzz_kit_root_surchargeWithinCap` | fails on `assertFalse(advice.reject, "reject")` |
| the eight `*_kit_pair_*` checks | skipped, `_kitSupportsPair` is false |

The one failure is the one Hookr flagged in advance. The fuzz asserts that advice never refuses, which holds for a fee advisory, and a size cap's job is to refuse. One run's counterexample was `args=[7205, true, false, 8]`: seed 7205 leaves 1/10^5 of the position, L = 1e19, and an exact-output buy of about 1e18 moves sqrt price about 10%, twenty times the 50 bps cap, so the advice is `reject`. The fuzz's other assertions (a surcharge within the cap, no quote take, the root's quote within the pool cap) are ones the block meets on every swap: its advice never carries a surcharge or a take (`testFuzz_neverRevertsOnABoundPool`). The counterexample changes from run to run because the fuzz seed is random; the failing assertion does not.

## Refuse-path tests

Against the same real HookrRoot, HookrRules, launcher, router and quoter as the kit (Hookr's `PeripheryFixture`, unmodified), with the block admitted as it declares itself and bound by three pools launched through `HookrLauncher.launchAdvised`: a fail-closed and a fail-open pool at 50 bps, `maxQuoteIn` 1e21 and `maxSubjectIn` 2e21 (the ceilings bind), and a fail-closed pool at 10 bps with both ceilings at `MAX_IN` (the impact cap binds). All open at price 1 with L = 1e24 across ticks -60000..60000.

| Property | Test |
|---|---|
| Fail-closed: one unit over the ceiling is refused with `SwapRejected`, exactly the ceiling fills, buy and sell | `test_failClosed_overCapBuyRefused_atCapBuyFills`, `test_failClosed_overCapSellRefused_atCapSellFills` |
| Fail-open: the same refusal reverts the swap as `InvalidModuleResult(block)` | `test_failOpen_refusalRevertsTheSwap` |
| Fail-open: a failed call lets an over-cap swap through at the native fee; fail-closed reverts it | `test_failOpen_failedCallLetsAnOverCapSwapThrough` |
| Ceiling, exact input, both directions: at the ceiling admitted, one more refused (`OVER_CEILING`) | `test_boundary_ceiling_exactInput_bothDirections` |
| Impact cap, exact input, both directions: equals SweepGuard's term, admitted at the cap and fills with a realised move within the cap, one more refused (`OVER_IMPACT`) | `test_boundary_impact_exactInput_bothDirections` |
| Impact cap, exact output, both directions: the largest output within the move is admitted and fills, one more refused | `test_boundary_impact_exactOutput_bothDirections` |
| Ceiling, exact output, both directions: the cost is checked as specified, the largest output whose cost fits fills, the next is refused | `test_boundary_ceiling_exactOutput_bothDirections` |
| No active liquidity refuses every swap, one unit included, either way and either type | `test_noActiveLiquidity_refusesEverySwap` |
| A price on a tick boundary is read on the side the swap moves into | `test_priceOnTickBoundary_readsTheSideTheSwapMovesInto` |
| Out-of-range and malformed terms revert; the ceilings themselves bind | `test_bind_termsAtAndPastTheirCeilings`, `test_bind_badTermsStopTheLaunch` |
| A pool or admission other than declared is refused (hook, advisory, phases, gas, PoolManager, caps), and a pool binds once | `test_bind_refusesWhatItDoesNotDeclare` |
| Every `beforeSwap` path, cold, and `bind`, cold, fit `ADVISORY_GAS` | `test_gas_everyPathUnderTheDeclaredLimit` |
| No admin or upgrade surface: the artifact exposes exactly 13 functions, 18 owner, upgrade, pause and setter probes revert from an outside caller and from the root, no EIP-1967 slot is set, no ether is accepted | `test_probe_noAdminOrUpgradeSurface` |
| Nothing writes storage outside `bind`: every view, and an admitted and a refused swap through the router recorded as a full state diff, write nothing; `bind` writes only its binding slot | `test_probe_writesNoStorageOutsideBind` |
| The runtime has no CALL, CALLCODE, DELEGATECALL, CREATE, CREATE2, SELFDESTRUCT or TSTORE; its six external call sites are STATICCALL and it has one SSTORE | `test_probe_runtimeOpcodes` |
| `beforeSwap` never reverts on a bound pool, at any amount, fee or price | `testFuzz_neverRevertsOnABoundPool` |
| Any exact input up to `maxExactInput` fills with a realised move within the cap; anything above is refused | `testFuzz_exactInput_admittedMovesWithinTheCap_restRefused` |

Measured boundaries on the 1e24 pools: the 10 bps impact cap admits an exact-input buy of 999,999,999,999,999,999,999 and a sell of 1,001,001,001,001,001,001,001 (token1 in and token0 in respectively). Under the 1e21 and 2e21 ceilings the largest exact outputs are a buy of 996,006,981,039,903,216,493 and a sell of 1,990,031,876,438,381,866,558, the difference being the 0.30% base fee and the output's own impact.

## Gas

Cold, with the block and the PoolManager cooled, from `test_gas_everyPathUnderTheDeclaredLimit`:

| Call | Gas |
|---|---|
| `beforeSwap`, exact input, price moving up | 16,509 |
| `beforeSwap`, exact input, moving down across tick 0 (reads one more slot) | 15,178 |
| `beforeSwap`, exact input, over the ceiling | 14,533 |
| `beforeSwap`, exact input, over the impact cap | 15,180 |
| `beforeSwap`, exact output, admitted | 15,862 |
| `beforeSwap`, exact output, over the impact cap | 14,758 |
| `bind`, with the block, the root and the registry cold | 48,763 |

The kit's own cold measurement in `test_kit_root_gasAtCap` is 13,981 and 15,151. The declared limit is 100,000. Runtime size 6,936 bytes.

## Authority surface

None. No owner, no setter, no pause, no upgrade path, no proxy, no DELEGATECALL. The PoolManager is a constructor immutable. A pool's terms are written once, in `bind`, under the calling root's address, so a caller can only write its own namespace, and nothing changes them afterwards. Every other function is view or pure. The external calls are all reads: the PoolManager's slot0, liquidity and one tick's liquidity on the swap path, and in `bind` the root's `poolManager()` and `registry()` and the registry's `admission` for this contract. The runtime holds no CALL opcode at all.

## Failure cases and limits

Fails closed in a fail-closed slot. A refused swap reverts and moves nothing.

- The impact cap assumes the active liquidity holds across the move. Depth concentrated right at spot over a thin range beyond lets a swap at the cap move further than the cap. The ceilings bound it.
- No active liquidity at the price refuses every swap, including one that would jump a gap to the next range. A pool pushed out of all its ranges stays refused until liquidity returns at its price.
- Exact output is checked on the specified output. The root adds the Rules' reservation on top after the advice (the Auto Burn share on an exact-output buy, the quote take on an exact-output sell), so the pool's own output, and its move, can be larger by that share. The cost check grosses up by the base LP fee only, so Rules surcharges are outside it too.
- The cap is per swap. A trader can split a large trade into swaps under the cap; each one is bounded, and the sandwich arithmetic holds per swap.
- Ceilings are raw units per direction, fixed at bind. A token with odd decimals needs ceilings set for it.
- The block reads one PoolManager, fixed at deploy, and refuses to bind for a root on another.
- An arb recapture executor's leg on a pool with an advisory is asked like any other swap (`HookrRoot.beforeSwap`), so the cap applies to legs too.

## What testing turned up

The first run of the kit failed in setUp with `vm.getCode: no matching artifact found`. Forge looks up `deployCode("PoolManager.sol:PoolManager")` only among the artifacts of the files a filtered or cached run selects, and the PoolManager compiles from a separate 0.8.26 fixture. `unchecked_cheatcode_artifacts = true` in `foundry.toml` lets the fixture read it from `out/`. Nothing in Hookr's files changed.

The tick-boundary case above came up while reading the kit's launch-buy check, which builds exactly that single-sided range. Reading `getLiquidity` alone, as SweepGuard does, refuses that dev buy whenever the subject sorts as currency1.

## Build settings

hookr-1 compiles with solc 0.8.37, via-IR, optimizer 200 runs, EVM prague, and its kit files require `^0.8.37`. `hookr-size-cap/foundry.toml` uses those settings so the block is built the way Hookr builds its own blocks; the PoolManager fixture compiles with 0.8.26, as hookr-1's does. This differs from the root of this repository (0.8.26, cancun). The source is `pragma solidity ^0.8.26` and also compiles with 0.8.26 for cancun, via-IR and legacy.

## Running it

```bash
cd hookr-size-cap
bash pin.sh            # hookr-contracts @ 5ba9dfc9, lib/forge-std @ c179529c, lib/v4-core @ 46c68346
forge test             # 35: 26 pass, 1 fails (testFuzz_kit_root_surchargeWithinCap, the expected one), 8 skipped
forge test --no-match-test testFuzz_kit_root_surchargeWithinCap   # 26 pass, 8 skipped
forge test --match-contract MidasSizeCapAdvisoryTest -vv           # the 19 refuse-path tests with their figures
```

Unaudited, nothing deployed.
