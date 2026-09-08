// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {UpgradeBase} from "./UpgradeBase.s.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {IStoreFactory} from "../../contracts/store/IStoreFactory.sol";
import {LabelStore} from "../../contracts/store/LabelStore.sol";
import {UserStore} from "../../contracts/store/UserStore.sol";

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

    /// @notice Upgrades both store implementations through the factory's beacons.
    function _upgradeStores(address owner, address registry) private {
        address factoryAddress = IDotnsProtocolRegistry(registry).get(DotnsConstants.STORE_FACTORY);
        if (factoryAddress == address(0)) {
            console.log("  skip      StoreFactory beacons (not registered on this deployment)");
            return;
        }

        IStoreFactory factory = IStoreFactory(factoryAddress);

        vm.startBroadcast(owner);
        address labelStore = address(new LabelStore());
        address userStore = address(new UserStore());
        factory.upgradeLabelStoreImplementation(labelStore);
        factory.upgradeUserStoreImplementation(userStore);
        vm.stopBroadcast();

        console.log("  upgraded  LabelStore beacon implementation", labelStore);
        console.log("  upgraded  UserStore beacon implementation ", userStore);
        _upgradedCount += 2;
    }
}
