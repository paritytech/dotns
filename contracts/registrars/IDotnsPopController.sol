// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IDotnsController} from "./IDotnsController.sol";

/// @title IDotnsPopController
/// @notice Interface for the dedicated PoP controller orchestrating lite-person and full-person
/// username issuance on behalf of the PoP gateway pallet.
/// @dev Deliberately disjoint from @custom:contract IDotnsRegistrarController. The two
/// controllers coexist on @custom:contract DotnsRegistrar via its multi-controller affordance
/// and neither imports the other. Collision handling reduces to the registrar's ERC721
/// availability check (first-to-mint wins). Reservation queuing for `reservedBaseLabel`
/// mirrors its live head into PopRules, so a queued stem also blocks the public
/// commit-reveal flow, which reads that slot when it prices a name.
///
/// Label formats:
/// Lite-person usernames (first argument to @custom:function reserveBaseName and the
/// `liteLabel` of a `LinkKind.LiteUsername` link) are a stem of lowercase ASCII letters, a
/// separator, then exactly two digits (e.g. `joseph.42`) per
/// @custom:function StringUtils.isLitePersonLabel. The stem is stricter than a DNS label
/// because People Chain restricts the name a person chooses to letters; a stem short enough to
/// be governance-reserved is rejected by classification, not by the shape. The label is stored in
/// the form the gateway sends, which is the form People Chain holds, so nothing here
/// normalises it.
/// Full-person usernames (the `label` of @custom:function registerBaseName and the
/// optional `reservedBaseLabel` of @custom:function reserveBaseName) are lowercase ASCII
/// letters only, per @custom:function StringUtils.isPersonLabel (e.g. `alice`). That is the
/// same rule a lite stem follows and is stricter than a DNS label: no hyphens and no interior
/// digits, because a full-person name is also a name a person chose. A separator marks a lite
/// label and is rejected everywhere else, so only the gateway can create a dotted name; a
/// digit suffix on its own is not exclusive, since a public label may carry one directly.
/// Cross-flow priority on the base stem is arbitrated by
/// @custom:function IPopRules.reserveBaseNameForPop.
/// @custom:security-contact admin@parity.io
interface IDotnsPopController is IDotnsController {
    /// @notice Discriminant for the `Link` union supplied to `registerBaseName`.
    /// @dev Selects the chat-key source for the full-person username. Orthogonal to whether
    /// the registration is a claim or standalone; that is derived from on-chain reservation
    /// state. `None` means the caller supplies a fresh chat key in `link.chatKey`.
    /// `LiteUsername` means the full-person username is linked to a prior lite-person
    /// username (`link.liteLabel`) and inherits its chat key.
    enum LinkKind {
        None,
        LiteUsername
    }

    /// @notice Tagged union selecting the chat-key source for a full-person registration.
    /// @param liteLabel Lite-person `stem.NN` label (only read when `kind == LiteUsername`).
    /// @param chatKey Chat key bytes (only read when `kind == None`).
    struct Link {
        LinkKind kind;
        string liteLabel;
        bytes chatKey;
    }

    /// @notice Per-user reservation pointer: which queue the user sits in and where.
    /// @param labelhash Non-zero when the user holds a live reservation; zero otherwise.
    /// @param index Monotonic queue index, meaningful only when `labelhash` is non-zero.
    struct UserReservation {
        bytes32 labelhash;
        uint64 index;
    }

    /// @notice Reservation queue entry: a user and the timestamp they joined the queue.
    /// @dev Packs into a single storage slot (20 + 8 bytes).
    struct ReservationEntry {
        address owner;
        uint64 joinedAt;
    }

    /// @notice Metadata describing the occupied range of a reservation queue.
    /// @dev Uses monotonically increasing indices. Active entries occupy `[head, tail)`;
    /// `length = tail - head`. Slots past `head` are deleted as the head advances so
    /// garbage never accumulates.
    struct ReservationQueueMeta {
        uint64 head;
        uint64 tail;
    }

