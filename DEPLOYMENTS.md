# DotNS Deployments

Current deployment addresses and developer deployment notes for dotNS contracts.

## What this file is for

This file is the operational companion to the README. It explains how to run the local ETH-RPC adapter, how to deploy DotNS, where deployment manifests are written, and which addresses are currently live on the supported Paseo environments.

> For a short, do-this-in-order checklist (including how to target **any** Polkadot chain, not just the Paseo environments), see [`DEPLOYMENT_CHECKLIST.md`](./DEPLOYMENT_CHECKLIST.md).

## Prerequisites

You need:

- Docker with Compose support.
- Foundry, including forge and cast.
- Bun, because the package manifest wraps the deployment runner.
- A funded deployer key for the target network.

The deployment runner uses a Foundry keystore account, not a long-lived plaintext private key. A plaintext private key is only needed for the first import of the deployer account into the local Foundry keystore.

## Local ETH-RPC adapter

Deploying to a revive-backed Paseo-style environment, and running fork tests against that chain state, requires a local ETH-RPC adapter. The repository includes a Docker Compose service named eth-rpc. It builds the revive ETH-RPC adapter image and exposes it on localhost port 8545.

The adapter is used instead of the public RPC directly because deployment and fork-test traffic is bursty. The public endpoint can rate-limit or stall under that pattern, which may drop in-flight transactions or invalidate fork-test assumptions. Unit, fuzz, and invariant tests still run in Foundry's in-process EVM; fork tests use the adapter.

Start the adapter:

```bash
docker compose up --build eth-rpc
```

In another terminal, confirm the adapter answers Ethereum JSON-RPC:

```bash
curl -fsS -X POST \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  http://localhost:8545
```

The checked-in Compose file uses Previewnet as its example upstream:

```text
wss://previewnet.substrate.dev/asset-hub
```

Treat that URL as an example/default, not as a protocol constant. Developers can point the adapter at another compatible Asset Hub endpoint by changing the node RPC URL passed to the eth-rpc service, or by maintaining a local override for the Compose command.

The exposed local RPC is:

```text
http://localhost:8545
```

The Foundry RPC alias used by the deploy script defaults to the local adapter:

```text
paseo_local
```

## Multicall3

Fresh deployments include a generic Multicall3 contract. It is deployed for client, indexer, and tooling batching and is not dotNS-specific. The deployment script records it in the manifest as Multicall3 and the wire-up stage publishes it through the protocol registry under the MULTICALL3 key.

This is an arbitrary-target Multicall3 surface, matching the common mds1/multicall3 interface used by wallet and RPC tooling. It is permissionless: anyone can call it. Target contracts still enforce their own permissions and see Multicall3 as the caller during CALL-based write batching. Use it freely for read aggregation; use write aggregation only for flows where the target contract is meant to accept Multicall3 as msg.sender.

Its address is deterministic, not the canonical mds1 singleton. It is deployed through the dotNS CREATE3 factory under the label `Multicall3` (kind `contract`), so it lands at the same address on every chain that shares the same factory (see Deterministic addresses below), and that address is **not** the well-known `0xcA11...` deployment. Consumers must read the Multicall3 address from the protocol registry `MULTICALL3` key or from the deployment manifest, never hardcode `0xcA11...`.

## One-time deployer bootstrap

Copy the example environment file:

```bash
cp .env.example .env
```

Set these fields:

