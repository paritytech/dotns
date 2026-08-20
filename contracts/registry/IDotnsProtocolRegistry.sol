// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IDotnsProtocolRegistry
/// @author Parity
/// @notice Interface for the DotNS protocol-level address registry.
/// @dev Single source of truth for sibling lookups. Contracts resolve each other via well-known
///      `bytes32` constants in `DotnsConstants` so an upgrade or rewire only mutates the
///      registry, never the consumers. The registry also holds the network's top-level domain,
///      so every consumer reads one TLD rather than compiling its own.
/// @custom:security-contact admin@parity.io
interface IDotnsProtocolRegistry {
    /// @notice Emitted when a protocol address is set or updated.
    event AddressUpdated(bytes32 indexed key, address indexed addr);

    /// @notice Thrown when a zero address is provided where one is not allowed.
    error ZeroAddress();

    /// @notice Thrown when the TLD label supplied at initialisation is not a single DNS label.
    error InvalidTld();

    /// @notice Returns the address stored for a given key.
    /// @dev Returns `address(0)` when the key is unset; callers must validate when non-zero is
    ///      required.
    function get(bytes32 key) external view returns (address addr);

    /// @notice Sets or updates the address for a given key.
    /// @dev Owner-restricted, otherwise @custom:reverts OwnableUnauthorizedAccount. `addr`
    ///      must be non-zero, otherwise @custom:reverts ZeroAddress. Idempotent when the new
    ///      value matches the stored one (no event emitted in that case). Maintains a
    ///      per-address refcount so the same contract can occupy multiple keys without losing
    ///      its registered status until every key is rewired. Emits
    ///      @custom:emits AddressUpdated on each effective change.
    function set(bytes32 key, address addr) external;

    /// @notice Returns true iff `addr` is currently registered under at least one well-known key.
    /// @dev O(1) refcount-backed lookup. Canonical peer-trust check consumed by `LabelStore`
    ///      writes and `StoreFactory` deploys; only addresses governance has actively
    ///      registered return true. Treats `address(0)` as never registered regardless of
    ///      refcount.
    function isRegisteredAddress(address addr) external view returns (bool registered);

    /// @notice Returns the namehash of the network's TLD node.
    /// @dev `namehash(0, keccak256(bytes(tldLabel)))`, fixed at initialisation. Consumers use it
    ///      as the root parent when deriving a name's node.
    function tldNode() external view returns (bytes32 node);

    /// @notice Returns the network's TLD suffix, including the leading dot (e.g. `.dot`).
    /// @dev Fixed at initialisation. Consumers append it when rendering a label as a full name.
    function tld() external view returns (string memory suffix);
}
