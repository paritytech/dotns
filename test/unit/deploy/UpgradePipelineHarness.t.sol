// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {UpgradeBase} from "../../../scripts/deploy/UpgradeBase.s.sol";

/// @notice Test-only harness exposing `UpgradeBase`'s internals so the upgrade pipeline's
///         decision paths can be driven directly.
/// @dev Every helper forwards to the matching internal, so coverage tracks the production
///      upgrade flow rather than a re-implementation of it.
contract UpgradePipelineHarness is UpgradeBase {
    function upgradeProxy(
        address owner,
        address protocolRegistry,
        bytes32 key,
        string memory artefact,
        string memory label,
        bytes memory postUpgradeCall
    )
        external
    {
        _upgradeProxy(owner, protocolRegistry, key, artefact, label, postUpgradeCall);
    }

    function prepareBeaconRotation(
        address owner,
        address beacon,
        string memory artefact,
        string memory label
    )
        external
        returns (address)
    {
        return _prepareBeaconRotation(owner, beacon, artefact, label);
    }

    function deployImplementation(string memory artefact) external returns (address) {
        return _deployImplementation(artefact);
    }

    function implementationOf(address proxy) external view returns (address) {
        return _implementationOf(proxy);
    }

    function basename(string memory path) external pure returns (string memory) {
        return _basename(path);
    }

    function upgradedCount() external view returns (uint256) {
        return _upgradedCount;
    }

    function unchangedCount() external view returns (uint256) {
        return _unchangedCount;
    }
}
