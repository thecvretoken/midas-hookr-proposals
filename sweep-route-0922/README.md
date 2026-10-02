# sweep-route-0922

The test and patch sent on 22 Sep 2026, pinned so they can be run instead of read.

`patches/MidasRWAHook.fix.patch` and `patches/MidasRWAHook.t.patch` are the two patches as attached. They apply cleanly to github.com/thecvretoken/midas-rwa-hook at 5f68ff4, whose files are the pre-image blobs a9ba41a and 032a758 named in the patch headers.

`src/MidasRWAHook.sol` is 5f68ff4 with the fix applied. It hashes to git blob 9248daf, the post-image the patch names. `test/MidasRWAHook.t.sol` is 5f68ff4 with the harness patch applied, blob b326c18.

`test/SweepRoute.t.sol` is the attached test file, unchanged. It was sent as US-ASCII, so its em dashes arrived as "?" and are left as received.

`test/Case14Replay.t.sol` is new. It replays the 14% run with every intermediate value logged and pins both totals to the figures reported on 09-22. The case is written up in `../docs/SWEEP-GUARD.md`.

```bash
cd .. && bash deps.sh && cd sweep-route-0922
forge test                                   # 29: the original 25, the three from 09-22, the replay
forge test --match-test test_case14_replay -vv
```

What the fix does: seals the GOLD route set at deploy with a non-zero seed reference per route, and refuses any route not on it. It is not deployed. The MidasRWAHook at 0xC97C22C241EcD0B9fb5656307e47C8a674ee2088 predates it, and putting it live is a new deploy because the constructor changes.
