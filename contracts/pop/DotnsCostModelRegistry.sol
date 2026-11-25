// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IDotnsCostModelRegistry} from "./IDotnsCostModelRegistry.sol";
import {IDotnsPricing} from "./IDotnsPricing.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {SystemUtils} from "../utils/SystemUtils.sol";

/// @title dotNS Cost Model Registry
/// @notice Keeps every registered cost model addressable by version and tracks the current one.
/// @dev Holds only pointers, so it is not upgradeable. `PopRules` resolves it through
///      `DotnsConstants.COST_MODEL` and prices the current version for fresh reads and a specific
///      version for in-flight registrations. Governed by Root, or by the bootstrap owner of its
///      protocol registry while one is set, with the same rules as
///      @custom:contract ProtocolOwnedUpgradeable: it keeps no owner of its own, and `msg.sender`
///      is read only when the caller is not Root.
/// @custom:security-contact admin@parity.io
contract DotnsCostModelRegistry is IDotnsCostModelRegistry {
    /// @notice Thrown when the caller is neither Root nor the bootstrap owner.
    /// @param account The caller.
    error OwnableUnauthorizedAccount(address account);

    /// @notice Thrown by the constructor for a zero protocol registry.
    error ZeroProtocolRegistry();

    /// @notice The protocol registry that holds the bootstrap owner.
    IDotnsProtocolRegistry public immutable protocolRegistry;

    /// @inheritdoc IDotnsCostModelRegistry
    mapping(uint256 version => IDotnsPricing model) public override modelOf;

    /// @inheritdoc IDotnsCostModelRegistry
    uint256 public override currentVersion;

    /// @notice Restricts a call to Root, or to the bootstrap owner while one is set.
    modifier onlyRootOrOwner() {
        if (!SystemUtils.tryCallerIsRoot()) {
            require(msg.sender == owner(), OwnableUnauthorizedAccount(msg.sender));
        }
        _;
    }

    /// @notice Binds the registry to the protocol registry that holds its bootstrap owner.
    /// @param registry Protocol registry of this deployment.
    constructor(IDotnsProtocolRegistry registry) {
        require(address(registry) != address(0), ZeroProtocolRegistry());
        protocolRegistry = registry;
    }

    /// @notice Returns the bootstrap owner, read from the protocol registry.
    /// @return owner_ The protocol registry's owner, or zero once it is renounced.
    function owner() public view returns (address owner_) {
        return OwnableUpgradeable(address(protocolRegistry)).owner();
    }

    /// @inheritdoc IDotnsCostModelRegistry
    function register(IDotnsPricing model) external override onlyRootOrOwner {
        uint256 version = model.version();
        require(version != 0, ZeroVersion());
        require(address(modelOf[version]) == address(0), AlreadyRegistered(version));
        modelOf[version] = model;
        currentVersion = version;
        emit CostModelRegistered(version, address(model));
    }

    /// @inheritdoc IDotnsCostModelRegistry
    function setCurrentVersion(uint256 version) external override onlyRootOrOwner {
        require(address(modelOf[version]) != address(0), UnknownVersion(version));
        currentVersion = version;
        emit CurrentModelSet(version);
    }

    /// @inheritdoc IDotnsCostModelRegistry
    function current() external view override returns (IDotnsPricing model) {
        return modelOf[currentVersion];
    }

    /// @inheritdoc IDotnsCostModelRegistry
    function priceForBaseLength(uint256 baseLength)
        external
        view
        override
        returns (uint256 weiPrice)
    {
        IDotnsPricing model = modelOf[currentVersion];
        require(address(model) != address(0), UnknownVersion(currentVersion));
        return model.priceForBaseLength(baseLength);
    }

    /// @inheritdoc IDotnsCostModelRegistry
    function priceForBaseLengthAtVersion(
        uint256 version,
        uint256 baseLength
    )
        external
        view
        override
        returns (uint256 weiPrice)
    {
        IDotnsPricing model = modelOf[version];
        require(address(model) != address(0), UnknownVersion(version));
        return model.priceForBaseLength(baseLength);
    }
}
