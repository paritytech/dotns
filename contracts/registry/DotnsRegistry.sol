// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IDotnsRegistry} from "./IDotnsRegistry.sol";
import {IDotnsController} from "../registrars/IDotnsController.sol";
import {IDotnsRegistrar} from "../registrars/IDotnsRegistrar.sol";
import {IStoreFactory} from "../store/IStoreFactory.sol";
import {StoreUtils} from "../utils/StoreUtils.sol";
import {LabelUtils} from "../utils/LabelUtils.sol";
import {IDotnsProtocolRegistry} from "./IDotnsProtocolRegistry.sol";
import {StringUtils} from "../utils/StringUtils.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";
import {SystemUtils} from "../utils/SystemUtils.sol";

/// @title dotNS Registry
/// @author Parity
/// @notice Upgradeable on-chain registry for hierarchical name ownership and resolution.
/// @dev Tokenised second-level nodes store `owner == address(0)` as a sentinel and defer to
///      `IDotnsRegistrar.ownerOf`; subnodes carry an explicit owner address in `records`.
/// @custom:security-contact admin@parity.io
contract DotnsRegistry is Initializable, UUPSUpgradeable, OwnableUpgradeable, IDotnsRegistry {
    using StoreUtils for IStoreFactory;
    using StringUtils for *;

    /// @notice Deepest a new subname may sit below its second-level name: a subname directly under
    ///         `alice` is at depth 1, one under `child.alice` at depth 2.
    /// @dev Bounds the read cost, not the clear cost. Clearing is constant at any depth, but
    ///      deciding whether a subname still resolves walks every level above it, and every
    ///      read of a subname (owner, authority, each resolver record) pays that walk. Checked only
    ///      when a subname is created, so a deeper subname that already exists keeps working.
    uint256 public constant MAX_SUBNAME_DEPTH = 8;

    /// @notice Mapping of node identifiers to records.
    mapping(bytes32 node => Record record) private records;

    /// @notice Protocol-level address registry for all dotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @notice Versions that let a node, or everything beneath it, be cleared at constant cost.
    /// @dev Neither records nor subnames can be listed, so clearing never visits them. It bumps a
    ///      version instead, and readers compare against it:
    ///      - `records` is the version a node's resolver records are stamped with. Bumping it makes
    ///        every record of the node read as unset.
    ///      - `subnames` is the version a new child is created under. Bumping it makes every child,
    ///        and through them every deeper subname, stop resolving.
    ///      - `parentSubnames` is the parent's `subnames` at the moment this subname was created.
    ///      Kept apart from `records` because @custom:function setOwner rewrites a whole `Record`,
    ///      and a version reset to zero would bring back every record written under it.
    struct NodeVersions {
        uint64 records;
        uint64 subnames;
        uint64 parentSubnames;
    }

    /// @notice Node => its versions.
    mapping(bytes32 node => NodeVersions versions) private _versions;

    /// @notice Subname => its parent. Zero for tokenised names, for deleted subnames, and for a
    ///         subname whose parent was never recorded until it is linked
    ///         (@custom:function linkSubname).
    mapping(bytes32 node => bytes32 parent) private _parentOf;

    uint256[48] private __gap;

    /// @notice Restricts access to the current owner of `node`.
    modifier authorised(bytes32 node) {
        _authorised(node);
        _;
    }

    /// @notice Restricts access to the configured registrar controller.
    modifier onlyRegistrarController() {
        _onlyRegistrarController();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the registry.
    /// @dev Callable exactly once via `Initializable`, otherwise
    ///      @custom:reverts InvalidInitialization. `registry` must be non-zero, otherwise
    ///      @custom:reverts NotAllowed.
    /// @param initialOwner Address that owns the contract once initialised.
    /// @param registry Protocol-level address registry used to resolve sibling contracts.
    function initialize(
        address initialOwner,
        IDotnsProtocolRegistry registry
    )
        external
        initializer
    {
        __Ownable_init(initialOwner);

        require(address(registry) != address(0), NotAllowed());
        protocolRegistry = registry;
    }

    /// @inheritdoc IDotnsRegistry
    function setSubnodeOwner(SubnodeRecord calldata record)
        external
        override
        authorised(record.parentNode)
        returns (bytes32 subnode)
    {
        address newOwner = record.owner;
        require(newOwner != address(0), NotAllowed());

        // Deferring the store write (persist == false) is a controller workflow: the deferred label
        // is backfilled later by an authorised writer, and only a registered controller drives that
        // path. Every other caller must persist eagerly rather than strand an unindexed label.
        if (!record.persist) {
            _onlyRegistrarController();
        }

        bytes32 parentNode = record.parentNode;
        string calldata subLabel = record.subLabel;
        string calldata parentLabel = record.parentLabel;
        require(subLabel.isSingleLabel(), InvalidLabel());
        require(parentLabel.isNamePath(), ParentLabelMismatch());
        require(_parentNamehash(parentLabel) == parentNode, ParentLabelMismatch());

        bytes32 labelhash = LabelUtils.labelhash(subLabel);
        subnode = LabelUtils.namehashUnder(parentNode, labelhash);

        Record storage existing = records[subnode];
        address reverseResolver = protocolRegistry.get(DotnsConstants.REVERSE_RESOLVER);
        _linkIfUnlinked(subnode, parentNode);
        if (existing.exists && _isLive(subnode)) {
            address previousOwner = existing.owner;
            // Reset the resolver pointer on reassignment so the prior subnode owner's resolver
            // (and any malicious wiring they staged before losing the subnode) cannot be inherited
            // by the new holder. Records keyed by `subnode` on other resolver contracts are not
            // wiped here; consumers should gate reads on current ownership. Skip the resolver
            // write when it already matches the default to avoid a redundant SSTORE on no-op
            // refresh paths.
            existing.owner = newOwner;
            if (existing.resolver != reverseResolver) {
                existing.resolver = reverseResolver;
                emit NewResolver(subnode, reverseResolver);
            }

            if (record.persist && newOwner != previousOwner) {
                string memory fullName =
                    string.concat(subLabel, ".", parentLabel, protocolRegistry.tld());
                _writeSubnodeToStore(newOwner, subnode, fullName);
            }
        } else {
            // A subname still on record but cut off by a clear above it is created again from
            // nothing: bumping its own versions keeps the records and subnames it held before out
            // of reach of the new holder, who may well be the same address.
            uint256 depth = _labelCount(parentLabel);
            require(depth <= MAX_SUBNAME_DEPTH, SubnameTooDeep(depth, MAX_SUBNAME_DEPTH));
            if (existing.exists) {
                _clearRecordVersion(subnode);
                _clearSubnameVersion(subnode);
            }
            records[subnode] = Record({owner: newOwner, resolver: reverseResolver, exists: true});
            _parentOf[subnode] = parentNode;
            // Usually both are zero, because the parent's subnames were never cleared, so the
            // write is skipped rather than storing the value the slot already holds.
            uint64 parentSubnames = _versions[parentNode].subnames;
            if (_versions[subnode].parentSubnames != parentSubnames) {
                _versions[subnode].parentSubnames = parentSubnames;
            }
            if (record.persist) {
                string memory fullName =
                    string.concat(subLabel, ".", parentLabel, protocolRegistry.tld());
                _writeSubnodeToStore(newOwner, subnode, fullName);
            }
        }

        emit NewOwner(parentNode, labelhash, newOwner);
    }

    /// @inheritdoc IDotnsRegistry
    function setOwner(bytes32 node, address newOwner) external override onlyRegistrarController {
        require(newOwner != address(0), NotAllowed());
        IDotnsRegistrar registrar = IDotnsRegistrar(protocolRegistry.get(DotnsConstants.REGISTRAR));
        require(registrar.ownerOf(uint256(node)) == newOwner, NotAuthorised());

        // The resolver pointer is reset to the default reverse resolver on every call to this
        // function, which the controller drives on registration and on reclaim from escrow, so a
        // prior owner's resolver cannot follow the name across that recycle. This does not cover a
        // secondary-market ERC-721 `transferFrom`: that path does not call the registry, so a name
        // sold directly carries the seller's resolver pointer until the buyer overwrites it.
        // Nor does it cover the nodes beneath: a subname carries its own owner in `records`,
        // and `_isAuthorised` returns on that owner before it ever consults the registrar, so a
        // seller keeps write authority over every subname whose stored owner is still the
        // seller, until the buyer deletes each one, or clears them all through `clearSubnames`;
        // reassigning one through `setSubnodeOwner` keeps its records and the subnames beneath it.
        // A subname created for someone else stays with that owner and leaves the seller no write
        // path.
        // The set is derivable from this contract's `NewOwner` events, which index the parent.
        // Owner remains the zero sentinel so reads delegate to the registrar's ERC-721 holder.
        records[node] = Record({
            owner: address(0),
            resolver: protocolRegistry.get(DotnsConstants.REVERSE_RESOLVER),
            exists: true
        });

        emit NodeTransferred(node, newOwner);
    }

    /// @inheritdoc IDotnsRegistry
    function setResolver(bytes32 node, address newResolver) external override authorised(node) {
        records[node].resolver = newResolver;
        emit NewResolver(node, newResolver);
    }

    /// @inheritdoc IDotnsRegistry
    function setSubnodeResolver(SubnodeResolverRecord calldata record)
        external
        override
        authorised(record.parentNode)
    {
        string calldata subLabel = record.subLabel;
        string calldata parentLabel = record.parentLabel;
        require(subLabel.isSingleLabel(), InvalidLabel());
        require(parentLabel.isNamePath(), ParentLabelMismatch());
        require(_parentNamehash(parentLabel) == record.parentNode, ParentLabelMismatch());

        bytes32 subnode =
            LabelUtils.namehashUnder(record.parentNode, LabelUtils.labelhash(subLabel));
        _linkIfUnlinked(subnode, record.parentNode);
        Record storage existing = records[subnode];
        require(existing.exists && _isLive(subnode), NotAuthorised());

        existing.resolver = record.resolver;
        emit NewResolver(subnode, record.resolver);
    }

    /// @inheritdoc IDotnsRegistry
    function clearRecords(bytes32 node) external override authorised(node) {
        _clearRecords(node);
    }

    /// @inheritdoc IDotnsRegistry
    function clearSubnames(bytes32 node) external override authorised(node) {
        _clearSubnameVersion(node);
    }

    /// @inheritdoc IDotnsRegistry
    function clear(bytes32 node) external override authorised(node) {
        _clearRecords(node);
        _clearSubnameVersion(node);
    }

    /// @inheritdoc IDotnsRegistry
    function deleteSubname(
        bytes32 parentNode,
        bytes32 labelhash
    )
        external
        override
        authorised(parentNode)
    {
        _deleteSubname(parentNode, labelhash);
    }

    /// @inheritdoc IDotnsRegistry
    function revokeName(bytes32 node) external override {
        address registrar = protocolRegistry.get(DotnsConstants.REGISTRAR);
        require(msg.sender == registrar, NotRegistrar(msg.sender));

        // Both versions are bumped before the record goes, for the reason given in
        // `_deleteSubname`: the name registered again must not match the stamps of records written
        // before, nor revive the subnames created beneath it. Deleting the record is what keeps
        // reads from deferring to a burned token, whose `ownerOf` reverts.
        _clearRecordVersion(node);
        _clearSubnameVersion(node);
        delete records[node];

        emit NewResolver(node, address(0));
        emit NodeTransferred(node, address(0));
    }

    /// @inheritdoc IDotnsRegistry
    /// @dev Reads no `msg.sender` (see SystemUtils.originIsRoot).
    function revokeSubname(bytes32 parentNode, bytes32 labelhash) external override {
        require(SystemUtils.originIsRoot(), NotRoot());

        address popController = protocolRegistry.get(DotnsConstants.POP_CONTROLLER);
        require(
            popController == address(0) || _owner(parentNode) != popController,
            IssuedByGateway(LabelUtils.namehashUnder(parentNode, labelhash))
        );

        _deleteSubname(parentNode, labelhash);
    }

    /// @inheritdoc IDotnsRegistry
    function linkSubname(bytes32 parentNode, bytes32 labelhash) external override {
        bytes32 subnode = LabelUtils.namehashUnder(parentNode, labelhash);
        Record storage existing = records[subnode];
        require(existing.exists && existing.owner != address(0), SubnameNotFound(subnode));
        _linkIfUnlinked(subnode, parentNode);
    }

    /// @inheritdoc IDotnsRegistry
    function recordVersion(bytes32 node)
        external
        view
        override
        returns (bool live, uint64 recordsVersion)
    {
        live = _isLive(node);
        recordsVersion = _versions[node].records;
    }

    /// @inheritdoc IDotnsRegistry
    function parentOf(bytes32 node) external view override returns (bytes32 parent) {
        parent = _parentOf[node];
    }

    /// @inheritdoc IDotnsRegistry
    function owner(bytes32 node) external view override returns (address) {
        return _owner(node);
    }

    /// @notice Body of @custom:function owner.
    /// @param node Node identifier.
    /// @return The address that owns `node`, or zero when it does not resolve.
    function _owner(bytes32 node) internal view returns (address) {
        Record storage record = records[node];
        // Read `owner` first: a non-zero stored owner proves the record exists and is a subnode,
        // which then resolves only while every level above it does, so the subnode branch walks
        // its ancestors. The `exists` SLOAD only runs on the tokenised-or-missing branch.
        address storedOwner = record.owner;
        if (storedOwner != address(0)) return _isLive(node) ? storedOwner : address(0);
        if (!record.exists) return address(0);
        IDotnsRegistrar registrar = IDotnsRegistrar(protocolRegistry.get(DotnsConstants.REGISTRAR));
        return registrar.ownerOf(uint256(node));
    }

    /// @inheritdoc IDotnsRegistry
    function resolver(bytes32 node) external view override returns (address) {
        return _isLive(node) ? records[node].resolver : address(0);
    }

    /// @inheritdoc IDotnsRegistry
    function recordExists(bytes32 node) external view override returns (bool) {
        return records[node].exists && _isLive(node);
    }

    /// @inheritdoc IDotnsRegistry
    function isAuthorised(
        bytes32 node,
        address account
    )
        external
        view
        override
        returns (bool authorisedFlag)
    {
        authorisedFlag = _isAuthorised(node, account);
    }

    /// @notice Writes subnode registration to the owner's `LabelStore`.
    /// @dev Keys the entry by `node` (full namehash) rather than labelhash so a single store
    ///      lookup yields the canonical full name without re-walking the parent chain.
    function _writeSubnodeToStore(
        address storeOwner,
        bytes32 node,
        string memory fullName
    )
        internal
    {
        IStoreFactory factory = IStoreFactory(protocolRegistry.get(DotnsConstants.STORE_FACTORY));
        factory.writeNewLabel(storeOwner, node, fullName);
    }

    /// @notice Computes the namehash of `parentLabel` rooted at the network's TLD node.
    /// @dev Walks the label right-to-left in calldata using memory-safe assembly to avoid the
    ///      cost of slicing into intermediate `bytes` and to keep gas linear in the label depth.
    ///      Reads the TLD node from the protocol registry, so it is a view rather than pure.
    function _parentNamehash(string calldata parentLabel) internal view returns (bytes32 node) {
        bytes calldata labels = bytes(parentLabel);
        uint256 end = labels.length;
        require(end != 0, ParentLabelMismatch());

        node = protocolRegistry.tldNode();

        while (true) {
            uint256 start = end;
            while (start > 0 && labels[start - 1] != bytes1(0x2e)) {
                unchecked {
                    --start;
                }
            }

            require(start != end, ParentLabelMismatch());

            bytes32 labelhash;
            assembly ("memory-safe") {
                let pointer := mload(0x40)
                let len := sub(end, start)
                calldatacopy(pointer, add(labels.offset, start), len)
                labelhash := keccak256(pointer, len)
                mstore(pointer, node)
                mstore(add(pointer, 0x20), labelhash)
                node := keccak256(pointer, 0x40)
            }

            if (start == 0) return node;
            end = start - 1;
        }
    }

    /// @notice Internal authorisation check for node ownership.
    /// @dev Reverts with NotAuthorised when `msg.sender` is not authorised for `node`.
    function _authorised(bytes32 node) internal view {
        require(_isAuthorised(node, msg.sender), NotAuthorised());
    }

    /// @notice Canonical authorisation rule for a node, parameterised by `account`.
    /// @dev Honours the sentinel-zero pattern: if the registry has no explicit owner, fall back
    ///      to the registrar's ERC-721 owner / approved / operator-for-all chain. This is the
    ///      single source of truth `_authorised` and `isAuthorised` both delegate to.
    function _isAuthorised(bytes32 node, address account) internal view returns (bool) {
        Record storage record = records[node];

        // Read `owner` first: a non-zero stored owner means this is a subnode with an explicit
        // owner and the existence flag is implied. The owner is compared before the ancestor walk
        // so a caller who is not the owner costs one slot read.
        address storedOwner = record.owner;
        if (storedOwner != address(0)) {
            return storedOwner == account && _isLive(node);
        }

        if (!record.exists) return false;

        IDotnsRegistrar registrar = IDotnsRegistrar(protocolRegistry.get(DotnsConstants.REGISTRAR));
        uint256 tokenId = uint256(node);
        address tokenOwner = registrar.ownerOf(tokenId);
        if (account == tokenOwner) return true;
        // Operator-for-all is the common marketplace / escrow delegation path; check it before
        // the single-token approval so the common case terminates on one STATICCALL.
        if (registrar.isApprovedForAll(tokenOwner, account)) return true;
        return registrar.getApproved(tokenId) == account;
    }

    /// @notice Returns whether `node` currently resolves.
    /// @dev A tokenised name, or a node that was never created or was deleted, carries a zero
    ///      stored owner, and resolves exactly when its record exists. A subname resolves while the
    ///      subname version it was created under is still its parent's, and its parent resolves in
    ///      turn, so the walk ends at the tokenised name above it. Clearing therefore costs the
    ///      same at any depth, and the depth is paid on reads instead. A subname with no recorded
    ///      parent ends the walk as resolving, because nothing above it can be checked, until
    ///      @custom:function linkSubname or a write through its parent links it.
    /// @param node Node identifier.
    /// @return live True when `node` resolves.
    function _isLive(bytes32 node) internal view returns (bool live) {
        while (true) {
            Record storage record = records[node];
            if (record.owner == address(0)) return record.exists;

            bytes32 parent = _parentOf[node];
            if (parent == bytes32(0)) return true;
            if (_versions[node].parentSubnames != _versions[parent].subnames) return false;
            node = parent;
        }
    }

    /// @notice Returns the number of labels in a dotted name path, which is the depth below its
    ///         second-level name of a subname created under it.
    /// @dev `path` has already passed `isNamePath`, so it has no empty segment and no leading or
    ///      trailing dot, and the count is one more than the number of dots.
    /// @param path Dotted parent path without the TLD.
    /// @return count Number of labels in `path`.
    function _labelCount(string calldata path) internal pure returns (uint256 count) {
        bytes calldata raw = bytes(path);
        count = 1;
        for (uint256 i; i < raw.length; ++i) {
            if (raw[i] == bytes1(0x2e)) ++count;
        }
    }

    /// @notice Deletes one subname of `parentNode`, its records and every subname beneath it.
    /// @dev Shared by @custom:function deleteSubname and @custom:function revokeSubname, which
    ///      differ only in who may call them. Reads no `msg.sender`, so it also runs under a Root
    ///      origin (see SystemUtils.originIsRoot).
    /// @param parentNode Parent of the subname.
    /// @param labelhash Labelhash of the subname under `parentNode`.
    function _deleteSubname(bytes32 parentNode, bytes32 labelhash) internal {
        bytes32 subnode = LabelUtils.namehashUnder(parentNode, labelhash);
        Record storage existing = records[subnode];
        // A subname a clear has already cut off can still be deleted, so the parent's holder can
        // free its storage after a clear, a release or a transfer. The callers limit this to
        // whoever controls the parent now, or to Root.
        require(existing.owner != address(0) && existing.exists, SubnameNotFound(subnode));

        // The record and the parent link are zeroed, which releases their storage deposit to the
        // signer of the transaction. A node with no record is what a node that was never created
        // looks like, so every read treats the subname as absent and every deeper subname fails
        // its walk here.
        // The versions are the one slot that stays, and are bumped rather than zeroed: a subname
        // created here again must not match the stamps of records written for this one, nor the
        // subnames created beneath it, none of which can be listed to delete.
        delete records[subnode];
        delete _parentOf[subnode];
        _clearRecordVersion(subnode);
        _clearSubnameVersion(subnode);

        emit NewOwner(parentNode, labelhash, address(0));
    }

    /// @notice Links `subnode` to `parentNode` when it is a subname with no recorded parent.
    /// @dev The caller derives `subnode` from `parentNode`, which is what proves the parent. The
    ///      subname is linked under its parent's first subname version, which is the version it
    ///      was created under: every path that creates a subname records its parent, so one with no
    ///      recorded parent was created while its parent's subname version was still zero.
    /// @param subnode The subname.
    /// @param parentNode Its parent.
    function _linkIfUnlinked(bytes32 subnode, bytes32 parentNode) internal {
        if (records[subnode].owner == address(0) || _parentOf[subnode] != bytes32(0)) return;
        _parentOf[subnode] = parentNode;
        emit SubnameLinked(subnode, parentNode);
    }

    /// @notice Clears every record of `node` and returns its resolver pointer to the default.
    /// @param node Node to clear.
    function _clearRecords(bytes32 node) internal {
        _clearRecordVersion(node);
        address reverseResolver = protocolRegistry.get(DotnsConstants.REVERSE_RESOLVER);
        records[node].resolver = reverseResolver;
        emit NewResolver(node, reverseResolver);
    }

    /// @notice Bumps the record version of `node`.
    /// @param node Node identifier.
    function _clearRecordVersion(bytes32 node) internal {
        uint64 nextVersion = ++_versions[node].records;
        emit RecordsCleared(node, nextVersion);
    }

    /// @notice Bumps the subname version of `node`.
    /// @param node Node identifier.
    function _clearSubnameVersion(bytes32 node) internal {
        uint64 nextVersion = ++_versions[node].subnames;
        emit SubnamesCleared(node, nextVersion);
    }

    /// @notice Internal check for registrar-authorised controller privileges.
    /// @dev The registry trusts every controller the registrar trusts. Routing controller
    ///      authorisation through the registrar's `controllers` mapping keeps the trust list
    ///      in one place and lets commit-reveal and PoP controllers coexist without registry
    ///      reconfiguration on each addition.
    function _onlyRegistrarController() internal view {
        IDotnsRegistrar registrar = IDotnsRegistrar(protocolRegistry.get(DotnsConstants.REGISTRAR));
        require(registrar.controllers(IDotnsController(msg.sender)), NotAuthorised());
    }

    /// @notice Returns the release this network declares it runs, read live from the protocol
    ///         registry so every dotNS contract reports one synchronised value.
    /// @dev Mirror of `IDotnsProtocolRegistry.protocolVersion`, kept under the historical
    ///      `version()` selector for ABI compatibility. It reports the network's declaration,
    ///      not this contract's build; per-contract identity is the codehash declared on the
    ///      registry.
    /// @return versionString Declared release as bare semver, empty when never declared.
    function version() external view virtual returns (string memory versionString) {
        versionString = protocolRegistry.protocolVersion();
    }
    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
