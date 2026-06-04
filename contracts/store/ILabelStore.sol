// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IDotnsStore} from "./IDotnsStore.sol";

/// @title ILabelStore
/// @notice Interface for the per-user DotNS label store.
/// @dev The `LabelStore` is the protocol-managed half of the per-user storage pair:
///      write-only by addresses registered in the protocol registry, read-only by
///      everyone else, and permanently locked per `labelhash` on first write. It
///      holds registration records only; every other per-name category (reverse,
///      content, forward address, chat key, lite link) lives on a dedicated
///      resolver, not here.
/// @custom:security-contact admin@parity.io
interface ILabelStore is IDotnsStore {
    /// @notice Emitted when a label is stored for the first (and only) time under a given
    /// labelhash. @param owner The user this store is bound to.
    /// @param labelhash The labelhash key.
    /// @param label The stored label string (typically the full name, e.g. "alice.dot").
    event LabelStored(address indexed owner, bytes32 indexed labelhash, string label);

    /// @notice Thrown when a caller that is not currently protocol-registered attempts a write.
    /// @param caller The msg.sender that failed the `isRegisteredAddress` check.
    error NotAuthorised(address caller);

    /// @notice Thrown when `initialize` is called with a zero user address.
    /// @param user The invalid user argument.
    error InvalidUser(address user);

    /// @notice Thrown when `initialize` is called with a zero protocol registry address.
    /// @param protocolRegistry The invalid registry argument.
    error InvalidProtocolRegistry(address protocolRegistry);

    /// @notice Thrown when `storeLabel` is called with a zero labelhash.
    /// @param labelhash The invalid labelhash argument.
    error InvalidLabel(bytes32 labelhash);

    /// @notice Thrown when `storeLabel` is called for a labelhash already present in the index.
    /// @dev Labels are write-once and permanently locked on first store, so any second write
    ///      for the same labelhash fails with this error regardless of caller or session.
    /// @param labelhash The conflicting labelhash.
    error LabelAlreadyExists(bytes32 labelhash);

    /// @notice Initialises the store, binding it permanently to `user_` and `protocolRegistry_`.
    /// @dev Callable exactly once via `Initializable`; both parameters are immutable post-call.
    ///      `user_` must be non-zero, otherwise @custom:reverts InvalidUser.
    ///      `protocolRegistry_` must be non-zero, otherwise @custom:reverts
    /// InvalidProtocolRegistry. @param user_ The user this store is bound to forever.
    /// @param protocolRegistry_ The protocol registry used to authorise writers.
    function initialize(address user_, address protocolRegistry_) external;

    /// @notice Records a label under `labelhash` and locks the slot permanently.
    /// @dev Gated to addresses currently registered in the protocol registry, otherwise
    ///      @custom:reverts NotAuthorised. `labelhash` must be non-zero, otherwise
    ///      @custom:reverts InvalidLabel. The slot must not already hold an entry, otherwise
    ///      @custom:reverts LabelAlreadyExists; the write is permanent so any second call
    ///      reverts. Emits @custom:emits LabelStored on the single successful write.
    /// @param labelhash The labelhash key.
    /// @param label The label string to store.
    function storeLabel(bytes32 labelhash, string calldata label) external;

    /// @notice Returns the protocol registry this store queries for write authorisation.
    /// @return protocolRegistry_ The registry address.
    function protocolRegistry() external view returns (address protocolRegistry_);

    /// @notice Returns true iff a label has been stored under `labelhash`.
    /// @param labelhash The labelhash to check.
    /// @return exists True iff the slot holds a label.
    function hasLabel(bytes32 labelhash) external view returns (bool exists);

    /// @notice Returns true iff the slot for `labelhash` is permanently locked.
    /// @dev Always equal to `hasLabel` in the current design; exposed explicitly so future
    ///      implementations behind the beacon can distinguish "stored" from "locked" if needed.
    /// @param labelhash The labelhash to check.
    /// @return locked True iff the slot is locked.
    function isLocked(bytes32 labelhash) external view returns (bool locked);

    /// @notice Returns the stored label for `labelhash`, or the empty string if none.
    /// @param labelhash The labelhash to look up.
    /// @return label The stored label string.
    function getLabel(bytes32 labelhash) external view returns (string memory label);

    /// @notice Returns the total number of labels ever stored.
    /// @return count Current length of the insertion-order list.
    function getLabelCount() external view returns (uint256 count);

    /// @notice Returns the human-readable label at the given insertion-order index.
    /// @dev Primary read for "give me my names"; does not require the caller to know any
    ///      labelhash. For the underlying labelhash key see @custom:function getLabelhashAt.
    /// @param index Zero-based index into the insertion-order list.
    /// @return label The stored label string at `index`.
    function getLabelAt(uint256 index) external view returns (string memory label);

    /// @notice Returns the labelhash at the given insertion-order index.
    /// @param index Zero-based index into the insertion-order list.
    /// @return labelhash The labelhash at `index`.
    function getLabelhashAt(uint256 index) external view returns (bytes32 labelhash);

    /// @notice Paginated read returning just the stored labels, in insertion order.
    /// @dev Primary bulk read for "give me all my names". Callers never need to touch
    ///      labelhashes. Length is `min(limit, getLabelCount() - offset)`;
    ///      `offset >= getLabelCount()` returns an empty array (not a revert).
    /// @param offset Start index.
    /// @param limit Maximum entries to return.
    /// @return labels Slice of label strings.
    function getLabels(uint256 offset, uint256 limit) external view returns (string[] memory labels);

    /// @notice Paginated read over the labelhash keys, in insertion order.
    /// @dev Advanced read for callers that need the raw labelhash keys. Symmetric with
    ///      @custom:function getLabels; same indices map to the same entries.
    /// @param offset Start index.
    /// @param limit Maximum entries to return.
    /// @return labelhashes Slice of labelhash keys.
    function getLabelhashes(
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (bytes32[] memory labelhashes);
}
