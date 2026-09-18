# `paseo-assethub`

`420420417.json` is **Paseo Asset Hub Next**, reached at `https://eth-rpc-paseo-next.polkadot.io`.

The note lives here rather than in the manifest because the manifest is address-only by
contract: `BaseDeployer.initDeployment` parses every key in it as an address, and so does
`release-metadata.mjs`. A text field added there fails the deploy pipeline on its first read.

## The chain id does not identify the network

Chain id 420420417 is shared with other Paseo-style environments, including the public Polkadot
Hub TestNet gateway at `https://services.polkadothub-rpc.com/testnet`, which answers on that id
and has no code at any of these addresses. An adapter or fork pointed at the wrong one resolves
every address here and finds all of them empty, so calls revert for reasons that look like
anything but the real cause. The fork tests assert code is present at each address they resolve,
which turns that into a clear failure instead of a confusing one.

That gateway also answers `eth_getLogs` with an empty result for every range, not an error,
so anything derived from a log replay against it looks like it worked and is empty. Nothing in
this repository depends on that: the store migration reads its holders from the factory's own
`getLabelStores` and each store's `owner`. Worth knowing before reaching for logs to answer a
question about this network. Use an archive node, or Blockscout at
`https://blockscout-paseo-next.polkadot.io`.

## What is deployed here is not a release

These proxies are upgraded in place from `dev/testnet-upgrades`, which is never merged to
`master`, so no release tag describes the code they run. `DEPLOYMENTS.md` has the detail; the
short version is that `verify --tag` reports the `registrarController` key as drift permanently
and by design, every other key verifies, and a second drifting key is a real finding.

Before broadcasting anything against this network, run `scripts/shell/verify-snapshots.sh`
against it. It is the only check that catches a snapshot describing an implementation that was
replaced in place and stopped running months ago.
