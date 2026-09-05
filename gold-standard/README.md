# GoldStandardHook, deployed source and test suite

This folder tests the contract that is LIVE on Robinhood Chain at
0xA0E75Ca3470638AF11417e0EAC79a1f50129e0cC. `src/GoldStandardHook.sol` is
the verified source pulled from Sourcify, unmodified. Its SHA-256 is
a926600a682f430f228d87490dc26411b24cac47e03165e9217f927a6d924cd6.

Compiled with the settings and remappings in this folder against v4-core at
commit a22414e4 (the 17 library files Sourcify recorded for the deployment
hash-match that commit exactly), solc 0.8.26, optimizer 200, no via-IR,
cancun, the runtime bytecode reproduces the on-chain contract including the
IPFS metadata hash 3f02500f8a79bdf04e0f25cf5da5d531b9736c3d94e2a41e4744860922d17989.

The suite was written after deployment, against the deployed code. 44 tests.

```bash
cd gold-standard
mkdir -p lib && cd lib
git clone https://github.com/Uniswap/v4-core.git && cd v4-core && git checkout a22414e4 && git submodule update --init lib/forge-std lib/solmate lib/openzeppelin-contracts && cd ..
ln -s v4-core/lib/forge-std forge-std && cd ..
forge build && forge test -vv
```
