// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IDotnsController} from "./IDotnsController.sol";

/// @title IDotnsPopController
/// @notice Interface for the dedicated PoP controller orchestrating lite-person and
///         full-person username issuance on behalf of the PoP gateway pallet.
/// @dev Deliberately disjoint from `IDotnsRegistrarController`. The two controllers
///      coexist on `DotnsRegistrar` via its multi-controller affordance and neither
///      imports the other. Collision handling reduces to the registrar's ERC721
///      availability check (first-to-mint wins). Reservation queuing for
///      `reservedBaseLabel` is an intra-PoP coordination mechanism only; it does
///      not block public registrations.
///
/// @dev Label formats:
///      - Lite-person usernames (first argument to {reserveBaseName} and the
///        `liteLabel` of a `LinkKind.LiteUsername` link) are DNS labels with at
///        least two trailing digits (e.g. `alice42`) per
///        {StringUtils-isLitePersonLabel}. The gateway strips any separator
///        before calling so the on-chain label is flat.
///      - Full-person usernames (the `label` of {registerBaseName} and the optional
///        `reservedBaseLabel` of {reserveBaseName}) follow the DNS-label rules
///        enforced by {StringUtils-isSingleLabel} (e.g. `alice`).
///      Lite and public registrations share one namespace; first-to-mint wins at
///      the ERC721 layer. Cross-flow priority on the stripped base stem is
///      arbitrated by {IPopRules.reserveBaseNameForPop}.
/// @custom:security-contact admin@parity.io
interface IDotnsPopController is IDotnsController {
    /// @notice Discriminant for the `Link` union supplied to `registerBaseName`.
    /// @dev Selects the chat-key source for the full-person username. Orthogonal to
    ///      whether the registration is a claim or standalone; that is derived
    ///      from on-chain reservation state. `None` means the caller supplies a
    ///      fresh chat key in `link.chatKey`. `LiteUsername` means the
    ///      full-person username is linked to a prior lite-person username
    ///      (`link.liteLabel`) and inherits its chat key.
    enum LinkKind {
        None,
        LiteUsername
    }

    /// @notice Tagged union selecting the chat-key source for a full-person registration.
    /// @param kind Which branch of the union is populated.
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

    /// @notice Emitted when a name is successfully registered via the PoP controller.
    /// @param label Registered label.
    /// @param labelhash Keccak256 hash of the label.
    /// @param owner Owner of the name.
    /// @param store The Store instance used to persist the immutable registration record.
    event NameRegistered(
        string indexed label, bytes32 indexed labelhash, address indexed owner, address store
    );

    /// @notice Thrown when the caller is not the PoP gateway.
    /// @param caller The address that attempted the call.
    error NotGateway(address caller);

    /// @notice Thrown when a supplied lite-person label does not match `NAMEXX`.
    error InvalidLiteLabel();

    /// @notice Thrown when a supplied base label is not a canonical DNS label.
    error InvalidBaseLabel();

    /// @notice Thrown when a user tries to claim or relinquish a reservation that they do not hold.
    /// @param user The address that attempted the operation.
    error NoActiveReservation(address user);

    /// @notice Thrown when a reservation queue has reached its capacity.
    /// @param labelhash Labelhash of the reserved name.
    error QueueFull(bytes32 labelhash);

    /// @notice Thrown when attempting to enqueue a user who already has an active reservation.
    /// @param user The address that attempted to reserve.
    /// @param labelhash Labelhash of the reserved name.
    error AlreadyReserved(address user, bytes32 labelhash);

    /// @notice Thrown when someone tries to mint a base label in standalone mode
    ///         while another user holds the live head-of-queue reservation.
    /// @param user The address that attempted the mint.
    /// @param labelhash Labelhash of the reserved base label.
    error NotHolder(address user, bytes32 labelhash);

