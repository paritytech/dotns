# DotnsContentResolver

Stores per-node contenthash and arbitrary text key/value records — where a name points at content (e.g. an IPFS CID) and publishes metadata (social handles, avatars, verification data).

## Interface

**Reads (open)**: `contenthash(node) → bytes`, `text(node, key) → string`, `isApprovedForAll(owner, operator) → bool`.

**Writes**:
- `setContenthash(node, bytes)`, `setText(node, key, value)` — the node owner, a resolver-local approved operator, or any address the registry's `isAuthorised` recognises for the node (the ERC721 holder, a single-token approvee, or an operator-for-all on the registrar); `NotAuthorised` otherwise.
- `setApprovalForAll(operator, bool)` — ERC721-style, but scoped to this resolver: the operator can edit the caller's records yet gains no power over ownership or transfers. This is the narrowest delegation; a registrar-level approval also confers record-write authority here (and transfer power everywhere).

UUPS-upgradeable, `Ownable`. Authority is re-evaluated against the current node owner (via the forward registry, resolved live from the protocol registry) on every write, so transferring the name drops the prior owner's delegates automatically.

## Notes

- Records are opaque bytes/strings — no validation or normalization; text keys are case-sensitive.
