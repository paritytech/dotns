# DotNS Release Artifacts

What each release publishes, what the files guarantee, and how to consume them.

## What a release contains

| Asset | Contents |
| --- | --- |
| `<Contract>.json` | One per contract and interface, the bare ABI array |
| `deployments.json` | Contract addresses, per network |
| `release-manifest.json` | What this release contains, machine readable |
| `codehashes.json` | Stripped-metadata hash of each contract's built runtime bytecode |
| `abi-diff.json` | Selector-level ABI changes since the previous release, machine readable |
| `dotns-abis-<tag>.zip` | The same files in one archive |

Every JSON asset is attached to the release individually, at the top level, with no folder. The zip holds the ABIs under `abis/` plus `deployments.json`, `release-manifest.json`, and `codehashes.json` at its root; `abi-diff.json` is generated together with the release body and attached individually.

The release surface is decided in `.github/abi-contracts.txt` so a contract reaches consumers only when it is listed there.

**Pre-releases carry no addresses.** A pre-release is cut in order to be deployed, so at that point the recorded addresses still belong to the previous deployment of different code. Publishing them under that tag would break the one thing `version` is for, namely that a release's addresses and its ABIs came from the same release. A pre-release therefore ships the ABIs, `release-manifest.json`, `codehashes.json`, and `abi-diff.json`, and the addresses arrive with the release that follows the deployment. `codehashes.json` is on the pre-release deliberately: deploys run from pre-release tags, and an upgrade diffs its build against the previous release's copy before touching a live network.

`deployments.json` and `release-manifest.json` were also added after this repository had already published releases, so an older release carries only the per-contract ABIs and the zip. That is expected rather than broken, and it cannot be corrected: releases here are immutable, so no asset can be attached after publication. Treat either file being missing as "this release predates it, or is a pre-release" and fall back, or pin a release you have checked.

## `deployments.json`

```json
{
  "version": "v1.2.3",
  "networks": {
    "paseo-assethub": {
      "chainId": 420420417,
      "contracts": {
        "DotnsProtocolRegistry": "0x0000000000000000000000000000000000000001",
        "DotnsRegistrar": "0x0000000000000000000000000000000000000002"
      }
    }
  }
}
```

- `version` is the release tag, so a consumer can assert its addresses and its ABIs came from the same release.
- Networks are keyed by deployment name, matching the `deployments/<network>/` directory the addresses come from.
- `chainId` is informational. **Do not index by it.** Chain ids are not unique here: several chains report 420420417 and do not all run the same deployment.
- One entry can serve more than one live network. `paseo-assethub` is the deployment that both previewnet and Paseo Asset Hub Next V2 run, because every network deployed through the shared CREATE3 factory lands on the same addresses. So expect entries named after deployments, not after every chain you might connect to.
- The names under `contracts` (`DotnsRegistrar`, `PopRules`) do not change, and a name always means the same contract. Your code can depend on that.
- Addresses are copied from the manifest verbatim, which the deploy pipeline writes EIP-55 checksummed. Compare them case-insensitively rather than relying on the casing.
- Only per-network manifests are published. `deployments/expected.json` — the fresh-deploy address set that CI and the genesis builder verify against (see `DEPLOYMENTS.md`) — is not a network and never appears here, so a release cut while an address move is awaiting its network's redeploy still advertises the addresses each live network actually runs.
- `LabelStoreBeacon` and `UserStoreBeacon` appear when deployed but are not network-stable, because the `StoreFactory` initialiser deploys them. Read them from the factory rather than pinning them.

## `release-manifest.json`

```json
{
  "version": "v1.2.3",
  "contracts": ["DotnsRegistrar", "PopRules"],
  "abiOnly": ["IDotnsRegistrar", "DotnsRoleManager"],
  "files": { "DotnsRegistrar": "abis/DotnsRegistrar.json" }
}
```

- `contracts` are deployable; `abiOnly` covers interfaces and abstract bases. The split comes from the build output, so it cannot disagree with what was compiled.
- `files` values are paths inside the zip. The same ABI is also attached to the release on its own, under the file name alone: `abis/DotnsRegistrar.json` in the zip is the `DotnsRegistrar.json` asset. Reading this map means never hardcoding the list of ABIs a release contains.

## `codehashes.json`

```json
{
  "version": "v1.2.3",
  "build": { "solcVersion": "0.8.34+commit...", "optimizer": {}, "viaIr": true, "evmVersion": "cancun", "foundryLockSha256": "..." },
  "hashes": { "DotnsRegistrar": "0x..." }
}
```

- `hashes` maps each deployable contract to the keccak256 of its built runtime bytecode with the trailing CBOR metadata stripped, so a comment-only edit does not read as a code change. Comparing two releases' files tells you exactly which contracts a release changed; an upgrade must cover that whole set before the release may be declared on a network (see `DEPLOYMENT_CHECKLIST.md`).
- These are artifact-side hashes, for comparing builds with builds. A deployed contract hashes differently on chain (its bytecode carries the metadata and any immutable values), so compare this file against another release's copy of it.
- `build` records the toolchain inputs. The same source under a different toolchain hashes differently, and that difference is a real code change on chain, so treat the hashes as comparable only alongside their build inputs.

