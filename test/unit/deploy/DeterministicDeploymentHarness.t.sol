// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDeployer} from "../../../scripts/deploy/BaseDeployer.s.sol";

/// @notice Test-only harness that exposes `BaseDeployer`'s deploy entry points so
///         test contracts can drive the same code paths the production deploy
///         pipeline uses.
/// @dev Every helper here forwards to the matching `BaseDeployer` internal
///      method so test coverage tracks the production CREATE3 flow exactly. The
///      manifest write step is skipped (no `saveDeployments` call) so harness
///      use leaves the working tree clean.
contract DeterministicDeploymentHarness is BaseDeployer {
    /// @notice Initialises the in-memory manifest at a scratch path. Required
    ///         before any deploy helper because `_broadcastDeployUups` /
    ///         `_broadcastDeployCreate3` call `logDeployment`, which needs a
    ///         baseline manifest seeded by `initDeployment`.
    function initManifest() external {
        initDeployment("__test_scratch", "deterministic");
    }

    function bootstrapCreate3Factory(address owner) external returns (address) {
        return _bootstrapCreate3Factory(owner);
    }

    function ensureCreate3Factory(address owner) external returns (address) {
        return _ensureCreate3Factory(owner);
    }

    function adoptCreate3Factory(address factory) external {
        _adoptCreate3Factory(factory);
    }

    function registerCreate3Factory(
        address owner,
        address protocolRegistry,
        address factory
    )
        external
    {
        _registerCreate3Factory(owner, protocolRegistry, factory);
    }

    function setCreate3Factory(address factory) external {
        _setCreate3Factory(factory);
    }

    function deployUups(
        address owner,
        string memory artefact,
        bytes memory initialiserCalldata,
        string memory label
    )
        external
        returns (address)
    {
        return _broadcastDeployUups(owner, artefact, initialiserCalldata, label);
    }

    function deployCreate3(
        address owner,
        string memory artefact,
        bytes memory constructorData,
        string memory label
    )
        external
        returns (address)
    {
        return _broadcastDeployCreate3(owner, artefact, constructorData, label);
    }

    function predictCreate3(
        string memory label,
        string memory kind
    )
        external
        view
        returns (address)
    {
        return _predictCreate3(label, kind);
    }
}
