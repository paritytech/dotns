# Paseo Asset Hub Next: broadcast order for the v1.1.0 in-place upgrade

Upgrades the deployment from v1.0.0 to v1.1.0 and applies the settings that go with it. Every
step is one `scripts/deploy/upgrade.sh` invocation under the deployment owner, broadcast through
CI with one label per step; see "Broadcasting through the review PR" below.

Three contracts change code: PopRules, DotnsPopController and DotnsRegistrarController. Every other
proxy and both store beacons already run code identical to this branch's build, and are left
alone.

## Order

| # | Script | What it does |
| --- | --- | --- |
| 1 | `UpgradePopRules` | Adds `reassignBaseNameForPop`. The deployed controller keeps working. |
| 2 | `UpgradePopController` | Bounds the queue work in every gateway call. Refuses to run before step 1. |
| 3 | `UpgradeRegistrarController` | Makes names minted through `registerReserved` releasable. |
| 4 | `SetReservationDuration` | Sets the reservation duration to 30 days. |
| 5 | `PrepareDeviceContainers` | Prepares containers `00` to `99`, one transaction each. |
| 6 | `DeclareRelease` | Declares every codehash, then `1.1.0`. Last, always. |

Two dependencies fix the order:

- **The rules go before the PoP controller.** The new controller calls
  `PopRules.reassignBaseNameForPop`, which only the new rules have. The script checks that PopRules
  reports the current interface before it broadcasts.
- **The declaration goes last.** It is a claim about the whole deployment. An abandoned run leaves
  `1.0.0` declared, which clients read as an older network.

Steps 3 and 4 do not depend on the others. Step 5 needs step 2: it calls
`prepareDeviceContainer`, which only the new controller has.

The whitelist caps are a separate Root step; see "Whitelist caps" below.

## Before anything is broadcast

```bash
RPC_URL=https://eth-rpc-paseo-next.polkadot.io scripts/shell/verify-snapshots.sh

PASEO_FORK_RPC=https://eth-rpc-paseo-next.polkadot.io \
  RPC_URL=https://eth-rpc-paseo-next.polkadot.io scripts/shell/fork-tests.sh
```

Run both on the day. Every `*Old.sol` snapshot that has a deployed counterpart must reproduce the
implementation deployed now. The fork suite includes `PaseoV110CampaignForkTest`, which runs all
six steps in order on one fork and ends on a verified `1.1.0` declaration.

The broadcaster owns every proxy and the protocol registry. Each script asserts this before it
broadcasts.

## Broadcasting through the review PR

The workflow (`.github/workflows/paseo-upgrade-step.yml`) lives only on `dev/paseo-upgrades` and is
triggered by labels on an open review PR into master. One step:

1. Add the label `run:<Script>` to the review PR, for example `run:UpgradePopRules`.
2. The run pauses on the `testnet-upgrades` environment. Approve it there. The run is pinned to
   the PR's head commit at label time, so a push after labelling does not change what an approval
   executes.
3. Before an upgrade step, the job checks the snapshot of the contract that step upgrades against
   the chain.
4. The job starts the local ETH-RPC adapter, broadcasts the one script, uploads the broadcast
   record and the manifest as artifacts, comments the outcome on the PR, and removes the label.
5. Retry by re-adding the label.

Setup:

- Environment `testnet-upgrades`: required reviewer(s), secret `DOTNS_ADMIN_KEY` (the owner key),
  variable `DOTNS_RELEASE_TAG` set to `1.1.0`.
- Leave the environment's deployment branch policy unrestricted. A `pull_request` run deploys from
  `refs/pull/N/merge`, which no branch-name pattern matches.
- The labels:

```bash
for s in UpgradePopRules UpgradePopController UpgradeRegistrarController \
  SetReservationDuration PrepareDeviceContainers DeclareRelease; do
  gh label create "run:$s" --repo paritytech/dotns --color 4FEF0F \
    --description "Broadcast $s on Paseo (gated)" --force
done
```

- Enable the console once the review PR is open: `gh workflow enable "Paseo Upgrade Step"`.

## After each step

Verify from an independent client before the next label. The workflow's green check means the
transactions landed; it does not read the chain back.

- **Steps 1 to 3:** `cast implementation <proxy>` moved, the owner is unchanged, and one state
  read survives: `price` for a probe name on PopRules, `reservationDuration` and
  `pendingClaimUserCount` on the controller, `minCommitmentAge` on the registrar controller.
- **Step 1, additionally:** PopRules reports `supportsInterface(type(IPopRules).interfaceId)`.
- **Step 2, additionally:** the controller answers `MAX_QUEUE_STEPS_PER_CALL()` with `4`.
- **Step 4:** `reservationDuration()` is `2592000`.
- **Step 5:** the run logs how many containers it prepared. A second run prepares none.
- **Step 6:**

```bash
node scripts/js/release-metadata.mjs verify --network paseo-assethub \
  --rpc https://eth-rpc-paseo-next.polkadot.io --tag v1.1.0
```

It reports the `registrarController` key as drift, as described in `DEPLOYMENTS.md`. Any other key
it reports is a real finding.

## Whitelist caps

`DotnsNameWhitelist.setMaxClaimants` and `setMaxGrantBatch` accept only a Root origin, so the
console, which signs with the owner key, cannot call them. Set them through a Root dispatch on
Paseo, as a `Revive.call` to the whitelist proxy `0x420166cD67Ca0233094E492a4BbA67045eD7C38C`:

- `setMaxClaimants(24)`, from 64;
- `setMaxGrantBatch(32)`, from 100.

Both are within the limits v1.1.0 enforces, and neither depends on the steps above.

## If a step fails

Stop. Every step can be re-run by re-adding its label:

- `UpgradePopRules` and `UpgradeRegistrarController` swap in the same code again.
- `UpgradePopController` broadcasts nothing once the proxy runs the new implementation.
- `SetReservationDuration` broadcasts nothing once the duration is set.
- `PrepareDeviceContainers` skips every container already recorded, so a run that died part way
  is finished by running it again.
- `DeclareRelease` writes the version last, so a failure before that leaves `1.0.0` declared.

Do not skip ahead to `DeclareRelease` to tidy up. Declaring a release the deployment does not
fully run is the one state the declarations cannot represent.

Rolling a proxy back means upgrading it to its previous implementation, recorded below, through
the same console.

| Proxy | Implementation before this campaign |
| --- | --- |
| PopRules `0x747B456bE03aec0b42bd85C51513730FBD45DA31` | `0xdf1800ba0055c2ca3587400831123e9bcd4d5818` |
| DotnsPopController `0xCC932348606cc1f3318cADeC5A5Cd2CA447f8a4b` | `0xf8901566396db4333ce511693992124d28507795` |
| DotnsRegistrarController `0xBdaA01bD1bA67d709F2b1fF286Da0d854977EA30` | `0x310dd512fc43e267798e02e81fc0d9628307cfb2` |

Rolling back PopRules alone, after step 2, breaks every gateway call that moves a reservation.
Roll the controller back first.

## Close-out

Once the release verify is clean: disable the console with
`gh workflow disable "Paseo Upgrade Step"`, close the review PR, and tag the branch head
`upgrades/paseo-nv2-v1.1.0`.
