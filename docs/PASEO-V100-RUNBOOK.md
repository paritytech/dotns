# Paseo Asset Hub Next: broadcast order for the v1.0.0 in-place upgrade

Upgrades the deployment from v0.8.0 to v1.0.0. Every step is one `scripts/deploy/upgrade.sh`
invocation under the deployment owner, broadcast through CI with one label per step; see
"Broadcasting through the review PR" below. The owner key lives only in the `testnet-upgrades`
environment, so the label path is the mechanism.

Four contracts change code and one is replaced. StoreFactory, RegistrarController,
ReverseResolver and the rest are unchanged at the bytecode level and are left alone.

## Order

| # | Script | Why here |
| --- | --- | --- |
| 1 | `UpgradeRegistry` | `isNamePath` bounds a name path at 255 octets. No dependency on the others. |
| 2 | `UpgradePopRules` | Renames `personhoodOf` to `popStatusOf` and the tier names. No contract calls it. |
| 3 | `UpgradePopResolverAndController` | One script, two transactions: resolver, then controller. |
| 4 | `RedeployPopLens` | Reads the resolver through its new getters, so after step 3. Writes the manifest. |
| 5 | `DeclareRelease` | Declares every codehash, then `1.0.0`. Last, always. |

Steps 1 and 2 can go in either order. Three dependencies fix the rest:

- **The PoP resolver and controller change together.** The new controller writes the personhood
  link through `setDeviceLink`, which only the new resolver has; the old controller writes it
  through `setLiteLink`, which the new resolver drops. Either one alone leaves every linked
  personhood issuance reverting. Step 3 swaps both in consecutive transactions, and an issuance
  that lands between them reverts without writing anything.
- **The lens goes after the pair.** It reads `deviceLabelhashOf` and `personhoodNodeOf`, which the
  old resolver does not have.
- **The declaration goes last.** It is a claim about the whole deployment. An abandoned run
  leaves `0.8.0` declared, which clients read as an older network.

Between steps 1 and 5 the declared codehashes of the swapped proxies trail the chain, so a client
that verifies them sees drift for that window. Step 4 declares the lens in the same run that
rewires it, so the lens never shows drift.

## Before anything is broadcast

```bash
RPC_URL=https://eth-rpc-paseo-next.polkadot.io scripts/shell/verify-snapshots.sh

PASEO_FORK_RPC=https://eth-rpc-paseo-next.polkadot.io \
  RPC_URL=https://eth-rpc-paseo-next.polkadot.io scripts/shell/fork-tests.sh
```

Run both on the day. Every `*Old.sol` snapshot must reproduce the implementation deployed now;
the proxies are upgraded in place, so a swap landing in between changes the answer. The fork suite
includes `PaseoV100CampaignForkTest`, which runs all five steps in order on one fork and ends on a
verified `1.0.0` declaration.

The broadcaster owns every proxy and the protocol registry. Each script asserts this before it
broadcasts.

## Broadcasting through the review PR

The workflow (`.github/workflows/paseo-upgrade-step.yml`) lives only on `dev/testnet-upgrades`
and is triggered by labels on an open review PR into master. One step:

1. Add the label `run:<Script>` to the review PR, for example `run:UpgradeRegistry`.
2. The run pauses on the `testnet-upgrades` environment. Approve it there. The run is pinned to
   the PR's head commit at label time, so a push after labelling does not change what an approval
   executes.
3. Before an upgrade step, the job checks the snapshots of the contracts that step upgrades
   against the chain. Proxies an earlier step upgraded have moved past their snapshots by design,
   so the check is scoped to the step. A contract the step names also passes when it already runs
   this branch's build, which is what a retry of a step that died part way finds.
4. The job starts the local ETH-RPC adapter, broadcasts the one script, uploads the broadcast
   record and the manifest as artifacts, comments the outcome on the PR, and removes the label.
5. Retry by re-adding the label. Manual work between steps (committing the step 4 manifest from
   the artifact, since the runner cannot produce the signed commit this branch requires) happens
   with no label applied.

Setup, in the repository UI plus one shell loop:

- Environment `testnet-upgrades`: required reviewer(s), secret `DOTNS_ADMIN_KEY` (the owner key),
  variable `DOTNS_RELEASE_TAG` set to `1.0.0`. Step 4 scopes the lens salt to it and step 5
  declares it.
- **Leave the environment's deployment branch policy unrestricted.** A `pull_request` run deploys
  from `refs/pull/N/merge`, which no branch-name pattern matches, so any restriction blocks every
  gated run with a misleading error. The protection is the required reviewer.
- The labels:

```bash
for s in UpgradeRegistry UpgradePopRules UpgradePopResolverAndController RedeployPopLens \
  DeclareRelease; do
  gh label create "run:$s" --repo paritytech/dotns --color 4FEF0F \
    --description "Broadcast $s on Paseo (gated)" --force
done
```

- Re-enable the console once the review PR is open: `gh workflow enable "Paseo Upgrade Step"`.

## After each step

Verify from an independent client before the next label. The workflow's green check means the
transactions landed; it does not read the chain back.

- **Steps 1 to 3:** `cast implementation <proxy>` moved; the new implementation's runtime code
  equals this branch's build, with the `__self` immutable and the trailing metadata masked; the
  owner is unchanged; one state read survives (the TLD record for the registry, `price` for a
  probe name on PopRules, `pendingClaimUserCount` and `reservationDuration` on the controller).
