// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IStore} from "../../../contracts/store/IStore.sol";
import {Store} from "../../../contracts/store/Store.sol";
import {IStoreFactory} from "../../../contracts/store/StoreFactory.sol";

contract StoreFactoryTests is BaseDotns {
    function test_deploy_reverts_when_already_deployed() public {
        vm.prank(ed);
        IStore deployed = storeFactory.deploy();

        vm.expectRevert(
            abi.encodeWithSelector(IStoreFactory.AlreadyDeployed.selector, address(deployed))
        );
        vm.prank(ed);
        storeFactory.deploy();
    }

    function test_transferownership_moves_mapping_and_emits() public {
        vm.prank(ed);
        IStore deployed = storeFactory.deploy();

        vm.expectEmit(true, true, true, false);
        emit IStoreFactory.OwnershipTransfered(ed, leonardo);

        vm.prank(ed);
        storeFactory.transferOwnership(leonardo);

        assertEq(address(storeFactory.getDeployedStore(ed)), address(0));
        assertEq(address(storeFactory.getDeployedStore(leonardo)), address(deployed));
        assertEq(Store(address(deployed)).owner(), ed);
    }

    function test_transferownership_reverts_when_caller_has_no_store() public {
        vm.expectRevert(abi.encodeWithSelector(IStoreFactory.InvalidTransfer.selector, tiago));
        vm.prank(tiago);
        storeFactory.transferOwnership(leonardo);
    }

    function test_transferownership_reverts_when_new_owner_already_has_store() public {
        vm.prank(ed);
        storeFactory.deploy();

        vm.prank(leonardo);
        storeFactory.deploy();

        vm.expectRevert(abi.encodeWithSelector(IStoreFactory.InvalidTransfer.selector, leonardo));
        vm.prank(ed);
        storeFactory.transferOwnership(leonardo);
    }

    function test_transferownership_to_zero_address_updates_mapping() public {
        vm.prank(ed);
        IStore deployed = storeFactory.deploy();

        vm.expectEmit(true, true, true, false);
        emit IStoreFactory.OwnershipTransfered(ed, address(0));

        vm.prank(ed);
        storeFactory.transferOwnership(address(0));

        assertEq(address(storeFactory.getDeployedStore(ed)), address(0));
        assertEq(address(storeFactory.getDeployedStore(address(0))), address(deployed));
        assertEq(Store(address(deployed)).owner(), ed);
    }

    function test_deploy_after_transferownership_creates_new_store_for_old_owner() public {
        vm.prank(ed);
        IStore first = storeFactory.deploy();

        vm.prank(ed);
        storeFactory.transferOwnership(leonardo);

        vm.prank(ed);
        IStore second = storeFactory.deploy();

        assertEq(address(storeFactory.getDeployedStore(ed)), address(second));
        assertEq(address(storeFactory.getDeployedStore(leonardo)), address(first));
        assertEq(Store(address(first)).owner(), ed);
        assertEq(Store(address(second)).owner(), ed);
        assertTrue(address(first) != address(second));
    }
}
