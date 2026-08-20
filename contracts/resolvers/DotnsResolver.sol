// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

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
import {DotnsConstants} from "../utils/DotnsConstants.sol";

/// @title Dotns Resolver
/// @notice Stores forward-resolution address records for DotNS nodes
/// @dev Writes are gated on node ownership in the forward registry, not on a
///      privileged writer address. Address records describe where a name points
///      and only the current node owner has the authority to set that target.
/// @custom:security-contact admin@parity.io
contract DotnsResolver is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IDotnsResolver
{
    /// @notice Protocol-level address registry for all DotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @dev Reserved storage space to allow for layout changes in the future.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[50] private __gap;

    /// @notice Node => resolved address.
    mapping(bytes32 node => address owner) private addresses;

    /// @notice Restricts access to the owner of `node` as recorded in the registry.
    /// @param node Node identifier.
    modifier onlyNodeOwner(bytes32 node) {
        _onlyNodeOwner(node);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the resolver.
    /// @dev Runs once through the UUPS proxy; a repeat call reverts with
    ///      @custom:reverts InvalidInitialization. Emits @custom:emits OwnershipTransferred when
    ///      `msg.sender` is recorded as the initial owner and @custom:emits Initialized once
    ///      setup completes.
    /// @param registry Protocol-level address registry used to resolve sibling contracts.
    function initialize(IDotnsProtocolRegistry registry) external initializer {
        __Ownable_init(msg.sender);
        __ERC165_init();
        protocolRegistry = registry;
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

    /// @notice Internal ownership check for a registry node.
    /// @dev Resolves the registry lazily through `protocolRegistry` so a registry
    ///      upgrade or rewire is picked up automatically without a resolver upgrade.
    /// @param node Node identifier.
    function _onlyNodeOwner(bytes32 node) internal view {
        IDotnsRegistry _registry = IDotnsRegistry(protocolRegistry.get(DotnsConstants.REGISTRY));
        require(_registry.owner(node) == msg.sender, NotAuthorised(node, msg.sender));
    }

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.0.0";
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
