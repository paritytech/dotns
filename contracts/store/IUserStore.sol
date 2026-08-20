// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IDotnsStore} from "./IDotnsStore.sol";

/// @title IUserStore
/// @notice Interface for the per-user generic key/value store with per-key history.
/// @dev Each user may claim at most one `UserStore` from `StoreFactory`. The store is
///      bound to its claimer forever: `_owner` is set once at `initialize` and only that
///      address may write. Each `setValue` snapshots the prior non-empty value into a
///      per-key history list with a timestamp; current and history are both readable by
///      anyone, paginated.
/// @custom:security-contact admin@parity.io
interface IUserStore is IDotnsStore {
    /// @notice A historical (prior) value for a key and the block timestamp at which it was
    /// snapshotted. @param value The prior value that was just superseded.
    /// @param timestamp Block timestamp at the moment of supersession.
    struct Entry {
        bytes value;
        uint256 timestamp;
    }

    /// @notice Emitted when the owner sets (or updates) a value under `key`.
    /// @param owner The user this store is bound to.
    /// @param key The key being written.
    /// @param value The new current value.
    event ValueSet(address indexed owner, bytes32 indexed key, bytes value);

    /// @notice Thrown when any caller other than the bound owner attempts a write.
    /// @param caller The unauthorised msg.sender.
    error NotOwner(address caller);

    /// @notice Thrown when `initialize` is called with a zero user address.
    /// @param user The invalid user argument.
    error InvalidUser(address user);

    /// @notice Thrown when `setValue` is called with a zero key.
    error InvalidKey();

    /// @notice Initialises the store, binding it permanently to `user_`.
    /// @dev Callable exactly once via `Initializable`. `user_` must be non-zero, otherwise
    ///      @custom:reverts InvalidUser.
    /// @param user_ The user this store is bound to forever.
    function initialize(address user_) external;

    /// @notice Sets the current value for `key`.
    /// @dev Callable only by the bound owner; any other caller @custom:reverts NotOwner.
    ///      `key` must be non-zero, otherwise @custom:reverts InvalidKey. If a non-empty
    ///      prior value existed it is pushed into the per-key history list with
    ///      `block.timestamp`; empty prior values produce no history entry. Emits
    ///      @custom:emits ValueSet on every successful write.
    /// @param key The key to write.
    /// @param value The new current value (may be empty).
    function setValue(bytes32 key, bytes calldata value) external;

    /// @notice Returns the current value under `key`, or empty bytes if unset.
    /// @param key The key to read.
    /// @return value The current value.
    function getValue(bytes32 key) external view returns (bytes memory value);

    /// @notice Returns true iff the current value under `key` has non-zero length.
    /// @param key The key to check.
    /// @return present True iff `getValue(key).length != 0`.
    function hasValue(bytes32 key) external view returns (bool present);

    /// @notice Returns the number of prior (historical) values recorded for `key`.
    /// @param key The key to read.
    /// @return count Length of the history list.
    function getHistoryCount(bytes32 key) external view returns (uint256 count);

    /// @notice Returns the historical entry at `index` for `key`.
    /// @param key The key to read.
    /// @param index Zero-based index into the history list.
    /// @return entry The `(value, timestamp)` pair.
    function getHistoryAt(bytes32 key, uint256 index) external view returns (Entry memory entry);

    /// @notice Paginated read over the per-key history list.
    /// @dev `offset >= getHistoryCount(key)` returns an empty array. Length is
    ///      `min(limit, getHistoryCount(key) - offset)`.
    /// @param key The key to read.
    /// @param offset Start index.
    /// @param limit Maximum entries to return.
    /// @return entries Slice of history entries.
    function getHistory(
        bytes32 key,
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (Entry[] memory entries);

    /// @notice Returns the number of distinct keys ever written.
    /// @return count Length of the key-insertion list.
    function getKeyCount() external view returns (uint256 count);

    /// @notice Returns the key at the given insertion-order index.
    /// @param index Zero-based index into the key list.
    /// @return key The key at `index`.
    function getKeyAt(uint256 index) external view returns (bytes32 key);

    /// @notice Paginated read over the insertion-order key list.
    /// @dev `offset >= getKeyCount()` returns an empty array. Length is
    ///      `min(limit, getKeyCount() - offset)`.
    /// @param offset Start index.
    /// @param limit Maximum entries to return.
    /// @return keys Slice of keys.
    function getKeys(uint256 offset, uint256 limit) external view returns (bytes32[] memory keys);
}
