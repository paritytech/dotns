// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BaseDeployer} from "./BaseDeployer.s.sol";

/// @title UpgradePopRules
/// @notice Upgrades the deployed PopRules proxy to the current implementation. Resolves the proxy
///         from the on-disk manifest, diffs the new storage layout against the pinned
///         @custom:contract PopRulesOld snapshot, and swaps the implementation only when the diff
///         and every unsafe-pattern check pass.
/// @dev PR-scoped. This script, the `PopRulesOld` snapshot it references, and the paired
///      `test/fork/UpgradePopRules.t.sol` are deleted before merge per the upgrade-PR workflow in
///      CONTRIBUTING.md. The storage-layout reference is always supplied, so the layout diff is
///      mandatory: there is no environment switch that turns it off, and the run fails closed if a
///      slot moves, shrinks, or changes type.
/// @custom:security-contact admin@parity.io
contract UpgradePopRules is BaseDeployer {
    /// @notice Pre-upgrade snapshot the layout diff compares the new implementation against.
    /// @dev Source-file route, not a stored build-info directory, so the snapshot is versioned
    ///      beside the implementation and rebuilt by `forge build`. Deleted before merge.
    string internal constant REFERENCE_CONTRACT = "PopRulesOld.sol:PopRulesOld";

    /// @notice Manifest label the PopRules proxy is recorded under.
    string internal constant POP_RULES_LABEL = "PopRules";

    /// @notice Reads the manifest, resolves the PopRules proxy, and upgrades it as `msg.sender`.
    /// @dev `msg.sender` must own the proxy, otherwise the `_authorizeUpgrade` owner gate reverts.
    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        address proxy = _readAddress(POP_RULES_LABEL);
        _upgradePopRules(owner, proxy);

        console.log("=== UpgradePopRules complete ===");
    }

    /// @notice Upgrades `proxy` to the current `PopRules` implementation under `owner`.
    /// @dev The layout diff runs inside `Upgrades.upgradeProxy` before the implementation swap. No
    ///      `unsafeSkipAllChecks` or `unsafeAllow` override is set, so an incompatible layout
    /// aborts the run rather than corrupting state. An empty upgrade call is passed because the new
    ///      implementation adds no storage that needs seeding: the classification and pricing
    /// change is logic-only, and `shortNamesEnabled` keeps whatever value the live proxy holds.
    /// @param owner Account that owns the proxy and broadcasts the upgrade.
    /// @param proxy PopRules proxy address resolved from the manifest.
    function _upgradePopRules(address owner, address proxy) internal {
        Options memory opts;
        opts.referenceContract = REFERENCE_CONTRACT;

        vm.startBroadcast(owner);
        Upgrades.upgradeProxy(proxy, "PopRules.sol:PopRules", "", opts);
        vm.stopBroadcast();

        console.log("  upgraded PopRules proxy", proxy);
    }
}
