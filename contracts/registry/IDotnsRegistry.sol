// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IDotnsRegistrarController} from "../registrars/IDotnsRegistrarController.sol";

/// @title Dot Registry Interface
/// @notice Minimal on-chain registry for hierarchical name ownership and resolution.
/// @dev Defines the canonical storage and mutation surface for DotNS nodes.
///      The registry is intentionally minimal and self-contained:
///      - Tracks ownership of nodes in a hierarchy
///      - Associates nodes with resolver contracts
///      - Enforces authorisation strictly via node ownership (or explicit controller for privileged ops)
/// @custom:security-contact admin@parity.io
interface IDotnsRegistry {
    /// @notice Record describing a subnode creation request
    /// @param parentNode Parent node
    /// @param subLabel Human readable subnode label e.g "alice"
    /// @param parentLabel Human readable parent label e.g. bob
    /// @param owner Address to assign as owner of the created subnode
    /// @dev Label string is included for convenience, for the store
    struct SubnodeRecord {
        bytes32 parentNode;
        string subLabel;
        string parentLabel;
        address owner;
    }

    /// @notice Record describing the state of a node.
    /// @param owner Address that owns the node.
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

    /// @notice Emitted when the registrar controller address is updated.
    /// @param oldRegistrarController Previous registrar controller.
    /// @param newRegistrarController New registrar controller.
    event RegistrarControllerUpdated(
        IDotnsRegistrarController indexed oldRegistrarController,
        IDotnsRegistrarController indexed newRegistrarController
    );

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

    /// @notice Creates a new subnode and assigns its owner.
    /// @dev Callable only by the current owner of `node`.
    ///      Reverts if the derived subnode already exists.
    /// @param record SubnodeRecord see @custom:structs SubnodeRecord.
    /// @return subnode The derived subnode identifier.
    function setSubnodeOwner(SubnodeRecord calldata record) external returns (bytes32 subnode);

    /// @notice Transfers ownership of an existing node.
    /// @dev Callable only by the configured `registrarController`.
    ///      This is a privileged operation used by the registrar controller during registration flows.
    /// @param node Node identifier.
    /// @param newOwner New owner address.
    /// @param resolverAddr Resolver address to set for the node.
    /// @custom:reverts NotRegistryController if the caller is not the registrar controller.
    function setOwner(bytes32 node, address newOwner, address resolverAddr) external;

    /// @notice Sets or clears the resolver for a node.
    /// @dev Callable only by the current node owner.
    /// @param node Node identifier.
    /// @param resolverAddr Resolver contract address (zero clears).
    function setResolver(bytes32 node, address resolverAddr) external;

    /// @notice Returns the owner of a node.
    /// @param node Node identifier.
    function owner(bytes32 node) external view returns (address);

    /// @notice Returns the resolver of a node.
    /// @param node Node identifier.
    function resolver(bytes32 node) external view returns (address);

    /// @notice Returns whether a node exists.
    /// @param node Node identifier.
    function recordExists(bytes32 node) external view returns (bool);

    /// @notice Sets the registrar controller used for privileged node ownership writes.
    /// @dev Callable only by the registry owner.
    /// @param registrarController Address of the registrar controller contract.
    function updateRegistrarController(IDotnsRegistrarController registrarController) external;
}
