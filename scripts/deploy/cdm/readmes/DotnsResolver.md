# DotnsResolver

Forward address resolver — the conventional "name → address" lookup. One address record per node.

## Interface

- `addressOf(bytes32 node) → address` — open read; `address(0)` if unset.
- `setAddress(bytes32 node, address)` — current node owner only (`NotAuthorised` otherwise). Emits `AddressSet`.

The owner check is live: the resolver fetches the registry from the protocol registry on each write, so a registry rewire needs no resolver redeploy. UUPS-upgradeable, `Ownable`.

## Notes

- Single address per node — no coin-type / multi-chain records and no operator delegation; only the node owner writes.
