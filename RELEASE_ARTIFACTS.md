# DotNS Release Artifacts

What each release publishes, what the files guarantee, and how to consume them.

## What a release contains

| Asset | Contents |
| --- | --- |
| `<Contract>.json` | One per contract and interface, the bare ABI array |
| `deployments.json` | Contract addresses, per network |
| `release-manifest.json` | What this release contains, machine readable |
| `dotns-abis-<tag>.zip` | The same files in one archive |

The first three are attached to the release individually, at the top level, with no folder. The zip holds the ABIs under `abis/` and the two JSON files at its root.

The release surface is decided in `.github/abi-contracts.txt` so a contract reaches consumers only when it is listed there.

**Pre-releases carry no addresses.** A pre-release is cut in order to be deployed, so at that point the recorded addresses still belong to the previous deployment of different code. Publishing them under that tag would break the one thing `version` is for, namely that a release's addresses and its ABIs came from the same release. A pre-release therefore ships the ABIs and `release-manifest.json`, and the addresses arrive with the release that follows the deployment.

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
- `LabelStoreBeacon` and `UserStoreBeacon` appear when deployed but are not network-stable, because the `StoreFactory` constructor deploys them. Read them from the factory rather than pinning them.

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

It reads the well-known keys from `DotnsConstants.sol`, resolves each through the protocol registry, and checks that every resolved address is one the manifest records and has code, that every recorded contract is pointed at by some key. The beacons are reported as unverifiable, since nothing in the registry points at them.

It compares the two sides as sets, so it does not check that a given key holds the contract you would expect; that pairing is asserted when a deployment is wired. It reads a committed manifest rather than a published asset, so run it from a checkout at the tag.

## Publishing

`deployments.json` and `release-manifest.json` are generated during the release by `scripts/js/release-metadata.mjs build`, from the committed deployment manifests and the build that just ran. Neither is committed: an address stored in two tracked files eventually disagrees with itself, so `deployments/<network>/<chain-id>.json` is the only tracked copy.

That file holds exactly one address per contract, the current one. Each deploy overwrites the entries it produces, so it tracks only the latest deployment for a network and never a history of them; previous address sets exist only in this repository's git history. It also carries no implementation addresses behind the UUPS proxies, and no record of which commit was deployed.

The release fails before publishing if an expected file is missing from the draft, so a published release always carries the set it advertises.

The order for a release that changes contract code:

1. Cut a pre-release. It carries the ABIs but no addresses.
2. Deploy that tag from [`dotns-releases`](https://github.com/paritytech/dotns-releases). Deploying a tag rather than a branch is what ties the addresses to the code that produced them.
3. Record the resulting addresses in `deployments/<network>/<chain-id>.json`.
4. Cut the release from a commit that differs from the deployed tag only by that record, and run `deployments:verify` against the network first.

A release that changes no contract code needs none of this: nothing is deployed, addresses have not moved, and the existing record is still correct.