    /// @notice Deferred per-user binding of a freshly minted name to its `LabelStore`.
    /// @dev Recorded by the gateway path when the user has no `LabelStore`. The binding later
    /// settles via @custom:function settlePendingClaims, which deploys the store from a signed
    /// origin and writes the stashed label. PoP-resolver records (chat key, lite link) are
    /// persisted eagerly at mint time on @custom:contract IDotnsPopResolver, not at settlement,
    /// so the resolver carries the full identity record regardless of whether the user has
    /// settled their Store. A user accumulates one entry per deferred name: the Root gateway path
    /// cannot deploy a `LabelStore` (contract creation is forbidden from the Root origin), so it
    /// keeps stashing entries until a signed-origin @custom:function settlePendingClaims deploys
    /// the store and settles the entries. Each entry's deadline is measured from its own
    /// `mintedAt` against `reservationDuration`.
    /// @param label Bare label without the TLD, which is appended at settlement time. A lite
    /// claim carries its separator, so this is not always a single DNS label.
    /// @param mintedAt Timestamp of the originating mint.
    struct PendingClaim {
        string label;
        uint64 mintedAt;
    }

    /// @notice Lite-person registration payload.
    /// @dev Single struct so the gateway can ABI-encode one tuple as the cross-chain payload
    /// and the contract decodes it directly out of `msg.data`. All fields are required;
    /// `chatKey` may be empty bytes to skip the resolver write.
    /// @param liteLabel Lite-person `stem.NN` label being minted.
    /// @param user Beneficiary account on this chain.
    /// @param chatKey Chat-key bytes persisted on the PoP resolver. Empty leaves the slot unset.
    struct LiteRegistration {
        string liteLabel;
        address user;
        bytes chatKey;
    }

    /// @notice Lite-person registration combined with an optional base-name reservation.
    /// @dev `BaseReservation` is a @custom:struct LiteRegistration plus a base-label reservation
    /// slot, expressed as composition rather than duplicated fields so internal helpers can
    /// consume the lite leg via `params.lite` without unpacking. The lite leg always runs;
    /// the reservation leg only runs when `reservedBaseLabel` is non-empty.
    /// @param lite Lite-person registration request; see LiteRegistration.
    /// @param reservedBaseLabel Base label to enqueue for a later full-person claim. Empty
    /// string skips the reservation leg.
    struct BaseReservation {
        LiteRegistration lite;
        string reservedBaseLabel;
    }

    /// @notice Base-name reservation payload for the split gateway flow.
    /// @dev This is the reservation-only primitive. The lite username mint is handled by
    /// @custom:function reserveLiteName, and LabelStore settlement is handled by
    /// @custom:function settlePendingClaims.
    /// @param user Beneficiary account that will hold the reservation.
    /// @param reservedBaseLabel Base label to enqueue for a later full-person claim.
    struct BaseNameReservation {
        address user;
        string reservedBaseLabel;
    }

    /// @notice Full-person registration payload.
    /// @param label Base DNS label being minted.
    /// @param user Beneficiary account on this chain.
    /// @param link Chat-key source for the new entry; see @custom:struct Link.
    struct FullRegistration {
        string label;
        address user;
        Link link;
    }

    /// @notice Emitted when a lite-person username is registered via the PoP gateway.
    event LiteNameReserved(bytes32 indexed labelhash, address indexed user, string label);

    /// @notice Emitted when a full-person username is claimed out of an existing reservation.
    event BaseNameClaimed(bytes32 indexed labelhash, address indexed user, string label);

    /// @notice Emitted when a standalone full-person username is registered via the PoP gateway.
    event StandaloneNameRegistered(bytes32 indexed labelhash, address indexed user, string label);

    /// @notice Emitted when a reservation entry is added to the queue for a base name.
    /// @param position Position in the queue at the time of joining (0 = active holder).
    event ReservationQueued(
        bytes32 indexed reservedLabelhash, address indexed user, uint64 position
    );

    /// @notice Emitted when a reservation entry is removed due to expiry.
    event ReservationExpired(bytes32 indexed reservedLabelhash, address indexed user);

