// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
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

/// @title dotNS Resolver
/// @notice Stores forward-resolution address records for dotNS nodes
/// @dev Writes are gated on node ownership in the forward registry, not on a
///      privileged writer address. Address records describe where a name points
///      and only the current node owner has the authority to set that target.
///      Each record is stamped with the node's record version from the registry
///      (@custom:function IDotnsRegistry.recordVersion), and a read returns the zero address
///      unless the node still resolves and the stamp is current. That is how a cleared name, or
///      a name beneath a cleared one, stops resolving without its records being visited.
/// @custom:security-contact admin@parity.io
contract DotnsResolver is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IDotnsResolver
{
    /// @notice Protocol-level address registry for all dotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @dev Reserved storage space to allow for layout changes in the future.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[50] private __gap;

    /// @notice Node => resolved address.
    mapping(bytes32 node => address owner) private addresses;

    /// @notice Node => registry record version its address was written under.
    /// @dev Zero for every record written before stamps existed, which matches the version every
    ///      node starts at, so those records stay readable until the node is first cleared.
    mapping(bytes32 node => uint64 version) private addressVersions;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the resolver.
    /// @dev Runs once through the UUPS proxy; a repeat call reverts with
    ///      @custom:reverts InvalidInitialization. Emits @custom:emits OwnershipTransferred when
    ///      `msg.sender` is recorded as the initial owner and @custom:emits Initialized once
    ///      setup completes.
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
        __ERC165_init();
        protocolRegistry = registry;
    }

    /// @inheritdoc IDotnsResolver
    function setAddress(bytes32 node, address value) external override {
        IDotnsRegistry registry = _onlyNodeOwner(node);
        if (value == address(0)) {
            // A zero address is a delete: both slots are zeroed so their storage deposit is
            // released to the caller, rather than a zero being stamped under a new version.
            delete addresses[node];
            delete addressVersions[node];
        } else {
            (, uint64 currentVersion) = registry.recordVersion(node);
            addresses[node] = value;
            if (addressVersions[node] != currentVersion) addressVersions[node] = currentVersion;
        }
        emit AddressSet(node, value);
    }

    /// @inheritdoc IDotnsResolver
    function addressOf(bytes32 node) external view override returns (address value) {
        (bool live, uint64 currentVersion) = _registry().recordVersion(node);
        if (!live || addressVersions[node] != currentVersion) return address(0);
        return addresses[node];
    }

    /// @inheritdoc ERC165Upgradeable
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return
            interfaceId == type(IDotnsResolver).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice Internal ownership check for a registry node.
    /// @param node Node identifier.
    /// @return registry The forward registry, returned so the caller reads it once.
    function _onlyNodeOwner(bytes32 node) internal view returns (IDotnsRegistry registry) {
        registry = _registry();
        require(registry.owner(node) == msg.sender, NotAuthorised(node, msg.sender));
    }

    /// @notice Returns the forward registry.
    /// @dev Resolved lazily through `protocolRegistry` so a registry upgrade or rewire is picked
    ///      up automatically without a resolver upgrade.
    /// @return registry The forward registry.
    function _registry() internal view returns (IDotnsRegistry registry) {
        registry = IDotnsRegistry(protocolRegistry.get(DotnsConstants.REGISTRY));
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
