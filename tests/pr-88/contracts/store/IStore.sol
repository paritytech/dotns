// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IStore
/// @notice Interface defining a key-value storage for IPFS URIs scoped by user address.
/// @dev Each user maintains an isolated namespace of key-value pairs. Authorized contracts can write on behalf of users.
///
/// @dev Permanent locking:
///      Some `(user, key)` entries can be locked permanently to make them immutable:
///      - Locked entries cannot be overwritten by any caller.
///      - Locked entries cannot be deleted by any caller, including the store owner.
///      - The intended use is for DotNS-related data written by the DotNS registry controller.
/// @custom:security-contact admin@parity.io
interface IStore {
    /// @notice Emitted when a new value is stored or updated.
    /// @param user The address whose storage was modified.
    /// @param key The key under which the value is stored.
    /// @param value The stored IPFS URI.
    event ValueStored(address indexed user, bytes32 indexed key, string value);

    /// @notice Emitted when a value is deleted.
    /// @param user The address whose storage was modified.
    /// @param key The key that was deleted.
    event ValueDeleted(address indexed user, bytes32 indexed key);

    /// @notice Emitted when an address is authorized to write on behalf of users.
    /// @param authorizedAddress The address that was granted authorization.
    event StoreAuthorized(address indexed authorizedAddress);

    /// @notice Emitted when an address loses authorization to write on behalf of users.
    /// @param unauthorizedAddress The address that had authorization revoked.
    event StoreUnauthorized(address indexed unauthorizedAddress);

    /// @notice Emitted when an authorized address is marked as a DotNS controller for locking semantics.
    /// @param controllerAddress The address that was granted DotNS controller status.
    event DotnsControllerAuthorized(address indexed controllerAddress);

    /// @notice Emitted when an address loses DotNS controller status.
    /// @param controllerAddress The address that had DotNS controller status revoked.
    event DotnsControllerUnauthorized(address indexed controllerAddress);

    /// @notice Emitted when a key is locked permanently for a user.
    /// @param user The address whose key was locked.
    /// @param key The key that was locked.
    /// @param locker The address that caused the lock.
    event KeyLockedPermanently(address indexed user, bytes32 indexed key, address indexed locker);

    /// @notice Thrown when an unauthorized address attempts a privileged operation.
    /// @param caller The address that attempted the unauthorized operation.
    error NotAuthorised(address caller);

    /// @notice Thrown when attempting to overwrite or delete a permanently locked key.
    /// @param user The user namespace owner of the key.
    /// @param key The key that is locked.
    error KeyLocked(address user, bytes32 key);

    /// @notice Store or update an IPFS URI under a given key for the caller.
    /// @dev Keys are scoped to msg.sender to prevent collisions across users.
    /// @param key The unique identifier for the stored value.
    /// @param value The IPFS URI to store.
    /// @custom:reverts KeyLocked if `(msg.sender, key)` is locked permanently.
    function setValue(bytes32 key, string calldata value) external;

    /// @notice Store or update an IPFS URI under a given key for a specified user.
    /// @dev Only authorized contracts can call this function. Keys are scoped to the specified user.
    /// @dev If the caller is a DotNS controller, the key may be locked permanently as part of the write.
    /// @param user The address whose storage will be modified.
    /// @param key The unique identifier for the stored value.
    /// @param value The IPFS URI to store.
    /// @custom:reverts NotAuthorised if caller is not an authorized contract.
    /// @custom:reverts KeyLocked if `(user, key)` is locked permanently.
    function setValueFor(address user, bytes32 key, string calldata value) external;

    /// @notice Retrieve the IPFS URI for a given key from caller's storage.
    /// @param key The key to look up.
    /// @return The stored IPFS URI, or an empty string if none exists.
    function getValue(bytes32 key) external view returns (string memory);

    /// @notice Retrieve the IPFS URI for a given key from a specified user's storage.
    /// @dev Allows reading any user's stored data regardless of the caller.
    /// @param user The address whose storage to query.
    /// @param key The key to look up.
    /// @return The stored IPFS URI, or an empty string if none exists.
    function getValueFor(address user, bytes32 key) external view returns (string memory);

    /// @notice Delete a value associated with a key from caller's storage.
    /// @param key The key to delete.
    /// @custom:reverts KeyLocked if `(msg.sender, key)` is locked permanently.
    function deleteValue(bytes32 key) external;

    /// @notice Check if a key has a stored value in caller's storage.
    /// @param key The key to check.
    /// @return exists True if the key has a non-empty value.
    function hasValue(bytes32 key) external view returns (bool exists);

    /// @notice Retrieve all stored values for the caller.
    /// @dev Returns values in the order they were added. May include duplicates if setValue was called multiple times.
    /// @return An array of all IPFS URIs stored by the caller.
    function getValues() external view returns (string[] memory);

    /// @notice Check if an address is authorized to write on behalf of users.
    /// @param storeAddress The address to check authorization status.
    /// @return authorized True if the address is authorized.
    function isAuthorized(address storeAddress) external view returns (bool authorized);

    /// @notice Check if an address is marked as a DotNS controller for locking semantics.
    /// @dev DotNS controllers may cause `(user, key)` writes via `setValueFor` to become permanently locked.
    /// @param controllerAddress The address to check.
    /// @return isController True if the address is a DotNS controller.
    function isDotnsController(address controllerAddress) external view returns (bool isController);

    /// @notice Check if a `(user, key)` pair is permanently locked.
    /// @param user The user namespace owner of the key.
    /// @param key The key to check.
    /// @return locked True if the key is locked permanently.
    function isLocked(address user, bytes32 key) external view returns (bool locked);

    /// @notice Authorizes an address to call setValueFor on behalf of users.
    /// @dev Only the store owner can authorize new addresses.
    /// @param storeAddress The address to authorize.
    /// @custom:reverts NotAuthorised if caller is not the owner.
    function authorizeStore(address storeAddress) external;

    /// @notice Revokes authorization for an address to call setValueFor.
    /// @dev Only the store owner can revoke authorizations.
    /// @param storeAddress The address to unauthorize.
    /// @custom:reverts NotAuthorised if caller is not the owner.
    function unauthorizeStore(address storeAddress) external;

    /// @notice Marks an address as a DotNS controller for locking semantics.
    /// @dev Only the store owner can grant this role.
    ///      This role does not grant write access by itself; the address must also be authorized via `authorizeStore`.
    /// @param controllerAddress The address to mark as DotNS controller.
    /// @custom:reverts NotAuthorised if caller is not the owner.
    function authorizeDotnsController(address controllerAddress) external;

    /// @notice Removes DotNS controller status from an address.
    /// @dev Only the store owner can revoke this role.
    ///      Revoking does not unlock existing locked keys.
    /// @param controllerAddress The address to unmark as DotNS controller.
    /// @custom:reverts NotAuthorised if caller is not the owner.
    function unauthorizeDotnsController(address controllerAddress) external;
}