    /// @notice Emitted when a user voluntarily relinquishes their reservation.
    event ReservationRelinquished(bytes32 indexed reservedLabelhash, address indexed user);

    /// @notice Emitted when a full-person username is linked to a lite-person username.
    event LiteToFullLinked(bytes32 indexed fullLabelhash, bytes32 indexed liteLabelhash);

    /// @notice Emitted when the reservation duration is updated.
    event ReservationDurationSet(uint64 duration);

    /// @notice Emitted when a name is successfully registered via the PoP controller.
    /// @param store The Store instance used to persist the immutable registration record.
    event NameRegistered(
        string indexed label, bytes32 indexed labelhash, address indexed owner, address store
    );

    /// @notice Emitted when a gateway-path mint defers its `LabelStore` write into the
    /// pending-claim mapping because the user has no store yet.
    event PendingClaimStashed(address indexed user, bytes32 indexed labelhash, string label);

    /// @notice Emitted when a pending claim is written into a `LabelStore`.
    /// @dev Fires once per settled entry from @custom:function settlePendingClaims. `settledBy`
    /// is the caller: it equals `user` for a self-settlement and is any other address for a
    /// third-party settlement, so consumers can tell the two apart from the log alone.
    /// @param user Account the settled name belongs to.
    /// @param labelhash Labelhash of the settled name.
    /// @param store The `LabelStore` the label was written into.
    /// @param settledBy Caller that performed and paid for the settlement.
    event PendingClaimSettled(
        address indexed user, bytes32 indexed labelhash, address store, address indexed settledBy
    );

    /// @notice Emitted when a reservation queue's head transitions to a new user, either via
    /// expiry of the prior head or via the explicit relinquish path.
    /// @param labelhash Base-label hash whose queue head changed.
    /// @param newHead Address now holding the head slot.
    event ReservationHeadAdvanced(bytes32 indexed labelhash, address indexed newHead);

    /// @notice Thrown when a gated entrypoint is reached without a substrate
    ///         Root origin.
    /// @dev Carries no caller parameter: a Root origin has no account to report,
    ///      and reading `msg.sender` under one traps.
    error NotRoot();

    /// @notice Thrown when a supplied lite-person label does not match `stem.NN`.
    error InvalidLiteLabel();

    /// @notice Thrown when a supplied base label is not a canonical DNS label.
    error InvalidBaseLabel();

    /// @notice Thrown when a reserved base label already has an owner on the registrar, so the
    /// queued reservation could never be redeemed at mint time.
    error BaseNameAlreadyRegistered();

    /// @notice Thrown when a supplied chat key is non-empty and not exactly 65 bytes long.
    /// @dev Mirrors the resolver's `InvalidChatKeyLength` so the controller surfaces a
    /// controller-local error before the mint runs.
    /// @param length Caller-supplied chat key length, in bytes.
    error InvalidChatKey(uint256 length);

    /// @notice Thrown when a user tries to claim or relinquish a reservation that they do not hold.
    error NoActiveReservation(address user);

    /// @notice Thrown when a reservation queue has reached its capacity.
    error QueueFull(bytes32 labelhash);

    /// @notice Thrown when attempting to enqueue a user who already has an active reservation.
    error AlreadyReserved(address user, bytes32 labelhash);

    /// @notice Thrown when someone tries to mint a base label in standalone mode while another user
    /// holds the live head-of-queue reservation.
    error NotHolder(address user, bytes32 labelhash);

    /// @notice Thrown when a lite-link inheritance does not match the registrar-side owner
    /// of the lite label.
    /// @dev Prevents identity hijack by ensuring the registrant on the full-name leg actually
    /// holds the prior lite identity whose chat key is being inherited.
    /// @param user Registrant supplied by the gateway.
    /// @param liteLabelhash Lite label whose ownership did not match.
    error LiteLabelNotOwnedByUser(address user, bytes32 liteLabelhash);

    /// @notice Thrown when @custom:function setReservationDuration is called with a value below
    /// the protocol minimum.
    /// @param duration Caller-supplied duration, in seconds.
    error ReservationDurationTooLow(uint64 duration);

