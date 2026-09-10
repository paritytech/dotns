# DotnsRegistrar

ERC721 token of record for `.dot` second-level names. The `tokenId` is the name's namehash; holding the token *is* owning the name. Registration is permanent — there is no expiry or renewal.

## What it does

Minting is gated to addresses in the `controllers` mapping (owner-managed via `addController`/`removeController`). This is how the public commit-reveal controller and the PoP controller coexist on one registrar: every other contract checks *this* mapping rather than keeping its own.

Transfers are `payable` and fee-gated. On each transfer the ERC721 `_update` hook:
- mirrors the name's label from the sender's LabelStore into the recipient's, so the label travels with the token;
- quotes a cross-tier transfer floor via `PopRules.transferFloor(label, from, to)` and reverts `TransferFeeRequired` if `msg.value` is short;
- rebinds any escrow release position to the new holder (the refundable deposit follows the NFT, not the prior owner);
- forwards the fee to the escrow.

Mints and self-transfers must carry no value (`UnexpectedValue`).

## Interface

**Reads**
- `available(uint256 id) → bool` — true if unminted *or* held by escrow (signals mint vs. reclaim to the controller).
- `exists(uint256 id) → bool`
- `labelOf(uint256 id) → string` — human label (no `.dot`), read from the holder's LabelStore.
- `quoteTransferFee(uint256 id, address to) → uint256` — extra native value a transfer to `to` will require.
- `controllers(address) → bool`, plus standard ERC721 views.

**Writes**
- `register(uint256 id, address owner, string label)` — controllers only. Label may be empty (gateway-cold mints) or a single canonical DNS label.
- `addController` / `removeController` — owner only.
- `transferFrom` / `safeTransferFrom` — payable; routed through the fee/escrow hook.

UUPS-upgradeable, `Ownable`, ERC721.

## Notes

- A gateway-issued name whose holder has not yet called `claimLabelStore` has no readable label, so its transfer floor quotes as zero until the store is settled.
- Permanent ownership: names move only by transfer or escrow reclaim — there is no burn path.
