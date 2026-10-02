# Midas Hookr proposals

Six market rules proposed to Hookr, five of them built as Uniswap v4 hooks with Foundry test
suites, one written as a design spec because the market it needs does not exist yet. Plus
SweepGuard, the sweep rails from MidasRWAHook as a standalone library.

Prepared by Midas. Everything here is UNAUDITED and NOT DEPLOYED. The two deployed base hooks
these extend are listed at the bottom.

## What is in here

| Contract | Rule | Flags | Tests | Runtime |
|---|---|---|---|---|
| `MarketHoursGuardHook` | Widen the fee and clamp size while the quote asset's underlying market is shut | `0x2088` | 28 | 8,135 B |
| `PolicyEnvelopeHook` | A fee that floats inside immutable walls, moved by a capsule rather than an owner key | `0x2088` | 25 | 7,714 B |
| `TimeWeightedExitHook` | Price the exit, not just the entry: a sell fee decaying to base over the holding period, all to LPs | `0x2080` | 30 | 4,790 B |
| `BurnAttributionHook` | Attribute each burn contribution to the address that funded it, rebate the largest contributors | `0x20cc` | 22 | 8,207 B |
| `FloorBidHook` | Park fees as a standing bid the pool owns instead of burning them | `0x2088` | 26 | 13,147 B |
| Fee-Stream Collateral | Borrow against realised fees instead of selling supply | spec + interfaces | n/a | n/a |
| `SweepGuard` (library) | Cooldown, sqrt-space reference band and output floor for a conversion through a pool the caller does not control | n/a | 23 | n/a |

154 tests, all passing. solc 0.8.26, via_ir, optimizer 200 runs, cancun.

`sweep-route-0922/` holds the 22 Sep route-allowlist patch and its tests, pinned: 29 passing.

## Reviewer briefs

One per rule in `docs/`, each covering the mechanism, the permission flags, the authority
surface, the parameters and their ceilings, the invariants with the test that proves each,
the failure cases stated plainly, and where the rule fits in a modular stack.

`docs/SWEEP-RAILS.md` is not one of the six rules. It is a standalone writeup of three guards
that keep a permissionless conversion safe when the hook has to trade through a pool it does
not control and has no trustworthy price for: a per-route rate limit, a self-maintained
reference band compared in sqrt space, and a slippage floor against the pre-swap spot quote.
They are extracted from the deployed `MidasRWAHook` and are reusable independently of it.

`docs/SWEEP-GUARD.md` covers the library built from them: the API, the four attack scenarios
with measured results, and the 22 Sep 14% case step by step.

`docs/FEE-STREAM-COLLATERAL.md` is the design spec for the credit idea, with
`src/interfaces/IFeeStream.sol` and `src/interfaces/IFeeStreamCredit.sol` encoding it. There is
no implementation on purpose: credit against an undeployed credit market is a memo, not a
proposal.

## The design rules every contract here follows

No owner, no upgrade path, and no setter that touches a fee rate, a fee destination, or a
ceiling. Every rate is a constant or a constructor immutable validated against a hardcoded
ceiling at deploy.

Where a parameter has to move, it moves only inside immutable bounds and can never redirect
where value goes. That is the Policy Envelope pattern, and `MarketHoursGuardHook` uses a
minimal version of it for its session table.

The fallback state is always the conservative one. An unconfigured pool trades on closed
terms, an unstamped seller pays the full exit fee, a stream with no history values at zero.

No oracles. Every rule here reads `block.timestamp`, the pool's own slot0, or the hook's own
accounting, and nothing else.

## Build

```bash
bash deps.sh
forge test -vv
```

`deps.sh` clones every dependency into `lib/` at the exact commit the suites were run against:
v4-core, v4-periphery, uniswap-hooks (OpenZeppelin, BaseHook lives here now), forge-std,
openzeppelin-contracts, solmate. Remappings are in `remappings.txt`. `gold-standard/` keeps its
own pin, v4-core a22414e4, because the deployed source predates the move of `SwapParams`.

## The deployed base hooks these extend

Both on Robinhood Chain (chain 4663), source verified on Blockscout, unaudited, deployed via
CREATE2 from `0x7689f33dac018e92A33EF6F49CC51D150544f393`.

`GoldStandardHook` at `0xA0E75Ca3470638AF11417e0EAC79a1f50129e0cC` lets any ERC-20 pair against
PAXG. Creation tx `0xde809abb913060c9ce654f02d66772a374e5defbd663f9dfb2339bdca0665d15`.

`MidasRWAHook` at `0xC97C22C241EcD0B9fb5656307e47C8a674ee2088` is the launch template for
tokens quoted in Robinhood Chain stock tokens. Creation tx
`0x02d3b78870b50cb23abe4dff770aef3ff04cb2c8b8498f6360b833d86e92552c`. Source at
github.com/thecvretoken/midas-rwa-hook, 25 tests passing.

## Disclosure

The author receives a template royalty on pools that adopt `GoldStandardHook`, `MidasRWAHook`,
`PolicyEnvelopeHook` and `MarketHoursGuardHook`, and holds GOLD, which `MidasRWAHook`'s burn
share buys. `TimeWeightedExitHook`, `BurnAttributionHook` and `FloorBidHook` carry no royalty
and no deployer share: they are proposed as blocks, not as templates. Every royalty recipient
in this repository is an immutable with no setter, including for the author.

## Dependencies

`lib/` is gitignored. `bash deps.sh` fills it at these commits:

| Dependency | Commit |
|---|---|
| Uniswap/v4-core | 46c6834698c48bc4a463a86d8420f4eb1d7f3b75 |
| Uniswap/v4-periphery | 9969eec44cfdf07e24b41de47f40276a58401976 |
| OpenZeppelin/uniswap-hooks | 9894eda2554e72eed6840e36c794dd8f1e87833a |
| foundry-rs/forge-std | c6fa5d82a3a287c4ff23f26c8f7e2958aafd32d9 |
| OpenZeppelin/openzeppelin-contracts | 40a51f7e78852e48d0b128d4ee3d620cbc7d35d8 |
| transmissions11/solmate | 89365b880c4f3c786bdd453d4b8e8fe410344a69 |
