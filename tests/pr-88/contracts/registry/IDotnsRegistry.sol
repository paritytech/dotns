// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IDotnsProtocolRegistry} from "./IDotnsProtocolRegistry.sol";

/// @title Dot Registry
/// @notice Minimal on-chain registry for hierarchical name ownership and resolution.
/// @dev Defines the canonical storage and mutation surface for DotNS nodes.
///      The registry stores explicit owners for non-tokenised nodes (subnodes).
///      For tokenised nodes (base .dot registrations), implementations may use a sentinel owner:
///      - records[node].owner == address(0) means "owner is derived from the ERC721 registrar".
///      In that mode, authorisation MUST be based on ERC721 owner/approvals.
/// @custom:security-contact admin@parity.io
interface IDotnsRegistry {
    /// @notice Record describing a subnode creation request
    /// @param parentNode Parent node
    /// @param subLabel Human readable subnode label e.g "alice"
    /// @param parentLabel Canonical parent name without the `.dot` suffix e.g. bob or child.bob
    /// @param owner Address to assign as owner of the created subnode
    /// @dev Label string is included for convenience, for the store
    struct SubnodeRecord {
        bytes32 parentNode;
        string subLabel;
        string parentLabel;
        address owner;
    }

    /// @notice Record describing the state of a node.
    /// @param owner Address that owns the node, or address(0) sentinel for tokenised nodes.
    /// @param resolver Address of the resolver associated with the node.
    /// @param exists Whether the node has been explicitly created.
    struct Record {
        address owner;
        address resolver;
        bool exists;
    }

    /// @notice Emitted when a new subnode owner is set.
    /// @param node Parent node.
    /// @param label Labelhash of the created subnode.
    /// @param owner New owner of the subnode.
    event NewOwner(bytes32 indexed node, bytes32 indexed label, address owner);

    /// @notice Emitted when ownership of a node is transferred.
    /// @param node Node whose owner changed.
    /// @param owner New owner of the node.
    event NodeTransferred(bytes32 indexed node, address owner);

    /// @notice Emitted when a resolver is set or updated.
    /// @param node Node whose resolver changed.
    /// @param resolver New resolver for the node.
    event NewResolver(bytes32 indexed node, address resolver);

    /// @notice Thrown when an invalid (zero) address is provided.
    error NotAllowed();

    /// @notice Thrown when the caller is not authorised.
    error NotAuthorised();

    /// @notice Thrown when the caller is not the registry controller.
    error NotRegistryController();

    /// @notice Thrown when attempting to create a node that already exists.
    /// @param node The node identifier that already exists.
    error NodeAlreadyOwned(bytes32 node);

    /// @notice Thrown when attempting to create a subnode that already exists.
    /// @param subnode The derived node identifier that already exists.
    error NodeAlreadyExists(bytes32 subnode);

    /// @notice Thrown when a sublabel is not a canonical lowercase ASCII DNS label.
    error InvalidLabel();

    /// @notice Thrown when the supplied parent label does not match the parent node.
    error ParentLabelMismatch();

    /// @notice Creates a new subnode and assigns its owner.
    /// @dev Callable only by the current owner of `parentNode`.
    ///      Reverts if the derived subnode already exists.
    /// @param record SubnodeRecord.
    /// @return subnode The derived subnode identifier.
    function setSubnodeOwner(SubnodeRecord calldata record) external returns (bytes32 subnode);

    /// @notice Creates a node record for a tokenised base registration.
    /// @dev Callable only by the configured `registrarController`.
    ///      Implementations SHOULD use the sentinel owner pattern:
    ///      - store owner as address(0) to derive ownership from the ERC721 registrar.
    /// @param node Node identifier.
    /// @param newOwner New owner address for event emission and validation.
    /// @param resolverAddr Resolver address to set for the node.
    function setOwner(bytes32 node, address newOwner, address resolverAddr) external;

    /// @notice Sets or clears the resolver for a node.
    /// @dev Callable only by the current node owner.
    ///      For tokenised nodes, authorisation is based on ERC721 owner/approvals.
    /// @param node Node identifier.
    /// @param resolverAddr Resolver contract address (zero clears).
    function setResolver(bytes32 node, address resolverAddr) external;

    /// @notice Returns the owner of a node.
    /// @dev For tokenised nodes (sentinel owner), returns the ERC721 owner.
    /// @param node Node identifier.
    function owner(bytes32 node) external view returns (address);

    /// @notice Returns the resolver of a node.
    /// @param node Node identifier.
    function resolver(bytes32 node) external view returns (address);

    /// @notice Returns whether a node exists.
    /// @param node Node identifier.
    function recordExists(bytes32 node) external view returns (bool);

    /// @notice Emitted when the protocol registry is updated.
    /// @param newRegistry The address of the new protocol registry.
    event ProtocolRegistryUpdated(IDotnsProtocolRegistry indexed newRegistry);

    /// @notice Updates the protocol registry address.
    /// @dev Callable only by the contract owner.
    /// @param registry The address of the new protocol registry.
    function updateProtocolRegistry(IDotnsProtocolRegistry registry) external;
}
