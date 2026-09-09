# DotNS Deployment Checklist

A step-by-step, copy/paste checklist for deploying DotNS to **any** Polkadot
chain (any PolkaVM / `revive`-backed Asset Hub-style chain that exposes an
ETH-RPC adapter).

For the full operational reference — architecture of the pipeline, deterministic
CREATE3 addresses, manifest layout, and current live addresses — see
[`DEPLOYMENTS.md`](./DEPLOYMENTS.md). This file is the short, do-this-in-order
version.

## Before you start

You need:

- **Docker** with Compose support.
- **Foundry** (`forge` and `cast`).
- **Bun** (the deploy runner is wrapped by the package manifest).
- A **funded deployer private key** on the target chain.
- A usable **Root dispatch path** on the target chain: sudo, or a governance track that can
  dispatch `Revive.call`. Every admin action on `DotnsNameWhitelist` needs it, so without one
  the deployment cannot issue or revoke a single name grant. The deploy itself does not need
  it; operating the whitelist afterwards does.

Two facts about your target chain:

- [ ] Its **substrate node WSS URL** (e.g. `wss://my-asset-hub-rpc.example.io`).
- [ ] Its **EVM chain id** (you confirm this in Step 3).

> **Want addresses that match your other chains?** Every contract address is
> derived from the CREATE3 factory address, and the factory is the deployer's
> first transaction. Deploy from a **fresh account (nonce 0)** to get the same
> address set across chains. Optional, but it must be decided before Step 5.

## Step 1 — Point the local RPC adapter at your chain

Edit `docker-compose.yaml`, under `command:` → `--node-rpc-url`:

```yaml
      - "--node-rpc-url"
      - "wss://YOUR-CHAIN-WSS-URL-HERE"
```

## Step 2 — Start the adapter

Leave this running in its own terminal:

```bash
docker compose up --build eth-rpc
```

## Step 3 — Confirm it's alive and get the chain id

```bash
cast chain-id --rpc-url http://localhost:8545
```

- [ ] You get a number back with no error. Note it — call it `<CHAINID>`.

## Step 4 — (Recommended) Give your chain a named manifest folder

Without this, deployments land in the generic `deployments/localhost/` folder.
It still works; it's just messy. To name it, add **one line** to
`scripts/deploy/DeploymentNetwork.sol`:

```solidity
        if (chainId == <CHAINID>) return "my-chain-name";
```

And the matching line to the `case` block in `scripts/deploy/run.sh` so the
validator messages line up:

```bash
  <CHAINID>) DEPLOYMENT_FOLDER="my-chain-name" ;;
```

## Step 5 — Create the bootstrap env file

```bash
cp .env.example .env
```

Set these in `.env`:

- [ ] `PRIVATE_KEY=0x...` — funded deployer key (first run only; imported into
  the Foundry keystore, then `.env` is auto-deleted on success).
- [ ] `ACCOUNT_PASSWORD=...` — any password; encrypts the keystore account.
- [ ] `RPC_URL=paseo_local` — leave as-is; this is the local adapter on :8545.

## Step 6 — (Sanity) Build and run the non-fork tests

```bash
forge clean && forge build
forge test --no-match-path 'test/fork/**'
```

- [ ] Build succeeds, tests green.

## Step 7 — Deploy

```bash
bun install      # first time only
bun run deploy   # imports the key, runs all 5 stages, deletes .env on success
```

The pipeline runs five stages in order, each a separate `forge script`
invocation:

`DeployCore → DeployRecords → DeployPolicy → DeployPopSystem → WireDeployments`

After each stage the runner verifies every manifest address actually has
bytecode. On any failure it restores the previous manifest and stops.

- [ ] Ends with `=== Pipeline complete ===` and
  `Deleted one-off env file: .env`.

## Step 8 — Verify

```bash
cat deployments/<folder>/<CHAINID>.json
```

Confirm these keys are present:

- [ ] `DotnsProtocolRegistry`
- [ ] `DotnsRegistrar`
- [ ] `DotnsRegistry`
- [ ] `DotnsRegistrarController`
- [ ] `DotnsPopController`
- [ ] `PopRules`
- [ ] `DotnsResolver`
- [ ] `DotnsReverseResolver`
- [ ] `DotnsContentResolver`
- [ ] `DotnsPopResolver`
- [ ] `DotnsNameEscrow`
- [ ] `DotnsNameWhitelist`
- [ ] `StoreFactory`
- [ ] `LabelStoreBeacon`
- [ ] `UserStoreBeacon`
- [ ] `Multicall3`

The wiring stage already asserts every protocol-registry binding, so a green deploy means they
are set. One is worth confirming by hand, because it is the only key whose absence surfaces to
users rather than to the pipeline: with `nameWhitelist` unset, `registerReserved` reverts
`WhitelistNotConfigured` for every caller, Root included.

```bash
cast call "$PROTOCOL_REGISTRY" "get(bytes32)(address)" \
  "$(cast format-bytes32-string nameWhitelist)" --rpc-url "$RPC_URL"
```

- [ ] The address returned matches `DotnsNameWhitelist` in the manifest.

Done. ✅

## Troubleshooting — the four things that actually go wrong

- **`PRIVATE_KEY is required`** — the keystore account doesn't exist yet. Make
  sure `PRIVATE_KEY` and `ACCOUNT_PASSWORD` are set in `.env`.
- **Adapter not responding / chain-id errors** — Docker isn't running, port
  8545 is busy, or the WSS URL from Step 1 is wrong or unreachable.
- **A stage fails midway** — `.env` is intentionally left in place and the
  manifest is auto-restored. Fix the cause (usually funds or RPC flakiness) and
  rerun `bun run deploy`.
- **Out of gas / dropped transactions** — run with a larger timeout and slow
  mode:

  ```bash
  ./scripts/deploy/run.sh '--slow --timeout 1000'
  ```
