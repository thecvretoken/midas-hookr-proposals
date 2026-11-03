#!/usr/bin/env bash
# Clones Hookr's contracts at the exact commit this block was built and tested against (3 Nov 2026), with the two
# submodules hookr-1 builds from at the commits its foundry.lock records. Run from this folder: bash pin.sh.
# The kit, HookrRoot and every interface the block imports come from this checkout; nothing is copied or edited.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p lib
HOOKR=5ba9dfc9cc3d1b463315518f17dda8bb07f48d3b
FORGE_STD=c179529c064588ede54a0661ec3cc98219460d07
V4_CORE=46c6834698c48bc4a463a86d8420f4eb1d7f3b75
dir=lib/hookr-contracts
[ -d "$dir/.git" ] || git clone --quiet --filter=blob:none https://github.com/Hookr-fun/hookr-contracts.git "$dir"
git -C "$dir" fetch --quiet origin "$HOOKR" 2>/dev/null || true
git -C "$dir" -c advice.detachedHead=false checkout --quiet "$HOOKR"
git -C "$dir" submodule update --quiet --init --recursive lib/forge-std lib/v4-core
pinned() {
  local path="$1" want="$2" got lock
  got=$(git -C "$dir/$path" rev-parse HEAD)
  lock=$(sed -n "/\"$(echo "$path" | sed 's#/#\\/#g')\"/,/rev/s/.*\"rev\": \"\([0-9a-f]*\)\".*/\1/p" "$dir/foundry.lock")
  if [ "$got" != "$want" ] || [ "$lock" != "$want" ]; then
    echo "$path is at $got, foundry.lock says $lock, expected $want"
    exit 1
  fi
  echo "$path @ ${got:0:8}"
}
echo "hookr-contracts @ $(git -C "$dir" rev-parse --short=8 HEAD)"
pinned lib/forge-std "$FORGE_STD"
pinned lib/v4-core "$V4_CORE"
