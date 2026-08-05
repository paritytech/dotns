# DotnsPopResolver

Per-node resolver for records produced by the Proof-of-Personhood flow. The writer is the PoP controller (resolved live from the protocol registry), not the node owner — these records are issued during identity provisioning, not curated by the holder.

## Records

- **Chat key** — a 65-byte uncompressed public key per node, the on-chain discovery channel for end-to-end encrypted messaging. Written by the controller on issuance (lite reservations and base registrations, whether fresh or inherited from a prior lite name); must be exactly 65 bytes (`InvalidChatKeyLength`).
- **Lite link** (`liteLink`): full node → the lite labelhash it was claimed from.
- **Full claim** (`fullClaim`): lite labelhash → the full node that claimed it.

The two links are written together and kept bidirectionally consistent (`fullClaim(liteLink(node)) == node`), so consumers resolve either direction without scanning events. Re-linking nulls the stale inverse entries.

## Interface

**Reads (open)**: `chatKey(node)`, `liteLink(node)`, `fullClaim(liteLabelhash)`.

**Writes (PoP controller only)**: `setChatKey(node, bytes)`, `setLiteLink(fullNode, liteLabelhash)`.

UUPS-upgradeable, `Ownable`.

## Notes

- Rotating the PoP controller needs no resolver upgrade — the writer is read from the registry on each write.
