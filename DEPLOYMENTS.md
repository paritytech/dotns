# DotNS Deployments

Current deployment addresses and developer deployment notes for dotNS contracts.

## What this file is for

This file is the operational companion to the README. It explains how to run the local ETH-RPC adapter, how to deploy DotNS, where deployment manifests are written, and which addresses are currently live on the supported Paseo environments.

## Prerequisites

You need:

- Docker with Compose support.
- Foundry, including forge and cast.
- Bun, because the package manifest wraps the deployment runner.
- A funded deployer key for the target network.
- A whitelist-operator address to receive whitelist-management permission after deployment.

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
| WHITELIST_OPERATOR | optional | Address granted whitelist-management permission after deployment. Defaults to the team operator in the example file. |
| RPC_URL | optional | Foundry RPC alias or full RPC URL. Defaults to paseo_local, which means the local adapter. |

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

## Deployment pipeline

The fresh-deploy pipeline is split across five stages:

| Stage | Script | Purpose |
| --- | --- | --- |
| Deploy core | scripts/deploy/DeployCore.s.sol | Foundational name-ownership layer: Multicall3, store factory, registrar, reverse resolver, and forward registry. |
| Deploy records | scripts/deploy/DeployRecords.s.sol | Per-name record layer: forward resolver, content resolver, and PopRules. |
| Deploy policy | scripts/deploy/DeployPolicy.s.sol | Commit-reveal controller and protocol registry. |
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
- The RootGatewayDispatcher is present on environments that use the root-dispatch path.

Then run the relevant tests again against the freshly deployed network assumptions:

```bash
forge test --match-path 'test/fork/**' -vvvvv
```

If the deployment was intended to update a public environment, update the address tables in this file from the deployment manifest in the same change that updates the generated deployment JSON.

## Deployment manifests

Every stage writes its output to a shared JSON manifest. Later stages read the addresses written by earlier stages from the same file.

The manifest folder is selected from the current chain id:

| Chain id | Manifest folder |
| ---: | --- |
| 420420422 | deployments/passethub-testnet |
| 420420417 | deployments/paseo-assethub |
| 420420420 | deployments/paseo-local |
| other | deployments/localhost |

The manifest filename is the numeric chain id with a .json extension.

Examples:

```text
deployments/paseo-assethub/420420417.json
deployments/paseo-local/420420420.json
```

## Troubleshooting

If the adapter is not responding, confirm Docker is running and that port 8545 is free. The compose health check uses eth_chainId against http://localhost:8545.

If the deploy script says PRIVATE_KEY is required, the configured ACCOUNT_NAME has not yet been imported into the Foundry keystore. Populate .env once, or provide PRIVATE_KEY and ACCOUNT_PASSWORD through the shell environment.

If the deploy script fails after importing the key, .env is intentionally left in place. Correct the failed field or network issue and rerun the same command.

If the deploy script succeeds, .env should be gone. Future runs should use the keystore account and should not require the deployer private key.

If a stage fails after writing partial addresses, inspect the relevant deployment manifest before retrying. Later stages consume whatever earlier stages wrote, so stale manifests can produce confusing wire-up errors.

## Live addresses

### Paseo Asset Hub Previewnet

**DotnsProtocolRegistry**

```text
0x288Cc06f13a5bbCd82599bc7f939A14056937C70
```

**Multicall3**

```text
0x6159BfCF76f3795d11cA1ff4a0542699EE125658
```

**DotnsRegistrar**

```text
0xE2dbCeBa3f87e68f8D7BcDd4E23b5d852e31E297
```

**DotnsRegistry**

```text
0x1a53D3528b66593905B7d0955F8727f9890ec5E2
```

**DotnsRegistrarController**

```text
0x8ED21251E084537F078bf210fE7242f6B43478D8
```

**DotnsPopController**

```text
0xaAFB391735F3387750A7E29206f1f828a35A390B
```

**RootGatewayDispatcher**

```text
0x9827c34f4604c153f4B9A68D5ef3C104923d63b4
```

**PopRules**

```text
0xA712C591e4C1Ac283927E12fd32C21c8788177CA
```

**DotnsResolver**

```text
0x956396732cc4c5C6AdD58D8749d524c49f07A18D
```

**DotnsReverseResolver**

```text
0xB3e352B7F5027D985271B0b0B984F083b8c160B2
```

**DotnsContentResolver**

```text
0xb90cb11Ccd2D5462c47E00B67d2c5FB902c8f1ca
```

**DotnsPopResolver**

```text
0x4619d718D8eD0160484799649BF1EA870B41BF48
```

**DotnsNameEscrow**

```text
0x0B0B2a9bB1298DFB12324E75Ab5929729Be584A0
```

**StoreFactory**

```text
0xe931C08B3EA28bC7e054916B6Ed87cda06fD7bCB
```

**LabelStoreBeacon**

```text
0x9d9E51f1C6d007A96e54F5461F61ecb7132f9902
```

**UserStoreBeacon**

```text
0xCd2da082bc7898Aa1A70cEc1B5b29e603d7071D8
```

### Paseo Asset Hub Next V2

**DotnsProtocolRegistry**

```text
0x0000000000000000000000000000000000000000
```

**Multicall3**

```text
0x0000000000000000000000000000000000000000
```

**DotnsRegistrar**

```text
0x0000000000000000000000000000000000000000
```

**DotnsRegistry**

```text
0x0000000000000000000000000000000000000000
```

**DotnsRegistrarController**

```text
0x0000000000000000000000000000000000000000
```

**DotnsPopController**

```text
0x0000000000000000000000000000000000000000
```

**RootGatewayDispatcher**

```text
0x0000000000000000000000000000000000000000
```

**PopRules**

```text
0x0000000000000000000000000000000000000000
```

**DotnsResolver**

```text
0x0000000000000000000000000000000000000000
```

**DotnsReverseResolver**

```text
0x0000000000000000000000000000000000000000
```

**DotnsContentResolver**

```text
0x0000000000000000000000000000000000000000
```

**DotnsPopResolver**

```text
0x0000000000000000000000000000000000000000
```

**DotnsNameEscrow**

```text
0x0000000000000000000000000000000000000000
```

**StoreFactory**

```text
0x0000000000000000000000000000000000000000
```

**LabelStoreBeacon**

```text
0x0000000000000000000000000000000000000000
```

**UserStoreBeacon**

```text
0x0000000000000000000000000000000000000000
```
