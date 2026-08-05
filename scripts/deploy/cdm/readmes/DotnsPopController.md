# DotnsPopController

Dedicated controller for the Proof-of-Personhood username flow. Its registration entry points are callable only by the PoP gateway (the `RootGatewayDispatcher` registered under `popGateway`). It issues lite- and full-person usernames to verified users and coordinates with `PopRules` so the public flow sees the same reservations.

## What it does

**Issuance**
- `reserveLiteName` — mints a lite-person username. Input is `stem.NN` (one stem label plus a two-digit suffix, e.g. `michal.03`); the controller strips the dot so the on-chain label is flat (`michal03`). Optionally persists the user's chat key on the PoP resolver.
- `reserveBaseName` — mints a lite username and, when a base label is supplied, also enqueues a reservation for the full-person base name the user intends to claim later. `reserveBaseNameOnly` enqueues the reservation without minting.
- `registerBaseName` — mints a full-person username. Whether it is a claim against the user's queued reservation or a fresh standalone registration is derived from on-chain state, not chosen by the caller. A `link` selects the chat-key source (fresh, or inherit from a prior lite name); inheriting also writes the bidirectional lite⇄full links on the PoP resolver in the same transaction.

**Reservation queue.** Each base label has a head/tail FIFO queue (`MAX_RESERVATION_QUEUE` = 64 deep; entries live for `reservationDuration`). On every head transition the new head is mirrored into `PopRules`, so the public commit-reveal flow is blocked on the same stem. `expireReservation` is permissionless GC of a stale head; `relinquishReservation` drops your own entry.

**Deferred LabelStore (testnet limitation).** substrate Root cannot deploy a contract for an account it does not control, so for a user with no store yet the controller stamps a *pending claim* instead of writing the label. The user later calls `claimLabelStore` (or the gateway calls `claimLabelStoreFor`) to settle it; `expirePendingClaim` is permissionless GC of stale pending claims. Until a name is settled it has no readable label, and so quotes a zero transfer floor.

## Interface

**Writes (gateway only)**: `reserveLiteName`, `reserveBaseName`, `reserveBaseNameOnly`, `registerBaseName`, `claimLabelStoreFor`. The four reserve/register entry points each have a typed-tuple overload and an ABI-encoded-`bytes` overload (for cross-chain payloads); `claimLabelStoreFor(address)` is typed only.

**Writes (open)**: `claimLabelStore()`, `relinquishReservation()`, `expireReservation(string)`, `expirePendingClaim(address)`.

**Writes (owner)**: `setReservationDuration(uint64)`.

**Reads**: `isReservedForClaim(string) → (bool, address)`, `reservationMeta`, `reservationEntry`, `userReservation`, `pendingClaims`, `pendingClaimUsers`/`pendingClaimUserCount` (paginated enumeration).

UUPS-upgradeable, `Ownable`.

## Notes

- The two controllers never import each other; `PopRules` is the single cross-flow authority for stem collisions.
- `registerBaseName` rejects lite-shaped and governance-reserved labels (`InvalidBaseLabel`) and rejects a stem held by another user (`NotHolder`).
