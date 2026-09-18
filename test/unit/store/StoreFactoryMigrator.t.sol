// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {StoreFactory} from "../../../contracts/store/StoreFactory.sol";
import {StoreFactoryMigrator} from "../../../contracts/store/StoreFactoryMigrator.sol";
import {IStoreFactory} from "../../../contracts/store/IStoreFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title StoreFactoryMigratorTests
/// @notice Covers the one-shot import that carries per-user `LabelStore` bindings onto a new
///         factory, which is the only part of the store migration with behaviour of its own.
/// @dev The fixture stands in for the real shape: `storeFactory` from `BaseDotns` plays the
///      factory being migrated from, and a fresh proxy plays the one being migrated to. What is
///      asserted is what a reviewer cannot check by reading the diff, namely that a binding is
///      adopted rather than re-deployed, that the guards actually close, and that the proxy comes
///      back out of the migrator with the imported state intact.
/// @custom:security-contact admin@parity.io
contract StoreFactoryMigratorTests is BaseDotns {
    /// @notice The proxy the bindings are imported into.
    StoreFactoryMigrator internal target;

    /// @notice Users holding a store on the factory being migrated from.
    address[] internal holders;

    function setUp() public override {
        super.setUp();

        // Two bindings on the old factory, created the ordinary way so they are real stores.
        vm.startPrank(owner);
        storeFactory.deployLabelStoreFor(ed);
        storeFactory.deployLabelStoreFor(tiago);
        vm.stopPrank();

        holders.push(ed);
        holders.push(tiago);

        target = StoreFactoryMigrator(
            address(
                new ERC1967Proxy(
                    address(new StoreFactoryMigrator()),
                    abi.encodeCall(StoreFactory.initialize, (owner, address(protocolRegistry)))
                )
            )
        );
    }

    /// @notice An imported user keeps the store they already had.
    /// @dev The whole point of the migration: the binding is adopted, not re-created. A fresh
    ///      factory would hand them a new empty store instead, and their labels would drop out of
    ///      per-address enumeration while their names stayed put.
    function test_import_adopts_the_existing_store() public {
        address edStore = storeFactory.getLabelStore(ed);
        address tiagoStore = storeFactory.getLabelStore(tiago);

        vm.prank(owner);
        target.importStores(address(storeFactory), holders, 2);

        assertEq(target.getLabelStore(ed), edStore, "ed keeps the store he already had");
        assertEq(target.getLabelStore(tiago), tiagoStore, "tiago keeps the store he already had");
        assertEq(target.getLabelStoreCount(), 2, "both bindings land in the enumeration");
    }

    /// @notice A list shorter than the old factory's count is rejected.
    /// @dev The failure the loop cannot see. Every address supplied would import correctly while
    ///      the users left out stay unbound, and nothing would surface that until one of them
    ///      registered a name and silently got a second, empty store.
    function test_import_reverts_when_the_list_is_short() public {
        address[] memory shortList = new address[](1);
        shortList[0] = ed;

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(StoreFactoryMigrator.ImportCountMismatch.selector, 2, 1)
        );
        target.importStores(address(storeFactory), shortList, 2);
    }

    /// @notice Importing a user twice is rejected rather than repointing them.
    /// @dev Bindings are permanent everywhere else in the factory, and the migration does not get
    ///      to be the exception: a second run over an overlapping list fails loudly instead of
    ///      rewriting a user's history.
    function test_import_reverts_on_a_user_already_bound() public {
        vm.startPrank(owner);
        target.importStores(address(storeFactory), holders, 2);

        address[] memory again = new address[](1);
        again[0] = ed;
        vm.expectRevert(
            abi.encodeWithSelector(
                IStoreFactory.AlreadyDeployed.selector, ed, storeFactory.getLabelStore(ed)
            )
        );
        target.importStores(address(storeFactory), again, 1);
        vm.stopPrank();
    }

    /// @notice A user with no store on the old factory cannot be imported.
    /// @dev Importing a zero binding would consume the user's one permanent slot with nothing in
    ///      it, and the factory would then refuse to deploy them a real store ever after.
    function test_import_reverts_on_a_user_with_no_store() public {
        address[] memory stranger = new address[](1);
        stranger[0] = address(0xBEEF);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStoreFactory.InvalidUser.selector, address(0xBEEF)));
        target.importStores(address(storeFactory), stranger, 1);
    }

    /// @notice Only the owner may import.
    /// @dev The import writes bindings directly, bypassing every check `deployLabelStoreFor`
    ///      applies, so it is the most privileged entrypoint the factory has ever carried.
    function test_import_is_owner_only() public {
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ed));
        target.importStores(address(storeFactory), holders, 2);
    }

    /// @notice The imported bindings survive the upgrade back to the shipped implementation.
    /// @dev The migrator is meant to be transient. This is the assertion that the round trip
    ///      leaves a normal factory holding the imported state, rather than a deployment parked
    ///      on migration tooling.
    function test_bindings_survive_the_return_to_the_shipped_implementation() public {
        address edStore = storeFactory.getLabelStore(ed);

        vm.startPrank(owner);
        target.importStores(address(storeFactory), holders, 2);
        target.upgradeToAndCall(address(new StoreFactory()), "");
        vm.stopPrank();

        StoreFactory restored = StoreFactory(address(target));
        assertEq(restored.getLabelStore(ed), edStore, "binding survives the swap back");
        assertEq(restored.getLabelStoreCount(), 2, "enumeration survives the swap back");
    }
}
