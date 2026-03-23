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

import {IDotnsResolver} from "./IDotnsResolver.sol";
import {IDotnsRegistry} from "../registry/IDotnsRegistry.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";

/// @title Dotns Resolver
/// @notice Stores forward-resolution address records for DotNS nodes
/// @dev Maps node identifiers to a resolved address.
///      Write access is restricted to the owner of the node as recorded in the DotNS registry.
/// @custom:security-contact admin@parity.io
contract DotnsResolver is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IDotnsResolver
{
    /// @notice DEPRECATED: Registry used to resolve node ownership.
    /// @dev Retained for UUPS storage layout compatibility. Use protocolRegistry instead.
    /// TODO: Remove on fresh deploy (not upgrade). Restore __gap accordingly.
    IDotnsRegistry public registry;

    /// @notice Protocol-level address registry for all DotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @notice Well-known protocol registry key for the forward registry.
    /// casting to 'bytes32' is safe because the string fits in 32 bytes.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant KEY_REGISTRY = bytes32("registry");

    /// @dev Reserved storage space to allow for layout changes in the future.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[49] private __gap;

    /// @notice Node → resolved address
    mapping(bytes32 node => address owner) private addresses;

    /// @notice Restricts access to the owner of `node` as recorded in the registry
    /// @param node Node identifier
    modifier onlyNodeOwner(bytes32 node) {
        _onlyNodeOwner(node);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the resolver
    /// @param _registry DotNS registry used for ownership checks
    function initialize(IDotnsRegistry _registry) external initializer {
        __Ownable_init(msg.sender);
        __ERC165_init();
        registry = _registry;
    }

    /// @inheritdoc IDotnsResolver
    function setAddress(bytes32 node, address value) external override onlyNodeOwner(node) {
        addresses[node] = value;
        emit AddressSet(node, value);
    }

    /// @inheritdoc IDotnsResolver
    function addressOf(bytes32 node) external view override returns (address value) {
        return addresses[node];
    }

    /// @inheritdoc ERC165Upgradeable
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return
            interfaceId == type(IDotnsResolver).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IDotnsResolver
    function updateProtocolRegistry(IDotnsProtocolRegistry _registry) external override onlyOwner {
        protocolRegistry = _registry;
        emit ProtocolRegistryUpdated(_registry);
    }

    /// @notice Internal ownership check for a registry node
    /// @param node Node identifier
    function _onlyNodeOwner(bytes32 node) internal view {
        IDotnsRegistry _registry = IDotnsRegistry(protocolRegistry.get(KEY_REGISTRY));
        require(_registry.owner(node) == msg.sender, NotAuthorised(node, msg.sender));
    }

    /// @notice Returns implementation version
    /// @return versionString Current version string
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.1.0";
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
