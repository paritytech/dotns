// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title UpgradePopRules
/// @notice Upgrades the deployed PopRules proxy to the current implementation. Resolves the
///         proxy from the on-disk manifest, diffs the new storage layout against the pinned
///         @custom:contract PopRulesOld snapshot, and swaps the implementation only when the
///         diff and every unsafe-pattern check pass.
/// @dev The swap adds `reassignBaseNameForPop`, which the new PoP controller calls to move a
///      personhood name's slot to the next live reservation in one write, and moves name
///      classification into `PopClassification`. Classification and prices are unchanged. A live
///      reservation now closes the public path to every account, its holder included, who claims
///      the name through the gateway. The old controller never calls the new function, so it
///      keeps working against these rules until its own swap.
///
///      The snapshot is the implementation deployed on chain. These proxies were upgraded in place
///      after their last release, so a snapshot taken from a release tag would describe code that
///      does not run on this network.
///      `scripts/shell/verify-snapshots.sh` is what holds that property, by building the snapshot
///      and comparing it against the chain. The layout diff cannot: it compares whatever pair it
///      is given, and is blind to a change that lives in calldata.
/// @custom:security-contact admin@parity.io
contract UpgradePopRules is BaseDeployer {
    /// @notice Pre-upgrade snapshot the layout diff compares the new implementation against.
    /// @dev A source file, so the snapshot is versioned beside the implementation and rebuilt by
    ///      `forge build`.
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
    ///      aborts the run before anything is broadcast. An empty upgrade call is passed because
    ///      the new implementation seeds no storage of its own.
    /// @param owner Account that owns the proxy and broadcasts the upgrade.
    /// @param proxy PopRules proxy address resolved from the manifest.
    function _upgradePopRules(address owner, address proxy) internal {
        require(
            owner == OwnableUpgradeable(proxy).owner(),
            "UpgradePopRules: broadcaster is not the proxy owner"
        );

        Options memory opts;
        opts.referenceContract = REFERENCE_CONTRACT;

        vm.startBroadcast(owner);
        Upgrades.upgradeProxy(proxy, "PopRules.sol:PopRules", "", opts);
        vm.stopBroadcast();

        console.log("  upgraded PopRules proxy", proxy);
    }
}
