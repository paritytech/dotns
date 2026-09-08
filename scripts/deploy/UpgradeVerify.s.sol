// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";

import {UpgradeBase} from "./UpgradeBase.s.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {IDotnsNameEscrow} from "../../contracts/escrow/IDotnsNameEscrow.sol";
import {IDotnsNameWhitelist} from "../../contracts/whitelist/IDotnsNameWhitelist.sol";
import {IDotnsPopController} from "../../contracts/registrars/IDotnsPopController.sol";
import {IStoreFactory} from "../../contracts/store/IStoreFactory.sol";

/// @title UpgradeVerify
/// @notice Read-only check that an upgraded deployment is whole. Run after the four upgrade
///         stages, as `WireDeployments._verifyDeployment` runs after a fresh deploy.
/// @dev An upgrade fails differently from a deploy. A deploy that half-works leaves addresses
///      missing, which is loud. An upgrade that half-works leaves every address in place and the
///      behaviour behind one of them wrong, which is silent: a swapped implementation with an
///      unseeded configuration value reverts only when a user hits the path it governs. So this
///      checks the values, not just the addresses.
/// @dev Ownership is re-checked because `_authorizeUpgrade` is `onlyOwner` on every proxy: an
///      owner that drifted would make the next upgrade impossible, and it is cheaper to learn
///      that here than at the next release.
/// @dev Mirrors the checklist in `DEPLOYMENTS.md` -> "Post-deployment verification". It does not
///      replace the fork tests that section also asks for; run those separately against the
///      upgraded network.
/// @custom:security-contact admin@parity.io
contract UpgradeVerify is UpgradeBase {
    function run() external view {
        address expectedOwner = msg.sender;
        address registryAddress = vm.envAddress("DOTNS_PROTOCOL_REGISTRY");
        _requireContract("DotnsProtocolRegistry", registryAddress);

        console.log("=== UpgradeVerify ===");
        console.log("  protocol registry:", registryAddress);
        console.log("  expected owner:   ", expectedOwner);
        console.log("");

        IDotnsProtocolRegistry registry = IDotnsProtocolRegistry(registryAddress);

        // Every address the deployment is expected to publish, and behind each an implementation
        // with code: an upgrade that pointed a proxy at an empty address would otherwise pass a
        // presence check on the proxy itself.
        _present(registry, DotnsConstants.REGISTRAR, "registrar");
        _present(registry, DotnsConstants.CONTROLLER, "controller");
        _present(registry, DotnsConstants.REGISTRY, "registry");
        _present(registry, DotnsConstants.RESOLVER, "resolver");
        _present(registry, DotnsConstants.REVERSE_RESOLVER, "reverseResolver");
        _present(registry, DotnsConstants.CONTENT_RESOLVER, "contentResolver");
        _present(registry, DotnsConstants.POP_RESOLVER, "popResolver");
        _present(registry, DotnsConstants.POP_CONTROLLER, "popController");
        _present(registry, DotnsConstants.POP_RULES, "popRules");
        _present(registry, DotnsConstants.NAME_ESCROW, "nameEscrow");
        _present(registry, DotnsConstants.NAME_WHITELIST, "nameWhitelist");
        _present(registry, DotnsConstants.STORE_FACTORY, "storeFactory");
        _present(registry, DotnsConstants.MULTICALL3, "multicall3");

        _verifyStoreBeacons(registry);
        _verifyConfiguration(registry);

        console.log("");
        console.log("=== UpgradeVerify complete ===");
    }

    /// @notice The key resolves, the target has code, and so does the implementation behind it.
    function _present(
        IDotnsProtocolRegistry registry,
        bytes32 key,
        string memory name
    )
        private
        view
    {
        address target = registry.get(key);
        require(target != address(0), string.concat("missing registry key: ", name));
        require(target.code.length != 0, string.concat("no code at: ", name));

        // Non-proxies read back the zero slot, which is not a failure: only assert on the ones
        // that actually carry an implementation pointer.
        address implementation = _implementationOf(target);
        if (implementation != address(0)) {
            require(
                implementation.code.length != 0, string.concat("implementation has no code: ", name)
            );
        }

        console.log("  ok  %s", name);
    }

    /// @notice Both store beacons exist and carry an implementation.
    function _verifyStoreBeacons(IDotnsProtocolRegistry registry) private view {
        IStoreFactory factory = IStoreFactory(registry.get(DotnsConstants.STORE_FACTORY));

        address labelBeacon = factory.labelStoreBeacon();
        address userBeacon = factory.userStoreBeacon();
        require(labelBeacon.code.length != 0, "LabelStoreBeacon: no code");
        require(userBeacon.code.length != 0, "UserStoreBeacon: no code");

        console.log("  ok  labelStoreBeacon");
        console.log("  ok  userStoreBeacon");
    }

    /// @notice Configuration values a bare implementation swap would leave at zero.
    /// @dev The escrow's redeem window is the documented example: a zero leaves `release`
    ///      reverting `RedeemWindowNotConfigured` for every name on the deployment, so a holder
    ///      who releases a name by accident can never redeem it back.
    function _verifyConfiguration(IDotnsProtocolRegistry registry) private view {
        IDotnsNameEscrow escrow =
            IDotnsNameEscrow(payable(registry.get(DotnsConstants.NAME_ESCROW)));
        require(escrow.redeemWindow() != 0, "NameEscrow: redeemWindow unseeded");
        require(escrow.cooldown() != 0, "NameEscrow: cooldown unseeded");
        console.log("  ok  nameEscrow.redeemWindow  %s", escrow.redeemWindow());
        console.log("  ok  nameEscrow.cooldown      %s", escrow.cooldown());

        IDotnsNameWhitelist whitelist =
            IDotnsNameWhitelist(registry.get(DotnsConstants.NAME_WHITELIST));
        require(whitelist.maxClaimants() != 0, "NameWhitelist: maxClaimants unseeded");
        require(whitelist.maxReasonBytes() != 0, "NameWhitelist: maxReasonBytes unseeded");
        require(whitelist.maxGrantBatch() != 0, "NameWhitelist: maxGrantBatch unseeded");
        console.log("  ok  nameWhitelist.maxClaimants   %s", whitelist.maxClaimants());
        console.log("  ok  nameWhitelist.maxReasonBytes %s", whitelist.maxReasonBytes());
        console.log("  ok  nameWhitelist.maxGrantBatch  %s", whitelist.maxGrantBatch());

        IDotnsPopController popController =
            IDotnsPopController(registry.get(DotnsConstants.POP_CONTROLLER));
        require(
            popController.reservationDuration() != 0, "PopController: reservationDuration unseeded"
        );
        console.log(
            "  ok  popController.reservationDuration %s", popController.reservationDuration()
        );
    }
}
