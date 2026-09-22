# previewnet

The Product Preview Network's Asset Hub (`wss://previewnet.substrate.dev/asset-hub`,
ETH RPC `https://previewnet.substrate.dev/eth-rpc`), TLD `.dot`. Deployed from a v0.8.0
genesis, so every address matches the fresh-deploy set in `deployments/expected.json`.

The chain id is `420420417`, the same as `paseo-assethub`: pallet-revive testnets share it,
so the network folder, not the chain id, is what identifies a deployment. The two manifests
differ where their histories do: a network upgraded in place carries `*Legacy` entries for
addresses its upgrades superseded, and can hold contracts deployed before the current set.

This network is wiped and redeployed periodically; verify against the chain before relying
on this file after a wipe:

```bash
node scripts/js/release-metadata.mjs verify --network previewnet \
  --rpc https://previewnet.substrate.dev/eth-rpc --tag v0.8.0
```
