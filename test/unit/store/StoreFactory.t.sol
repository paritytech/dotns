// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {StoreFactory} from "../../../contracts/store/StoreFactory.sol";
import {IStoreFactory} from "../../../contracts/store/IStoreFactory.sol";
import {LabelStore} from "../../../contracts/store/LabelStore.sol";
import {ILabelStore} from "../../../contracts/store/ILabelStore.sol";
import {IUserStore} from "../../../contracts/store/IUserStore.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title LabelStoreV2
/// @notice Test-only LabelStore implementation extended with a version marker, used to verify
/// beacon upgrades propagate to live proxies.
contract LabelStoreV2 is LabelStore {
    /// @notice Returns a constant marker identifying this fixture as the v2 implementation.
    /// @return marker The literal string "v2".
    function versionMarker() external pure returns (string memory marker) {
        marker = "v2";
    }
}

/// @title StoreFactoryTests
/// @notice Unit tests for StoreFactory: beacon wiring, authorisation, deployment and claim flows,
/// beacon upgrades, and enumeration.
contract StoreFactoryTests is BaseDotns {
    function test_constructor_reverts_on_zero_registry() public {
        vm.expectRevert(
            abi.encodeWithSelector(IStoreFactory.InvalidProtocolRegistry.selector, address(0))
        );
        new StoreFactory(address(0), owner);
    }

    function test_constructor_deploys_both_beacons_and_implementations() public {
        StoreFactory fresh = new StoreFactory(address(protocolRegistry), owner);
        assertTrue(fresh.labelStoreBeacon() != address(0));
        assertTrue(fresh.userStoreBeacon() != address(0));
        assertTrue(fresh.labelStoreBeacon() != fresh.userStoreBeacon());
        assertEq(fresh.owner(), owner);
    }

    function test_beacon_owner_is_factory_for_both_beacons() public view {
        assertEq(UpgradeableBeacon(storeFactory.labelStoreBeacon()).owner(), address(storeFactory));
        assertEq(UpgradeableBeacon(storeFactory.userStoreBeacon()).owner(), address(storeFactory));
    }

    function test_deployLabelStoreFor_succeeds_for_owner() public {
        vm.prank(owner);
        address store = storeFactory.deployLabelStoreFor(ed);
        assertEq(storeFactory.getLabelStore(ed), store);
        assertEq(ILabelStore(store).owner(), ed);
        assertEq(ILabelStore(store).protocolRegistry(), address(protocolRegistry));
    }

    function test_deployLabelStoreFor_succeeds_for_registered_protocol() public {
        vm.prank(address(dotnsRegistrarController));
        address store = storeFactory.deployLabelStoreFor(ed);
        assertEq(storeFactory.getLabelStore(ed), store);
    }

    function test_deployLabelStoreFor_reverts_for_unregistered_non_owner() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IStoreFactory.NotAuthorised.selector, attacker));
        storeFactory.deployLabelStoreFor(ed);
    }

    function test_deployLabelStoreFor_reverts_on_zero_user() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStoreFactory.InvalidUser.selector, address(0)));
        storeFactory.deployLabelStoreFor(address(0));
    }

    function test_deployLabelStoreFor_reverts_on_double_deploy() public {
        vm.startPrank(owner);
        address first = storeFactory.deployLabelStoreFor(ed);
        vm.expectRevert(abi.encodeWithSelector(IStoreFactory.AlreadyDeployed.selector, ed, first));
        storeFactory.deployLabelStoreFor(ed);
        vm.stopPrank();
    }

    function test_claimUserStore_owner_is_caller() public {
        vm.prank(ed);
        address store = storeFactory.claimUserStore();
        assertEq(IUserStore(store).owner(), ed);
        assertEq(storeFactory.getUserStore(ed), store);
    }

    function test_claimUserStore_reverts_on_double_claim() public {
        vm.startPrank(ed);
        address first = storeFactory.claimUserStore();
        vm.expectRevert(abi.encodeWithSelector(IStoreFactory.AlreadyDeployed.selector, ed, first));
        storeFactory.claimUserStore();
        vm.stopPrank();
    }

    function test_claimUserStore_frontrun_is_harmless() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        address attackerStore = storeFactory.claimUserStore();

        vm.prank(ed);
        address victimStore = storeFactory.claimUserStore();

        assertTrue(attackerStore != victimStore);
        assertEq(IUserStore(attackerStore).owner(), attacker);
        assertEq(IUserStore(victimStore).owner(), ed);
    }

    function test_upgradeLabelStoreImplementation_reverts_for_non_owner() public {
        LabelStoreV2 newImplementation = new LabelStoreV2();
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ed));
        storeFactory.upgradeLabelStoreImplementation(address(newImplementation));
    }

    function test_upgradeLabelStoreImplementation_reverts_on_zero_impl() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IStoreFactory.InvalidImplementation.selector, address(0))
        );
        storeFactory.upgradeLabelStoreImplementation(address(0));
    }

    function test_upgradeLabelStoreImplementation_propagates_to_live_proxies() public {
        vm.prank(owner);
        address store = storeFactory.deployLabelStoreFor(ed);

        LabelStoreV2 newImplementation = new LabelStoreV2();
        vm.prank(owner);
        storeFactory.upgradeLabelStoreImplementation(address(newImplementation));

        assertEq(LabelStoreV2(store).versionMarker(), "v2");
    }

    function test_getLabelStores_enumerates_in_deployment_order() public {
        vm.startPrank(owner);
        address edStore = storeFactory.deployLabelStoreFor(ed);
        address leonardoStore = storeFactory.deployLabelStoreFor(leonardo);
        address tiagoStore = storeFactory.deployLabelStoreFor(tiago);
        vm.stopPrank();

        assertEq(storeFactory.getLabelStoreCount(), 3);

        address[] memory allStores = storeFactory.getLabelStores(0, 10);
        assertEq(allStores.length, 3);
        assertEq(allStores[0], edStore);
        assertEq(allStores[1], leonardoStore);
        assertEq(allStores[2], tiagoStore);

        address[] memory middle = storeFactory.getLabelStores(1, 1);
        assertEq(middle.length, 1);
        assertEq(middle[0], leonardoStore);

        address[] memory past = storeFactory.getLabelStores(5, 2);
        assertEq(past.length, 0);
    }

    function test_getUserStores_enumerates_in_claim_order() public {
        vm.prank(ed);
        address edStore = storeFactory.claimUserStore();
        vm.prank(leonardo);
        address leonardoStore = storeFactory.claimUserStore();

        assertEq(storeFactory.getUserStoreCount(), 2);
        address[] memory allStores = storeFactory.getUserStores(0, 10);
        assertEq(allStores.length, 2);
        assertEq(allStores[0], edStore);
        assertEq(allStores[1], leonardoStore);
    }
}