    /// @notice Registers a lite-person username on behalf of the supplied user
    /// and optionally enqueues a reservation for a base name they intend to
    /// claim as a full person later.
    /// @dev Callable only under a substrate Root origin (otherwise @custom:reverts NotRoot). The
    /// lite leg validates the `stem.NN` shape and requires the label to classify outside the
    /// governance-reserved tier (otherwise @custom:reverts InvalidLiteLabel), and rejects a
    /// supplied chat key whose length is neither zero nor `CHAT_KEY_LENGTH`
    /// (otherwise @custom:reverts InvalidChatKey). On a warm-path mint (user already has a
    /// `LabelStore`) it @custom:emits LiteNameReserved and @custom:emits NameRegistered;
    /// on a cold-path mint it @custom:emits LiteNameReserved and
    /// @custom:emits PendingClaimStashed, with @custom:emits NameRegistered deferred to
    /// @custom:function settlePendingClaims when the claim settles. The base-name leg only runs
    /// when `reservedBaseLabel` is non-empty: it requires a letters-only person label, which is
    /// therefore also a true base label (otherwise @custom:reverts InvalidBaseLabel), and
    /// with no owner on the registrar (otherwise @custom:reverts BaseNameAlreadyRegistered),
    /// since a name that already has an owner could never be claimed. This validation runs
    /// before both the lite mint and any queue mutation, so an already-registered
    /// `reservedBaseLabel` aborts the whole call and the candidate receives no lite username
    /// either; callers should validate the reserved label before attesting rather than relying
    /// on this revert. It then advances the
    /// head past expired entries (@custom:emits ReservationExpired for each one),
    /// removes the user from any prior queue position so a single user holds at most one live
    /// reservation across all labels, and enqueues a fresh entry
    /// (@custom:emits ReservationQueued). The enqueue rejects with @custom:reverts
    /// AlreadyReserved when the user already holds a reservation that was not cleared by the
    /// prior removal and with @custom:reverts QueueFull when the per-label queue has reached
    /// `MAX_RESERVATION_QUEUE`. Cross-chain callers pass the ABI-encoded reservation tuple as
    /// the call's payload, which Solidity decodes directly.
    /// @param params Reservation request; see @custom:struct BaseReservation.
    function reserveBaseName(BaseReservation calldata params) external;

    /// @notice Enqueues only the full/base-name reservation for a user.
    /// @dev Callable only under a substrate Root origin (otherwise @custom:reverts NotRoot).
    /// This is the second step of the split
    /// gateway flow: @custom:function reserveLiteName mints the lite username first, then this
    /// function reserves the full/base label in a separate transaction so proof-size stays below
    /// per-call limits. Reverts with @custom:reverts InvalidBaseLabel when the label is empty,
    /// is not lowercase ASCII letters (so a hyphen or any digit rejects it), or is
    /// governance-reserved, and with
    /// @custom:reverts BaseNameAlreadyRegistered when the label already has an owner on the
    /// registrar and so could never be claimed. The caller remains agnostic about
    /// backend batching; it simply exposes a small retryable primitive.
    /// @param params Reservation request; see @custom:struct BaseNameReservation.
    function reserveBaseNameOnly(BaseNameReservation calldata params) external;

    /// @notice Registers a lite-person username on behalf of the supplied
    /// user without touching the base-name reservation queue.
    /// @dev Callable only under a substrate Root origin (otherwise @custom:reverts NotRoot). The
    /// supplied label must satisfy the `stem.NN` shape and must classify outside the
    /// governance-reserved tier (otherwise @custom:reverts InvalidLiteLabel); a supplied chat
    /// key whose length is neither zero nor `CHAT_KEY_LENGTH` reverts
    /// @custom:reverts InvalidChatKey before mint and resolver writes run. On a warm-path mint
    /// @custom:emits LiteNameReserved and @custom:emits NameRegistered. On a cold-path
    /// mint @custom:emits LiteNameReserved and @custom:emits PendingClaimStashed, with
    /// @custom:emits NameRegistered deferred to @custom:function settlePendingClaims when the
    /// claim settles. Cross-chain callers pass the ABI-encoded lite-registration tuple as the
    /// call's payload, which Solidity decodes directly.
    /// @param params Registration request; see @custom:struct LiteRegistration.
    function reserveLiteName(LiteRegistration calldata params) external;