    /// @notice Registers a lite-person username on behalf of `user` and optionally
    ///         enqueues a reservation for a base name the user intends to claim as a
    ///         full person later.
    /// @dev Callable only by the PoP gateway registered in
    ///      `DotnsProtocolRegistry.POP_GATEWAY`. Bypasses pricing (PoP tiers pay
    ///      zero) and commit-reveal, but still honours classification and tier
    ///      enforcement via `IPopRules.priceWithCheck`, so the gateway cannot mint
    ///      a name whose classification does not match the user's tier.
    ///      The lite-person username is minted immediately. If `reservedBaseLabel` is
    ///      non-empty the user is enqueued on the reservation queue for that label; at
    ///      most one active reservation per account is enforced and any prior
    ///      reservation is relinquished.
    ///
    ///      For the lite-only path (no base reservation), prefer {reserveLiteName}.
    ///      It is an independent gateway primitive that never fails on base-queue
    ///      state, so a full base queue never denies a user their lite name.
    /// @param liteLabel The lite-person `NAMEXX` label to register.
    /// @param user The lite-person account receiving the username.
    /// @param chatKey ECDH chat-key bytes to persist on {IDotnsChatKeyResolver}.
    /// @param reservedBaseLabel Optional base name to reserve. Empty string skips.
    function reserveBaseName(
        string calldata liteLabel,
        address user,
        bytes calldata chatKey,
        string calldata reservedBaseLabel
    )
        external;

    /// @notice Registers a lite-person username on behalf of `user` without
    ///         touching the base-name reservation queue.
    /// @dev Callable only by the PoP gateway. Bypasses pricing and commit-reveal
    ///      but honours classification and tier enforcement via
    ///      `IPopRules.priceWithCheck`. Compositional counterpart to
    ///      {reserveBaseName}: for flows that only need to mint the lite name,
    ///      this entrypoint has no failure modes tied to base queue capacity.
    /// @param liteLabel The lite-person `NAMEXX` label to register.
    /// @param user The lite-person account receiving the username.
    /// @param chatKey ECDH chat-key bytes to persist on {IDotnsChatKeyResolver}.
    function reserveLiteName(
        string calldata liteLabel,
        address user,
        bytes calldata chatKey
    )
        external;

    /// @notice Registers a full-person username on behalf of `user`.
    /// @dev Callable only by the PoP gateway. Bypasses pricing (PoP tiers pay
    ///      zero) and commit-reveal, but still honours classification and tier
    ///      enforcement via `IPopRules.priceWithCheck`.
    ///
    ///      Two orthogonal axes decide behaviour:
    ///      1. Reservation axis (derived from state): if `user` holds the live
    ///         head-of-queue reservation on `label`, this is a claim and the queue is
    ///         wiped. Otherwise this is a standalone registration; any pending
    ///         reservation the user holds is silently relinquished.
    ///      2. Chat-key axis (selected by `link.kind`): when `link.kind == None` the
    ///         fresh `link.chatKey` is stored on {IDotnsChatKeyResolver}. When
    ///         `link.kind == LiteUsername` the full-person username inherits the chat
    ///         key currently stored for `link.liteLabel`, and a lite=>full link is
    ///         persisted in the full-person's Store.
    /// @param label The full-person label to register.
    /// @param user The full-person account receiving the username.
    /// @param link Tagged union selecting the chat-key source.
    function registerBaseName(string calldata label, address user, Link calldata link) external;

    /// @notice Permissionlessly removes expired entries from the head of a reservation queue.
    /// @param reservedBaseLabel The reserved label whose queue should be compacted.
    function expireReservation(string calldata reservedBaseLabel) external;

    /// @notice Lets the caller voluntarily drop their own active reservation.
    function relinquishReservation() external;

    /// @notice Returns whether a label currently has a live reservation at the queue head.
    /// @param reservedBaseLabel The label to query.
    /// @return reserved True when a live head reservation exists.
    /// @return holder The current head-of-queue account.
    function isReservedForClaim(string calldata reservedBaseLabel)
        external
        view
        returns (bool reserved, address holder);

    /// @notice Updates the reservation duration used to decide when queue entries expire.
    /// @dev Callable only by the contract owner.
    /// @param duration New reservation duration in seconds.
    function setReservationDuration(uint64 duration) external;
}
