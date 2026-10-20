// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
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
    ///        At most `StringUtils.MAX_NAME_PATH_OCTETS` octets. The bound is on the path in
    ///        octets, so it limits nesting only through how much of that budget each level
    ///        spends.
    /// @param owner Address to assign as owner of the created subnode.
    /// @param persist Whether to index the subnode into the owner's `LabelStore`, deploying it on
    ///        demand. When false the ownership and resolver record is still written but the store
    /// is left untouched, and an authorised store writer backfills the label later by deploying
    ///        the owner's store and writing to it. Deferring the store write this way is restricted
    ///        to registered controllers (@custom:function IDotnsRegistrar.controllers): any other
    ///        caller must pass true, otherwise @custom:reverts NotAuthorised, because it could
    /// never backfill a deferred label. The registry writes the store only on creation or on a
    ///        reassignment to a new owner, so a later same-owner re-call with true does not
    /// backfill it; the authorised writer backfills it directly.
    struct SubnodeRecord {
        bytes32 parentNode;
        string subLabel;
        string parentLabel;
        address owner;
        bool persist;
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

    /// @notice Emitted when every record of `node` stops resolving.
    /// @dev Records live on resolver contracts and cannot be listed, so nothing is erased: the
    ///      node's record version moves to `version` and every resolver that stamps its writes with
    ///      @custom:function recordVersion reads anything written under an earlier version as
    ///      unset. Consumers that cache records must drop every cached record of `node` on this
    ///      event.
    /// @param node Node whose records were cleared.
    /// @param version Record version the node's records are now written under.
    event RecordsCleared(bytes32 indexed node, uint64 version);

    /// @notice Emitted when every subname beneath `node`, at any depth, stops resolving.
    /// @dev One event covers the whole subtree, because the subtree cannot be listed. Descendants
    ///      emit nothing of their own: consumers that index subnames must treat this event as the
    ///      removal of every node below `node`, together with their records.
    /// @param node Node whose subnames were cleared.
    /// @param version Subname version a new child of `node` is created under.
    event SubnamesCleared(bytes32 indexed node, uint64 version);

    /// @notice Emitted when a subname created without a recorded parent is linked to it.
    /// @param node The subname.
    /// @param parent Its parent node.
    event SubnameLinked(bytes32 indexed node, bytes32 indexed parent);

    /// @notice Thrown when an invalid (zero) address is provided.
    error NotAllowed();

    /// @notice Thrown when the caller is not authorised.
    error NotAuthorised();

    /// @notice Thrown when the caller is not the registry controller.
    error NotRegistryController();

    /// @notice Thrown when attempting to create a node that already exists.
    error NodeAlreadyOwned(bytes32 node);

    /// @notice Thrown when a subname that should exist under a parent does not, or no longer
    ///         resolves.
    /// @param node The subname.
    error SubnameNotFound(bytes32 node);

    /// @notice Thrown when a new subname would sit deeper below its second-level name than
    ///         `MAX_SUBNAME_DEPTH` allows.
    /// @param depth Depth the subname would have.
    /// @param maxDepth Deepest allowed.
    error SubnameTooDeep(uint256 depth, uint256 maxDepth);

    /// @notice Thrown when a sublabel is not a canonical lowercase ASCII DNS label.
    error InvalidLabel();

    /// @notice Thrown when the supplied parent label does not match the parent node, or is not a
    ///         valid name path.
    /// @dev The two cases share one error because both mean the caller's `parentLabel` cannot be
    ///      trusted to name `parentNode`: a mismatched namehash, a malformed segment, or a path
    ///      over `StringUtils.MAX_NAME_PATH_OCTETS`. That last bound is on the path in octets, so
    ///      it limits nesting only through how much of the budget each level spends. It exists
    ///      because the composed full name is stored in a `LabelStore` row that has no delete
    ///      path.
    error ParentLabelMismatch();

    /// @notice Record describing a subnode resolver update request.
    /// @param subLabel Human-readable subnode label e.g "alice".
    /// @param parentLabel Canonical parent name without the TLD suffix e.g bob or child.bob.
    ///        At most `StringUtils.MAX_NAME_PATH_OCTETS` octets. The bound is on the path in
    ///        octets, so it limits nesting only through how much of that budget each level
    ///        spends.
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
    ///      path of at most `StringUtils.MAX_NAME_PATH_OCTETS` octets whose namehash matches
    ///      `record.parentNode` (otherwise
    ///      @custom:reverts ParentLabelMismatch). Subnodes are parent-sovereign: the current
    ///      `record.parentNode` owner may reassign or rotate a subnode's resolver at any time
    ///      without the prior subnode owner's consent. On reassignment the resolver pointer is
    ///      reset to the protocol-registered default reverse resolver so a prior subnode
    ///      owner's resolver cannot be inherited by the next holder (records on other resolver
    ///      contracts are keyed by node and are not cleared by this function; downstream
    ///      consumers should gate resolver reads on current ownership). Indexes the subnode
    ///      under the new owner's `LabelStore` keyed by the namehashed `subnode` so off-chain
    ///      consumers can enumerate names per address. Indexing into the owner's `LabelStore` is
    ///      governed by `record.persist` (see @custom:struct SubnodeRecord); the ownership and
    ///      resolver record is written either way. A `record.persist` of false defers the store
    ///      write and is restricted to registered controllers
    ///      (@custom:function IDotnsRegistrar.controllers), otherwise @custom:reverts
    /// NotAuthorised. Creating a subname, as opposed to reassigning one that resolves, requires it
    ///      to sit at most `MAX_SUBNAME_DEPTH` levels below its second-level name, otherwise
    ///      @custom:reverts SubnameTooDeep. Emits @custom:emits NewOwner on each successful
    ///      assignment.
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
    ///      path of at most `StringUtils.MAX_NAME_PATH_OCTETS` octets whose namehash matches
    ///      `record.parentNode` (otherwise
    ///      @custom:reverts ParentLabelMismatch). The resulting subnode must already exist,
    ///      otherwise @custom:reverts NotAuthorised. Emits @custom:emits NewResolver on
    ///      success.
    function setSubnodeResolver(SubnodeResolverRecord calldata record) external;

    /// @notice Creates or resets a node record for a tokenised second-level registration.
    /// @dev Restricted to the registrar's controllers, otherwise @custom:reverts NotAuthorised.
    ///      `newOwner` must be non-zero (otherwise @custom:reverts NotAllowed) and must match
    ///      the ERC-721 owner reported by the registrar (otherwise
    ///      @custom:reverts NotAuthorised). The function is callable both on a fresh
    ///      registration and on every reclaim from escrow: each call rewrites
    ///      `records[node].resolver` to the protocol-registered default reverse resolver so a
    ///      prior owner's resolver pointer (and the records keyed under it) cannot be inherited
    ///      by the next holder across that recycle. A secondary-market ERC-721 `transferFrom` does
    ///      not call the registry, so a name sold directly keeps the seller's resolver pointer
    ///      until the buyer overwrites it. That covers the node itself and not the nodes beneath
    ///      it: a subname stores its own owner, and @custom:function isAuthorised returns on that
    ///      owner before consulting the registrar, so after the sale the seller keeps write
    ///      authority over every subname whose stored owner is still the seller, until the buyer
    ///      reassigns each one through @custom:function setSubnodeOwner, deletes it through
    ///      @custom:function deleteSubname, or clears them all at once through
    ///      @custom:function clearSubnames. A subname created for someone else stays with that
    ///      owner and leaves the seller no write path. The set is derivable from
    ///      @custom:emits NewOwner, which indexes the parent node. Stores
    ///      `owner = address(0)` as a sentinel so reads delegate to `IDotnsRegistrar.ownerOf` and
    ///      ERC-721 transfers remain authoritative. Emits
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

    /// @notice Returns the recorded parent of a subname.
    /// @dev Zero for a tokenised name, for a node that was never created, and for a subname
    ///      created before parents were recorded and not linked since (@custom:function
    ///      linkSubname). A backfill reads it to find the subnames still to link.
    /// @param node Node identifier.
    /// @return parent Recorded parent node, or zero.
    function parentOf(bytes32 node) external view returns (bytes32 parent);

    /// @notice Returns the owner of a node.
    /// @dev For tokenised nodes the stored owner is the zero sentinel; the implementation falls
    ///      back to `IDotnsRegistrar.ownerOf(uint256(node))`. A subname that no longer resolves,
    ///      because it or a name above it was cleared or deleted, has no owner and returns zero, as
    ///      do @custom:function resolver, @custom:function recordExists and
    ///      @custom:function isAuthorised for it.
    function owner(bytes32 node) external view returns (address);

    /// @notice Returns the resolver of a node, or zero when the node does not resolve.
    function resolver(bytes32 node) external view returns (address);

    /// @notice Returns whether a node exists and resolves.
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

    /// @notice Clears every record of `node`: each resolver record reads as unset and the resolver
    ///         pointer returns to the protocol default.
    /// @dev Callable by anyone @custom:function isAuthorised admits for `node`, otherwise
    ///      @custom:reverts NotAuthorised. Constant cost whatever the number of records: the node's
    ///      record version is bumped rather than any record being visited. Subnames are untouched;
    ///      see @custom:function clearSubnames. Emits @custom:emits RecordsCleared and
    ///      @custom:emits NewResolver.
    /// @param node Node to clear.
    function clearRecords(bytes32 node) external;

    /// @notice Clears every subname beneath `node`, at any depth, together with their records.
    /// @dev Callable by anyone @custom:function isAuthorised admits for `node`, otherwise
    ///      @custom:reverts NotAuthorised. Constant cost whatever the size or depth of the subtree:
    ///      the node's subname version is bumped, and a subname resolves only while the version it
    ///      was created under is still current at every level above it. A cleared subname can be
    ///      created again through @custom:function setSubnodeOwner, and starts with no records and
    ///      no subnames. The node's own records are untouched; see @custom:function clearRecords.
    ///      Emits @custom:emits SubnamesCleared.
    /// @param node Node whose subnames are cleared.
    function clearSubnames(bytes32 node) external;

    /// @notice Clears every record and every subname of `node`.
    /// @dev Equivalent to @custom:function clearRecords followed by @custom:function clearSubnames
    ///      in one call, with the same authority. `DotnsNameEscrow.release` calls it once it holds
    ///      the token, which is what makes a released name start clean for whoever gets it next.
    /// @param node Node to clear.
    function clear(bytes32 node) external;

    /// @notice Deletes one subname of `parentNode`, together with its records and every subname
    ///         beneath it.
    /// @dev Callable by anyone @custom:function isAuthorised admits for `parentNode`, otherwise
    ///      @custom:reverts NotAuthorised: subnames are parent-sovereign, so the parent decides,
    ///      not the subname's holder. The subname's record and parent link are zeroed, releasing
    ///      their storage deposit to the caller; one version slot stays so the subname, created
    ///      again, starts empty. Subnames beneath it are cleared but keep their storage, so a
    ///      parent that wants every deposit back deletes from the deepest subname up. The subname
    ///      must currently resolve, otherwise @custom:reverts SubnameNotFound. Emits @custom:emits
    ///      NewOwner with a zero owner, the deletion convention indexers already follow, and
    ///      @custom:emits RecordsCleared and @custom:emits SubnamesCleared for the subname.
    /// @param parentNode Parent of the subname.
    /// @param labelhash Labelhash of the subname under `parentNode`.
    function deleteSubname(bytes32 parentNode, bytes32 labelhash) external;

    /// @notice Records the parent of a subname created before parents were recorded, so that
    ///         clearing an ancestor reaches it.
    /// @dev Permissionless: the parent is proven by the namehash, since `subnode` is
    ///      `keccak256(parentNode, labelhash)`, so a caller cannot link a subname anywhere else.
    ///      The subname is linked as created under its parent's first subname version, so a subname
    ///      whose ancestor was cleared before it was linked reads as cleared once linked. Every
    ///      write path that names a parent links it as a side effect; this entry point covers the
    ///      rest. @custom:reverts SubnameNotFound when no subname exists there. A subname already
    ///      linked is left as it is. Emits @custom:emits SubnameLinked when it links.
    /// @param parentNode Parent of the subname.
    /// @param labelhash Labelhash of the subname under `parentNode`.
    function linkSubname(bytes32 parentNode, bytes32 labelhash) external;

    /// @notice Returns whether `node` resolves and the record version its records are written
    ///         under.
    /// @dev Resolvers stamp each write with `recordsVersion` and treat a record whose stamp
    ///      differs, or any record of a node that does not resolve, as unset. A tokenised name
    ///      resolves while its record exists; a subname resolves while no ancestor has cleared or
    ///      deleted it.
    ///      Version 0 is the version every node starts at, so records written before versions
    ///      existed carry a matching stamp and stay readable until the node is first cleared.
    ///      Checking a subname walks its ancestors, so the cost grows with its depth.
    /// @param node Node identifier.
    /// @return live True when `node` currently resolves.
    /// @return recordsVersion Record version of `node`.
    function recordVersion(bytes32 node) external view returns (bool live, uint64 recordsVersion);
}