    /// @notice Whether this controller minted the whole-label reading of `label`.
    /// @dev Keyed by text, so it answers about an interpretation rather than about a node: a
    /// true answer covers `joseph.42` taken as one label, and says nothing about a subname
    /// `joseph` under `42`, which renders as the same text. Both can exist at once, so a caller
    /// holding a node must also check that node is `namehash(tldNode, keccak(label))` before
    /// reading this answer as being about what it holds; node identity is what names the
    /// object. Set at mint and never cleared, so it is unaffected by a name later becoming
    /// transferable; the soulbound flag is a transfer rule and cannot stand in for it.
    /// @param label Bare label without the TLD, for example `joseph.42`.
    /// @return issued True when this controller minted `label`.
    function isPopIssued(string calldata label) external view returns (bool issued);

    /// @notice Registers a full-person username on behalf of the supplied user.
    /// @dev Callable only under a substrate Root origin (otherwise @custom:reverts NotRoot). The
    /// base label must be a letters-only person label, and therefore a true base label,
    /// (otherwise @custom:reverts InvalidBaseLabel), and the label must not
    /// classify as governance-reserved (otherwise @custom:reverts InvalidBaseLabel). The
    /// gateway also defers to PopRules as the single cross-flow authority: when PopRules
    /// carries a live base-name slot held by another user (this controller's prior queue head,
    /// or a sibling controller's write), the call reverts @custom:reverts NotHolder before any
    /// queue mutation. Two orthogonal axes drive the state machine. The reservation
    /// axis treats the user as claiming if and only if they hold the live head-of-queue
    /// reservation on the base label: a claim wipes the entire queue, releases the PopRules
    /// slot, and @custom:emits BaseNameClaimed; a non-claim silently relinquishes any
    /// pending entry the user holds and @custom:emits StandaloneNameRegistered. Advancing
    /// the queue head past expired entries @custom:emits ReservationExpired for each
    /// one. The chat-key axis selects whether a fresh key is persisted on the resolver or the
    /// new entry inherits its key from a prior lite-person username. The fresh-key branch
    /// rejects a chat key whose length is neither zero nor `CHAT_KEY_LENGTH` (otherwise
    /// @custom:reverts InvalidChatKey). The `LiteUsername` branch validates the lite label's
    /// `stem.NN` shape (otherwise @custom:reverts InvalidLiteLabel), requires the registrant to
    /// own the lite token (otherwise @custom:reverts LiteLabelNotOwnedByUser), reads the lite
    /// node's chat key from the resolver and copies it across; if the lite node carries no chat
    /// key the inherited value is empty and the full node's chat-key write is silently skipped
    /// (the `LiteToFullLinked` event still fires). @custom:emits LiteToFullLinked
    /// alongside the registration event. On a warm-path mint the event order is
    /// @custom:emits NameRegistered first (from the inner mint), then
    /// @custom:emits BaseNameClaimed or @custom:emits StandaloneNameRegistered, then
    /// @custom:emits LiteToFullLinked when applicable. On a cold-path mint
    /// @custom:emits PendingClaimStashed replaces the initial @custom:emits NameRegistered;
    /// the deferred @custom:emits NameRegistered fires later from @custom:function
    /// settlePendingClaims. Cross-chain callers pass the ABI-encoded full-registration tuple as
    /// the call's payload, which Solidity decodes directly.
    /// @param params Registration request; see @custom:struct FullRegistration.
    function registerBaseName(FullRegistration calldata params) external;

