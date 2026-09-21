# Paseo Asset Hub Next: broadcast order for the v0.8.0 in-place upgrade

Every step is one `scripts/deploy/upgrade.sh` invocation under the deployment owner, and the
order is not a preference. Broadcasts run through CI, one label per step; see "Broadcasting
through the review PR" below. Running locally instead needs the key material, which nobody
holds, so the label path is not a convenience but the mechanism. Three dependencies make it the only order that works:

- **The protocol registry goes first.** Every upgraded contract's `version()` reads
  `protocolRegistry.protocolVersion()`, and `MigrateStoreFactory` calls `setExpectedCodehash`.
  Neither entrypoint exists on the implementation the network starts on, so anything that runs
  before the registry swap either reverts or reads a contract that cannot answer.
- **The store migration goes after the registry and before the declaration.** It rewires the
  `storeFactory` key, and the declaration records the codehash of whatever that key resolves to.
  Declaring first would record the old factory and then quietly stop being true.
- **The declaration goes last.** It is a claim about the whole deployment. Made early, an
  abandoned run leaves a false claim standing; made last, the same abandoned run leaves the
  previous declaration, which clients read as an older network.

Nothing in the scripts enforces this. Each is independently runnable by design, so the ordering
lives here and in the fork tests that reproduce it.

## Before anything is broadcast

```bash
RPC_URL=https://eth-rpc-paseo-next.polkadot.io scripts/shell/verify-snapshots.sh

PASEO_FORK_RPC=https://eth-rpc-paseo-next.polkadot.io \
  RPC_URL=https://eth-rpc-paseo-next.polkadot.io scripts/shell/fork-tests.sh
```

The second form needs no Docker. `bun run test:fork` brings up the local ETH-RPC adapter, which
only translates for the same node the hosted endpoint already fronts, so both exercise the same
state. Use whichever is available; the suite is 15 tests and takes under a minute either way.

The first is the check that matters most and takes seconds. Every `*Old.sol` snapshot must
reproduce the implementation currently deployed; a snapshot that has drifted makes every layout
diff meaningless while leaving the build green. Re-run it on the day, not from an earlier run:
these proxies are upgraded in place, so a swap landing in between changes the answer.

Confirm the broadcaster owns the proxies. All of them, and the deployed store factory, answer to
the same account; each script asserts this before it swaps anything, so a wrong signer fails fast
instead of reverting inside an upgrade call.

## Order

| # | Script | Why here |
| --- | --- | --- |
| 0 | `RotateOwnership` | Moves every contract to a fresh key before anything else is broadcast. |
| 1 | `UpgradeProtocolRegistry` | Adds `protocolVersion` and `setExpectedCodehash`, which steps 2 to 14 depend on. |
| 2 | `UpgradeRegistry` | Adds the deferred-write gate. Reads `registrar.controllers` live. |
| 3 | `UpgradeRegistrar` | Holds the controller authorisations the gate reads. |
| 4 | `UpgradeRegistrarController` | Carries the retained slot that keeps `protocolRegistry` readable. |
| 5 | `UpgradePopController` | |
| 6 | `UpgradePopRules` | |
| 7 | `UpgradeNameEscrow` | Custodies deposits; check `redeemWindow()` is non-zero afterwards. |
| 8 | `UpgradeNameWhitelist` | |
| 9 | `UpgradeResolver` | |
| 10 | `UpgradeReverseResolver` | |
| 11 | `UpgradeContentResolver` | |
| 12 | `UpgradePopResolver` | |
| 13 | `MigrateStoreFactory` | Deploys the replacement, imports the bindings, rewires the key. |
| 14 | `DeclareRelease` | Declares every codehash, then the release. Last, always. |

Steps 5 to 12 have no dependency on each other and can go in any order among themselves.

## Broadcasting through the review PR

The workflow (`.github/workflows/paseo-upgrade-step.yml`) lives only on this branch and is
triggered by labels on the open review PR into master, because a dispatch button only exists for
workflows on the default branch and nothing that signs with the owner key goes there. One step:

1. Add the label `run:<Script>` to the review PR, for example `run:UpgradeProtocolRegistry`.
2. The run starts and immediately pauses on the `paseo-upgrade` environment. Approve it there.
   The run is pinned to the PR's head commit at label time, so a push after labelling does not
   change what an approval executes.
3. The job starts the local ETH-RPC adapter, broadcasts the one script, uploads the broadcast
   record and the manifest as artifacts, comments the outcome on the PR, and removes the label.
4. Retry by re-adding the label. Manual work between steps (funding the fresh account, swapping
   the environment secret after step 0, committing the step 13 manifest from the artifact,
   since the runner cannot produce the signed commit this branch requires) happens with no label
   applied, which is what makes the pauses real.

One-time setup, in the repository UI plus one shell loop:

- Environment `paseo-upgrade`: required reviewer(s), variables `DOTNS_NEW_OWNER` and
  `DOTNS_RELEASE_TAG` (`0.8.0`), optionally `DOTNS_OLD_STORE_FACTORY`. No secret yet: step 0
  signs with the repository-level `DOTNS_ADMIN_KEY`, which nobody can read and therefore nobody
  can move. After step 0, add the fresh key as the environment secret `DOTNS_ADMIN_KEY`, which
  shadows the repository one for gated jobs, and delete the repository copy.
- The labels:

