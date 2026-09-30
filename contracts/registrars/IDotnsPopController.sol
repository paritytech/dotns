// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {IDotnsController} from "./IDotnsController.sol";

/// @title IDotnsPopController
/// @notice Interface for the dedicated PoP controller that issues device names and personhood
/// names on behalf of the dotNS gateway pallet.
/// @dev Deliberately disjoint from @custom:contract IDotnsRegistrarController. The two
/// controllers coexist on @custom:contract DotnsRegistrar via its multi-controller affordance
/// and neither imports the other. A personhood name collides through the registrar's ERC721
/// availability check (first-to-mint wins); a device name is not a token, so it collides through
/// @custom:function IDotnsRegistry.recordExists at its stem-under-container node
/// (@custom:reverts DeviceNameAlreadyIssued). Reservation queuing for `reservedLabel`
/// mirrors its live head into PopRules, so a queued base name also blocks the public
/// commit-reveal flow, which reads that slot when it prices a name.
///
/// Label formats:
/// Device names (the `label` of @custom:function issueDeviceName and the `deviceLabel` of a
/// `LinkKind.DeviceName` link) are a stem of lowercase ASCII letters, a separator, then exactly
/// two digits (e.g. `joseph.42`) per @custom:function StringUtils.isDeviceLabel. The stem is
/// stricter than a DNS label because the name a person chooses is restricted to letters; a stem
/// short enough to be governance-reserved is rejected by classification, not by the shape. The
/// label is stored in the form the gateway sends, which is the canonical form of the name, so
/// nothing here normalises it.
/// Personhood names (the `label` of @custom:function issuePersonhoodName and the optional
/// `reservedLabel` of @custom:function issueDeviceNameWithReservation) are lowercase ASCII
/// letters only, per @custom:function StringUtils.isPersonhoodLabel (e.g. `alice`). That is the
/// same rule a device-name stem follows and is stricter than a DNS label: no hyphens and no
/// interior digits, because a personhood name is also a name a person chose. A separator marks a
/// device name and is rejected everywhere else, so only the gateway can create a dotted name; a
/// digit suffix on its own is not exclusive, since a public label may carry one directly.
/// Cross-flow priority on the base name is arbitrated by
/// @custom:function IPopRules.reserveBaseNameForPop.
/// @custom:security-contact admin@parity.io
interface IDotnsPopController is IDotnsController {
    /// @notice Discriminant for the `Link` union supplied to `issuePersonhoodName`.
    /// @dev Selects the chat-key source for the personhood name. Orthogonal to whether the
    /// issuance is a claim or standalone; that is derived from on-chain reservation state. `None`
    /// means the caller supplies a fresh chat key in `link.chatKey`. `DeviceName` means the
    /// personhood name is linked to a prior device name (`link.deviceLabel`) and inherits its chat
    /// key. The member order is part of the ABI: the gateway pallet encodes `DeviceName` as `1`.
    enum LinkKind {
        None,
        DeviceName
    }

    /// @notice Tagged union selecting the chat-key source for a personhood-name issuance.
    /// @param deviceLabel Device name `stem.NN` (only read when `kind == DeviceName`).
    /// @param chatKey Chat key bytes (only read when `kind == None`).
    struct Link {
        LinkKind kind;
        string deviceLabel;
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
    /// origin and writes the stashed label. PoP-resolver records (chat key, device link) are
    /// persisted eagerly at mint time on @custom:contract IDotnsPopResolver, not at settlement,
    /// so the resolver carries the full identity record regardless of whether the user has
    /// settled their Store. A user accumulates one entry per deferred name: the Root gateway path
    /// cannot deploy a `LabelStore` (contract creation is forbidden from the Root origin), so it
    /// keeps stashing entries until a signed-origin @custom:function settlePendingClaims deploys
    /// the store and settles the entries. Entries never lapse and can be settled at any time;
    /// `mintedAt + reservationDuration` is only the advisory deadline the lens reports.
    /// @param label Bare label without the TLD, which is appended at settlement time. A device
    /// name carries its separator, so this is not always a single DNS label.
    /// @param mintedAt Timestamp of the originating mint.
    struct PendingClaim {
        string label;
        uint64 mintedAt;
    }

