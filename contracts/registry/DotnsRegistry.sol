// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IDotnsRegistry} from "./IDotnsRegistry.sol";
import {IDotnsRegistrarController} from "../registrars/IDotnsRegistrarController.sol";
import {IDotnsReverseResolver} from "../resolvers/IDotnsReverseResolver.sol";

/// @title Dot Registry
/// @notice Upgradeable on-chain registry for hierarchical name ownership and resolution.
/// @dev Stores ownership and resolver data for DotNS nodes.
///      Authorisation is enforced strictly via node ownership, except for privileged ownership writes
///      performed by a designated `registrarController`.
/// @custom:security-contact admin@parity.io
contract DotnsRegistry is Initializable, UUPSUpgradeable, OwnableUpgradeable, IDotnsRegistry {
    /// @notice Mapping of node identifiers to records.
    mapping(bytes32 node => Record record) private records;

    /// @notice Address authorised to perform privileged ownership writes
    /// @dev Typically the DotnsRegistrarController proxy address.
    IDotnsRegistrarController public registrarController;
    /// @notice DotNS Reverse Resolver
    IDotnsReverseResolver public reverseResolver;

    /// @dev Reserved storage space to allow for layout changes in the future.
    // forge-lint: disable-next-line(mixed-case-variable)
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
    /// @param _reverseResolver Address of the DotNS reverse resolver contract.
    /// @dev Sets the deployer as the owner and initializes the root node (bytes32(0)).
    ///      Root node owner is set to the initializer caller.
    function initialize(IDotnsReverseResolver _reverseResolver) external initializer {
        __Ownable_init(msg.sender);
        reverseResolver = _reverseResolver;
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

        registrarController.writeSubnodeToStore(record);

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
        require(newOwner != address(0), NotRegistryController());
        require(!records[node].exists, NodeAlreadyOwned(node));

        records[node].owner = newOwner;
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
        return records[node].owner;
    }

    /// @inheritdoc IDotnsRegistry
    function resolver(bytes32 node) external view override returns (address) {
        return records[node].resolver;
    }

    /// @inheritdoc IDotnsRegistry
    function recordExists(bytes32 node) external view override returns (bool) {
        return records[node].exists;
    }

    /// @notice Internal authorisation check for node ownership.
    /// @param node Node identifier.
    function _authorised(bytes32 node) internal view {
        require(records[node].owner == msg.sender, NotAuthorised());
    }

    /// @notice Internal check for registrar controller privileges.
    function _onlyRegistrarController() internal view {
        require(IDotnsRegistrarController(msg.sender) == registrarController, NotAuthorised());
    }

    /// @notice Returns implementation version
    /// @return versionString Current version string
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.0.0";
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
