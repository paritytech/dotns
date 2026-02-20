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

    /// @notice Mapping of node identifiers to records.
    mapping(bytes32 node => Record record) private records;

    /// @notice Address authorised to perform privileged node writes.
    IDotnsRegistrarController public registrarController;

    /// @notice ERC721 registrar backing base node ownership.
    IDotnsRegistrar public dotnsRegistrar;

    /// @notice DotNS reverse resolver.
    IDotnsReverseResolver public reverseResolver;

    /// @notice Factory for per-user Store instances.
    IStoreFactory public storeFactory;

    /// @notice Key prefix for Dotns-written Store immutable entries ("dotns.registered").
    /// casting to 'bytes32' is safe because this is safe
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant DOTNS_REGISTERED_KEY = bytes32("dotns.registered");

    /// @dev Reserved storage space to allow for layout changes in the future.
    uint256[50] private __gap;

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
    function updateRegistrarController(IDotnsRegistrarController newRegistrarController)
        external
        override
        onlyOwner
    {
        require(address(newRegistrarController) != address(0), NotAllowed());
        emit RegistrarControllerUpdated(registrarController, newRegistrarController);
        registrarController = newRegistrarController;
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

        bytes32 labelhash;
        assembly {
            let freeMemoryPointer := mload(0x40)
            let labelLength := subLabel.length
            calldatacopy(freeMemoryPointer, subLabel.offset, labelLength)
            labelhash := keccak256(freeMemoryPointer, labelLength)
        }

        assembly {
            let freeMemoryPointer := mload(0x40)
            mstore(freeMemoryPointer, parentNode)
            mstore(add(freeMemoryPointer, 0x20), labelhash)
            subnode := keccak256(freeMemoryPointer, 0x40)
        }

        require(!records[subnode].exists, NodeAlreadyExists(subnode));

        records[subnode] =
            Record({owner: newOwner, resolver: address(reverseResolver), exists: true});

        _writeSubnodeToStore(record, labelhash);

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
        address tokenOwner = dotnsRegistrar.ownerOf(uint256(node));
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
        return dotnsRegistrar.ownerOf(uint256(node));
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
    /// @param record Subnode record containing owner and label information.
    /// @param labelhash Precomputed keccak256 hash of the sublabel.
    function _writeSubnodeToStore(SubnodeRecord calldata record, bytes32 labelhash) internal {
        address[] memory controllers = new address[](1);
        controllers[0] = address(this);

        Store store = storeFactory.getOrCreateStore(controllers, record.owner);

        bytes32 storeKey = _storeKey(record.parentNode, labelhash);
        string memory fullName = string.concat(record.subLabel, ".", record.parentLabel, ".dot");

        store.setValueFor(record.owner, storeKey, fullName);
    }

    /// @notice Computes keccak256("dotns.registered", parentNode, labelhash).
    /// @param parentNode The parent node hash.
    /// @param labelhash keccak256(label).
    /// @return key Store key used for DotNS-written subnode registration entry.
    function _storeKey(bytes32 parentNode, bytes32 labelhash) internal pure returns (bytes32 key) {
        bytes32 prefix = DOTNS_REGISTERED_KEY;
        assembly {
            let pointer := mload(0x40)
            mstore(pointer, prefix)
            mstore(add(pointer, 0x20), parentNode)
            mstore(add(pointer, 0x40), labelhash)
            key := keccak256(pointer, 0x60)
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

        uint256 tokenId = uint256(node);
        address tokenOwner = dotnsRegistrar.ownerOf(tokenId);

        if (msg.sender == tokenOwner) return;

        address approved = dotnsRegistrar.getApproved(tokenId);
        if (approved == msg.sender) return;

        bool approvedForAll = dotnsRegistrar.isApprovedForAll(tokenOwner, msg.sender);
        require(approvedForAll, NotAuthorised());
    }

    /// @notice Internal check for registrar controller privileges.
    function _onlyRegistrarController() internal view {
        require(IDotnsRegistrarController(msg.sender) == registrarController, NotAuthorised());
    }

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.0.0";
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
