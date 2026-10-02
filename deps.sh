#!/usr/bin/env bash
# Clones every dependency at the exact commit the suites were run against (2 Oct 2026).
# Run from the repo root with: bash deps.sh. It serves the root project and sweep-route-0922/.
# gold-standard/ has its own pin (v4-core a22414e4); see gold-standard/README.md.
set -euo pipefail
mkdir -p lib
pin() {
  local dir="lib/$1" url="$2" sha="$3"
  [ -d "$dir/.git" ] || git clone --quiet --filter=blob:none "$url" "$dir"
  git -C "$dir" fetch --quiet origin "$sha" 2>/dev/null || true
  git -C "$dir" checkout --quiet "$sha"
  echo "$1 @ $(git -C "$dir" rev-parse --short HEAD)"
}
pin v4-core                https://github.com/Uniswap/v4-core.git                46c6834698c48bc4a463a86d8420f4eb1d7f3b75
pin v4-periphery           https://github.com/Uniswap/v4-periphery.git           9969eec44cfdf07e24b41de47f40276a58401976
pin uniswap-hooks          https://github.com/OpenZeppelin/uniswap-hooks.git     9894eda2554e72eed6840e36c794dd8f1e87833a
pin forge-std              https://github.com/foundry-rs/forge-std.git           c6fa5d82a3a287c4ff23f26c8f7e2958aafd32d9
pin openzeppelin-contracts https://github.com/OpenZeppelin/openzeppelin-contracts.git 40a51f7e78852e48d0b128d4ee3d620cbc7d35d8
pin solmate                https://github.com/transmissions11/solmate.git        89365b880c4f3c786bdd453d4b8e8fe410344a69
