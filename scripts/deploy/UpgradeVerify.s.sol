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
import {IDotnsRegistrar} from "../../contracts/registrars/IDotnsRegistrar.sol";
import {IDotnsController} from "../../contracts/registrars/IDotnsController.sol";

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
/// @notice Minimal view of an `Ownable` contract.
interface IOwnable {
    function owner() external view returns (address);
}

/// @notice Minimal view of an `UpgradeableBeacon`.
interface IBeacon {
    function implementation() external view returns (address);
}

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
        _present(registry, DotnsConstants.REGISTRAR, "registrar", expectedOwner, false);
        _present(registry, DotnsConstants.CONTROLLER, "controller", expectedOwner, false);
        _present(registry, DotnsConstants.REGISTRY, "registry", expectedOwner, false);
        _present(registry, DotnsConstants.RESOLVER, "resolver", expectedOwner, false);
        _present(registry, DotnsConstants.REVERSE_RESOLVER, "reverseResolver", expectedOwner, false);
        _present(registry, DotnsConstants.CONTENT_RESOLVER, "contentResolver", expectedOwner, false);
        _present(registry, DotnsConstants.POP_RESOLVER, "popResolver", expectedOwner, false);
        _present(registry, DotnsConstants.POP_CONTROLLER, "popController", expectedOwner, false);
        _present(registry, DotnsConstants.POP_RULES, "popRules", expectedOwner, false);
        _present(registry, DotnsConstants.NAME_ESCROW, "nameEscrow", expectedOwner, false);
        _present(registry, DotnsConstants.NAME_WHITELIST, "nameWhitelist", expectedOwner, false);
        _present(registry, DotnsConstants.STORE_FACTORY, "storeFactory", expectedOwner, false);
        // Part of the graph even though the upgrade pipeline never touches them: a whole
        // deployment publishes them, and their absence is as broken as a missing resolver.
        _present(registry, DotnsConstants.COST_MODEL, "costModel", expectedOwner, false);
        _present(registry, DotnsConstants.POP_LENS, "popLens", expectedOwner, true);
        _present(registry, DotnsConstants.MULTICALL3, "multicall3", expectedOwner, true);

        _verifyRegistrySelf(registryAddress, expectedOwner);
        _verifyControllers(registry);

        _verifyStoreBeacons(registry);
        _verifyConfiguration(registry);

        console.log("");
        console.log("=== UpgradeVerify complete ===");
    }

    /// @notice The key resolves, the target and its implementation have code, and `expectedOwner`
    ///         still owns it.
    /// @dev Ownership is asserted, not just logged: `_authorizeUpgrade` is `onlyOwner` on every
    ///      proxy, so an owner that drifted makes the *next* upgrade impossible. Cheaper to learn
    ///      that here than at the next release. `ownerless` covers entries that are not
    ///      `Ownable`, such as Multicall3.
    function _present(
        IDotnsProtocolRegistry registry,
        bytes32 key,
        string memory name,
        address expectedOwner,
        bool ownerless
    )
        internal
        view
    {
        address target = registry.get(key);
        require(target != address(0), string.concat("missing registry key: ", name));
        require(target.code.length != 0, string.concat("no code at: ", name));

        if (!ownerless) {
            require(IOwnable(target).owner() == expectedOwner, string.concat("wrong owner: ", name));
        }

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

    /// @notice The registry itself: it cannot look itself up, so it is checked directly.
    function _verifyRegistrySelf(address registryAddress, address expectedOwner) internal view {
        require(IOwnable(registryAddress).owner() == expectedOwner, "wrong owner: protocolRegistry");
        address implementation = _implementationOf(registryAddress);
        require(implementation != address(0), "protocolRegistry: no implementation");
        require(implementation.code.length != 0, "protocolRegistry: implementation has no code");
        console.log("  ok  protocolRegistry (self)");
    }

    /// @notice The registrar still authorises both minting controllers.
    /// @dev Registration and every gateway name flow through this. It is registry-independent
    ///      state, so a swap that corrupted the registrar's storage would drop it while every
    ///      address still resolved.
    function _verifyControllers(IDotnsProtocolRegistry registry) internal view {
        IDotnsRegistrar registrar = IDotnsRegistrar(registry.get(DotnsConstants.REGISTRAR));

        address controller = registry.get(DotnsConstants.CONTROLLER);
        address popController = registry.get(DotnsConstants.POP_CONTROLLER);
        require(
            registrar.controllers(IDotnsController(controller)),
            "registrar: controller not authorised"
        );
        require(
            registrar.controllers(IDotnsController(popController)),
            "registrar: popController not authorised"
        );

        console.log("  ok  registrar.controllers[controller]");
        console.log("  ok  registrar.controllers[popController]");
    }

    /// @notice Both store beacons exist and point at implementations that have code.
    /// @dev Checking the beacon has code is not enough: every store on the network follows the
    ///      beacon's implementation, so a beacon pointing at an empty address bricks all of them
    ///      while the beacon itself still looks fine.
    function _verifyStoreBeacons(IDotnsProtocolRegistry registry) internal view {
        IStoreFactory factory = IStoreFactory(registry.get(DotnsConstants.STORE_FACTORY));

        address[2] memory beacons = [factory.labelStoreBeacon(), factory.userStoreBeacon()];
        string[2] memory names = ["labelStoreBeacon", "userStoreBeacon"];

        for (uint256 i; i < beacons.length; ++i) {
            require(beacons[i].code.length != 0, string.concat(names[i], ": no code"));
            address implementation = IBeacon(beacons[i]).implementation();
            require(implementation != address(0), string.concat(names[i], ": no implementation"));
            require(
                implementation.code.length != 0,
                string.concat(names[i], ": implementation has no code")
            );
            console.log("  ok  %s implementation %s", names[i], implementation);
        }
    }

    /// @notice Configuration values a bare implementation swap would leave at zero.
    /// @dev The escrow's redeem window is the documented example: a zero leaves `release`
    ///      reverting `RedeemWindowNotConfigured` for every name on the deployment, so a holder
    ///      who releases a name by accident can never redeem it back.
    function _verifyConfiguration(IDotnsProtocolRegistry registry) internal view {
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
