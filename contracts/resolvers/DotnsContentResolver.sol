// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ERC165Upgradeable
} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";

import {IDotnsRegistry} from "../registry/IDotnsRegistry.sol";
import {IDotnsContentResolver} from "./IDotnsContentResolver.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";

/// @title Dotns Content Resolver
/// @notice Implements `IDotnsContentResolver` interface with content hash, text records, and operator approvals
/// @dev Stores opaque content hash bytes and text key-value pairs per node
///      Authorisation enforced via DotNS registry ownership or approved operators
/// @custom:security-contact admin@parity.io
contract DotnsContentResolver is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IDotnsContentResolver
{
    /// @notice DEPRECATED: Registry used for ownership checks.
    /// @dev Retained for UUPS storage layout compatibility. Use protocolRegistry instead.
    /// TODO: Remove on fresh deploy (not upgrade). Restore __gap accordingly.
    IDotnsRegistry public registry;

    /// @notice Stores all content hash mappings
    mapping(bytes32 node => bytes contentHash) private contenthashes;

    /// @notice Stores all text records
    mapping(bytes32 node => mapping(string key => string value)) private textRecords;

    /// @notice Store all approval mapping
    mapping(address owner => mapping(address operator => bool approved)) private operators;

    /// @notice Protocol-level address registry for all DotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @dev Reserved storage space to allow for layout changes in the future.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[49] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the content resolver
    /// @param _registry Address of the DotNS registry contract
    // TODO: On fresh deploy (not upgrade), accept IDotnsProtocolRegistry and set protocolRegistry here.
    function initialize(IDotnsRegistry _registry) external initializer {
        __Ownable_init(msg.sender);
        __ERC165_init();
        registry = _registry;
    }

    /// @inheritdoc IDotnsContentResolver
    function setContenthash(bytes32 node, bytes calldata hash) external override {
        _requireNodeOwnerOrOperator(node);
        contenthashes[node] = hash;
        emit ContentHashUpdated(node, hash);
    }

    /// @inheritdoc IDotnsContentResolver
    function contenthash(bytes32 node) external view override returns (bytes memory hash) {
        return contenthashes[node];
    }

    /// @inheritdoc IDotnsContentResolver
    function setText(bytes32 node, string calldata key, string calldata value) external override {
        _requireNodeOwnerOrOperator(node);
        textRecords[node][key] = value;
        emit TextUpdated(node, key, value);
    }

    /// @inheritdoc IDotnsContentResolver
    function text(
        bytes32 node,
        string calldata key
    )
        external
        view
        override
        returns (string memory value)
    {
        return textRecords[node][key];
    }

    /// @inheritdoc IDotnsContentResolver
    function setApprovalForAll(address operator, bool approved) external override {
        operators[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    /// @inheritdoc IDotnsContentResolver
    function isApprovedForAll(
        address owner,
        address operator
    )
        external
        view
        override
        returns (bool)
    {
        return operators[owner][operator];
    }

    /// @inheritdoc IDotnsContentResolver
    // TODO: On fresh deploy (not upgrade), remove this function. Set protocolRegistry in initialize instead.
    function updateProtocolRegistry(IDotnsProtocolRegistry _registry) external override onlyOwner {
        protocolRegistry = _registry;
        emit ProtocolRegistryUpdated(_registry);
    }

    /// @notice Ensures caller is either the node owner or an approved operator
    /// @param node Node identifier
    function _requireNodeOwnerOrOperator(bytes32 node) internal view {
        IDotnsRegistry _registry = IDotnsRegistry(protocolRegistry.get(DotnsConstants.REGISTRY));
        address nodeOwner = _registry.owner(node);
        require(
            msg.sender == nodeOwner || operators[nodeOwner][msg.sender],
            NotAuthorised(node, msg.sender)
        );
    }

    /// @notice Returns implementation version
    /// @return versionString Current version string
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.2.0";
    }

    /// @inheritdoc ERC165Upgradeable
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IDotnsContentResolver).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
