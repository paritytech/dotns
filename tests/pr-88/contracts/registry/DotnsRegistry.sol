// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IDotnsRegistry} from "./IDotnsRegistry.sol";
import {IDotnsRegistrarController} from "../registrars/IDotnsRegistrarController.sol";
import {IDotnsRegistrar} from "../registrars/IDotnsRegistrar.sol";
import {IDotnsReverseResolver} from "../resolvers/IDotnsReverseResolver.sol";
import {IStoreFactory} from "../store/IStoreFactory.sol";
import {Store} from "../store/Store.sol";
import {StoreUtils} from "../utils/StoreUtils.sol";
import {IDotnsProtocolRegistry} from "./IDotnsProtocolRegistry.sol";
import {StringUtils} from "../utils/StringUtils.sol";

/// @title Dotns Registry
/// @notice Upgradeable on-chain registry for hierarchical name ownership and resolution.
/// @dev Stores ownership and resolver data for DotNS nodes.
///      Explicit ownership is stored for subnodes.
///      Tokenised base nodes use the sentinel owner pattern:
///      - records[node].owner == address(0) means ownership is derived from the ERC721 registrar.
///      Authorisation for tokenised nodes follows ERC721 owner/approvals.
/// @custom:security-contact admin@parity.io
contract DotnsRegistry is Initializable, UUPSUpgradeable, OwnableUpgradeable, IDotnsRegistry {
    using StoreUtils for IStoreFactory;
    using StringUtils for *;

    bytes32 private constant DOT_NODE =
        0x3fce7d1364a893e213bc4212792b517ffc88f5b13b86c8ef9c8d390c3a1370ce;

    /// @notice Mapping of node identifiers to records.
    mapping(bytes32 node => Record record) private records;

    /// @notice DEPRECATED: Address authorised to perform privileged node writes.
    /// @dev Retained for UUPS storage layout compatibility. Use protocolRegistry instead.
    /// TODO: Remove on fresh deploy (not upgrade). Restore __gap accordingly.
    IDotnsRegistrarController public registrarController;

    /// @notice DEPRECATED: ERC721 registrar backing base node ownership.
    /// @dev Retained for UUPS storage layout compatibility. Use protocolRegistry instead.
    /// TODO: Remove on fresh deploy (not upgrade). Restore __gap accordingly.
    IDotnsRegistrar public dotnsRegistrar;

    /// @notice DEPRECATED: DotNS reverse resolver.
    /// @dev Retained for UUPS storage layout compatibility. Use protocolRegistry instead.
    /// TODO: Remove on fresh deploy (not upgrade). Restore __gap accordingly.
    IDotnsReverseResolver public reverseResolver;

    /// @notice DEPRECATED: Factory for per-user Store instances.
    /// @dev Retained for UUPS storage layout compatibility. Use protocolRegistry instead.
    /// TODO: Remove on fresh deploy (not upgrade). Restore __gap accordingly.
    IStoreFactory public storeFactory;

    /// @notice Key prefix for Dotns-written Store immutable entries ("dotns.registered").
    /// casting to 'bytes32' is safe because this is safe
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant DOTNS_REGISTERED_KEY = bytes32("dotns.registered");

    /// @notice Protocol-level address registry for all DotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @notice Well-known protocol registry key for the registrar controller.
    /// casting to 'bytes32' is safe because the string fits in 32 bytes.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant KEY_CONTROLLER = bytes32("controller");

    /// @notice Well-known protocol registry key for the ERC721 registrar.
    /// casting to 'bytes32' is safe because the string fits in 32 bytes.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant KEY_REGISTRAR = bytes32("registrar");

    /// @notice Well-known protocol registry key for the reverse resolver.
    /// casting to 'bytes32' is safe because the string fits in 32 bytes.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant KEY_REVERSE_RESOLVER = bytes32("reverseResolver");

    /// @notice Well-known protocol registry key for the store factory.
    /// casting to 'bytes32' is safe because the string fits in 32 bytes.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant KEY_STORE_FACTORY = bytes32("storeFactory");

    /// @dev Reserved storage space to allow for layout changes in the future.
    uint256[49] private __gap;

    /// @notice Restricts access to the current owner of `node`.
    /// @param node Node identifier.
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

    /// @notice Initializes the registry.
    /// @param _registrar Address of the ERC721 registrar for base nodes.
    /// @param _reverseResolver Address of the Dotns reverse resolver contract.
    /// @param _factory Store factory used for per-user deployment stores.
    function initialize(
        IDotnsRegistrar _registrar,
        IDotnsReverseResolver _reverseResolver,
        IStoreFactory _factory
    )
        external
        initializer
    {
        __Ownable_init(msg.sender);

        require(address(_registrar) != address(0), NotAllowed());
        require(address(_reverseResolver) != address(0), NotAllowed());
        require(address(_factory) != address(0), NotAllowed());

        dotnsRegistrar = _registrar;
        reverseResolver = _reverseResolver;
        storeFactory = _factory;

        records[bytes32(0)] = Record({owner: msg.sender, resolver: address(0), exists: true});
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

        bytes32 labelhash = _labelhash(subLabel);
        subnode = _namehash(parentNode, labelhash);

        require(!records[subnode].exists, NodeAlreadyExists(subnode));

        address _reverseResolver = protocolRegistry.get(KEY_REVERSE_RESOLVER);
        records[subnode] = Record({owner: newOwner, resolver: _reverseResolver, exists: true});

        _writeSubnodeToStore(
            record.owner, subnode, string.concat(subLabel, ".", parentLabel, ".dot")
        );

        emit NewOwner(parentNode, labelhash, newOwner);
    }

    /// @inheritdoc IDotnsRegistry
    function setOwner(
        bytes32 node,
        address newOwner,
        address resolverAddr
    )
        external
        override
        onlyRegistrarController
    {
        require(newOwner != address(0), NotAllowed());
        require(!records[node].exists, NodeAlreadyOwned(node));
        IDotnsRegistrar registrar = IDotnsRegistrar(protocolRegistry.get(KEY_REGISTRAR));
        address tokenOwner = registrar.ownerOf(uint256(node));
        require(tokenOwner == newOwner, NotAuthorised());

        records[node].owner = address(0);
        records[node].resolver = resolverAddr;
        records[node].exists = true;

        emit NodeTransferred(node, newOwner);
    }

    /// @inheritdoc IDotnsRegistry
    function setResolver(bytes32 node, address newResolver) external override authorised(node) {
        records[node].resolver = newResolver;
        emit NewResolver(node, newResolver);
    }

    /// @inheritdoc IDotnsRegistry
    function owner(bytes32 node) external view override returns (address) {
        Record storage record = records[node];
        if (!record.exists) return address(0);
        if (record.owner != address(0)) return record.owner;
        IDotnsRegistrar registrar = IDotnsRegistrar(protocolRegistry.get(KEY_REGISTRAR));
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

    /// @notice Writes subnode registration to the owner's Store.
    /// @dev Acquires or deploys a Store for the owner, then writes the full subnode name.
    /// @param storeOwner Subnode owner whose Store receives the record.
    /// @param node Derived subnode identifier.
    /// @param fullName Canonical full subnode name.
    function _writeSubnodeToStore(
        address storeOwner,
        bytes32 node,
        string memory fullName
    )
        internal
    {
        address[] memory controllers = new address[](1);
        controllers[0] = address(this);

        IStoreFactory factory = IStoreFactory(protocolRegistry.get(KEY_STORE_FACTORY));
        Store store = factory.getOrCreateStore(controllers, storeOwner);

        bytes32 storeKey = _storeKey(node);
        store.setValueFor(storeOwner, storeKey, fullName);
    }

    /// @notice Computes keccak256("dotns.registered", labelhash).
    /// @param labelhash keccak256(label).
    /// @return key Store key used for DotNS-written registration entry.
    function _storeKey(bytes32 labelhash) internal pure returns (bytes32 key) {
        bytes32 prefix = DOTNS_REGISTERED_KEY;
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, prefix)
            mstore(add(pointer, 0x20), labelhash)
            key := keccak256(pointer, 0x40)
        }
    }

    function _labelhash(string calldata label) internal pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            let len := label.length
            calldatacopy(pointer, label.offset, len)
            hash := keccak256(pointer, len)
        }
    }

    function _namehash(bytes32 parentNode, bytes32 labelhash) internal pure returns (bytes32 node) {
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, parentNode)
            mstore(add(pointer, 0x20), labelhash)
            node := keccak256(pointer, 0x40)
        }
    }

    function _parentNamehash(string calldata parentLabel) internal pure returns (bytes32 node) {
        bytes calldata labels = bytes(parentLabel);
        uint256 end = labels.length;
        require(end != 0, ParentLabelMismatch());

        node = DOT_NODE;

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
    /// @dev For explicit-owner nodes, caller must equal stored owner.
    ///      For tokenised nodes (sentinel owner), caller must be ERC721 owner or approved.
    /// @param node Node identifier.
    function _authorised(bytes32 node) internal view {
        Record storage record = records[node];
        require(record.exists, NotAuthorised());

        address storedOwner = record.owner;
        if (storedOwner != address(0)) {
            require(storedOwner == msg.sender, NotAuthorised());
            return;
        }

        IDotnsRegistrar registrar = IDotnsRegistrar(protocolRegistry.get(KEY_REGISTRAR));
        uint256 tokenId = uint256(node);
        address tokenOwner = registrar.ownerOf(tokenId);

        if (msg.sender == tokenOwner) return;

        address approved = registrar.getApproved(tokenId);
        if (approved == msg.sender) return;

        bool approvedForAll = registrar.isApprovedForAll(tokenOwner, msg.sender);
        require(approvedForAll, NotAuthorised());
    }

    /// @inheritdoc IDotnsRegistry
    function updateProtocolRegistry(IDotnsProtocolRegistry registry) external override onlyOwner {
        protocolRegistry = registry;
        emit ProtocolRegistryUpdated(registry);
    }

    /// @notice Internal check for registrar controller privileges.
    function _onlyRegistrarController() internal view {
        address controller = protocolRegistry.get(KEY_CONTROLLER);
        require(msg.sender == controller, NotAuthorised());
    }

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.2.0";
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
