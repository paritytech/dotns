// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IDotnsController} from "./IDotnsController.sol";

/// @title IDotnsPopController
/// @notice Interface for the dedicated PoP controller orchestrating lite-person and full-person
/// username issuance on behalf of the PoP gateway pallet.
/// @dev Deliberately disjoint from @custom:contract IDotnsRegistrarController. The two
/// controllers coexist on @custom:contract DotnsRegistrar via its multi-controller affordance
/// and neither imports the other. Collision handling reduces to the registrar's ERC721
/// availability check (first-to-mint wins). Reservation queuing for `reservedBaseLabel` is
/// an intra-PoP coordination mechanism only; it does not block public registrations.
///
/// Label formats:
/// Lite-person usernames (first argument to @custom:function reserveBaseName and the
/// `liteLabel` of a `LinkKind.LiteUsername` link) are DNS labels with exactly two
/// trailing digits (e.g. `alice42`) per @custom:function StringUtils.isLitePersonLabel.
/// The gateway strips any separator before calling so the on-chain label is flat.
/// Full-person usernames (the `label` of @custom:function registerBaseName and the
/// optional `reservedBaseLabel` of @custom:function reserveBaseName) follow the
/// DNS-label rules enforced by @custom:function StringUtils.isSingleLabel (e.g.
/// `alice`). Lite and public registrations share one namespace; first-to-mint wins at
/// the ERC721 layer. Cross-flow priority on the stripped base stem is arbitrated by
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
    /// @param liteLabel Lite-person `NAMEXX` label (only read when `kind == LiteUsername`).
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
    /// @dev Recorded by the gateway path when the user has no `LabelStore`. The user
    /// later settles the binding via @custom:function claimLabelStore, which deploys
    /// the store from a signed origin and writes the stashed label. PoP-resolver records
    /// (chat key, lite link) are persisted eagerly at mint time on
    /// @custom:contract IDotnsPopResolver, not at settlement, so the resolver carries
    /// the full identity record regardless of whether the user has settled their Store.
    /// A user accumulates one entry per deferred name: the Root gateway path cannot deploy a
    /// `LabelStore` (contract creation is forbidden from the Root origin), so it keeps stashing
    /// entries until a signed-origin @custom:function claimLabelStore deploys the store and
    /// settles every entry at once. Each entry's expiry is measured from its own `mintedAt`
    /// against `reservationDuration`.
    /// @param label Bare DNS label (no TLD); the TLD is appended at settlement time.
    /// @param mintedAt Timestamp of the originating mint.
    struct PendingClaim {
        string label;
        uint64 mintedAt;
    }

    /// @notice Lite-person registration payload.
    /// @dev Single struct so the gateway can ABI-encode one tuple as the cross-chain payload
    /// and the contract decodes it directly out of `msg.data`. All fields are required;
    /// `chatKey` may be empty bytes to skip the resolver write.
    /// @param liteLabel Lite-person `NAMEXX` label being minted.
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
    /// @custom:function claimLabelStoreFor or the user fallback @custom:function claimLabelStore.
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

    /// @notice Emitted when a user settles a deferred binding by deploying their
    /// `LabelStore` and backfilling the stashed label and chat key.
    event PendingClaimSettled(address indexed user, bytes32 indexed labelhash, address store);

    /// @notice Emitted when a deferred binding is reaped because it sat unsettled past
    /// `reservationDuration`.
    event PendingClaimExpired(address indexed user, bytes32 indexed labelhash);

    /// @notice Emitted when a reservation queue's head transitions to a new user, either via
    /// expiry of the prior head or via the explicit relinquish path.
    /// @param labelhash Base-label hash whose queue head changed.
    /// @param newHead Address now holding the head slot.
    event ReservationHeadAdvanced(bytes32 indexed labelhash, address indexed newHead);

    /// @notice Thrown when a gated entrypoint is reached from an address that
    ///         is not the gateway registered on the protocol registry under
    ///         the PoP gateway key.
    /// @dev The controller delegates substrate Root-authority verification to
    ///      the registered gateway, which is the Root gateway dispatcher, and
    ///      authorises calls solely against the address resolved from the
    ///      protocol registry. The caller parameter carries the immediate EVM
    ///      caller observed by this contract for off-chain diagnostics.
    /// @param caller Immediate EVM caller observed by this contract.
    error NotGateway(address caller);

    /// @notice Thrown when a supplied lite-person label does not match `NAMEXX`.
    error InvalidLiteLabel();

    /// @notice Thrown when a supplied base label is not a canonical DNS label.
    error InvalidBaseLabel();

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

    /// @notice Thrown when @custom:function claimLabelStore is called by a user with no
    /// recorded pending-claim entries.
    /// @param user Caller observed by the controller.
    error NoPendingClaim(address user);

    /// @notice Thrown when @custom:function expirePendingClaim is invoked but the user holds
    /// no entry past its `mintedAt + reservationDuration` deadline.
    /// @param user Address whose entries are being inspected.
    error PendingClaimNotExpired(address user);

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
    /// @dev Callable only via the registered PoP gateway (otherwise @custom:reverts NotGateway);
    /// the gateway is responsible for asserting substrate Root authority before forwarding
    /// here. The lite leg validates the dotted `stem.NN` shape and requires the flattened label
    /// to classify as PopLite (otherwise @custom:reverts InvalidLiteLabel), and rejects a
    /// supplied chat key whose length is neither zero nor `CHAT_KEY_LENGTH`
    /// (otherwise @custom:reverts InvalidChatKey). On a warm-path mint (user already has a
    /// `LabelStore`) it emits @custom:emits LiteNameReserved and @custom:emits NameRegistered;
    /// on a cold-path mint it emits @custom:emits LiteNameReserved and
    /// @custom:emits PendingClaimStashed, with @custom:emits NameRegistered deferred to
    /// @custom:function claimLabelStore when the user settles. The base-name leg only runs
    /// when `reservedBaseLabel` is non-empty: it validates the DNS-label shape and requires a
    /// true base label with no trailing digits (otherwise @custom:reverts InvalidBaseLabel)
    /// before any queue mutation so a bad reservation never touches the queue, advances the
    /// head past expired entries (emitting @custom:emits ReservationExpired for each one),
    /// removes the user from any prior queue position so a single user holds at most one live
    /// reservation across all labels, and enqueues a fresh entry (emitting
    /// @custom:emits ReservationQueued). The enqueue rejects with @custom:reverts
    /// AlreadyReserved when the user already holds a reservation that was not cleared by the
    /// prior removal and with @custom:reverts QueueFull when the per-label queue has reached
    /// `MAX_RESERVATION_QUEUE`. Cross-chain callers pass the ABI-encoded reservation tuple as
    /// the call's payload, which Solidity decodes directly.
    /// @param params Reservation request; see @custom:struct BaseReservation.
    function reserveBaseName(BaseReservation calldata params) external;

    /// @notice Raw-payload variant of @custom:function reserveBaseName for cross-chain dispatch.
    /// @dev `payload` is `abi.encode(BaseReservation({...}))`, the bare ABI-encoded struct
    /// with NO function-selector prefix and NO leading bytes-length word. The contract
    /// prepends the typed selector and `delegatecall`s itself so the typed entrypoint runs
    /// in the original call context and remains the single source of truth, which means the
    /// typed overload's full revert surface bubbles up byte-for-byte: gateway-only access
    /// (otherwise @custom:reverts NotGateway), lite-label shape (otherwise
    /// @custom:reverts InvalidLiteLabel), base-label shape (otherwise
    /// @custom:reverts InvalidBaseLabel), duplicate-reservation guard (otherwise
    /// @custom:reverts AlreadyReserved), and queue capacity (otherwise
    /// @custom:reverts QueueFull). The success path likewise emits the same events as the
    /// typed call: @custom:emits LiteNameReserved and @custom:emits NameRegistered on the lite
    /// leg, plus @custom:emits ReservationQueued and any @custom:emits ReservationExpired
    /// observed while advancing the queue head when the base-name leg runs.
    /// Note: `abi.decode` ignores trailing bytes past the encoded struct, so off-chain
    /// encoders MUST NOT assume strict length validation.
    /// @param payload `abi.encode(BaseReservation)` produced by the cross-chain caller.
    function reserveBaseName(bytes calldata payload) external;

    /// @notice Enqueues only the full/base-name reservation for a user.
    /// @dev Callable only via the registered PoP gateway. This is the second step of the split
    /// gateway flow: @custom:function reserveLiteName mints the lite username first, then this
    /// function reserves the full/base label in a separate transaction so proof-size stays below
    /// per-call limits. Reverts with @custom:reverts InvalidBaseLabel when the label is empty,
    /// non-canonical, digit-suffixed, or governance-reserved. The caller remains agnostic about
    /// backend batching; it simply exposes a small retryable primitive.
    /// @param params Reservation request; see @custom:struct BaseNameReservation.
    function reserveBaseNameOnly(BaseNameReservation calldata params) external;

    /// @notice Raw-payload variant of @custom:function reserveBaseNameOnly for cross-chain
    /// dispatch. @param payload `abi.encode(BaseNameReservation)` produced by the cross-chain
    /// caller.
    function reserveBaseNameOnly(bytes calldata payload) external;

    /// @notice Registers a lite-person username on behalf of the supplied
    /// user without touching the base-name reservation queue.
    /// @dev Callable only via the registered PoP gateway (otherwise @custom:reverts NotGateway);
    /// the gateway is responsible for asserting substrate Root authority before forwarding
    /// here. The supplied label must satisfy the dotted `stem.NN` shape and the flattened label
    /// must classify as PopLite (otherwise @custom:reverts InvalidLiteLabel); a supplied chat
    /// key whose length is neither zero nor `CHAT_KEY_LENGTH` reverts
    /// @custom:reverts InvalidChatKey before mint and resolver writes run. On a warm-path mint
    /// emits @custom:emits LiteNameReserved and @custom:emits NameRegistered. On a cold-path
    /// mint emits @custom:emits LiteNameReserved and @custom:emits PendingClaimStashed, with
    /// @custom:emits NameRegistered deferred to @custom:function claimLabelStore when the user
    /// settles. Cross-chain callers pass the ABI-encoded lite-registration tuple as the call's
    /// payload, which Solidity decodes directly.
    /// @param params Registration request; see @custom:struct LiteRegistration.
    function reserveLiteName(LiteRegistration calldata params) external;

    /// @notice Raw-payload variant of @custom:function reserveLiteName for cross-chain dispatch.
    /// @dev `payload` is `abi.encode(LiteRegistration({...}))`, the bare ABI-encoded struct
    /// with NO function-selector prefix and NO leading bytes-length word. The contract
    /// prepends the typed selector and `delegatecall`s itself so the typed entrypoint runs
    /// in the original call context and remains the single source of truth, so the typed
    /// overload's revert surface bubbles up byte-for-byte: gateway-only access (otherwise
    /// @custom:reverts NotGateway) and lite-label shape (otherwise
    /// @custom:reverts InvalidLiteLabel). The success path emits the same events as the typed
    /// call: @custom:emits LiteNameReserved and @custom:emits NameRegistered.
    /// Note: `abi.decode` ignores trailing bytes past the encoded struct, so
    /// off-chain encoders MUST NOT assume strict length validation; pad-only
    /// junk past the tail is silently dropped (no state corruption; decoded
    /// values are unchanged).
    /// Worked example off-chain:
    ///   `bytes payload = abi.encode(LiteRegistration({liteLabel: "alice42", user: u, chatKey:
    /// k}));`
    /// @param payload `abi.encode(LiteRegistration)` produced by the cross-chain caller.
    function reserveLiteName(bytes calldata payload) external;

    /// @notice Registers a full-person username on behalf of the supplied user.
    /// @dev Callable only via the registered PoP gateway (otherwise @custom:reverts NotGateway);
    /// the gateway is responsible for asserting substrate Root authority before forwarding
    /// here. The base label must satisfy the DNS-label shape and be a true base label with no
    /// trailing digits (otherwise @custom:reverts InvalidBaseLabel), and the label must not
    /// classify as governance-reserved (otherwise @custom:reverts InvalidBaseLabel). The
    /// gateway also defers to PopRules as the single cross-flow authority: when PopRules
    /// carries a live base-name slot held by another user (stamped by the public commit-reveal
    /// flow or this controller's prior queue head), the call reverts @custom:reverts NotHolder
    /// before any queue mutation. Two orthogonal axes drive the state machine. The reservation
    /// axis treats the user as claiming if and only if they hold the live head-of-queue
    /// reservation on the base label: a claim wipes the entire queue, releases the PopRules
    /// slot, and emits @custom:emits BaseNameClaimed; a non-claim silently relinquishes any
    /// pending entry the user holds and emits @custom:emits StandaloneNameRegistered. Advancing
    /// the queue head past expired entries emits @custom:emits ReservationExpired for each
    /// one. The chat-key axis selects whether a fresh key is persisted on the resolver or the
    /// new entry inherits its key from a prior lite-person username. The fresh-key branch
    /// rejects a chat key whose length is neither zero nor `CHAT_KEY_LENGTH` (otherwise
    /// @custom:reverts InvalidChatKey). The `LiteUsername` branch validates the lite label's
    /// `NAMEXX` shape (otherwise @custom:reverts InvalidLiteLabel), requires the registrant to
    /// own the lite token (otherwise @custom:reverts LiteLabelNotOwnedByUser), reads the lite
    /// node's chat key from the resolver and copies it across; if the lite node carries no chat
    /// key the inherited value is empty and the full node's chat-key write is silently skipped
    /// (the `LiteToFullLinked` event still fires). Emits @custom:emits LiteToFullLinked
    /// alongside the registration event. On a warm-path mint the event order is
    /// @custom:emits NameRegistered first (from the inner mint), then
    /// @custom:emits BaseNameClaimed or @custom:emits StandaloneNameRegistered, then
    /// @custom:emits LiteToFullLinked when applicable. On a cold-path mint
    /// @custom:emits PendingClaimStashed replaces the initial @custom:emits NameRegistered;
    /// the deferred @custom:emits NameRegistered fires later from @custom:function
    /// claimLabelStore. Cross-chain callers pass the ABI-encoded full-registration tuple as
    /// the call's payload, which Solidity decodes directly.
    /// @param params Registration request; see @custom:struct FullRegistration.
    function registerBaseName(FullRegistration calldata params) external;

    /// @notice Raw-payload variant of @custom:function registerBaseName for cross-chain dispatch.
    /// @dev `payload` is `abi.encode(FullRegistration({...}))`, the bare ABI-encoded struct
    /// with NO function-selector prefix and NO leading bytes-length word. The contract
    /// prepends the typed selector and `delegatecall`s itself so the typed entrypoint runs
    /// in the original call context and remains the single source of truth, so the typed
    /// overload's revert surface bubbles up byte-for-byte: gateway-only access (otherwise
    /// @custom:reverts NotGateway), base-label shape (otherwise @custom:reverts InvalidBaseLabel),
    /// lite-label shape on the `LiteUsername` branch (otherwise @custom:reverts InvalidLiteLabel),
    /// and the standalone-mint holder guard (otherwise @custom:reverts NotHolder). The success
    /// path emits the same events as the typed call: @custom:emits BaseNameClaimed on a claim
    /// or @custom:emits StandaloneNameRegistered otherwise, @custom:emits LiteToFullLinked on
    /// the `LiteUsername` branch, @custom:emits ReservationExpired for each entry reaped while
    /// advancing the queue head, and always @custom:emits NameRegistered.
    /// Note: `abi.decode` ignores trailing bytes past the encoded struct, so off-chain
    /// encoders MUST NOT assume strict length validation.
    /// @param payload `abi.encode(FullRegistration)` produced by the cross-chain caller.
    function registerBaseName(bytes calldata payload) external;

    /// @notice Permissionlessly removes expired entries from the head of a reservation queue.
    /// @dev Permissionless on purpose: anyone (typically a UI or a bot) can poke a stale queue
    /// so the next live head takes over without waiting for the next gateway call. Validates
    /// the DNS-label shape of `reservedBaseLabel` (otherwise @custom:reverts InvalidBaseLabel)
    /// and emits @custom:emits ReservationExpired for every expired entry reaped from the
    /// head. Only base-shaped labels (no trailing digits) ever key a reservation queue, so a
    /// lite-shaped label still passes the shape check but resolves to an empty queue and the
    /// call is a no-op.
    function expireReservation(string calldata reservedBaseLabel) external;

    /// @notice Lets the caller voluntarily drop their own active reservation.
    /// @dev Reverts with @custom:reverts NoActiveReservation when the caller holds no live
    /// reservation. On success the caller's entry is removed from its queue and
    /// @custom:emits ReservationRelinquished is emitted; if the removed entry was the queue
    /// head, head advancement may additionally emit @custom:emits ReservationExpired for any
    /// stale entries reaped behind it.
    function relinquishReservation() external;

    /// @notice Returns whether a label currently has a live reservation at the queue head.
    /// @dev Validates the DNS-label shape of `reservedBaseLabel` (otherwise
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
    /// because invariant tests and off-chain consumers (dotli, dweb) use it to enumerate
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

    /// @notice Settles the caller's deferred bindings by writing every stashed label into
    /// the caller's `LabelStore`, deploying the store first if the caller doesn't yet
    /// have one.
    /// @dev User-signed entrypoint: `pallet-revive` charges any `LabelStore` storage
    /// deposit against `msg.sender`'s balance through the runtime's configured deposit
    /// backend. This is the only path that can create the store, because the Root gateway
    /// origin cannot instantiate contracts. Reverts with @custom:reverts NoPendingClaim when
    /// the caller holds no live stashed entries. Reuses any existing `LabelStore` returned by
    /// the factory (settling via this controller after a concurrent public-flow mint, or
    /// settling twice through this controller, both find a live store and skip deployment),
    /// otherwise deploys a fresh store via the protocol-registered factory. Writes each live
    /// label keyed by its `node` (namehash), clears the pending-claim entries, and emits
    /// @custom:emits PendingClaimSettled and @custom:emits NameRegistered per settled name.
    /// Chat-key and lite-link records are not touched here; they are persisted on the PoP
    /// resolver at mint time, not at settlement.
    function claimLabelStore() external;

    /// @notice Gateway-driven variant of @custom:function claimLabelStore for split workflows.
    /// @dev Callable only via the registered PoP gateway. It settles the pending LabelStore claim
    /// for `user` without requiring a user transaction. The user-signed
    /// @custom:function claimLabelStore remains as a permissioned-by-origin fallback if gateway
    /// dispatch fails.
    /// @param user Account whose pending claim should be settled.
    function claimLabelStoreFor(address user) external;

    /// @notice Permissionlessly reaps a user's deferred bindings that sat unsettled past
    /// `reservationDuration`.
    /// @dev Permissionless on purpose: anyone (typically a UI or a bot) can poke stale
    /// entries so the user's pile cannot grow without bound. Sweeps every expired entry,
    /// leaving any still-live ones in place; the user is removed from the enumeration set
    /// only when no entries remain. Reverts with @custom:reverts NoPendingClaim when the
    /// user holds no entries and with @custom:reverts PendingClaimNotExpired when none of
    /// the held entries have lapsed. Emits @custom:emits PendingClaimExpired per swept name.
    /// @param user Address whose pending claims are being swept.
    function expirePendingClaim(address user) external;

    /// @notice Returns `user`'s pending-claim entries.
    /// @dev An empty array means the user has no pending claims. A user accumulates one
    /// entry per deferred name until a signed-origin @custom:function claimLabelStore
    /// settles them.
    /// @param user Account whose pending claims are being read.
    /// @return claims Per-user pending-claim entries; see @custom:struct PendingClaim.
    function pendingClaims(address user) external view returns (PendingClaim[] memory claims);

    /// @notice Returns the number of users with at least one live pending claim.
    /// @dev Exact live count, not an all-time tally: fully settled and fully expired users
    /// are removed from the enumeration set so off-chain consumers can page through every
    /// stalled user without filtering.
    /// @return count Number of users currently holding a pending claim.
    function pendingClaimUserCount() external view returns (uint256 count);

    /// @notice Returns a paginated slice of users with at least one live pending claim.
    /// @dev Pair with @custom:function pendingClaims to read each user's stashed entries.
    /// Ordering is not chronological; callers MUST NOT assume `mintedAt` is monotonic
    /// across the slice. Returns an empty array when `offset` is past the live count.
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
