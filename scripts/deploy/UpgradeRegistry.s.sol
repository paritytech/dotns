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
/// @dev The swap adds the controller gate on a deferred store write (`persist` false), and moves
/// the store write to `StoreUtils.writeNewLabel`, which refuses to overwrite a locked label with a
///      different one instead of silently skipping it.
///
///      The snapshot is the implementation deployed on chain, not the previous release: these
///      proxies were upgraded in place after their last release, so a snapshot taken from a tag
///      would describe code that has not run on this network for months.
///      `scripts/shell/verify-snapshots.sh` is what holds that property, by building the snapshot
///      and comparing it against the chain. The layout diff cannot: it compares whatever pair it
///      is given, and is blind to a change that lives in calldata.
/// @custom:security-contact admin@parity.io
contract UpgradeRegistry is BaseDeployer {
    /// @notice Pre-upgrade snapshot the layout diff compares the new implementation against.
    /// @dev Source-file route, not a stored build-info directory, so the snapshot is versioned
    ///      beside the implementation and rebuilt by `forge build`.
    string internal constant REFERENCE_CONTRACT = "DotnsRegistryOld.sol:DotnsRegistryOld";

    /// @notice Manifest label the DotnsRegistry proxy is recorded under.
    string internal constant REGISTRY_LABEL = "DotnsRegistry";

    /// @notice Reads the manifest, resolves the DotnsRegistry proxy, and upgrades it as
    /// `msg.sender`.
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
    ///      aborts the run rather than corrupting state. An empty upgrade call is passed because
    ///      the new implementation seeds no storage of its own; where a release declares anything
    ///      on chain, `DeclareRelease.s.sol` does it once, after every swap has verified.
    /// @param owner Account that owns the proxy and broadcasts the upgrade.
    /// @param proxy DotnsRegistry proxy address resolved from the manifest.
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
