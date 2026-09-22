// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

/// @title Dotns Resolver
/// @notice Defines forward-resolution address records for DotNS nodes.
/// @dev Forward-address records describe where a name points. Authority therefore
///      follows node ownership in the forward registry, not a privileged writer.
/// @custom:security-contact admin@parity.io
interface IDotnsResolver {
    /// @notice Thrown when a caller is not authorised to modify a node.
    /// @param node The node being modified.
    /// @param caller The address attempting the modification.
    error NotAuthorised(bytes32 node, address caller);

    /// @notice Emitted when an address record is updated.
    /// @param node The node whose address record changed.
    /// @param value The new resolved address.
    event AddressSet(bytes32 indexed node, address value);

    /// @notice Sets the resolved address for a node.
    /// @dev The caller must be the current owner of `node` in the forward registry, otherwise
    ///      @custom:reverts NotAuthorised. Emits @custom:emits AddressSet on every successful
    ///      write.
    /// @param node The node identifier.
    /// @param value The address to associate with the node.
    function setAddress(bytes32 node, address value) external;

    /// @notice Returns the resolved address for a node.
    /// @param node The node identifier.
    /// @return value The resolved address, or zero if unset.
    function addressOf(bytes32 node) external view returns (address value);
}
