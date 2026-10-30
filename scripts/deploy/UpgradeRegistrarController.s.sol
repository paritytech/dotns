// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title UpgradeRegistrarController
/// @notice Upgrades the deployed DotnsRegistrarController proxy to the current implementation.
///         Resolves the proxy from the on-disk manifest, diffs the new storage layout against the
///         pinned @custom:contract DotnsRegistrarControllerOld snapshot, and swaps the
///         implementation only when the diff and every unsafe-pattern check pass.
/// @dev The swap makes a name minted through `registerReserved` releasable: the registration now
///      opens an escrow release position for the owner with a zero deposit, and a reserved
///      registration of a name held in escrow reclaims it. The interface is
///      unchanged, and the controller only calls PopRules functions both rules versions have, so
///      the step does not depend on the others.
///
///      The live proxy keeps a retained slot where its first release had the whitelist mapping,
///      and this branch's source declares it, so `protocolRegistry` stays in the slot the proxy
///      uses. The snapshot is the implementation deployed on chain.
///      `scripts/shell/verify-snapshots.sh` is what holds that property, by building the snapshot
///      and comparing it against the chain.
/// @custom:security-contact admin@parity.io
contract UpgradeRegistrarController is BaseDeployer {
    /// @notice Pre-upgrade snapshot the layout diff compares the new implementation against.
    string internal constant REFERENCE_CONTRACT =
        "DotnsRegistrarControllerOld.sol:DotnsRegistrarControllerOld";

    /// @notice New implementation artefact.
    string internal constant ARTEFACT = "DotnsRegistrarController.sol:DotnsRegistrarController";

    /// @notice Manifest label the DotnsRegistrarController proxy is recorded under.
    string internal constant REGISTRAR_CONTROLLER_LABEL = "DotnsRegistrarController";

    /// @notice Reads the manifest, resolves the proxy, and upgrades it as `msg.sender`.
    /// @dev `msg.sender` must own the proxy, otherwise the run stops before broadcasting.
    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        address proxy = _readAddress(REGISTRAR_CONTROLLER_LABEL);
        _upgradeRegistrarController(owner, proxy);

        console.log("=== UpgradeRegistrarController complete ===");
    }

    /// @notice Upgrades `proxy` to the current implementation under `owner`.
    /// @dev The layout diff runs inside `Upgrades.upgradeProxy` before the swap with no override,
    ///      so an incompatible layout aborts the run before anything is broadcast. An empty upgrade
    ///      call is passed because the new implementation seeds no storage. A retry swaps in the
    ///      same code again.
    /// @param owner Account that owns the proxy and broadcasts the upgrade.
    /// @param proxy DotnsRegistrarController proxy address resolved from the manifest.
    function _upgradeRegistrarController(address owner, address proxy) internal {
        require(
            owner == OwnableUpgradeable(proxy).owner(),
            "UpgradeRegistrarController: broadcaster is not the proxy owner"
        );

        Options memory opts;
        opts.referenceContract = REFERENCE_CONTRACT;

        vm.startBroadcast(owner);
        Upgrades.upgradeProxy(proxy, ARTEFACT, "", opts);
        vm.stopBroadcast();

        console.log("  upgraded DotnsRegistrarController proxy", proxy);
    }
}
