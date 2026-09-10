// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title UpgradeRegistry
/// @notice Upgrades the deployed DotnsRegistry proxy to the current implementation. Resolves the
///         proxy from the on-disk manifest, diffs the new storage layout against the pinned
///         @custom:contract DotnsRegistryOld snapshot, and swaps the implementation only when the
///         diff and every unsafe-pattern check pass.
/// @dev PR-scoped. This script, the `DotnsRegistryOld` snapshot it references, and the paired
///      `test/fork/UpgradeRegistry.t.sol` are deleted before merge per the upgrade-PR workflow in
///      CONTRIBUTING.md. The storage-layout reference is always supplied, so the layout diff is
///      mandatory: there is no environment switch that turns it off, and the run fails closed if a
///      slot moves, shrinks, or changes type.
/// @custom:security-contact admin@parity.io
contract UpgradeRegistry is BaseDeployer {
    /// @notice Pre-upgrade snapshot the layout diff compares the new implementation against.
    /// @dev Source-file route, not a stored build-info directory, so the snapshot is versioned
    ///      beside the implementation and rebuilt by `forge build`. Deleted before merge.
    string internal constant REFERENCE_CONTRACT = "DotnsRegistryOld.sol:DotnsRegistryOld";

    /// @notice Manifest label the registry proxy is recorded under.
    string internal constant REGISTRY_LABEL = "DotnsRegistry";

    /// @notice Reads the manifest, resolves the registry proxy, and upgrades it as `msg.sender`.
    /// @dev `msg.sender` must own the proxy, otherwise the `_authorizeUpgrade` owner gate reverts.
    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        address proxy = _readAddress(REGISTRY_LABEL);
        _upgradeRegistry(owner, proxy);

        console.log("=== UpgradeRegistry complete ===");
    }

    /// @notice Upgrades `proxy` to the current `DotnsRegistry` implementation under `owner`.
    /// @dev The layout diff runs inside `Upgrades.upgradeProxy` before the implementation swap. No
    ///      `unsafeSkipAllChecks` or `unsafeAllow` override is set, so an incompatible layout
    /// aborts the run rather than corrupting state. An empty upgrade call is passed because the new
    ///      implementation seeds no storage: the `persist` field it adds lives on the calldata
    ///      `SubnodeRecord`, not in a storage slot, so every existing record and gap slot is
    ///      preserved unchanged.
    /// @param owner Account that owns the proxy and broadcasts the upgrade.
    /// @param proxy Registry proxy address resolved from the manifest.
    function _upgradeRegistry(address owner, address proxy) internal {
        require(
            owner == OwnableUpgradeable(proxy).owner(),
            "UpgradeRegistry: broadcaster is not the proxy owner"
        );

        Options memory opts;
        opts.referenceContract = REFERENCE_CONTRACT;

        vm.startBroadcast(owner);
        Upgrades.upgradeProxy(proxy, "DotnsRegistry.sol:DotnsRegistry", "", opts);
        vm.stopBroadcast();

        console.log("  upgraded DotnsRegistry proxy", proxy);
    }
}