- **Step 3, additionally:** the controller reports the current interface,
  `supportsInterface(type(IDotnsPopController).interfaceId)`, and the resolver answers
  `deviceLabelhashOf(0)`.
- **Step 4:** `protocolRegistry.get(popLens)` is the address the run logged,
  `expectedCodehash(popLens)` equals that address's `extcodehash`, and the lens's
  `protocolRegistry()` is the registry. Commit the manifest from the run's artifact to the review
  PR before step 5: `DeclareRelease` reads the lens address from it.
- **Step 5:**

```bash
node scripts/js/release-metadata.mjs verify --network paseo-assethub \
  --rpc https://eth-rpc-paseo-next.polkadot.io --tag v1.0.0
```

Any key this reports is a real finding.

## The controller is not the release artefact

DotnsPopController on this branch keeps `__gap` at 49, the size the live proxy's layout needs;
the v1.0.0 tag has 50. The runtime code is the same, but the metadata trailer differs, so the
deployed controller's `extcodehash` does not match the v1.0.0 release asset. The release verify
compares declarations with the chain, so it stays clean. Expect the difference when diffing the
implementation against published bytecode; mask the metadata trailer to compare code.

## The lens address

A fresh deploy puts the lens at the CREATE3 address for the label `DotnsPopLens`. On Paseo that
address already holds an earlier lens build, and CREATE3 slots are single use, so
`RedeployPopLens` uses a salt scoped to the release, the kind `contract:<DOTNS_RELEASE_TAG>`. The
address is predictable before broadcasting (`0x309C5ff21f9082A53211500c6f33cA2a21024Ae4` for
`1.0.0` on Paseo, as the fork tests log it), and a re-run adopts the lens a previous run deployed.
The outgoing lens holds no state and nothing points at it once the key moves, so it leaves the
manifest without a `*Legacy` entry.

## If a step fails

Stop. Every step can be re-run by re-adding its label:

- `UpgradeRegistry` and `UpgradePopRules` swap in the same code again.
- `UpgradePopResolverAndController` upgrades only the proxies still on the previous
  implementation, detected by interface, so a run that died between its two transactions is
  finished by running it again. `test_rerun_completes_a_resolver_only_upgrade` is the executable
  version.
- `RedeployPopLens` adopts the lens at its predicted address and skips the key writes the chain
  already holds.
- `DeclareRelease` first checks that every key points where the manifest says, so a run with the
  step 4 manifest not yet committed stops before writing anything. It writes the version last, so
  a failure before that leaves `0.8.0` declared.

Do not skip ahead to `DeclareRelease` to tidy up. Declaring a release the deployment does not
fully run is the one state the declarations cannot represent.

Rolling a proxy back means upgrading it to its previous implementation, recorded below, through
the same console.

| Proxy | Implementation before this campaign |
| --- | --- |
| DotnsRegistry `0xf34054fd76BbF85f216cf9908226D5f0A72E50CA` | `0x0d4708a5bb49b4f237d7bd9dea51fe895415625f` |
| PopRules `0x747B456bE03aec0b42bd85C51513730FBD45DA31` | `0xef403ba39bed71c806d5777996012647df968014` |
| DotnsPopResolver `0xDaC984884EcA8Fc44011f1D6C49B27828390A72B` | `0x90ef3ed7897fee2f18717a99f198e4c219541deb` |
| DotnsPopController `0xCC932348606cc1f3318cADeC5A5Cd2CA447f8a4b` | `0x20e8026c960da6185877c8ad41c2ad25b7861e98` |

The outgoing lens is `0xAE374b07c7e6f473CBa21d57e36AC15C631Abc51`.

## Close-out

Once the release verify is clean: disable the console with
`gh workflow disable "Paseo Upgrade Step"`, close the review PR, and tag the branch head
`upgrades/paseo-nv2-v1.0.0` so the campaign's exact code stays addressable.

## Running the next campaign on this branch

The branch and its tooling are permanent; the step list changes. In order:

1. Merge `master` into `dev/testnet-upgrades`. Nothing ever merges back.
2. Remove the previous campaign's snapshots, scripts and fork tests. They stay in the branch
   history and under the previous campaign's tag.
3. Take fresh `*Old.sol` snapshots from the code the chain is running: the previous campaign's
   tag, proven by `scripts/shell/verify-snapshots.sh` before anything else is written. A file in
   a snapshot's import closure needs an `Old` copy only when its code differs from the merged tip;
   files that differ only in comments are imported directly. String literals keep their text, so
   the copies compile to the deployed bytecode.
4. Write one upgrade script and one fork test per contract that changes, plus a campaign fork
   test that runs every step in order on one fork. Any script leg that loops over live state is
   paged from day one; see "Limits the simulator cannot see" in CONTRIBUTING.
5. Update the step map in `.github/workflows/paseo-upgrade-step.yml` (each script and the
   contracts whose snapshots it checks), create the labels, set `DOTNS_RELEASE_TAG`, re-enable
   the console, open a review PR, and broadcast one label at a time.
6. Close out as above.

From the first swap on, CI's full `verify-snapshots` on the review PR fails by design, because
the chain no longer matches the pre-upgrade snapshots. That red is the guard working.
