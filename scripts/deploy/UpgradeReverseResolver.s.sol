// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title UpgradeReverseResolver
/// @notice Upgrades the deployed DotnsReverseResolver proxy to the current implementation. It
///         resolves the proxy from the on-disk manifest, diffs the new storage layout against the
///         pinned @custom:contract DotnsReverseResolverOld snapshot, and swaps the implementation
///         only when the diff and every unsafe-pattern check pass.
/// @dev PR-scoped. This script, the `DotnsReverseResolverOld` snapshot, and the paired fork test
///      `test/fork/UpgradeReverseResolver.t.sol` are deleted before merge per the upgrade-PR
///      workflow in CONTRIBUTING.md. The storage-layout reference is always supplied, so the diff
///      is mandatory: there is no switch that turns it off, and the run fails closed if a slot
///      moves, shrinks, or changes type.
/// @custom:security-contact admin@parity.io
contract UpgradeReverseResolver is BaseDeployer {
    /// @notice Pre-upgrade snapshot the layout diff compares the new implementation against.
    /// @dev Source-file route, not a stored build-info directory, so the snapshot is versioned
    ///      beside the implementation and rebuilt by `forge build`. Deleted before merge.
    string internal constant REFERENCE_CONTRACT =
        "DotnsReverseResolverOld.sol:DotnsReverseResolverOld";

    /// @notice Manifest label the reverse resolver proxy is recorded under.
    string internal constant REVERSE_RESOLVER_LABEL = "DotnsReverseResolver";

    /// @notice Reads the manifest, resolves the reverse resolver proxy, and upgrades it as
    ///         `msg.sender`.
    /// @dev `msg.sender` must own the proxy, otherwise the `_authorizeUpgrade` owner gate reverts.
    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        address proxy = _readAddress(REVERSE_RESOLVER_LABEL);
        _upgradeReverseResolver(owner, proxy);

        console.log("=== UpgradeReverseResolver complete ===");
    }

    /// @notice Upgrades `proxy` to the current `DotnsReverseResolver` implementation under `owner`.
    /// @dev The layout diff runs inside `Upgrades.upgradeProxy` before the implementation swap. No
    ///      `unsafeSkipAllChecks` or `unsafeAllow` override is set, so an incompatible layout
    /// aborts the run rather than corrupting state. An empty upgrade call is passed because the new
    ///      implementation seeds no storage: it reads a lite name's owner through the registry at
    ///      the hierarchical node and adds no storage slot, so every existing reverse record is
    ///      preserved unchanged.
    /// @param owner Account that owns the proxy and broadcasts the upgrade.
    /// @param proxy Reverse resolver proxy address resolved from the manifest.
    function _upgradeReverseResolver(address owner, address proxy) internal {
        require(
            owner == OwnableUpgradeable(proxy).owner(),
            "UpgradeReverseResolver: broadcaster is not the proxy owner"
        );

        Options memory opts;
        opts.referenceContract = REFERENCE_CONTRACT;

        vm.startBroadcast(owner);
        Upgrades.upgradeProxy(proxy, "DotnsReverseResolver.sol:DotnsReverseResolver", "", opts);
        vm.stopBroadcast();

        console.log("  upgraded DotnsReverseResolver proxy", proxy);
    }
}
