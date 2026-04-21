// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";

/// @title Dotns Registrar Controller
/// @notice Interface for registering .dot labels using a commit–reveal scheme.
/// @dev This interface defines allocation only. Forward resolution, reverse lookup, pricing mechanics,
///      PoP validation, and store writing are handled by external contracts.
///
/// @dev Commit–reveal:
///      - Users commit a hash of registration parameters.
///      - After a minimum delay, they reveal the same parameters to register.
///
/// @dev Store writing:
///      - Implementations write the successfully registered name into the user’s Store
///        to create an immutable onchain record of the name registration.
///      - This store serves as a quick lookup for all names registered.
/// @custom:security-contact admin@parity.io
interface IDotnsRegistrarController {
    /// @notice Parameters used to generate and reveal a commitment.
    /// @dev All fields must match exactly between commitment and reveal.
    /// @param label Label being registered (e.g. "alice").
    /// @param owner Address that will own the registered name.
    /// @param secret Secret used to bind the commitment.
    /// @param reserved Whether the name is reserved.
    struct Registration {
        string label;
        address owner;
        bytes32 secret;
        bool reserved;
    }

    /// @notice Discriminant for the `Link` union supplied to `registerBaseName`.
    /// @dev Selects the chat-key source for the full-person username. Orthogonal to
    ///      whether the registration is a claim or standalone — that is derived from
    ///      on-chain reservation state, not from this discriminant. `None` means the
    ///      caller supplies a fresh chat key in `link.chatKey`. `LiteUsername` means
    ///      the full-person username is linked to a prior lite-person username
    ///      (`link.liteLabel`) and inherits its chat key.
    enum LinkKind {
        None,
        LiteUsername
    }

    /// @notice Tagged union selecting the chat-key source for a full-person registration.
    /// @dev When `kind == LinkKind.LiteUsername` the `liteLabel` field identifies the prior
    ///      lite-person username to link to and `chatKey` is ignored (the existing chat key
    ///      associated with the lite username is inherited). When `kind == LinkKind.None` the
    ///      `chatKey` field carries the new chat key for the registration and `liteLabel` is
    ///      ignored.
    /// @param kind Which branch of the union is populated.
    /// @param liteLabel Lite-person username label (only read when `kind == LiteUsername`).
    /// @param chatKey Chat key bytes (only read when `kind == None`).
    struct Link {
        LinkKind kind;
        string liteLabel;
        bytes chatKey;
    }

    /// @notice Emitted when a commitment is submitted.
    /// @param commitment Commitment hash.
    event NameCommitted(bytes32 indexed commitment);

    /// @notice Emitted when a name is successfully registered.
    /// @param label Registered label.
    /// @param labelhash Keccak256 hash of the label.
    /// @param owner Owner of the name.
    /// @param baseCost The price returned by the oracle for this registration.
    /// @param store The Store instance used to persist an immutable registration record.
    event NameRegistered(
        string indexed label,
        bytes32 indexed labelhash,
        address indexed owner,
        uint256 baseCost,
        address store
    );

    /// @notice Emitted when an address is added to or removed from the whitelist.
    /// @param who The address being whitelisted.
    /// @param whiteListStatus Whether the address was added or removed from the whitelist.
    event WhiteListed(address indexed who, bool indexed whiteListStatus);

    /// @notice Emitted when a lite-person username is registered via the PoP gateway.
    /// @param labelhash Keccak256 hash of the lite-person label.
    /// @param user Address receiving the lite-person username.
    /// @param label Human-readable label.
    event LiteNameReserved(bytes32 indexed labelhash, address indexed user, string label);

    /// @notice Emitted when a full-person username is claimed out of an existing reservation.
    /// @param labelhash Keccak256 hash of the full-person label.
    /// @param user Address receiving the full-person username.
    /// @param label Human-readable label.
    event BaseNameClaimed(bytes32 indexed labelhash, address indexed user, string label);

    /// @notice Emitted when a standalone full-person username is registered via the PoP gateway.
    /// @param labelhash Keccak256 hash of the full-person label.
    /// @param user Address receiving the full-person username.
    /// @param label Human-readable label.
    event StandaloneNameRegistered(bytes32 indexed labelhash, address indexed user, string label);

    /// @notice Emitted when a reservation entry is added to the queue for a base name.
    /// @param reservedLabelhash Keccak256 hash of the reserved base name.
    /// @param user Address joining the reservation queue.
    /// @param position Position in the queue at the time of joining (0 = active holder).
    event ReservationQueued(
        bytes32 indexed reservedLabelhash, address indexed user, uint64 position
    );

    /// @notice Emitted when a reservation entry is removed due to expiry.
    /// @param reservedLabelhash Keccak256 hash of the reserved base name.
    /// @param user Address whose entry was removed.
    event ReservationExpired(bytes32 indexed reservedLabelhash, address indexed user);

