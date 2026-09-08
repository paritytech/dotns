// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {UpgradeBase} from "./UpgradeBase.s.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {IStoreFactory} from "../../contracts/store/IStoreFactory.sol";

/// @title UpgradeCore
/// @notice First upgrade stage, mirroring what `DeployCore` deploys: the protocol registry and the
///         name-ownership layer, plus both store implementations through the factory's beacons.
/// @dev The registry goes first because every later stage resolves its targets through it, so a
///      broken registry implementation surfaces here rather than after eleven other swaps.
/// @dev `StoreFactory` itself is not upgradeable (plain `Ownable`, immutable beacons), so a change
///      to the factory's own code still needs a fresh deploy. Its beacons are upgraded here, which
///      reaches every deployed `LabelStore` and `UserStore` in one call each. `Multicall3` and
///      `Create3Factory` are not upgradeable either, and never change in place.
/// @custom:security-contact admin@parity.io
contract UpgradeCore is UpgradeBase {
    function run() external {
        (address owner, address registry) = _beginUpgrade("UpgradeCore");

        _upgradeProxy(
            owner,
            registry,
            bytes32(0),
            "DotnsProtocolRegistry.sol:DotnsProtocolRegistry",
            "DotnsProtocolRegistry"
        );
        _upgradeProxy(
            owner,
            registry,
            _key("registrar"),
            "DotnsRegistrar.sol:DotnsRegistrar",
            "DotnsRegistrar"
        );
        _upgradeProxy(
            owner,
            registry,
            _key("reverseResolver"),
            "DotnsReverseResolver.sol:DotnsReverseResolver",
            "DotnsReverseResolver"
        );
        _upgradeProxy(
            owner, registry, _key("registry"), "DotnsRegistry.sol:DotnsRegistry", "DotnsRegistry"
        );

        _upgradeStores(owner, registry);

        _endUpgrade("UpgradeCore");
    }

    /// @notice Rotates both store beacons, so every deployed store follows the new code.
    /// @dev `StoreFactory` itself is not upgradeable, so this reaches the stores through the
    ///      beacons it owns rather than by replacing the factory. The rotation is sent from here
    ///      rather than from a callback in the base, so the only broadcast calls are to the
    ///      factory and never to the script address.
    function _upgradeStores(address owner, address registry) private {
        address factoryAddress = IDotnsProtocolRegistry(registry).get(DotnsConstants.STORE_FACTORY);
        if (factoryAddress == address(0)) {
            console.log("  skip      StoreFactory beacons (not registered on this deployment)");
            return;
        }

        IStoreFactory factory = IStoreFactory(factoryAddress);

        address labelStore = _prepareBeaconRotation(
            owner, factory.labelStoreBeacon(), "LabelStore.sol:LabelStore", "LabelStore"
        );
        if (labelStore != address(0)) {
            vm.broadcast(owner);
            factory.upgradeLabelStoreImplementation(labelStore);
        }

        address userStore = _prepareBeaconRotation(
            owner, factory.userStoreBeacon(), "UserStore.sol:UserStore", "UserStore"
        );
        if (userStore != address(0)) {
            vm.broadcast(owner);
            factory.upgradeUserStoreImplementation(userStore);
        }
    }
}
