// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";

/// @title Dotns Resolver
/// @notice Defines forward-resolution address records for DotNS nodes
/// @dev A resolver maps a deterministic node identifier to a resolved address.
/// @custom:security-contact admin@parity.io
interface IDotnsResolver {
    /// @notice Thrown when a caller is not authorised to modify a node
    /// @param node The node being modified
    /// @param caller The address attempting the modification
    error NotAuthorised(bytes32 node, address caller);

    /// @notice Emitted when an address record is updated
    /// @param node The node whose address record changed
    /// @param value The new resolved address
    event AddressSet(bytes32 indexed node, address value);

    /// @notice Sets the resolved address for a node
    /// @param node The node identifier
    /// @param value The address to associate with the node
    function setAddress(bytes32 node, address value) external;

    /// @notice Returns the resolved address for a node
    /// @param node The node identifier
    /// @return value The resolved address, or zero if unset
    function addressOf(bytes32 node) external view returns (address value);

    /// @notice Emitted when the protocol registry is updated.
    /// @param newRegistry The address of the new protocol registry.
    event ProtocolRegistryUpdated(IDotnsProtocolRegistry indexed newRegistry);

    /// @notice Updates the protocol registry address.
    /// @dev Callable only by the contract owner.
    /// @param registry The address of the new protocol registry.
    function updateProtocolRegistry(IDotnsProtocolRegistry registry) external;
}
