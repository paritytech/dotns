# StoreFactory

Deploys the per-user storage layer: at most one **LabelStore** and one **UserStore** per account, ever. Both run as `BeaconProxy` instances behind two `UpgradeableBeacon`s the factory owns, so every store of a kind upgrades atomically.

## What it does

- `deployLabelStoreFor(user)` — deploy-on-demand of a user's protocol-managed LabelStore. Callable by the factory owner or any protocol-registered address (so the registrar/controllers can provision on first write); unused accounts never pay.
- `claimUserStore()` — self-claim of the caller's UserStore; binds to `msg.sender` regardless of who pays gas.

Re-deploying or re-claiming reverts `AlreadyDeployed`. The factory verifies each fresh proxy reports the expected owner before returning it.

## Interface

**Reads**: `getLabelStore(user)`, `getUserStore(user)`, `getLabelStores`/`getUserStores(offset, limit)` and counts, `labelStoreBeacon()`, `userStoreBeacon()`.

**Writes**: `deployLabelStoreFor(user)`, `claimUserStore()`, `upgradeLabelStoreImplementation(impl)` / `upgradeUserStoreImplementation(impl)` (owner only).

`Ownable`. The factory itself is not a proxy; the stores it deploys are.

## Notes

- Bindings are permanent — stores can't be transferred, reassigned, or re-created.
- See `LabelStoreBeacon` and `UserStoreBeacon` for what each store kind holds.
