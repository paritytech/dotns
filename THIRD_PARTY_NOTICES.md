# Third-party notices

This project (MIT) incorporates or builds against the following third-party components. Each is the
property of its respective authors and is used under its own licence. This file is a convenience
summary; the licence text shipped with each dependency is authoritative.

## Code derived from ENS

Parts of the DotNS contract suite are adapted from the Ethereum Name Service (ENS) contracts
(registry / registrar / resolver / reverse-resolver structure, namehash and labelhash, and the
commit-reveal registration flow). The ENS contracts are MIT-licensed and copyright True Names
Limited. The MIT licence requires the original copyright and permission notice to be retained; it is
reproduced here in full:

> MIT License
>
> Copyright (c) 2018, True Names Limited
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
> associated documentation files (the "Software"), to deal in the Software without restriction,
> including without limitation the rights to use, copy, modify, merge, publish, distribute,
> sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or
> substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
> NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
> NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
> DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
> OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Source: https://github.com/ensdomains/ens-contracts

## Solidity libraries

These are vendored under `lib/` (pinned by commit in `setup.bash` or `.gitmodules`).

| Library                            | Licence          | Used by deployed contracts                  | Source                                                             |
| ---------------------------------- | ---------------- | ------------------------------------------- | ------------------------------------------------------------------ |
| forge-std                          | MIT / Apache-2.0 | No (test/scripts only)                      | https://github.com/foundry-rs/forge-std                            |
| OpenZeppelin Contracts             | MIT              | Yes                                         | https://github.com/OpenZeppelin/openzeppelin-contracts             |
| OpenZeppelin Contracts Upgradeable | MIT              | Yes                                         | https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable |
| OpenZeppelin Foundry Upgrades      | MIT              | No (deploy tooling)                         | https://github.com/OpenZeppelin/openzeppelin-foundry-upgrades      |
| Solady                             | MIT              | Yes (`contracts/deploy/Create3Factory.sol`) | https://github.com/Vectorized/solady                               |
| halmos-cheatcodes                  | AGPL-3.0         | No — not imported anywhere                  | https://github.com/a16z/halmos-cheatcodes                          |

Note on halmos-cheatcodes: it is AGPL-3.0, but no contract, script, or test in this repository imports
it, so it does not affect the licensing of this project's code. Consider removing it from `setup.bash`
if it is no longer needed.

## External interface definitions

The following files under `contracts/external/` are interface definitions retaining the licence of
their upstream source (the SPDX header in each file is authoritative):

- `contracts/external/personhood/IPersonhood.sol` — GPL-3.0-only (upstream personhood pallet interface)
- `contracts/external/revive/ISystem.sol` — Apache-2.0 (upstream revive/system interface)

## npm dependencies

The npm dependency tree (build/test tooling: viem, vitest, ts-node, typescript, prettier, dotenv,
cross-env, @openzeppelin/upgrades-core, and their transitive dependencies) is entirely permissive:
predominantly MIT, with ISC, BSD-2-Clause, BSD-3-Clause, and Apache-2.0. Two transitive packages
(`ethereumjs-util`, `rlp`) are MPL-2.0, a file-level weak copyleft compatible with MIT outbound. No
GPL/AGPL packages are present in the npm tree. Regenerate this summary with:

```bash
npx license-checker-rseidelsohn --summary
```
