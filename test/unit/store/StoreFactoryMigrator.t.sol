// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {StoreFactory} from "../../../contracts/store/StoreFactory.sol";
import {StoreFactoryMigrator} from "../../../contracts/store/StoreFactoryMigrator.sol";
import {IStoreFactory} from "../../../contracts/store/IStoreFactory.sol";
import {IDotnsStore} from "../../../contracts/store/IDotnsStore.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title StoreFactoryMigratorTests
/// @notice Covers the paged import that carries per-user `LabelStore` bindings onto a new
///         factory, which is the only part of the store migration with behaviour of its own.
/// @dev `storeFactory` from `BaseDotns` stands in for the factory being migrated from, and a
///      fresh proxy for the one being migrated to. What is asserted is what reading the diff
///      cannot show: that a binding is adopted instead of re-deployed, that the guards close, and
///      that the proxy comes back out of the migrator with the imported state intact.
/// @custom:security-contact admin@parity.io
contract StoreFactoryMigratorTests is BaseDotns {
    /// @notice The proxy the bindings are imported into.
    StoreFactoryMigrator internal target;

    function setUp() public override {
        super.setUp();

        // Two bindings on the old factory, created the ordinary way so they are real stores.
        vm.startPrank(owner);
        storeFactory.deployLabelStoreFor(ed);
        storeFactory.deployLabelStoreFor(tiago);
        vm.stopPrank();

        target = StoreFactoryMigrator(
            address(
                new ERC1967Proxy(
                    address(new StoreFactoryMigrator()),
                    abi.encodeCall(StoreFactory.initialize, (owner, address(protocolRegistry)))
                )
            )
        );
    }

    /// @notice Imported users keep the stores they already had.
    /// @dev The whole point of the migration: the binding is adopted, not re-created. A fresh
    ///      factory would hand them a new empty store instead, and their labels would drop out of
    ///      per-address enumeration while their names stayed put.
    function test_import_adopts_the_existing_stores() public {
        address edStore = storeFactory.getLabelStore(ed);
        address tiagoStore = storeFactory.getLabelStore(tiago);

        vm.prank(owner);
        target.importStores(address(storeFactory), 0, 10);

        assertEq(target.getLabelStore(ed), edStore, "ed keeps the store he already had");
        assertEq(target.getLabelStore(tiago), tiagoStore, "tiago keeps the store he already had");
        assertEq(target.getLabelStoreCount(), 2, "both bindings land in the enumeration");
    }

    /// @notice The holder set is read from the old factory, not supplied by the caller.
    /// @dev An earlier version took the list as an argument, which left a window between an
    ///      operator reading the set and the import running. A store created in that window is
    ///      silently left unbound, and its holder is handed an empty store on their next
    ///      registration. Reading inside the call closes the window, so a binding created right up
    ///      to the transaction is still carried.
    function test_import_sees_a_binding_created_after_the_decision_to_migrate() public {
        address latecomer = makeAddr("latecomer");

        vm.prank(owner);
        storeFactory.deployLabelStoreFor(latecomer);
        address lateStore = storeFactory.getLabelStore(latecomer);

        vm.prank(owner);
        target.importStores(address(storeFactory), 0, 10);

        assertEq(target.getLabelStore(latecomer), lateStore, "the late binding is carried too");
        assertEq(target.getLabelStoreCount(), 3, "and is counted");
    }

    /// @notice A store whose owner disagrees with the old factory's mapping is rejected.
    /// @dev The store list and the per-user mapping are separate state. Trusting a store's own
    ///      `owner` alone would bind a user the old factory does not hold that store for, and
    ///      bindings here are permanent, so that user could never be given their real one.
    function test_import_reverts_when_a_store_owner_disagrees_with_the_mapping() public {
        address edStore = storeFactory.getLabelStore(ed);
        address impostor = makeAddr("impostor");

        // Only the store's answer is changed; the factory still has it bound to ed.
        vm.mockCall(
            edStore, abi.encodeWithSelector(IDotnsStore.owner.selector), abi.encode(impostor)
        );

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                StoreFactoryMigrator.ImportBindingMismatch.selector, impostor, edStore
            )
        );
        target.importStores(address(storeFactory), 0, 10);
    }

    /// @notice The import lands identically when carried one binding per page.
    /// @dev The pages exist because a whole-list import does not fit in a pallet-revive block,
    ///      so the property that matters is that page boundaries are invisible in the result:
    ///      same bindings, same count, no matter how the list was sliced.
    function test_import_is_the_same_result_page_by_page() public {
        address edStore = storeFactory.getLabelStore(ed);
        address tiagoStore = storeFactory.getLabelStore(tiago);

        vm.startPrank(owner);
        target.importStores(address(storeFactory), 0, 1);
        target.importStores(address(storeFactory), 1, 1);
        vm.stopPrank();

        assertEq(target.getLabelStore(ed), edStore, "ed keeps his store across a page boundary");
        assertEq(target.getLabelStore(tiago), tiagoStore, "tiago keeps his on the later page");
        assertEq(target.getLabelStoreCount(), 2, "both pages land, neither twice");
    }

    /// @notice Replaying pages already carried is a no-op instead of a failure.
    /// @dev Partial-failure recovery: a death between pages is finished by running the same pages
    ///      again, so a page that already landed must skip its bindings silently. Loud rejection
    ///      here would make the interrupted import unfinishable.
    function test_replaying_an_imported_page_is_a_noop() public {
        vm.startPrank(owner);
        target.importStores(address(storeFactory), 0, 10);
        target.importStores(address(storeFactory), 0, 10);
        vm.stopPrank();

        assertEq(target.getLabelStoreCount(), 2, "the replay carried nothing twice");
        assertEq(
            target.getLabelStore(ed),
            storeFactory.getLabelStore(ed),
            "the binding is the one the old factory holds"
        );
    }

    /// @notice A user already bound to a DIFFERENT store is rejected, not repointed.
    /// @dev The skip above is strictly for identical pairs. Bindings are permanent everywhere
    ///      else in the factory, and the migration does not get to be the exception: a
    ///      conflicting pair fails loudly instead of rewriting history.
    function test_import_reverts_on_a_conflicting_binding() public {
        address edStore = storeFactory.getLabelStore(ed);
        address tiagoStore = storeFactory.getLabelStore(tiago);

        vm.prank(owner);
        target.importStores(address(storeFactory), 0, 10);

        // The old factory now claims ed holds tiago's store: list slot, store owner and mapping
        // all agree with each other, and disagree only with the binding already imported.
        address[] memory page = new address[](1);
        page[0] = tiagoStore;
        vm.mockCall(
            address(storeFactory),
            abi.encodeWithSelector(IStoreFactory.getLabelStores.selector, 0, 1),
            abi.encode(page)
        );
        vm.mockCall(tiagoStore, abi.encodeWithSelector(IDotnsStore.owner.selector), abi.encode(ed));
        vm.mockCall(
            address(storeFactory),
            abi.encodeWithSelector(IStoreFactory.getLabelStore.selector, ed),
            abi.encode(tiagoStore)
        );

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStoreFactory.AlreadyDeployed.selector, ed, edStore));
        target.importStores(address(storeFactory), 0, 1);
    }

    /// @notice A zero-sized page is a caller bug, named as such.
    /// @dev Importing nothing while looking like progress is how a wrong pagination loop would
    ///      hide; the guard turns it into a revert at the first page.
    function test_import_rejects_an_empty_page() public {
        vm.prank(owner);
        vm.expectRevert(StoreFactoryMigrator.ImportPageEmpty.selector);
        target.importStores(address(storeFactory), 0, 0);
    }

    /// @notice Only the owner may import.
    /// @dev The import writes bindings directly, bypassing every check `deployLabelStoreFor`
    ///      applies, so it is the most privileged entrypoint the factory has ever carried.
    function test_import_is_owner_only() public {
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ed));
        target.importStores(address(storeFactory), 0, 10);
    }

    /// @notice The imported bindings survive the upgrade back to the shipped implementation.
    /// @dev The migrator is meant to be transient. This is the assertion that the round trip
    ///      leaves an ordinary factory holding the imported state, instead of a deployment parked
    ///      on migration tooling.
    function test_bindings_survive_the_return_to_the_shipped_implementation() public {
        address edStore = storeFactory.getLabelStore(ed);

        vm.startPrank(owner);
        target.importStores(address(storeFactory), 0, 10);
        target.upgradeToAndCall(address(new StoreFactory()), "");
        vm.stopPrank();

        StoreFactory restored = StoreFactory(address(target));
        assertEq(restored.getLabelStore(ed), edStore, "binding survives the swap back");
        assertEq(restored.getLabelStoreCount(), 2, "enumeration survives the swap back");
    }
}