    /// @notice Device-name issuance payload.
    /// @dev Single struct so the gateway can ABI-encode one tuple as the cross-chain payload
    /// and the contract decodes it directly out of `msg.data`. All fields are required;
    /// `chatKey` may be empty bytes to skip the resolver write.
    /// @param label Device name `stem.NN` being issued.
    /// @param user Beneficiary account on this chain.
    /// @param chatKey Chat-key bytes persisted on the PoP resolver. Empty leaves the slot unset.
    struct DeviceNameIssuance {
        string label;
        address user;
        bytes chatKey;
    }

    /// @notice Device-name issuance combined with an optional personhood-name reservation.
    /// @dev Composition of a @custom:struct DeviceNameIssuance and a reservation slot, so
    /// internal helpers consume the issuance via `params.issuance` without unpacking. The issuance
    /// always runs; the reservation only runs when `reservedLabel` is non-empty.
    /// @param issuance Device-name issuance request; see DeviceNameIssuance.
    /// @param reservedLabel Personhood name to enqueue for a later claim. Empty string skips the
    /// reservation.
    struct DeviceNameIssuanceWithReservation {
        DeviceNameIssuance issuance;
        string reservedLabel;
    }

    /// @notice Personhood-name reservation payload.
    /// @dev The reservation-only primitive. Device-name issuance is handled by
    /// @custom:function issueDeviceName, and LabelStore settlement by
    /// @custom:function settlePendingClaims.
    /// @param user Beneficiary account that will hold the reservation.
    /// @param label Personhood name to enqueue for a later claim.
    struct PersonhoodNameReservation {
        address user;
        string label;
    }

    /// @notice Personhood-name issuance payload.
    /// @param label Personhood name being issued.
    /// @param user Beneficiary account on this chain.
    /// @param link Chat-key source for the new entry; see @custom:struct Link.
    struct PersonhoodNameIssuance {
        string label;
        address user;
        Link link;
    }

    /// @notice Emitted when the gateway pallet issues a device name.
    event DeviceNameIssued(bytes32 indexed labelhash, address indexed user, string label);

    /// @notice Emitted when the gateway pallet issues a personhood name.
    /// @dev Fires whether or not the user held a reservation for it; a claim of the live
    /// reservation also @custom:emits ReservationClaimed.
    event PersonhoodNameIssued(bytes32 indexed labelhash, address indexed user, string label);

    /// @notice Emitted when a reservation entry is added to the queue for a personhood name.
    /// @param position Position in the queue at the time of joining (0 = active holder).
    event ReservationQueued(
        bytes32 indexed reservedLabelhash, address indexed user, uint64 position
    );

    /// @notice Emitted when a reservation entry is removed due to expiry.
    event ReservationExpired(bytes32 indexed reservedLabelhash, address indexed user);

    /// @notice Emitted when a user's own reservation entry is dropped: an explicit relinquish, a
    /// standalone personhood-name issuance, or a re-reservation that moves the user to another
    /// queue.
    event ReservationRelinquished(bytes32 indexed reservedLabelhash, address indexed user);

    /// @notice Emitted when the holder of a queue's live head claims the reserved name.
    event ReservationClaimed(bytes32 indexed reservedLabelhash, address indexed user);

    /// @notice Emitted for each waiter removed from a queue when its head is claimed.
    event ReservationEvicted(bytes32 indexed reservedLabelhash, address indexed user);

    /// @notice Emitted when a personhood name is linked to a device name.
    event DeviceNameLinked(bytes32 indexed personhoodLabelhash, bytes32 indexed deviceLabelhash);

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
    /// @param labelhash Personhood-name hash whose queue head changed.
    /// @param newHead Address now holding the head slot.
    event ReservationHeadAdvanced(bytes32 indexed labelhash, address indexed newHead);

    /// @notice Thrown when a gated entrypoint is reached without a Root origin.
    /// @dev Carries no caller parameter: a Root origin has no account to report,
    ///      and reading `msg.sender` under one traps.
    error NotRoot();

    /// @notice Thrown when a supplied device name does not match `stem.NN`, or its stem is
    /// governance-reserved.
    error InvalidDeviceLabel();

    /// @notice Thrown when a supplied personhood name is not lowercase ASCII letters only, or
    /// classifies outside what the gateway may issue or reserve.
    error InvalidPersonhoodLabel();

