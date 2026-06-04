// SPDX-License-Identifier: MIT
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

/// @title Dotns Registry
/// @author Parity
/// @notice Upgradeable on-chain registry for hierarchical name ownership and resolution.
/// @dev Tokenised second-level nodes store `owner == address(0)` as a sentinel and defer to
///      `IDotnsRegistrar.ownerOf`; subnodes carry an explicit owner address in `records`.
/// @custom:security-contact admin@parity.io
contract DotnsRegistry is Initializable, UUPSUpgradeable, OwnableUpgradeable, IDotnsRegistry {
    using StoreUtils for IStoreFactory;
    using StringUtils for *;

    /// @notice Mapping of node identifiers to records.
    mapping(bytes32 node => Record record) private records;

    /// @notice Protocol-level address registry for all DotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

    uint256[50] private __gap;

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
    /// @param registry Protocol-level address registry used to resolve sibling contracts.
    function initialize(IDotnsProtocolRegistry registry) external initializer {
        __Ownable_init(msg.sender);

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
        if (existing.exists) {
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

            if (newOwner != previousOwner) {
                string memory fullName =
                    string.concat(subLabel, ".", parentLabel, DotnsConstants.TLD);
                _writeSubnodeToStore(newOwner, subnode, fullName);
            }
        } else {
            records[subnode] = Record({owner: newOwner, resolver: reverseResolver, exists: true});
            string memory fullName = string.concat(subLabel, ".", parentLabel, DotnsConstants.TLD);
            _writeSubnodeToStore(newOwner, subnode, fullName);
        }

        emit NewOwner(parentNode, labelhash, newOwner);
    }

    /// @inheritdoc IDotnsRegistry
    function setOwner(bytes32 node, address newOwner) external override onlyRegistrarController {
        require(newOwner != address(0), NotAllowed());
        IDotnsRegistrar registrar = IDotnsRegistrar(protocolRegistry.get(DotnsConstants.REGISTRAR));
        require(registrar.ownerOf(uint256(node)) == newOwner, NotAuthorised());

        // The resolver pointer is unconditionally reset to the default reverse resolver on every
        // call so a prior owner's resolver cannot follow the name into the new holder's hands on
        // reclaim from escrow. Owner remains the zero sentinel so reads delegate to the
        // registrar's ERC-721 holder.
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
        Record storage existing = records[subnode];
        require(existing.exists, NotAuthorised());

        existing.resolver = record.resolver;
        emit NewResolver(subnode, record.resolver);
    }

    /// @inheritdoc IDotnsRegistry
    function owner(bytes32 node) external view override returns (address) {
        Record storage record = records[node];
        // Read `owner` first: a non-zero stored owner proves the record exists and is a subnode,
        // collapsing the lookup to a single SLOAD. The slower `exists` SLOAD only runs on the
        // tokenised-or-missing branch.
        address storedOwner = record.owner;
        if (storedOwner != address(0)) return storedOwner;
        if (!record.exists) return address(0);
        IDotnsRegistrar registrar = IDotnsRegistrar(protocolRegistry.get(DotnsConstants.REGISTRAR));
        return registrar.ownerOf(uint256(node));
    }

    /// @inheritdoc IDotnsRegistry
    function resolver(bytes32 node) external view override returns (address) {
        return records[node].resolver;
    }

    /// @inheritdoc IDotnsRegistry
    function recordExists(bytes32 node) external view override returns (bool) {
        return records[node].exists;
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
        factory.writeLabel(storeOwner, node, fullName);
    }

    /// @notice Computes the namehash of `parentLabel` rooted at the configured TLD.
    /// @dev Walks the label right-to-left in calldata using memory-safe assembly to avoid the
    ///      cost of slicing into intermediate `bytes` and to keep gas linear in the label depth.
    function _parentNamehash(string calldata parentLabel) internal pure returns (bytes32 node) {
        bytes calldata labels = bytes(parentLabel);
        uint256 end = labels.length;
        require(end != 0, ParentLabelMismatch());

        node = DotnsConstants.DOT_NODE;

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
    /// @dev Honours the sentinel-zero pattern: if the registry has no explicit owner, fall back
    ///      to the registrar's ERC-721 owner / approved / operator-for-all chain.
    function _authorised(bytes32 node) internal view {
        Record storage record = records[node];

        // Read `owner` first: a non-zero stored owner means this is a subnode with an explicit
        // owner and the existence flag is implied. Skipping the `exists` SLOAD on the common
        // subnode path saves one slot read.
        address storedOwner = record.owner;
        if (storedOwner != address(0)) {
            require(storedOwner == msg.sender, NotAuthorised());
            return;
        }

        require(record.exists, NotAuthorised());

        IDotnsRegistrar registrar = IDotnsRegistrar(protocolRegistry.get(DotnsConstants.REGISTRAR));
        uint256 tokenId = uint256(node);
        address tokenOwner = registrar.ownerOf(tokenId);
        if (msg.sender == tokenOwner) return;
        // Operator-for-all is the common marketplace / escrow delegation path; check it before
        // the single-token approval so the common case terminates on one STATICCALL.
        if (registrar.isApprovedForAll(tokenOwner, msg.sender)) return;
        require(registrar.getApproved(tokenId) == msg.sender, NotAuthorised());
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

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.0.0";
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