    /// @notice Permissionlessly removes expired entries from the head of a reservation queue.
    /// @dev Permissionless on purpose: anyone (typically a UI or a bot) can poke a stale queue
    /// so the next live head takes over without waiting for the next gateway call. Validates
    /// `reservedBaseLabel` as a letters-only person label (otherwise
    /// @custom:reverts InvalidBaseLabel)
    /// and @custom:emits ReservationExpired for every expired entry reaped from the
    /// head. A label carrying a digit or a hyphen is not a person label and
    /// @custom:reverts InvalidBaseLabel, as does a lite label, since a separator is not one
    /// either. Only a letters-only label reaches the queue, and one that was never reserved
    /// resolves to an empty queue so the call is a no-op.
    function expireReservation(string calldata reservedBaseLabel) external;

    /// @notice Lets the caller voluntarily drop their own active reservation.
    /// @dev Reverts with @custom:reverts NoActiveReservation when the caller holds no live
    /// reservation. On success the caller's entry is removed from its queue and
    /// @custom:emits ReservationRelinquished is emitted; if the removed entry was the queue
    /// head, head advancement may additionally @custom:emits ReservationExpired for any
    /// stale entries reaped behind it.
    function relinquishReservation() external;

    /// @notice Returns whether a label currently has a live reservation at the queue head.
    /// @dev Validates `reservedBaseLabel` as a letters-only person label (otherwise
    /// @custom:reverts InvalidBaseLabel) before inspecting the queue.
    function isReservedForClaim(string calldata reservedBaseLabel)
        external
        view
        returns (bool reserved, address holder);

    /// @notice Updates the reservation duration used to decide when queue entries expire.
    /// @dev Owner-gated (otherwise @custom:reverts OwnableUnauthorizedAccount); emits
    /// @custom:emits ReservationDurationSet on success.
    function setReservationDuration(uint64 duration) external;

    /// @notice Returns the queue metadata (`head`, `tail`) for `labelhash`.
    /// @dev Read-only accessor over the per-label reservation queue. `head == tail` means
    /// the queue is empty; active entries occupy `[head, tail)`. Exposed on the interface
    /// because invariant tests and off-chain consumers use it to enumerate
    /// live queue state without scanning storage.
    /// @param labelhash Keccak-256 of the base label whose queue is being read.
    /// @return head Index of the live queue head.
    /// @return tail Index one past the last queued entry.
    function reservationMeta(bytes32 labelhash) external view returns (uint64 head, uint64 tail);

    /// @notice Returns the queue entry at `index` for `labelhash`.
    /// @dev Sparse storage: a zero `entryOwner` means the slot was relinquished, expired and
    /// reaped, or never written. Callers pair this with @custom:function reservationMeta to walk
    /// the live window `[head, tail)`.
    /// @param labelhash Keccak-256 of the base label whose queue is being read.
    /// @param index Queue index to look up.
    /// @return entryOwner Owner of the slot (zero if empty/relinquished).
    /// @return joinedAt Timestamp the entry was enqueued (only meaningful when
    /// `entryOwner != address(0)`).
    function reservationEntry(
        bytes32 labelhash,
        uint64 index
    )
        external
        view
        returns (address entryOwner, uint64 joinedAt);

    /// @notice Returns `user`'s current reservation pointer.
    /// @dev A zero `labelhash` on the returned struct means the user holds no reservation;
    /// `index` is meaningful only when `labelhash` is non-zero.
    /// @param user Account whose reservation pointer is being read.
    /// @return reservation Per-user reservation pointer; see @custom:struct UserReservation.
    function userReservation(address user)
        external
        view
        returns (UserReservation memory reservation);

    /// @notice Returns the base label a reservation queue is keyed under.
    /// @dev Reverse lookup from the `bytes32` queue key to its label string, so a consumer that
    /// observed a queue by labelhash (for example from a reservation event) can recover the
    /// human-readable label without holding its preimage. Returns an empty string when no
    /// reservation was ever enqueued under `labelhash`.
    /// @param labelhash Keccak-256 of the base label.
    /// @return baseLabel The base label string, or empty when unknown.
    function reservedBaseLabelOf(bytes32 labelhash) external view returns (string memory baseLabel);

    /// @notice Returns the window, in seconds, after which a queue or pending-claim entry lapses.
    /// @dev Governance-configurable via @custom:function setReservationDuration. Read by the lens
    /// to compute each pending claim's settlement deadline.
    /// @return duration Reservation duration in seconds.
    function reservationDuration() external view returns (uint64 duration);