    /// @notice Emitted when a user voluntarily relinquishes their reservation.
    /// @param reservedLabelhash Keccak256 hash of the reserved base name.
    /// @param user Address whose reservation was removed.
    event ReservationRelinquished(bytes32 indexed reservedLabelhash, address indexed user);

    /// @notice Emitted when a full-person username is linked to a lite-person username.
    /// @param fullLabelhash Keccak256 hash of the full-person label.
    /// @param liteLabelhash Keccak256 hash of the linked lite-person label.
    event LiteToFullLinked(bytes32 indexed fullLabelhash, bytes32 indexed liteLabelhash);

    /// @notice Emitted when the reservation duration is updated.
    /// @param duration New reservation duration in seconds.
    event ReservationDurationSet(uint64 duration);

    /// @notice Thrown when the caller is not whitelisted or the owner.
    /// @param caller The address that attempted the call.
    error NotWhiteListedOrOwner(address caller);
    /// @notice Thrown when an unexpired commitment already exists.
    /// @param commitment Commitment hash.
    error UnexpiredCommitmentExists(bytes32 commitment);

    /// @notice Thrown when revealing a commitment that does not exist.
    /// @param commitment Commitment hash.
    error CommitmentNotFound(bytes32 commitment);

    /// @notice Thrown when a commitment is revealed before the minimum age.
    /// @param commitment Commitment hash.
    /// @param minTime Earliest timestamp at which reveal is allowed.
    /// @param currentTime Current block timestamp.
    error CommitmentTooNew(bytes32 commitment, uint256 minTime, uint256 currentTime);

    /// @notice Thrown when a commitment has expired.
    /// @param commitment Commitment hash.
    /// @param maxTime Latest timestamp at which reveal is allowed.
    /// @param currentTime Current block timestamp.
    error CommitmentTooOld(bytes32 commitment, uint256 maxTime, uint256 currentTime);

    /// @notice Thrown when attempting to register an unavailable name.
    /// @param label Label supplied by the caller.
    error NameNotAvailable(string label);

    /// @notice Thrown when a label is not a canonical lowercase ASCII DNS label.
    error InvalidLabel();

    /// @notice Thrown when supplied payment is insufficient.
    error InsufficientValue();

    /// @notice Thrown when refund fails.
    error RefundFailed();

    /// @notice Thrown when max commitment age is invalid (must be > minCommitmentAge).
    error MaxCommitmentAgeTooLow();

    /// @notice Thrown when max commitment age is invalid (exceeds implementation limit).
    error MaxCommitmentAgeTooHigh();

    /// @notice Thrown when an invalid Store instance is encountered.
    error InvalidStore();

    /// @notice Thrown when the caller is not the registry.
    error NotRegistry();

    /// @notice Thrown when the caller is not the PoP gateway.
    /// @param caller The address that attempted the call.
    error NotGateway(address caller);

    /// @notice Thrown when a public registration targets a label with an active PoP reservation
    ///         held by a different account.
    /// @param label The label that is reserved.
    error LabelReservedForPop(string label);

    /// @notice Thrown when a user tries to claim or relinquish a reservation that they do not hold.
    /// @param user The address that attempted the operation.
    error NoActiveReservation(address user);

    /// @notice Thrown when a reservation queue has reached its capacity.
    /// @param labelhash Labelhash of the reserved name.
    error QueueFull(bytes32 labelhash);

    /// @notice Thrown when attempting to enqueue a user who already has an active reservation
    ///         on the same label.
    /// @param user The address that attempted to reserve.
    /// @param labelhash Labelhash of the reserved name.
    error AlreadyReserved(address user, bytes32 labelhash);

    /// @notice Returns whether a label is available for registration.
    /// @param label Label to check.
    /// @return isAvailable True if the label can be registered.
    function available(string calldata label) external view returns (bool isAvailable);

    /// @notice Computes the commitment hash for a registration.
    /// @param registration Registration parameters.
    /// @return commitment Commitment hash.
    function makeCommitment(Registration calldata registration)
        external
        pure
        returns (bytes32 commitment);

    /// @notice Submits a commitment for a future registration.
    /// @param commitment Commitment hash produced by makeCommitment.
    function commit(bytes32 commitment) external;

    /// @notice Registers a name after the commitment delay.
    /// @dev Registration parameters must match the committed values.
    /// @param registration Registration parameters.
    function register(Registration calldata registration) external payable;

    /// @notice Registers a name after the commitment delay.
    /// @dev Registration parameters must match the committed values.
    /// @param registration Registration parameters.
    function registerReserved(Registration calldata registration) external;

    /// @notice Checks if the given address is whitelisted to call `registerReserved`.
    /// @param who Address to check.
    /// @return isWhiteListed True if the address is whitelisted.
    function isWhiteListed(address who) external view returns (bool isWhiteListed);

    /// @notice Adds or removes an address from the whitelist for `registerReserved`.
    /// @param who Address to update.
    /// @param whiteListStatus True to add to whitelist, false to remove.
    /// @custom:reverts NotOwner if caller is not the contract owner.
    function whiteListAddress(address who, bool whiteListStatus) external;

