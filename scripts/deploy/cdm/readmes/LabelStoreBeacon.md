# LabelStoreBeacon

The `UpgradeableBeacon` that every per-user **LabelStore** proxy points at. It is the stable implementation anchor: the `StoreFactory` owner upgrades all label stores at once by pointing this beacon at a new implementation. This entry is the beacon address, not any single per-user store instance.

## What a LabelStore is

The protocol-managed half of a user's storage — the durable, append-only ledger of names that address has held. The registrar and controllers write a label entry once when a name is registered or transferred in, and the slot is then **permanently locked** (`LabelAlreadyExists` on rewrite). It exists to answer "what names has this address ever held?", which neither the resolvers (keyed per node) nor the registry (live ownership only) can serve.

The invariant is *labels only* — every other per-name record (reverse, content, address, chat key, links) lives on a dedicated resolver. Writes are gated to protocol-registered addresses; reads are open and paginated (`getLabel(labelhash)`, `getLabels`, `getLabelhashes`).

## Beacon interface

- `implementation() → address` — the LabelStore logic all proxies delegate to.
- `upgradeTo(address)` — owner (StoreFactory) only; upgrades every label store at once. Emits `Upgraded`.
- `owner()`, `transferOwnership(address)`.

## Notes

- Per-user store addresses come from `StoreFactory.getLabelStore(user)`; this beacon is the shared implementation pointer, not a store itself.
- The beacon is a plain OZ `UpgradeableBeacon` deployed inside the `StoreFactory` constructor, so unlike the CREATE3-deployed core contracts its address is not guaranteed stable across networks — read it from `StoreFactory.labelStoreBeacon()` or the deployment manifest.