    /// @notice Settles up to `limit` of a user's pending claims, writing each stashed label into
    /// the user's `LabelStore` and deploying that store when the user has none yet.
    /// @dev Permissionless: any caller may settle any user's claims and bears the full cost,
    /// including the `LabelStore` storage deposit, which `pallet-revive` charges to the
    /// transaction signer. Settlement is never destructive: the name is already minted, so this
    /// only completes the deferred label write. Each settled entry is removed from the queue and
    /// the user leaves the pending-claim enumeration set once their queue empties. At most
    /// `limit` entries are processed so a large queue cannot exceed the block gas limit;
    /// `moreRemaining` reports whether entries are left for a follow-up call, and a `limit` of
    /// zero settles nothing. Writes are idempotent on an already-locked store slot, so a claim
    /// whose label was independently written settles harmlessly. Emits
    /// @custom:emits PendingClaimSettled and @custom:emits NameRegistered per settled entry, with
    /// `settledBy` set to the caller so a third-party settlement is distinguishable from a
    /// self-settlement.
    /// @param user Account whose pending claims are settled.
    /// @param limit Maximum number of entries to settle in this call.
    /// @return settledCount Number of entries settled.
    /// @return moreRemaining Whether the user still holds unsettled entries.
    function settlePendingClaims(
        address user,
        uint256 limit
    )
        external
        returns (uint256 settledCount, bool moreRemaining);

    /// @notice Settles the caller's own pending claims into their `LabelStore`.
    /// @dev Convenience for a user settling their own store: equivalent to
    /// @custom:function settlePendingClaims with `msg.sender` and a bounded batch. The caller
    /// deploys and pays for their store on the first write. Settles at most one bounded batch so
    /// the call cannot exceed the block gas limit; `moreRemaining` reports whether the caller
    /// still holds unsettled entries, in which case they call again. Emits the same
    /// @custom:emits PendingClaimSettled and @custom:emits NameRegistered as
    /// @custom:function settlePendingClaims.
    /// @return moreRemaining Whether the caller still holds unsettled entries.
    function claimLabelStore() external returns (bool moreRemaining);

    /// @notice Returns a paginated slice of a user's pending claims in queue order.
    /// @dev An empty array means the user has no pending claims at `offset`. Each entry carries
    /// its `mintedAt`; the settlement deadline is `mintedAt + reservationDuration`. An `offset`
    /// past the end returns an empty array rather than reverting, and a page holds at most
    /// `DotnsConstants.MAX_PAGE_SIZE` entries.
    /// @param user Account whose pending claims are read.
    /// @param offset Start index into the queue.
    /// @param limit Maximum entries to return.
    /// @return claims Page of the user's pending claims; see @custom:struct PendingClaim.
    function pendingClaims(
        address user,
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (PendingClaim[] memory claims);

    /// @notice Returns the number of pending claims currently staged for `user`.
    /// @param user Account whose pending claims are counted.
    /// @return count Number of staged pending claims.
    function pendingClaimCountOf(address user) external view returns (uint256 count);

    /// @notice Returns the number of users with at least one live pending claim.
    /// @dev Exact live count, not an all-time tally: fully settled users are removed from the
    /// enumeration set so off-chain consumers can page through every stalled user without
    /// filtering.
    /// @return count Number of users currently holding a pending claim.
    function pendingClaimUserCount() external view returns (uint256 count);

    /// @notice Returns a paginated slice of users with at least one live pending claim.
    /// @dev Pair with @custom:function pendingClaims to read each user's stashed entries.
    /// Ordering is not chronological; callers MUST NOT assume `mintedAt` is monotonic
    /// across the slice. Returns an empty array when `offset` is past the live count, and a page
    /// holds at most `DotnsConstants.MAX_PAGE_SIZE` entries.
    /// @param offset Start index.
    /// @param limit Maximum entries to return.
    /// @return users Slice of users currently holding a pending claim.
    function pendingClaimUsers(
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (address[] memory users);
}