## `abi-diff.json`

The machine-readable form of the "ABI changes since ..." section of the release body: per contract, the functions, events, and errors added, removed, or changed since the previous release, at selector level. A **changed signature** entry is the one to alert on: the name still exists but the selector moved (a struct parameter gained a field, say), so an un-updated caller gets a bare revert with no data. Contracts new to the release or no longer published are flagged as such. When no earlier release carries ABIs to diff against, the file says so instead of guessing.

## Stability

Unless a major version bump occurs, the layout of both files will not change: no key is removed, renamed, or given a different type. New keys may be added, so parse permissively and ignore what you do not recognise.

Addresses themselves are not part of that promise. A redeploy can move them, and when it does the release notes name the affected networks.

## How current the addresses are

Addresses are recorded by hand. A live deployment reports the addresses it produced but does not update this repository, so after one someone records them here, and a release publishes whatever is committed at the moment it is cut.

That leaves one way for a release to be out of date: a deployment moved an address and the commit had not landed yet. Nothing in the release process reads a live chain, so it cannot catch that.

Two ways to protect yourself. Resolve addresses through the protocol registry at runtime, so the chain is the authority and the published file is only a starting point. Or check a release against a chain yourself with `deployments:verify` before relying on it.

## Consuming it

Prefer resolving addresses at runtime. Every DotNS contract exposes `protocolRegistry`, and `DotnsProtocolRegistry.get(key)` resolves each well-known key in `DotnsConstants`, so one address from the artifact is enough to reach the rest and the chain remains the authority. Pin the whole set only when a runtime lookup is not possible.

Note that a `deployments.json` entry states where a contract was deployed, not that it is currently the live one for a role. The registry is the only answer to that question.

## Verifying a release

To check the addresses against a chain:

```bash
bun run deployments:verify --network paseo-assethub --rpc <eth-rpc-url>
```

It reads the well-known keys from `DotnsConstants.sol`, resolves each through the protocol registry, and checks that every resolved address is one the manifest records and has code, that every recorded contract is pointed at by some key. The beacons are reported as unverifiable, since nothing in the registry points at them. The `protocolRegistry` key (the registry registering itself, so its implementation has a declared codehash) is new; a network that predates it leaves the key unset, and verify skips that rather than treating it as a mismatch — except under `--tag`, which asserts a post-declaration network, so a missing self-key is an error there. That self-declared hash is sloppy-drift detection only — the declaration lives inside the contract it describes — so the trustless check against release artifacts stays off chain. `multicall3` is skipped unconditionally, for the opposite reason: it is deliberately never registered, since registry membership is a trust signal and Multicall3 is a generic call forwarder.

It compares the two sides as sets, so it does not check that a given key holds the contract you would expect; that pairing is asserted when a deployment is wired. It reads a committed manifest rather than a published asset, so run it from a checkout at the tag.

With `--tag vX.Y.Z` it additionally checks the chain's own declarations: `protocolVersion()` must equal the tag, and each key's declared codehash (`expectedCodehash(key)`) must match the code actually executing behind it, implementation-aware for proxies. A mismatch there means the code changed after the declaration was written, which is what an upgrade performed outside the release tooling looks like. A deployment that predates the declarations reports an empty version and zero hashes, which the check reports rather than tolerates, so only pass `--tag` for networks deployed at or after the release that introduced them.

## Publishing

`deployments.json`, `release-manifest.json`, and `codehashes.json` are generated during the release by `scripts/js/release-metadata.mjs build`, from the committed deployment manifests and the build that just ran; `abi-diff.json` comes from `abidiff` against the previous release's published ABIs. Neither is committed: an address stored in two tracked files eventually disagrees with itself, so `deployments/<network>/<chain-id>.json` is the only tracked copy.

That file holds exactly one address per contract, the current one. Each deploy overwrites the entries it produces, so it tracks only the latest deployment for a network and never a history of them; previous address sets exist only in this repository's git history. It also carries no implementation addresses behind the UUPS proxies, and no record of which commit was deployed.

The release fails before publishing if an expected file is missing from the draft, so a published release always carries the set it advertises.

The order for a release that changes contract code:

1. Cut a pre-release. It carries the ABIs but no addresses.
2. Deploy that tag from [`dotns-releases`](https://github.com/paritytech/dotns-releases). Deploying a tag rather than a branch is what ties the addresses to the code that produced them.
3. Record the resulting addresses in `deployments/<network>/<chain-id>.json`.
4. Cut the release from a commit that differs from the deployed tag only by that record, and run `deployments:verify` against the network first.
5. Re-declare the final tag on chain: the deploy declared the pre-release version (`protocolVersion()` returns e.g. `0.7.1-rc.1`), and the code is the same, so the owner runs `setProtocolVersion("0.7.1")` once the release exists. No codehash re-declaration is involved, since no code moved. `deployments:verify --tag` with the final tag confirms it.

A release that changes no contract code needs none of this: nothing is deployed, addresses have not moved, and the existing record is still correct.
