# DotnsRegistry

Forward registry for the `.dot` name hierarchy: maps each node to its `(owner, resolver)` and is where subnames live. Deliberately policy-free — no pricing, expiry, or eligibility logic lives here.

## What it does

Nodes are keyed by **namehash** (`keccak256(parentNode, keccak256(label))`, walking right-to-left from the root). Each node holds a `Record { owner, resolver, exists }`.

- **Second-level names** (`alice.dot`) are tokenised: the record stores `owner = address(0)` as a sentinel and ownership defers to the ERC721 registrar, so `owner(node)` returns the registrar's `ownerOf` for these.
- **Subnames** (`x.alice.dot`) store an explicit owner and can themselves carry subnames. The parent owner is sovereign: it can reassign a subname or its resolver without the subname holder's consent.

On any ownership change the resolver pointer is **reset to the default reverse resolver**, so a prior owner's resolver wiring never follows a name to its next holder.

## Interface

**Reads**
- `owner(bytes32 node) → address` — explicit subnode owner, else the registrar's `ownerOf`, else `address(0)`.
- `resolver(bytes32 node) → address`
- `recordExists(bytes32 node) → bool`
- `isAuthorised(bytes32 node, address account) → bool` — the protocol-wide "may this account manage this node?" check: the stored subnode owner, or (for tokenised names) the ERC721 holder, a single-token approvee, or an operator-for-all on the registrar. Sibling contracts (e.g. the content resolver) delegate to it, so one registrar-level approval carries across the protocol.

**Writes**
- `setSubnodeOwner((parentNode, subLabel, parentLabel, owner)) → bytes32 subnode` — parent-owner only. Creates/reassigns a subname and indexes it in the owner's LabelStore. Validates the label shape and that `parentLabel` hashes to `parentNode`.
- `setOwner(bytes32 node, address newOwner)` — registrar controllers only; used on escrow reclaim. Requires `newOwner == registrar.ownerOf(node)`.
- `setResolver(bytes32 node, address)` — node owner (or ERC721-approved, for tokenised nodes).
- `setSubnodeResolver((parentNode, subLabel, parentLabel, resolver))` — parent-owner override of an existing subname's resolver.

UUPS-upgradeable. Controller authority is delegated to the registrar's `controllers` mapping — the registry keeps no controller list of its own.

## Notes

- Resolver reset on transfer is unconditional; treat a resolver rotation as a re-attestation prompt and gate resolver reads on current ownership.
- Resolvers are not interface-validated here — verify resolver shape off-chain before trusting reads.
