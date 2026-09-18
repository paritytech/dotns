// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IDotnsPricingOld} from "./IDotnsPricingOld.sol";

/// @title DotNS Cost Model Registry
/// @notice Holds every cost model the protocol has run and names the current one.
/// @dev The address registered under `DotnsConstantsOld.COST_MODEL` points here, set once and never
///      repointed. Changing the live curve registers a new model, which adds its version and moves
///      the current pointer. Prior models stay live and priceable by version, so a registration
///      committed against an earlier curve settles at the amount it committed to.
/// @custom:security-contact admin@parity.io
interface IDotnsCostModelRegistryOld {
    /// @notice Emitted when a model is registered and becomes current.
    /// @param version The model's version identifier.
    /// @param model The model address now serving that version.
    event CostModelRegistered(uint256 indexed version, address indexed model);

    /// @notice Emitted when the current version is pointed at an already-registered model.
    /// @param version The version now serving fresh pricing.
    event CurrentModelSet(uint256 indexed version);

    /// @notice Thrown when registering a model whose version is already held.
    /// @param version The version already registered.
    error AlreadyRegistered(uint256 version);

    /// @notice Thrown when pricing against a version that was never registered.
    /// @param version The version with no registered model.
    error UnknownVersion(uint256 version);

    /// @notice Thrown when registering a model whose version is zero, which is the sentinel for
    ///         an unregistered version and so cannot name a real model.
    error ZeroVersion();

    /// @notice Thrown when a registration reveals at a different version than it committed to.
    /// @dev Raised where a commit-reveal flow binds a version at commit and checks it at reveal, so
    ///      the version a name prices at cannot move after the commitment is made.
    /// @param committed The version bound when the commitment was made.
    /// @param revealed The version supplied at reveal.
    error PricingVersionMismatch(uint256 committed, uint256 revealed);

    /// @notice Registers a model and makes it current.
    /// @dev Owner-only. Keys the model by its own `version`, so a version can be registered once;
    ///      a repeat triggers @custom:reverts AlreadyRegistered. Moves the current pointer to the
    ///      new version and emits @custom:emits CostModelRegistered.
    /// @param model The cost model to register.
    function register(IDotnsPricingOld model) external;

    /// @notice Points the current version at an already-registered model.
    /// @dev Owner-only. Reverts to a previously registered version without redeploying it, so
    ///      governance can roll fresh pricing back to an earlier curve. @custom:reverts
    ///      UnknownVersion when no model is registered for `version`. Emits @custom:emits
    ///      CurrentModelSet.
    /// @param version The already-registered version to make current.
    function setCurrentVersion(uint256 version) external;

    /// @notice Returns the model registered for a version, or the zero address when none.
    /// @param version The version to look up.
    /// @return model The model registered for that version.
    function modelOf(uint256 version) external view returns (IDotnsPricingOld model);

    /// @notice Returns the version currently serving fresh pricing.
    /// @return version The current version identifier.
    function currentVersion() external view returns (uint256 version);

    /// @notice Returns the current model.
    /// @return model The model serving the current version.
    function current() external view returns (IDotnsPricingOld model);

    /// @notice Prices a base length at the current version.
    /// @param baseLength Digit-stripped length of the label being priced.
    /// @return weiPrice Registration cost in wei at the current version.
    function priceForBaseLength(uint256 baseLength) external view returns (uint256 weiPrice);

    /// @notice Prices a base length at a specific version.
    /// @dev @custom:reverts UnknownVersion when no model is registered for `version`.
    /// @param version The version to price against.
    /// @param baseLength Digit-stripped length of the label being priced.
    /// @return weiPrice Registration cost in wei at that version.
    function priceForBaseLengthAtVersion(
        uint256 version,
        uint256 baseLength
    )
        external
        view
        returns (uint256 weiPrice);
}