| Field | Required | Meaning |
| --- | --- | --- |
| ACCOUNT_NAME | optional | Foundry keystore account name. Defaults to dotns-deploy. |
| ACCOUNT_PASSWORD | yes on first import | Password used to import and unlock the Foundry keystore account. |
| PRIVATE_KEY | yes on first import | Hex deployer private key. This is imported into the Foundry keystore, then removed from disk when the deploy succeeds. |
| RPC_URL | optional | Foundry RPC alias or full RPC URL. Defaults to paseo_local, which means the local adapter. |
| DEPLOYMENT_NETWORK | optional | Manifest subdirectory under deployments/. Set it to keep networks that share a chain id apart (see [Deployment manifests](#deployment-manifests)). Defaults to the chain-id mapping. |

The .env file is bootstrap input only. It is git-ignored. On a successful deployment the runner deletes it automatically. On failure the file is left in place so you can correct it and retry.

## Deploy locally through the adapter

Run the local-adapter deployment path:

```bash
bun run deploy:anvil
```

This command cleans and builds the project, then calls the staged deployment runner. Despite the name, this is not a local Anvil deployment; it is a deployment through the local revive ETH-RPC adapter.

## Build and test before deployment

Run a clean build before deploying:

```bash
forge clean
forge build
```

Run the full default Foundry test suite:

```bash
forge test -vvvvv
```

Run the non-fork suite when you do not have the adapter running:

```bash
forge test --no-match-path 'test/fork/**'
```

Run a targeted contract suite while iterating:

```bash
forge test --match-contract DotnsRegistrarControllerTest -vvvvv
forge test --match-contract DotnsNameEscrowTest -vvvvv
forge test --match-contract PopRulesTests -vvvvv
```

Run fork tests only after the ETH-RPC adapter is healthy on localhost port 8545:

```bash
docker compose up --build eth-rpc
forge test --match-path 'test/fork/**' -vvvvv
```

The expected test split is:

| Suite type | Environment | Purpose |
| --- | --- | --- |
| Unit tests | Foundry in-process EVM | Check isolated contract behaviour. |
| Fuzz tests | Foundry in-process EVM | Search input space around registration, transfer, escrow, and resolver invariants. |
| Invariant tests | Foundry in-process EVM | Exercise stateful flows such as escrow accounting and registrar lifecycle properties. |
| Fork tests | Local revive ETH-RPC adapter | Validate behaviour against live Paseo Asset Hub state and runtime assumptions. |

Do not use fork-test failures as a substitute for unit failures. If a fork test fails, first confirm the adapter is healthy and that the target network state has not drifted from the test assumptions.

## Deploy to testnet

Run the testnet deployment path:

```bash
bun run deploy:testnet
```

This calls the same deployment runner with a larger timeout. The runner forwards additional forge flags to every deployment stage.

You can call the runner directly when you need custom flags:

```bash
./scripts/deploy/run.sh '--slow --timeout 1000'
```

For scripted or CI use, provide secrets through the process environment instead of .env:

```bash
PRIVATE_KEY=0x... ACCOUNT_PASSWORD=... ./scripts/deploy/run.sh '--slow'
```

## Subsequent deployments

After the deployer key has been imported once, do not keep a private key in .env. Reuse the Foundry keystore account and provide only the password interactively or through the environment.

Typical subsequent run:

```bash
bun run deploy:testnet
```

If ACCOUNT_PASSWORD is not set and the process has a TTY, the runner prompts once for the keystore password and passes it to every stage.

## Upgrading a proxy that gained a new configuration value

An upgrade that adds a governance-tunable storage value must seed it in the **same transaction** as the implementation swap. A bare `upgradeTo` leaves the new slot at zero, and a proxy running with an unseeded policy value is a live misconfiguration, not a pending chore.

UUPS supports this directly: `upgradeToAndCall` performs the post-upgrade call as a delegatecall from the proxy context, so `msg.sender` is preserved and an `onlyOwner` setter is callable as part of the upgrade.

### DotnsNameEscrow: `redeemWindow`

The escrow's redeem window is the period after a `release` in which only the previous holder may act — they alone may `redeem` the name back, and `available` reports `false` so nobody wastes a commitment on it. Once it elapses, `reclaim` is permissionless. It is a separate value from `cooldown` and defaults to `ESCROW_REDEEM_WINDOW` (1 day) on a fresh deploy.

Upgrade an existing escrow proxy like this, not with a bare `upgradeTo`:

```bash
# 1 day, matching the ESCROW_REDEEM_WINDOW deploy constant
cast send "$ESCROW_PROXY" \
  'upgradeToAndCall(address,bytes)' \
  "$NEW_IMPL" \
  "$(cast calldata 'updateRedeemWindow(uint256)' 86400)" \
  --account "$DEPLOYER" --rpc-url "$RPC_URL"
```

Verify before considering the upgrade done:

```bash
cast call "$ESCROW_PROXY" 'redeemWindow()(uint256)' --rpc-url "$RPC_URL"   # expect 86400
```

If the window is left at zero, `release` reverts with `RedeemWindowNotConfigured` for **every** name on that deployment. That is deliberate: the alternative would be stamping `redeemableUntil` at the current timestamp, which silently opens permissionless reclaim the instant a name is released and hands the name to whoever is watching. A loud failure on `release` is recoverable with one owner transaction; a silent one is not.

To recover a proxy already upgraded without seeding, call the setter directly — no second upgrade is needed:

```bash
cast send "$ESCROW_PROXY" 'updateRedeemWindow(uint256)' 86400 \
  --account "$DEPLOYER" --rpc-url "$RPC_URL"
```

Bounds: at least `MIN_REDEEM_WINDOW` (1 day) and at most `MAX_REDEEM_WINDOW` (30 days). Changing the window later affects only releases recorded after the change; positions already released keep the `redeemableUntil` snapshot taken at their release time.

### The window does not apply to names already in escrow

Seeding `redeemWindow` covers every release *after* the upgrade. It does nothing for names already sitting in escrow when the upgrade lands, and operators should understand what happens to those.

A position released under the old contract has no `redeemableUntil` — the field reads as zero from previously unused padding. So the moment the upgrade lands:

- the name is **immediately reclaimable by anyone**, with no redeem grace at all
- `available` reports it registrable straight away
- its previous holder **cannot** `redeem` it, because the redeem window is already behind them

No value is lost: reclaim settles the deposit onto the previous holder's pull-payment balance, so they are made whole whether or not they ever withdrew. And these are names that were **stuck** before the upgrade, so becoming claimable is the fix working. But the previous holder gets no chance to change their mind, which is the one guarantee the upgrade cannot apply retroactively.

Enumerate the affected set before upgrading, so the outcome is a decision rather than a surprise:

```bash
cast call "$ESCROW_PROXY" 'releasedTokenCount()(uint256)' --rpc-url "$RPC_URL"
cast call "$ESCROW_PROXY" 'releasedTokens(uint256,uint256)(uint256[])' 0 200 --rpc-url "$RPC_URL"
```

If that set is non-empty and any of it matters, the options are to let the holders reclaim or withdraw before the upgrade, or to notify them that the grace period will not cover their name.

## Deployment pipeline

The fresh-deploy pipeline is split across five stages:

| Stage | Script | Purpose |
| --- | --- | --- |
| Deploy core | scripts/deploy/DeployCore.s.sol | Foundational name-ownership layer: Multicall3, store factory, registrar, reverse resolver, and forward registry. |
| Deploy records | scripts/deploy/DeployRecords.s.sol | Per-name record layer: forward resolver, content resolver, and PopRules. |
| Deploy policy | scripts/deploy/DeployPolicy.s.sol | Registration policy layer: name escrow and commit-reveal controller. |
| Deploy Pop system | scripts/deploy/DeployPopSystem.s.sol | Proof-of-Personhood resolver and controller. |
| Wire deployments | scripts/deploy/WireDeployments.s.sol | Authorisation and registry wire-up plus end-to-end verification. This stage does not deploy proxies. |

Each stage is a separate forge script invocation and therefore a separate EVM simulation. This keeps OpenZeppelin's upgrade-safety validator from accumulating enough simulated state to exhaust the EVM during validation.

## Post-deployment verification

The final wire-up stage performs end-to-end verification for the deployed graph. After deployment, check the generated manifest and confirm the expected contracts are present for the target chain id.

At minimum, confirm:

- The protocol registry address is present.
- The registrar address is present.
- The public registrar controller address is present.
- The Multicall3 address is present.
- The Pop controller address is present.
- PopRules is present.
- The forward, reverse, content, and Pop resolvers are present.
- The escrow address is present.
- StoreFactory and both store beacons are present.
- The escrow's redeem window is non-zero. A zero leaves `release` reverting with `RedeemWindowNotConfigured` for every name on the deployment, so a holder who releases a name by accident has no chance to redeem it back. Any value the setter accepted is already at least `MIN_REDEEM_WINDOW` (1 day), so this check is only ever confirming that the window was configured at all, which is exactly what a proxy upgraded without seeding it would fail.

```bash
cast call "$ESCROW_PROXY" 'redeemWindow()(uint256)' --rpc-url "$RPC_URL"   # expect 86400 at launch
```

Then run the relevant tests again against the freshly deployed network assumptions:

```bash
forge test --match-path 'test/fork/**' -vvvvv
```

If the deployment was intended to update a public environment, update the address tables in this file from the deployment manifest in the same change that updates the generated deployment JSON.

## Name grants (whitelisting)

Reserved registration is gated on `DotnsNameWhitelist`. A grant binds one label to one beneficiary address and is single use: `registerReserved` requires a grant naming `registration.owner`, spends it on the mint, and refuses a second attempt. See the [README economics section](./README.md#economics) for what a grant does and does not confer; this section covers the mechanics.

**Every admin action on the whitelist is a substrate Root dispatch.** Granting, revoking, accepting, rejecting, reserving, setting the request window and retuning the caps all require it. No signed account can do any of them, the contract owner included: the owner's authority is deployment and upgrade, not allocation. A signed call reverts with `NotGovernance`. There is no operator role and no address allowlist.

That is the point of the design. As a security measure, no single key can grant a name; a grant costs a referendum, or on a test network a sudo-dispatched Root call.

Two owner-level routes reach the same outcome and are **not** closed by this. `DotnsProtocolRegistry.set` is `onlyOwner`, so the owner can point the `nameWhitelist` key at a contract whose `isGrantedTo` returns true for everything. `DotnsRegistrar.addController` is `onlyOwner`, and a controller can mint any available name directly, without the whitelist at all. Treat the guarantee here as covering the whitelist's own admin surface, not the protocol as a whole, until upgrade authority and deploy-time ownership are settled.

The controller carries no roles either. It reads grants and consumes them, so `setRole` on the controller reverts with `UnsupportedRole`.

### Dispatching a grant

The dispatch is a Substrate extrinsic with the contract call nested inside it:

```
Root origin
  └─ Revive.call { dest: <DotnsNameWhitelist H160>, value: 0, data: <EVM calldata> }
       └─ grantName(string,address)
```

`cast` can be used for the innermost layer to encode `data`:

```bash
# grant one label to one beneficiary
cast calldata "grantName(string,address)" "$LABEL" "$ADDRESS"

# grant several labels to one beneficiary, up to maxGrantBatch
cast calldata "grantNames(string[],address)" '["alpha01","beta02"]' "$ADDRESS"

# release an unspent grant
cast calldata "revokeName(string)" "$LABEL"
```

Building the `Revive.call` around that hex and dispatching it as Root is done on the Substrate side. Wrap it in `Sudo.sudo` on a test network; put it up as a referendum on a production one. Both produce the same Root origin the contract checks, so the same `data` works either way.

The gas and storage-deposit limits belong to the `Revive.call` extrinsic rather than the contract call. Dry-run the call to size them rather than guessing, as an underestimate fails the whole dispatch.

### Reading state

Both views are open and need no authority:

```bash
cast call "$WHITELIST" "isGrantedTo(string,address)(bool)" "$LABEL" "$ADDRESS"
cast call "$WHITELIST" "statusOf(string)(uint8)" "$LABEL"
```

A grant that has been spent reads `false`, so `isGrantedTo` also distinguishes an unused grant from a consumed one. `$WHITELIST` is the `DotnsNameWhitelist` address for the target network, read from the protocol registry under the `nameWhitelist` key or taken from the [deployment manifest](#addresses), never hardcoded across networks.

### Configuration is Root too

`setWindow`, `setMaxClaimants`, `setMaxReasonBytes` and `setMaxGrantBatch` are on the same gate, so the deploy cannot configure the whitelist and the values `initialize` sets are what a fresh network starts with. Changing any of them later costs a governance action, so check the defaults in `DotnsConstants` are the ones you want at launch.

## Deterministic addresses (CREATE3)

Every contract in the pipeline is deployed through a CREATE3 factory, so its address is a pure function of the factory address and a salt. It does not depend on the deployed bytecode, the constructor arguments, the deployer's nonce, or (for a proxy) the implementation behind it. This is what lets the same logical contract land at the same address on every chain, and lets an implementation be upgraded without moving its proxy.

The salt is derived in `BaseDeployer.s.sol`:

```text
salt = keccak256(abi.encodePacked(CREATE3_SALT_NAMESPACE, ":", label, ":", kind))
```

- `CREATE3_SALT_NAMESPACE` is `dotns.create3.v1`. It deliberately excludes the chain id so addresses match across chains.
- `label` is the manifest name for the contract, for example `DotnsRegistrar` or `Multicall3`.
- `kind` is `implementation` or `proxy` for a UUPS proxy pair, or `contract` for a non-upgradeable contract.

So a contract's address is fixed by exactly three inputs: the factory address, the salt namespace, and its label (plus kind). Keep all three stable and the address is stable. Bytecode, constructor arguments, and the deployer account do not affect it.

Choosing and changing addresses:

- To add a new contract with a stable cross-chain address, give it a unique `label` and deploy it through the BaseDeployer CREATE3 helpers (`_broadcastDeployUups` for a UUPS proxy, `_broadcastDeployCreate3` for a plain contract). Its address is then fixed for that label.
- To intentionally move the entire address set (a clean re-deploy that must not collide with the previous one), bump `CREATE3_SALT_NAMESPACE` (`v1` becomes `v2`). Every address shifts together.
- Do not reuse a `label` for a different contract. The wire stage and external tooling key off stable labels, so a reused label silently repoints them.

Two other manifest entries are not CREATE3-derived: `LabelStoreBeacon` and `UserStoreBeacon`. They are deployed inside the `StoreFactory` constructor (and owned by it, so the factory owner can upgrade store implementations), so their addresses are `keccak(StoreFactory, nonce)`. They stay put across resets while `StoreFactory`'s bytecode is unchanged, but a change to that constructor can move them. This is deliberate: only the core CREATE3 contracts are guaranteed stable, so do not treat the beacon addresses as network-stable, read them from the manifest or the factory.

The one address that is not CREATE3-derived is the CREATE3 factory itself: it bootstraps the scheme, so it cannot deploy itself. The first deploy stage deploys it directly and records it on the protocol registry under the `CREATE3_FACTORY` key; every later stage resolves it from there rather than from an environment variable. Because every other address is derived from the factory's address, the factory must sit at the same address on each chain for the rest of the set to match. Deploy it as the deployer's first transaction on a fresh account (or through a deterministic singleton deployer) so its nonce-derived address is identical across chains.

### Keeping the factory address stable across chain resets

The "first transaction on a fresh account" rule only holds while the deployer key stays pristine. In practice the same key also runs upgrades and other operations, so on a chain reset it is no longer at nonce 0 when the pipeline runs, the factory lands at a new address, and every downstream address shifts with it. Because only the factory is nonce-sensitive, the fix is to isolate just the factory onto a single-purpose key and have the pipeline reuse it.

The single command does both steps, feeding the factory address into the pipeline:

```bash
bun run deploy:all
```

It runs `deploy:factory` (from the dedicated `dotns-factory` key, which asserts nonce 0 and lands the factory at its deterministic address), then runs the pipeline with `CREATE3_FACTORY` set to that address so `DeployCore` reuses it. On every fresh chain this reproduces the same address set.

The whole pipeline is idempotent, so a re-run resumes an interrupted deploy. Each stage adopts any contract already present at its deterministic address and skips re-initialising an adopted proxy, so rerunning the same command deploys only what is missing and leaves everything already deployed untouched. This is the recovery path when the adapter stalls a transaction part way through.

The two steps can also be run separately:

```bash
# 1. deploy (or confirm) the factory from the single-purpose key
ACCOUNT_NAME=dotns-factory RPC_URL=paseo bun run deploy:factory
# 2. run the pipeline reusing it (the shared pipeline/upgrade key can be at any nonce)
CREATE3_FACTORY=0xYourFactory bun run deploy
```

With `CREATE3_FACTORY` unset, `DeployCore` mints a fresh factory as before. On the next reset, `deploy:all` redeploys the factory from the same single-purpose key (nonce 0 again on the fresh genesis) to reproduce the same factory address.

## Deployment manifests

Every stage writes its output to a shared JSON manifest. Later stages read the addresses written by earlier stages from the same file.

The manifest folder defaults to a mapping from the current chain id:

| Chain id | Default manifest folder |
| ---: | --- |
| 420420422 | deployments/passethub-testnet |
| 420420417 | deployments/paseo-assethub |
| 420420420 | deployments/paseo-local |
| other | deployments/localhost |

Some environments cannot be told apart by chain id alone. A previewnet and a next environment reached through the same local ETH-RPC adapter both report 420420417, so the default mapping would write both to `deployments/paseo-assethub/420420417.json`, and each fresh deploy would overwrite the previous network's manifest.

Set `DEPLOYMENT_NETWORK` to name the subdirectory explicitly and keep each upstream's manifest separate:

```bash
DEPLOYMENT_NETWORK=paseo-previewnet bun run deploy
```

The deploy runner and every Solidity stage honour the same variable, so the bash-side manifest path and the on-chain stage output stay in step. When it is unset, the chain-id default above applies.

The manifest filename is the numeric chain id with a .json extension.

Examples:

```text
deployments/paseo-assethub/420420417.json
deployments/paseo-local/420420420.json
```

A manifest holds exactly one address per contract, the current one. Each deploy overwrites the entries it produces, so the file always describes the latest deployment for that network and never a history of them. Previous address sets exist only in this repository's git history. Nothing else is in there either: no implementation addresses behind the UUPS proxies, and no record of which commit was deployed.

## Troubleshooting

If the adapter is not responding, confirm Docker is running and that port 8545 is free. The compose health check uses eth_chainId against http://localhost:8545.

If the deploy script says PRIVATE_KEY is required, the configured ACCOUNT_NAME has not yet been imported into the Foundry keystore. Populate .env once, or provide PRIVATE_KEY and ACCOUNT_PASSWORD through the shell environment.

If the deploy script fails after importing the key, .env is intentionally left in place. Correct the failed field or network issue and rerun the same command.

If the deploy script succeeds, .env should be gone. Future runs should use the keystore account and should not require the deployer private key.

If a stage fails part way through, rerun the same command. Each stage adopts any contract already at its deterministic address and skips re-initialising an adopted proxy, so the rerun resumes from where it stopped and deploys only what is missing. Later stages read the deployment manifest for wire-up, so if you edit the manifest by hand keep it consistent with what is actually on chain, or the wire-up can fail.

## Addresses

The deployment manifest for a network is the only place in this repository that records its addresses:

```text
deployments/<network>/<chain-id>.json
```

Every network deployed through the shared CREATE3 factory lands on the same address set, so those manifests agree with each other; a chain deployed through a different factory has its own set, and a chain id alone does not identify one, since several networks report the same id. Only the TLD differs per network among the networks below.

| Network | TLD |
| --- | --- |
| Paseo Asset Hub Previewnet | `.testnet` |
| Paseo Asset Hub Next V2 | `.paseo` |

Each release also publishes the same addresses as `deployments.json`, attached to the release and at the root of `dotns-abis-<tag>.zip`, for consumers outside this repository. See [`RELEASE_ARTIFACTS.md`](./RELEASE_ARTIFACTS.md).

Prefer reading an address from the protocol registry at runtime. Every consumer contract exposes `protocolRegistry`, and the registry resolves each well-known key in `DotnsConstants`, so one known address is enough to reach the rest and the chain stays the authority.