    /// @notice Thrown when a personhood name to reserve already has an owner on the registrar, so
    /// the queued reservation could never be claimed.
    error PersonhoodNameUnavailable();

    /// @notice Thrown when a device name is issued again while its subname already exists.
    /// @dev A device name is issued once; re-issuing it would rehome the identity to a new owner
    ///      and overwrite its records, so an existing subname is rejected rather than reassigned.
    error DeviceNameAlreadyIssued();

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

    /// @notice Thrown when someone tries to issue a personhood name standalone while another user
    /// holds the live head-of-queue reservation for it.
    error NotHolder(address user, bytes32 labelhash);

    /// @notice Thrown when a device link names a device name the registrant does not own.
    /// @dev Prevents identity hijack by ensuring the registrant of the personhood name actually
    /// holds the device name whose chat key is being inherited.
    /// @param user Registrant supplied by the gateway.
    /// @param deviceLabelhash Device name whose ownership did not match.
    error DeviceNameNotOwned(address user, bytes32 deviceLabelhash);

    /// @notice Thrown when @custom:function setReservationDuration is called with a value below
    /// the protocol minimum.
    /// @param duration Caller-supplied duration, in seconds.
    error ReservationDurationTooLow(uint64 duration);

    /// @notice Issues a device name to the supplied user and optionally enqueues a reservation
    /// for a personhood name they intend to claim later.
    /// @dev Callable only under a Root origin (otherwise @custom:reverts NotRoot). The issuance
    /// validates the `stem.NN` shape and requires the label to classify outside the
    /// governance-reserved tier (otherwise @custom:reverts InvalidDeviceLabel), and rejects a
    /// supplied chat key whose length is neither zero nor `CHAT_KEY_LENGTH`
    /// (otherwise @custom:reverts InvalidChatKey). On a warm-path mint (user already has a
    /// `LabelStore`) it @custom:emits DeviceNameIssued and @custom:emits NameRegistered;
    /// on a cold-path mint it @custom:emits DeviceNameIssued and
    /// @custom:emits PendingClaimStashed, with @custom:emits NameRegistered deferred to
    /// @custom:function settlePendingClaims when the claim settles. The reservation only runs
    /// when `reservedLabel` is non-empty: it requires a letters-only personhood label
    /// (otherwise @custom:reverts InvalidPersonhoodLabel) with no owner on the registrar
    /// (otherwise @custom:reverts PersonhoodNameUnavailable), since a name that already has an
    /// owner could never be claimed. This validation runs before both the issuance and any queue
    /// mutation, so an already-registered `reservedLabel` aborts the whole call and the candidate
    /// receives no device name either; callers should validate the reserved label before
    /// attesting rather than relying on this revert. It then advances the head past expired
    /// entries (@custom:emits ReservationExpired for each one), removes the user from any prior
    /// queue position (@custom:emits ReservationRelinquished) so a single user holds at most one
    /// live reservation across all labels, and enqueues a fresh entry
    /// (@custom:emits ReservationQueued). The enqueue rejects with @custom:reverts
    /// AlreadyReserved when the user already holds a reservation that was not cleared by the
    /// prior removal and with @custom:reverts QueueFull when the per-label queue has reached
    /// `MAX_RESERVATION_QUEUE`. Cross-chain callers pass the ABI-encoded tuple as the call's
    /// payload, which Solidity decodes directly.
    /// @param params Issuance and reservation request; see
    /// @custom:struct DeviceNameIssuanceWithReservation.
    function issueDeviceNameWithReservation(DeviceNameIssuanceWithReservation calldata params)
        external;

    /// @notice Enqueues only a personhood-name reservation for a user.
    /// @dev Callable only under a Root origin (otherwise @custom:reverts NotRoot). This is the
    /// second step of the split gateway flow: @custom:function issueDeviceName issues the device
    /// name first, then this function reserves the personhood name in a separate transaction so
    /// proof-size stays below per-call limits. Reverts with @custom:reverts InvalidPersonhoodLabel
    /// when the label is empty, is not lowercase ASCII letters (so a hyphen or any digit rejects
    /// it), or is governance-reserved, and with @custom:reverts PersonhoodNameUnavailable when the
    /// label already has an owner on the registrar and so could never be claimed. Moving the user
    /// out of a prior queue @custom:emits ReservationRelinquished. The caller remains agnostic
    /// about backend batching; it simply exposes a small retryable primitive.
    /// @param params Reservation request; see @custom:struct PersonhoodNameReservation.
    function reservePersonhoodName(PersonhoodNameReservation calldata params) external;

