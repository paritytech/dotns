// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IDotnsCostModelRegistry} from "./IDotnsCostModelRegistry.sol";
import {IDotnsPricing} from "./IDotnsPricing.sol";

/// @title DotNS Cost Model Registry
/// @notice Keeps every registered cost model addressable by version and tracks the current one.
/// @dev Holds only pointers, so it stays a plain owner-gated contract. `PopRules` resolves it once
///      through `DotnsConstants.COST_MODEL` and prices the current version for fresh reads and a
///      specific version for in-flight registrations.
/// @custom:security-contact admin@parity.io
contract DotnsCostModelRegistry is Ownable, IDotnsCostModelRegistry {
    /// @inheritdoc IDotnsCostModelRegistry
    mapping(uint256 version => IDotnsPricing model) public override modelOf;

    /// @inheritdoc IDotnsCostModelRegistry
    uint256 public override currentVersion;

    /// @notice Sets the owner permitted to register models.
    /// @param owner_ Address that governs the model set.
    constructor(address owner_) Ownable(owner_) {}

    /// @inheritdoc IDotnsCostModelRegistry
    function register(IDotnsPricing model) external override onlyOwner {
        uint256 version = model.version();
        require(version != 0, ZeroVersion());
        require(address(modelOf[version]) == address(0), AlreadyRegistered(version));
        modelOf[version] = model;
        currentVersion = version;
        emit CostModelRegistered(version, address(model));
    }

    /// @inheritdoc IDotnsCostModelRegistry
    function setCurrentVersion(uint256 version) external override onlyOwner {
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
