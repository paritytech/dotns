// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IDotnsController} from "./IDotnsController.sol";

/// @title IDotnsPopController
/// @notice Interface for the dedicated PoP controller orchestrating lite-person and full-person
/// username issuance on behalf of the PoP gateway pallet. @dev Deliberately disjoint from
/// `IDotnsRegistrarController`. The two controllers coexist
/// on `DotnsRegistrar` via its multi-controller affordance and neither imports the other.
/// Collision handling reduces to the registrar's ERC721 availability check (first-to-mint
/// wins). Reservation queuing for `reservedBaseLabel` is an intra-PoP coordination mechanism
/// only; it does not block public registrations.
///
/// Label formats:
/// Lite-person usernames (first argument to {reserveBaseName} and the `liteLabel` of a
/// `LinkKind.LiteUsername` link) are DNS labels with at least two trailing digits (e.g.
/// `alice42`) per {StringUtils-isLitePersonLabel}. The gateway strips any separator before
/// calling so the on-chain label is flat. Full-person usernames (the `label` of
/// {registerBaseName} and the optional `reservedBaseLabel` of {reserveBaseName}) follow the
/// DNS-label rules enforced by {StringUtils-isSingleLabel} (e.g. `alice`). Lite and public
/// registrations share one namespace; first-to-mint wins at the ERC721 layer. Cross-flow
/// priority on the stripped base stem is arbitrated by {IPopRules.reserveBaseNameForPop}.
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
    /// @dev `BaseReservation` is a {LiteRegistration} plus a base-label reservation slot,
    /// expressed as composition rather than duplicated fields so internal helpers can
    /// consume the lite leg via `params.lite` without unpacking. The lite leg always runs;
    /// the reservation leg only runs when `reservedBaseLabel` is non-empty.
    /// @param lite Lite-person registration request; see {LiteRegistration}.
    /// @param reservedBaseLabel Base label to enqueue for a later full-person claim. Empty
    /// string skips the reservation leg.
    struct BaseReservation {
        LiteRegistration lite;
        string reservedBaseLabel;
    }

    /// @notice Full-person registration payload.
    /// @param label Base DNS label being minted.
    /// @param user Beneficiary account on this chain.
    /// @param link Chat-key source for the new entry; see {Link}.
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

    /// @notice Thrown when the call's substrate origin is not `Root`.
    /// @dev The implementation gates entrypoints on revive's
    ///      `ISystem.callerIsRoot()` precompile rather than on `msg.sender`,
    ///      because under `RuntimeOrigin::root()` the PVM `caller` syscall
    ///      traps. The `caller` field is therefore always `address(0)` and is
    ///      reserved for forward compatibility; indexers must not rely on it
    ///      to identify a spoofing actor.
    /// @param caller Reserved; always `address(0)` under the Root-origin auth
    ///        model.
    error NotGateway(address caller);

    /// @notice Thrown when a supplied lite-person label does not match `NAMEXX`.
    error InvalidLiteLabel();

    /// @notice Thrown when a supplied base label is not a canonical DNS label.
    error InvalidBaseLabel();

    /// @notice Thrown when a user tries to claim or relinquish a reservation that they do not hold.
    error NoActiveReservation(address user);

    /// @notice Thrown when a reservation queue has reached its capacity.
    error QueueFull(bytes32 labelhash);

    /// @notice Thrown when attempting to enqueue a user who already has an active reservation.
    error AlreadyReserved(address user, bytes32 labelhash);

    /// @notice Thrown when someone tries to mint a base label in standalone mode while another user
    /// holds the live head-of-queue reservation.
    error NotHolder(address user, bytes32 labelhash);

    /// @notice Registers a lite-person username on behalf of `params.user` and optionally enqueues
    /// a reservation for a base name they intend to claim as a full person later. @dev Callable
    /// only when the substrate origin is `Root`, verified via revive's
    /// `ISystem.callerIsRoot()` precompile. The base-name leg only runs when
    /// `params.reservedBaseLabel` is non-empty, and runs PopRules `priceWithCheck`
    /// BEFORE any queue mutation so a mis-tiered reservation never even touches the
    /// queue. The user is removed from any prior queue position before being enqueued,
    /// so a single user holds at most one live reservation across all labels.
    /// Cross-chain callers pass the ABI-encoded {BaseReservation} tuple directly as
    /// the call's payload; Solidity decodes it from `msg.data` into `params`.
    /// @param params Reservation request; see {BaseReservation}.
    /// @custom:emits LiteNameReserved
    /// @custom:emits NameRegistered
    /// @custom:emits ReservationQueued
    /// @custom:emits ReservationExpired
    /// @custom:reverts AlreadyReserved
    /// @custom:reverts InvalidBaseLabel
    /// @custom:reverts InvalidLiteLabel
    /// @custom:reverts NotGateway
    /// @custom:reverts QueueFull
    function reserveBaseName(BaseReservation calldata params) external;

    /// @notice Raw-payload variant of {reserveBaseName} for cross-chain dispatch.
    /// @dev `payload` is `abi.encode(BaseReservation({...}))`, the bare ABI-encoded struct
    /// with NO function-selector prefix and NO leading bytes-length word. The contract
    /// prepends the typed selector and `delegatecall`s itself so the typed entrypoint runs
    /// in the original call context and remains the single source of truth.
    /// Note: `abi.decode` ignores trailing bytes past the encoded struct, so off-chain
    /// encoders MUST NOT assume strict length validation.
    /// @param payload `abi.encode(BaseReservation)` produced by the cross-chain caller.
    /// @custom:emits LiteNameReserved
    /// @custom:emits NameRegistered
    /// @custom:emits ReservationQueued
    /// @custom:emits ReservationExpired
    /// @custom:reverts AlreadyReserved
    /// @custom:reverts InvalidBaseLabel
    /// @custom:reverts InvalidLiteLabel
    /// @custom:reverts NotGateway
    /// @custom:reverts QueueFull
    function reserveBaseName(bytes calldata payload) external;

    /// @notice Registers a lite-person username on behalf of `params.user` without touching the
    /// base-name reservation queue. @dev Callable only when the substrate origin is `Root`,
    /// verified via revive's
    /// `ISystem.callerIsRoot()` precompile. Cross-chain callers pass the ABI-encoded
    /// {LiteRegistration} tuple directly as the call's payload; Solidity decodes it
    /// from `msg.data` into `params`.
    /// @param params Registration request; see {LiteRegistration}.
    /// @custom:emits LiteNameReserved
    /// @custom:emits NameRegistered
    /// @custom:reverts InvalidLiteLabel
    /// @custom:reverts NotGateway
    function reserveLiteName(LiteRegistration calldata params) external;

    /// @notice Raw-payload variant of {reserveLiteName} for cross-chain dispatch.
    /// @dev `payload` is `abi.encode(LiteRegistration({...}))`, the bare ABI-encoded struct
    /// with NO function-selector prefix and NO leading bytes-length word. The contract
    /// prepends the typed selector and `delegatecall`s itself so the typed entrypoint runs
    /// in the original call context and remains the single source of truth.
    /// Note: `abi.decode` ignores trailing bytes past the encoded struct, so
    /// off-chain encoders MUST NOT assume strict length validation; pad-only
    /// junk past the tail is silently dropped (no state corruption; decoded
    /// values are unchanged).
    /// Worked example off-chain:
    ///   `bytes payload = abi.encode(LiteRegistration({liteLabel: "alice42", user: u, chatKey:
    /// k}));` @param payload `abi.encode(LiteRegistration)` produced by the cross-chain caller.
    /// @custom:emits LiteNameReserved
    /// @custom:emits NameRegistered
    /// @custom:reverts InvalidLiteLabel
    /// @custom:reverts NotGateway
    function reserveLiteName(bytes calldata payload) external;

    /// @notice Registers a full-person username on behalf of `params.user`.
    /// @dev Callable only when the substrate origin is `Root`, verified via revive's
    /// `ISystem.callerIsRoot()` precompile. Two orthogonal axes drive the state machine:
    /// (1) Reservation axis: `params.user` is "claiming" iff they hold the live head-of-queue
    /// reservation on `params.label`. A claim wipes the entire queue (`_clearQueue`) and releases
    /// the PopRules slot; a non-claim silently relinquishes any pending entry the user holds
    /// and reverts via `NotHolder` if another live head blocks the mint.
    /// (2) Chat-key axis: `params.link.kind` decides whether a fresh key is persisted on the
    /// resolver (`None`) or the new entry inherits the key from a prior lite-person username
    /// (`LiteUsername`). The two axes are independent so any combination is reachable.
    /// Cross-chain callers pass the ABI-encoded {FullRegistration} tuple directly as the call's
    /// payload; Solidity decodes it from `msg.data` into `params`.
    /// @param params Registration request; see {FullRegistration}.
    /// @custom:emits BaseNameClaimed
    /// @custom:emits LiteToFullLinked
    /// @custom:emits NameRegistered
    /// @custom:emits StandaloneNameRegistered
    /// @custom:emits ReservationExpired
    /// @custom:reverts InvalidBaseLabel
    /// @custom:reverts InvalidLiteLabel
    /// @custom:reverts NotGateway
    /// @custom:reverts NotHolder
    function registerBaseName(FullRegistration calldata params) external;

    /// @notice Raw-payload variant of {registerBaseName} for cross-chain dispatch.
    /// @dev `payload` is `abi.encode(FullRegistration({...}))`, the bare ABI-encoded struct
    /// with NO function-selector prefix and NO leading bytes-length word. The contract
    /// prepends the typed selector and `delegatecall`s itself so the typed entrypoint runs
    /// in the original call context and remains the single source of truth.
    /// Note: `abi.decode` ignores trailing bytes past the encoded struct, so off-chain
    /// encoders MUST NOT assume strict length validation.
    /// @param payload `abi.encode(FullRegistration)` produced by the cross-chain caller.
    /// @custom:emits BaseNameClaimed
    /// @custom:emits LiteToFullLinked
    /// @custom:emits NameRegistered
    /// @custom:emits StandaloneNameRegistered
    /// @custom:emits ReservationExpired
    /// @custom:reverts InvalidBaseLabel
    /// @custom:reverts InvalidLiteLabel
    /// @custom:reverts NotGateway
    /// @custom:reverts NotHolder
    function registerBaseName(bytes calldata payload) external;

    /// @notice Permissionlessly removes expired entries from the head of a reservation queue.
    /// @dev Permissionless on purpose: anyone (typically a UI or a bot) can poke a stale queue
    /// so the next live head takes over without waiting for the next gateway call.
    /// @custom:emits ReservationExpired
    /// @custom:reverts InvalidBaseLabel
    function expireReservation(string calldata reservedBaseLabel) external;

    /// @notice Lets the caller voluntarily drop their own active reservation.
    /// @custom:emits ReservationRelinquished
    /// @custom:emits ReservationExpired
    /// @custom:reverts NoActiveReservation
    function relinquishReservation() external;

    /// @notice Returns whether a label currently has a live reservation at the queue head.
    /// @custom:reverts InvalidBaseLabel
    function isReservedForClaim(string calldata reservedBaseLabel)
        external
        view
        returns (bool reserved, address holder);

    /// @notice Updates the reservation duration used to decide when queue entries expire.
    /// @custom:emits ReservationDurationSet
    /// @custom:reverts OwnableUnauthorizedAccount
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
    /// reaped, or never written. Callers pair this with {reservationMeta} to walk the live
    /// window `[head, tail)`.
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
    /// @return reservation Per-user reservation pointer; see {UserReservation}.
    function userReservation(address user)
        external
        view
        returns (UserReservation memory reservation);
}