    /// @notice Issues a device name to the supplied user without touching the reservation queue.
    /// @dev Callable only under a Root origin (otherwise @custom:reverts NotRoot). The
    /// supplied label must satisfy the `stem.NN` shape and must classify outside the
    /// governance-reserved tier (otherwise @custom:reverts InvalidDeviceLabel); a supplied chat
    /// key whose length is neither zero nor `CHAT_KEY_LENGTH` reverts
    /// @custom:reverts InvalidChatKey before mint and resolver writes run. A device name that has
    /// already been issued reverts @custom:reverts DeviceNameAlreadyIssued. On a warm-path mint
    /// @custom:emits DeviceNameIssued and @custom:emits NameRegistered. On a cold-path
    /// mint @custom:emits DeviceNameIssued and @custom:emits PendingClaimStashed, with
    /// @custom:emits NameRegistered deferred to @custom:function settlePendingClaims when the
    /// claim settles. Cross-chain callers pass the ABI-encoded issuance tuple as the call's
    /// payload, which Solidity decodes directly.
    /// @param params Issuance request; see @custom:struct DeviceNameIssuance.
    function issueDeviceName(DeviceNameIssuance calldata params) external;

    /// @notice Whether this controller issued `label` as a PoP identity.
    /// @dev Keyed by text, so it answers about a name rather than about a node. A device name is
    /// issued as a subname (`joseph` beneath its numeric container `42`) and a personhood name as
    /// a second-level name, so a caller holding a node must check that the node is the one `label`
    /// resolves to under those rules before reading this answer as being about what it holds; node
    /// identity is what names the object. Set at mint and never cleared, so it is unaffected by a
    /// name later becoming transferable; the soulbound flag is a transfer rule and cannot stand in
    /// for it.
    /// @param label Bare label without the TLD, for example `joseph.42`.
    /// @return issued True when this controller issued `label`.
    function isPopIssued(string calldata label) external view returns (bool issued);

    /// @notice Issues a personhood name to the supplied user.
    /// @dev Callable only under a Root origin (otherwise @custom:reverts NotRoot). The label must
    /// be a letters-only personhood label (otherwise @custom:reverts InvalidPersonhoodLabel), and
    /// must not classify as governance-reserved or as a device-name shape (otherwise
    /// @custom:reverts InvalidPersonhoodLabel). The gateway also defers to PopRules as the single
    /// cross-flow authority: when PopRules carries a live base-name slot held by another user (this
    /// controller's prior queue head, or a sibling controller's write), the call reverts
    /// @custom:reverts NotHolder before any queue mutation. Two orthogonal axes drive the state
    /// machine. The reservation axis treats the user as claiming if and only if they hold the live
    /// head-of-queue reservation on the label: a claim wipes the entire queue
    /// (@custom:emits ReservationEvicted for every other waiter), releases the PopRules slot, and
    /// @custom:emits ReservationClaimed; a non-claim drops any pending entry the user holds
    /// (@custom:emits ReservationRelinquished). Either way the issuance
    /// @custom:emits PersonhoodNameIssued. Advancing the queue head past expired entries
    /// @custom:emits ReservationExpired for each one. The chat-key axis selects whether a fresh key
    /// is persisted on the resolver or the new entry inherits its key from a prior device name.
    /// The fresh-key branch rejects a chat key whose length is neither zero nor `CHAT_KEY_LENGTH`
    /// (otherwise @custom:reverts InvalidChatKey). The `DeviceName` branch validates the device
    /// name's `stem.NN` shape (otherwise @custom:reverts InvalidDeviceLabel), requires the
    /// registrant to own the device name in the registry (otherwise
    /// @custom:reverts DeviceNameNotOwned), reads its chat key from the resolver and copies it
    /// across; if the device name carries no chat key the inherited value is empty and the
    /// personhood name's chat-key write is silently skipped (the `DeviceNameLinked` event still
    /// fires). @custom:emits DeviceNameLinked alongside the issuance event. On a warm-path mint
    /// the event order is @custom:emits NameRegistered first (from the inner mint), then
    /// @custom:emits PersonhoodNameIssued, then @custom:emits DeviceNameLinked when applicable. On
    /// a cold-path mint @custom:emits PendingClaimStashed replaces the initial
    /// @custom:emits NameRegistered; the deferred @custom:emits NameRegistered fires later from
    /// @custom:function settlePendingClaims. Cross-chain callers pass the ABI-encoded issuance
    /// tuple as the call's payload, which Solidity decodes directly.
    /// @param params Issuance request; see @custom:struct PersonhoodNameIssuance.
    function issuePersonhoodName(PersonhoodNameIssuance calldata params) external;

