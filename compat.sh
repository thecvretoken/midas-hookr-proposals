#!/usr/bin/env bash
# Compiles every SweepGuard function against v4-core at the commit deps.sh pins (Uniswap's
# current main) and at the v4.0.0 release, with solc 0.8.24, 0.8.26 and 0.8.37, legacy and
# via-IR. Run `bash deps.sh` first. To use local compilers instead of forge's downloads, set
# SOLC_DIR to a folder holding binaries named solc-<version>.
set -uo pipefail
cd "$(dirname "$0")"
[ -d lib/v4-core/src ] || { echo "run bash deps.sh first"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/src/libraries" "$tmp/compat" "$tmp/lib/v4-core-pinned"
cp src/libraries/SweepGuard.sol "$tmp/src/libraries/"
cp compat/SweepGuardHarness.sol "$tmp/compat/"
cp -r lib/v4-core/src "$tmp/lib/v4-core-pinned/src"
git -c advice.detachedHead=false clone -q --depth 1 --branch v4.0.0 https://github.com/Uniswap/v4-core "$tmp/lib/v4-core-v4.0.0"
printf '[profile.default]\nsrc = "compat"\nlibs = ["lib"]\noptimizer = true\noptimizer_runs = 200\nevm_version = "cancun"\n' > "$tmp/foundry.toml"
fail=0
for core in pinned v4.0.0; do
  echo "@uniswap/v4-core/=lib/v4-core-$core/" > "$tmp/remappings.txt"
  for v in 0.8.24 0.8.26 0.8.37; do
    use="$v"
    [ -n "${SOLC_DIR:-}" ] && use="$SOLC_DIR/solc-$v"
    for ir in legacy via-ir; do
      flag=""
      [ "$ir" = via-ir ] && flag="--via-ir"
      if forge build --root "$tmp" --use "$use" $flag --force --out "$tmp/out" >/dev/null 2>"$tmp/err"; then
        echo "v4-core $core  solc $v  $ir  ok"
      else
        echo "v4-core $core  solc $v  $ir  FAILED"
        head -5 "$tmp/err"
        fail=1
      fi
    done
  done
done
exit $fail
