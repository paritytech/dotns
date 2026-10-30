// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPopRules} from "../../contracts/pop/IPopRules.sol";

/// @title UpgradePopController
/// @notice Upgrades the deployed DotnsPopController proxy to the current implementation. Resolves
///         the proxy from the on-disk manifest, diffs the new storage layout against the pinned
///         @custom:contract DotnsPopControllerOld snapshot, and swaps the implementation only
///         when the diff and every unsafe-pattern check pass.
/// @dev The new controller clears at most `MAX_QUEUE_STEPS_PER_CALL` dead reservations per gateway
///      call, so every gateway call fits the gateway's weight limit, and records the numeric
///      containers it has minted in `_deviceContainers`, the one slot it adds from the gap.
///
///      It calls `PopRules.reassignBaseNameForPop`, which only the upgraded rules have, so the
///      script refuses to run until PopRules reports the current interface. A run against a proxy
///      that already runs the current implementation broadcasts nothing, so a retry is safe.
///
///      The snapshot is the implementation deployed on chain. `scripts/shell/verify-snapshots.sh`
///      is what holds that property, by building the snapshot and comparing it against the chain.
/// @custom:security-contact admin@parity.io
contract UpgradePopController is BaseDeployer {
    /// @notice Pre-upgrade snapshot the layout diff compares the new implementation against.
    string internal constant REFERENCE_CONTRACT = "DotnsPopControllerOld.sol:DotnsPopControllerOld";

    /// @notice New implementation artefact.
    string internal constant ARTEFACT = "DotnsPopController.sol:DotnsPopController";

    /// @notice Manifest label the DotnsPopController proxy is recorded under.
    string internal constant POP_CONTROLLER_LABEL = "DotnsPopController";

    /// @notice Manifest label the PopRules proxy is recorded under.
    string internal constant POP_RULES_LABEL = "PopRules";

    /// @notice Reads the manifest, resolves both proxies, and upgrades the controller as
    ///         `msg.sender`.
    /// @dev `msg.sender` must own the controller proxy, otherwise the run stops before
    ///      broadcasting.
    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        address controller = _readAddress(POP_CONTROLLER_LABEL);
        address rules = _readAddress(POP_RULES_LABEL);
        _upgradePopController(owner, controller, rules);

        console.log("=== UpgradePopController complete ===");
    }

    /// @notice Upgrades `controller` to the current implementation under `owner`.
    /// @dev The layout diff runs before the swap with no override, so an incompatible layout
    ///      aborts the run before anything is broadcast. An empty upgrade call is passed because
    ///      `_deviceContainers` starts empty and fills as containers are minted or prepared.
    /// @param owner Account that owns the proxy and broadcasts the upgrade.
    /// @param controller DotnsPopController proxy address resolved from the manifest.
    /// @param rules PopRules proxy address resolved from the manifest.
    function _upgradePopController(address owner, address controller, address rules) internal {
        require(
            owner == OwnableUpgradeable(controller).owner(),
            "UpgradePopController: broadcaster is not the proxy owner"
        );
        require(
            IERC165(rules).supportsInterface(type(IPopRules).interfaceId),
            "UpgradePopController: upgrade PopRules first"
        );

        Options memory opts;
        opts.referenceContract = REFERENCE_CONTRACT;
        Upgrades.validateUpgrade(ARTEFACT, opts);

        if (_controllerUpgraded(controller)) {
            console.log("  DotnsPopController proxy already upgraded, skipping", controller);
            return;
        }

        vm.startBroadcast(owner);
        Upgrades.upgradeProxy(controller, ARTEFACT, "", opts);
        vm.stopBroadcast();

        require(
            _controllerUpgraded(controller),
            "UpgradePopController: the proxy still runs the previous implementation"
        );
        console.log("  upgraded DotnsPopController proxy", controller);
    }

    /// @notice Whether `controller` already runs an implementation with the queue step bound.
    /// @dev The previous implementation has no `MAX_QUEUE_STEPS_PER_CALL`, so the static call
    ///      reverts there.
    /// @param controller DotnsPopController proxy.
    /// @return upgraded True once the current implementation is behind the proxy.
    function _controllerUpgraded(address controller) internal view returns (bool upgraded) {
        (upgraded,) = controller.staticcall(abi.encodeWithSignature("MAX_QUEUE_STEPS_PER_CALL()"));
    }
}