    /// @notice Emitted when the protocol registry is updated.
    /// @param newRegistry The address of the new protocol registry.
    event ProtocolRegistryUpdated(IDotnsProtocolRegistry indexed newRegistry);

    /// @notice Updates the protocol registry address.
    /// @dev Callable only by the contract owner.
    /// @param registry The address of the new protocol registry.
    // TODO: On fresh deploy (not upgrade), remove this function. Set protocolRegistry in initialize instead.
    function updateProtocolRegistry(IDotnsProtocolRegistry registry) external;

    /// @notice Registers a lite-person username on behalf of `user` and optionally enqueues a
    ///         reservation for a base name the user intends to claim as a full person later.
    /// @dev Callable only by the PoP gateway registered in `DotnsProtocolRegistry.POP_GATEWAY`.
    ///      Bypasses commit-reveal and PoP pricing; every PoP-gateway registration is free.
    ///      The lite-person username is minted immediately. If `reservedLabel` is non-empty the
    ///      user is enqueued on the reservation queue for that label; at most one active
    ///      reservation per account is enforced and any prior reservation is relinquished.
    /// @param label The lite-person username label to register (without TLD).
    /// @param user The lite-person account receiving the username.
    /// @param chatKey ECDH chat key bytes to persist alongside the username.
    /// @param reservedLabel Optional base name to reserve for a future full-person claim. Pass
    ///        the empty string to skip enqueueing a reservation.
    function reserveBaseName(
        string calldata label,
        address user,
        bytes calldata chatKey,
        string calldata reservedLabel
    )
        external;

    /// @notice Registers a full-person username on behalf of `user`.
    /// @dev Callable only by the PoP gateway registered in `DotnsProtocolRegistry.POP_GATEWAY`.
    ///      Bypasses commit-reveal and PoP pricing; every PoP-gateway registration is free.
    ///
    ///      Two orthogonal axes decide behaviour:
    ///
    ///      1. Reservation axis (derived from state): if `user` holds the live head-of-queue
    ///         reservation on `label`, this is a claim — the reservation queue for `label`
    ///         is wiped and every other waiter is evicted. Otherwise this is a standalone
    ///         registration and `label` must not be reserved by another user (reverts
    ///         `LabelReservedForPop` when another account holds the live head).
    ///
    ///         SILENT RELINQUISH: on the standalone path, if `user` sits in any reservation
    ///         queue — whether on a different label, or waiting behind the head on this one
    ///         — that queue entry is removed automatically and no event is emitted. Callers
    ///         must confirm the user intends to give up any pending reservation before
    ///         invoking this function with a standalone label.
    ///
    ///      2. Chat-key axis (selected by `link.kind`): when `link.kind == None` the fresh
    ///         `link.chatKey` is stored alongside the full-person username. When
    ///         `link.kind == LiteUsername` the full-person username is linked to
    ///         `link.liteLabel` and inherits the existing chat key from that lite-person
    ///         entry; `link.chatKey` is ignored.
    ///
    ///      All four combinations are supported: {claim, standalone} × {fresh key, linked}.
    ///      Emits `BaseNameClaimed` on the claim axis and `StandaloneNameRegistered` on the
    ///      standalone axis. Emits `LiteToFullLinked` whenever `link.kind == LiteUsername`,
    ///      independent of the reservation axis.
    /// @param label The full-person username label to register (without TLD).
    /// @param user The full-person account receiving the username.
    /// @param link Tagged union selecting the chat-key source (fresh vs. inherited from a
    ///        prior lite-person username).
    function registerBaseName(string calldata label, address user, Link calldata link) external;

    /// @notice Permissionlessly removes expired entries from the head of a reservation queue.
    /// @dev Advances the queue head past every entry whose `joinedAt + reservationDuration`
    ///      has elapsed. Bounded by queue length. Emits `ReservationExpired` per removed entry.
    /// @param label The reserved label whose queue should be compacted.
    function expireReservation(string calldata label) external;

    /// @notice Lets the caller voluntarily drop their own active reservation.
    /// @dev Removes the caller from whichever reservation queue they currently hold a slot in.
    ///      If the caller is at the head, advances the head. Otherwise marks the caller's entry
    ///      as removed in place. No-op if the caller has no active reservation (reverts
    ///      `NoActiveReservation`).
    function relinquishReservation() external;

    /// @notice Returns whether a label currently has a live reservation at the queue head.
    /// @dev An entry is considered live when it is at the head and has not yet expired.
    /// @param label The label to query.
    /// @return reserved True when a live head reservation exists.
    /// @return holder The current head-of-queue account (zero when `reserved` is false).
    function isReservedForClaim(string calldata label)
        external
        view
        returns (bool reserved, address holder);

    /// @notice Updates the reservation duration used to decide when queue entries expire.
    /// @dev Callable only by the contract owner.
    /// @param duration New reservation duration in seconds.
    function setReservationDuration(uint64 duration) external;
}
