# UserStoreBeacon

The `UpgradeableBeacon` that every per-user **UserStore** proxy points at — the stable implementation anchor, upgraded for all instances at once by the `StoreFactory` owner. This entry is the beacon address, not any single per-user store instance.

## What a UserStore is

The user-claimed half of a user's storage: a generic `key → value` store that only the bound owner can write, with each superseded non-empty value snapshotted into a per-key history (value + timestamp). It gives user-controlled records that don't belong to any one name a home that bills the user's own contract instead of polluting a shared resolver.

A user claims their store with `StoreFactory.claimUserStore()`; thereafter `setValue(key, bytes)` is owner-only. Reads are open and paginated: `getValue(key)`, `getKeys`, `getHistory(key, …)`.

## Beacon interface

- `implementation() → address` — the UserStore logic all proxies delegate to.
- `upgradeTo(address)` — owner (StoreFactory) only; upgrades every user store at once. Emits `Upgraded`.
- `owner()`, `transferOwnership(address)`.

## Notes

- Per-user store addresses come from `StoreFactory.getUserStore(user)`; this beacon is the shared implementation pointer, not a store itself.
- The beacon is a plain OZ `UpgradeableBeacon` deployed inside the `StoreFactory` constructor, so unlike the CREATE3-deployed core contracts its address is not guaranteed stable across networks — read it from `StoreFactory.userStoreBeacon()` or the deployment manifest.