    /// @notice Permissionlessly removes expired entries from the head of a reservation queue.
    /// @dev Permissionless on purpose: anyone (typically a UI or a bot) can poke a stale queue
    /// so the next live head takes over without waiting for the next gateway call. Validates
    /// `label` as a letters-only personhood label (otherwise @custom:reverts
    /// InvalidPersonhoodLabel) and @custom:emits ReservationExpired for every expired entry reaped
    /// from the head. A label carrying a digit or a hyphen is not a personhood label and
    /// @custom:reverts InvalidPersonhoodLabel, as does a device name, since a separator is not one
    /// either. Only a letters-only label reaches the queue, and one that was never reserved
    /// resolves to an empty queue so the call is a no-op.
    /// @param label Personhood name whose queue is reaped.
    function expireReservation(string calldata label) external;

    /// @notice Lets the caller voluntarily drop their own active reservation.
    /// @dev Reverts with @custom:reverts NoActiveReservation when the caller holds no live
    /// reservation. On success the caller's entry is removed from its queue and
    /// @custom:emits ReservationRelinquished is emitted; if the removed entry was the queue
    /// head, head advancement may additionally @custom:emits ReservationExpired for any
    /// stale entries reaped behind it.
    function relinquishReservation() external;

    /// @notice Returns whether a label currently has a live reservation at the queue head.
    /// @dev Validates `label` as a letters-only personhood label (otherwise
    /// @custom:reverts InvalidPersonhoodLabel) before inspecting the queue.
    /// @param label Personhood name whose queue is inspected.
    function isReservedForClaim(string calldata label)
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
    /// @param labelhash Keccak-256 of the personhood name whose queue is being read.
    /// @return head Index of the live queue head.
    /// @return tail Index one past the last queued entry.
    function reservationMeta(bytes32 labelhash) external view returns (uint64 head, uint64 tail);

    /// @notice Returns the queue entry at `index` for `labelhash`.
    /// @dev Sparse storage: a zero `entryOwner` means the slot was relinquished, expired and
    /// reaped, or never written. Callers pair this with @custom:function reservationMeta to walk
    /// the live window `[head, tail)`.
    /// @param labelhash Keccak-256 of the personhood name whose queue is being read.
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

    /// @notice Returns the personhood name a reservation queue is keyed under.
    /// @dev Reverse lookup from the `bytes32` queue key to its label string, so a consumer that
    /// observed a queue by labelhash (for example from a reservation event) can recover the
    /// human-readable label without holding its preimage. Returns an empty string when no
    /// reservation was ever enqueued under `labelhash`.
    /// @param labelhash Keccak-256 of the personhood name.
    /// @return label The personhood name, or empty when unknown.
    function reservedLabelOf(bytes32 labelhash) external view returns (string memory label);

    /// @notice Returns the window, in seconds, after which a reservation-queue entry lapses.
    /// @dev Governance-configurable via @custom:function setReservationDuration. Pending claims do
    /// not lapse; the lens adds this window to each claim's `mintedAt` to report an advisory
    /// settlement deadline.
    /// @return duration Reservation duration in seconds.
    function reservationDuration() external view returns (uint64 duration);

    /// @notice Settles up to `limit` of a user's pending claims, writing each stashed label into
    /// the user's `LabelStore` and deploying that store when the user has none yet.
    /// @dev Permissionless: any caller may settle any user's claims and bears the full cost,
    /// including the `LabelStore` storage deposit, which is charged to the
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
    /// its `mintedAt`; `mintedAt + reservationDuration` is an advisory settlement deadline, and
    /// the entry stays settleable after it. An `offset`
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