```bash
for s in RotateOwnership UpgradeProtocolRegistry UpgradeRegistry UpgradeRegistrar \
  UpgradeRegistrarController UpgradePopController UpgradePopRules UpgradeNameEscrow \
  UpgradeNameWhitelist UpgradeResolver UpgradeReverseResolver UpgradeContentResolver \
  UpgradePopResolver MigrateStoreFactory DeclareRelease; do
  gh label create "run:$s" --repo paritytech/dotns --color B60205 \
    --description "Broadcast $s on Paseo (gated)" --force
done
```

## Step 0, and why it is first

The deployment key's custody includes a laptop belonging to someone who has left, so the key is
treated as exposed. Rotation is one broadcast, individually verifiable, and doing it first means
the long upgrade window is not spent hoping an exposed key stays unused. Addresses do not move:
ownership is a storage field, so hosts, manifests, the SDK pins and the codehash declarations are
all untouched. Redeployment would buy nothing rotation does not.

The step is the old key's last act, and everything after it is broadcast by the new one:

1. Generate the new key with clean custody and fund its account with gas.
2. Run `RotateOwnership` as the old key, with `DOTNS_NEW_OWNER` set to the new account. The
   script hard-fails if any expected contract answers to a surprise owner, refuses to rotate to
   the broadcaster itself, verifies every transfer by readback, and ends by scanning the whole
   manifest for anything owner-answering that its inventory missed.
3. Swap the signer: replace the key in the CI environment (or the local keystore) with the new
   one. Until this happens, steps 1 to 14 fail their owner assertions, loudly and harmlessly.
4. Sweep the old account's gas balance to the new one with a plain `cast send`.
5. Delete every stored copy of the old key: `DOTNS_ADMIN_KEY` on this repository, and the
   organisation-level `DEPLOYER_KEY`, which the deployment records show controls the same
   account. An org owner has to do the second.

A partial failure is finished by running the script again with the same inputs: contracts that
already moved are skipped, so the old key can complete an interrupted rotation. Once everything
has moved, a re-run is a loud no-op. `test/fork/RotateOwnership.t.sol` proves the rotation, the
old key's lockout, the new key's ability to upgrade, and the no-op re-run, against live state.

One thing rotation does not cover: the CREATE3 factory deployer key cannot be rotated in any
meaningful sense, since the factory address is a historical function of it. On this chain the
slots are spent and it grants nothing; on future chains the deploy pipeline's occupancy checks
are the protection.

## After each swap

```bash
cast implementation <proxy> --rpc-url <rpc>
```

The new implementation's masked bytecode should equal this branch's build. `verify-snapshots.sh`
compares snapshots against the chain, so it is not the tool for this; the check here is that the
swap put the implementation you built where you expected it.

## After step 13

The migration is the only step that moves user state rather than swapping code. Confirm, for a
holder the old factory had:

```
protocolRegistry.get(storeFactory)        -> the replacement proxy
replacement.getLabelStore(<holder>)       -> the store they already had
replacement.getLabelStoreCount()          -> the old factory's count
```

`test_after_rewire_a_live_holder_resolves_to_their_existing_store` asserts exactly this on a
fork, so a surprise here means the fork and the chain have diverged since it last ran.

The old factory keeps its beacons, and the imported stores still point at them. **Do not discard
the old factory**: it is the only contract that can upgrade the implementations behind those
stores, and it answers to the same owner. A `BeaconProxy` holds its beacon in an immutable, so no
migration can move them.

The replacement takes the `StoreFactory` label and mints its own beacons, so after this step the
manifest's usual three entries all describe the new deployment. The outgoing addresses are
written first, under keys that do not move:

| Key | What it is |
| --- | --- |
| `StoreFactoryLegacy` | The factory the imported stores were created by. |
| `LabelStoreBeaconLegacy` | Beacon behind every imported `LabelStore`. |
| `UserStoreBeaconLegacy` | Its user-store counterpart. |

A `LabelStore` implementation rotation for the existing holders goes through
`StoreFactoryLegacy`, not through the new factory. The new factory's beacons serve only stores
created after this migration.

## After step 14

```bash
verify --network paseo-assethub --rpc https://eth-rpc-paseo-next.polkadot.io --tag v0.8.0
```

This does not come back clean, and must not be made to. Expected: every key verifies except
`registrarController`, reported as drift because its deployed code carries the retained slot that
keeps `protocolRegistry` where the live proxy has it, and no release tag describes that build. A
tag build reads the field as the zero address and bricks the contract, so the branch build is the
only deployable one. A second drifting key is a real finding. `DEPLOYMENTS.md` has the detail.

## If a step fails

Stop. The upgrades are independent, so a failure leaves the contracts already swapped on the new
code and the rest on the old, which is a running network: `version()` answers from the registry
for the swapped ones, and the declaration has not been made, so nothing on chain over-claims.

Fix the cause and resume from the failed step. Do not skip ahead to `DeclareRelease` to tidy up;
declaring a release the deployment does not fully run is the one state the declarations cannot
represent.

Step 0 is re-runnable by design, see its section.

**Step 13 is the exception: do not re-run it.** The other twelve are idempotent, and re-running
one that failed is safe. The migration is not. Its deploy leg adopts an existing proxy, which
covers a failure between the deploy and the import and nothing else. Once the import has landed,
a second run reverts on the first user it tries to bind, because bindings here are permanent. And
if the run died while the proxy was still on the migrator, the adopt is refused outright, since
the deployer requires the occupant to delegate to the implementation that run deployed.

So a step 13 failure is inspected, not retried. Read the proxy's implementation slot and its
`getLabelStoreCount`, work out which of the four legs completed, and continue from there by hand.
The legs are separate internals for that reason.
