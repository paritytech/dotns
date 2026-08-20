// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IDotnsRegistry
/// @author Parity
/// @notice Minimal on-chain registry for hierarchical name ownership and resolution.
/// @dev Tokenised second-level nodes are owned through the registrar (ERC-721); subnodes are
///      owned directly by the address stored in `Record.owner`.
/// @custom:security-contact admin@parity.io
interface IDotnsRegistry {
    /// @notice Record describing a subnode creation request.
    /// @param subLabel Human readable subnode label e.g "alice".
    /// @param parentLabel Canonical parent name without the TLD suffix e.g. bob or child.bob.
    /// @param owner Address to assign as owner of the created subnode.
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
    event NewOwner(bytes32 indexed node, bytes32 indexed label, address owner);

    /// @notice Emitted when ownership of a node is transferred.
    event NodeTransferred(bytes32 indexed node, address owner);

    /// @notice Emitted when a resolver is set or updated.
    event NewResolver(bytes32 indexed node, address resolver);

    /// @notice Thrown when an invalid (zero) address is provided.
    error NotAllowed();

    /// @notice Thrown when the caller is not authorised.
    error NotAuthorised();

    /// @notice Thrown when the caller is not the registry controller.
    error NotRegistryController();

    /// @notice Thrown when attempting to create a node that already exists.
    error NodeAlreadyOwned(bytes32 node);

    /// @notice Thrown when a sublabel is not a canonical lowercase ASCII DNS label.
    error InvalidLabel();

    /// @notice Thrown when the supplied parent label does not match the parent node.
    error ParentLabelMismatch();

    /// @notice Record describing a subnode resolver update request.
    /// @param subLabel Human-readable subnode label e.g "alice".
    /// @param parentLabel Canonical parent name without the TLD suffix e.g bob or child.bob.
    /// @param resolver Resolver contract address (zero clears).
    struct SubnodeResolverRecord {
        bytes32 parentNode;
        string subLabel;
        string parentLabel;
        address resolver;
    }

    /// @notice Creates or reassigns a subnode and assigns its owner.
    /// @dev Callable only by the current owner of `record.parentNode`, otherwise
    ///      @custom:reverts NotAuthorised. The new owner address must be non-zero, otherwise
    ///      @custom:reverts NotAllowed. `record.subLabel` must be a single canonical DNS label
    ///      (otherwise @custom:reverts InvalidLabel) and `record.parentLabel` must be a name
    ///      path whose namehash matches `record.parentNode` (otherwise
    ///      @custom:reverts ParentLabelMismatch). Subnodes are parent-sovereign: the current
    ///      `record.parentNode` owner may reassign or rotate a subnode's resolver at any time
    ///      without the prior subnode owner's consent. On reassignment the resolver pointer is
    ///      reset to the protocol-registered default reverse resolver so a prior subnode
    ///      owner's resolver cannot be inherited by the next holder (records on other resolver
    ///      contracts are keyed by node and are not cleared by this function; downstream
    ///      consumers should gate resolver reads on current ownership). Indexes the subnode
    ///      under the new owner's `LabelStore` keyed by the namehashed `subnode` so off-chain
    ///      consumers can enumerate names per address. Emits @custom:emits NewOwner on each
    ///      successful assignment.
    function setSubnodeOwner(SubnodeRecord calldata record) external returns (bytes32 subnode);

    /// @notice Sets the resolver for an existing subnode.
    /// @dev Callable only by the current owner of `record.parentNode`, otherwise
    ///      @custom:reverts NotAuthorised. The subnode owner can still update the resolver
    ///      directly via `setResolver`. Both entry points emit the same `NewResolver(subnode,
    ///      ...)` event, so the parent can silently override a subnode owner's chosen resolver:
    ///      this is the parent-sovereign hierarchy applied to resolution. Off-chain consumers
    ///      that surface trust signals to subnode owners should treat any resolver rotation as
    ///      a re-attestation prompt. `record.subLabel` must be a single canonical DNS label
    ///      (otherwise @custom:reverts InvalidLabel) and `record.parentLabel` must be a name
    ///      path whose namehash matches `record.parentNode` (otherwise
    ///      @custom:reverts ParentLabelMismatch). The resulting subnode must already exist,
    ///      otherwise @custom:reverts NotAuthorised. Emits @custom:emits NewResolver on
    ///      success.
    function setSubnodeResolver(SubnodeResolverRecord calldata record) external;

    /// @notice Creates or resets a node record for a tokenised base registration.
    /// @dev Restricted to the registrar's controllers, otherwise @custom:reverts NotAuthorised.
    ///      `newOwner` must be non-zero (otherwise @custom:reverts NotAllowed) and must match
    ///      the ERC-721 owner reported by the registrar (otherwise
    ///      @custom:reverts NotAuthorised). The function is callable both on a fresh
    ///      registration and on every reclaim from escrow: each call rewrites
    ///      `records[node].resolver` to the protocol-registered default reverse resolver so a
    ///      prior owner's resolver pointer (and the records keyed under it) cannot be inherited
    ///      by the next holder. Stores `owner = address(0)` as a sentinel so reads delegate to
    ///      `IDotnsRegistrar.ownerOf` and ERC-721 transfers remain authoritative. Emits
    ///      @custom:emits NodeTransferred on success.
    function setOwner(bytes32 node, address newOwner) external;

    /// @notice Sets or clears the resolver for a node.
    /// @dev Callable only by the current node owner, otherwise @custom:reverts NotAuthorised.
    ///      For tokenised nodes, authorisation falls back to ERC-721 owner / approved /
    ///      operator-for-all via the registrar. The registry does not validate
    ///      `resolverAddr` against any interface or code presence; off-chain consumers must
    ///      verify resolver shape before trusting reads. Emits @custom:emits NewResolver on
    ///      success.
    /// @param resolverAddr Resolver contract address (zero clears).
    function setResolver(bytes32 node, address resolverAddr) external;

    /// @notice Returns the owner of a node.
    /// @dev For tokenised nodes the stored owner is the zero sentinel; the implementation falls
    ///      back to `IDotnsRegistrar.ownerOf(uint256(node))`.
    function owner(bytes32 node) external view returns (address);

    /// @notice Returns the resolver of a node.
    function resolver(bytes32 node) external view returns (address);

    /// @notice Returns whether a node exists.
    function recordExists(bytes32 node) external view returns (bool);

    /// @notice Returns whether `account` is authorised to manage `node`.
    /// @dev For subnodes, authority is the explicit stored owner. For tokenised nodes it is the
    ///      ERC-721 owner, an address approved for the token, or an operator approved for all of
    ///      the owner's tokens via the registrar. This is the canonical authorisation check the
    ///      registry enforces on owner-gated entry points; sibling contracts may consult it so a
    ///      single registrar-level approval delegates management across the protocol. Returns
    ///      false for a node that does not exist.
    /// @param node Node identifier.
    /// @param account Address whose authority is being checked.
    /// @return authorisedFlag True when `account` may manage `node`.
    function isAuthorised(bytes32 node, address account) external view returns (bool authorisedFlag);
}
