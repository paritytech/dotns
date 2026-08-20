// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {StoreInvariantHandler} from "./StoreInvariantHandler.t.sol";
import {ILabelStore} from "../../../contracts/store/ILabelStore.sol";
import {IUserStore} from "../../../contracts/store/IUserStore.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title Store Invariant Suite
/// @notice Asserts immutability and ownership properties of the LabelStore and UserStore
///         beacon proxies deployed via `StoreFactory`.
contract StoreInvariantTest is BaseDotns {
    /// @notice Handler driving randomised actions against the store factory and its stores.
    StoreInvariantHandler internal handler;

    /// @notice Deploys the store invariant handler and targets it as the sole fuzzed contract.
    function setUp() public override {
        super.setUp();
        handler = new StoreInvariantHandler(
            storeFactory, protocolRegistry, owner, address(dotnsRegistrarController)
        );
        targetContract(address(handler));
    }

    /// @notice Every labelhash ever written to a label store must remain locked thereafter.
    function invariant_locked_labels_never_unlock() public view {
        uint256 stores = handler.labelStoreCount();
        for (uint256 i; i < stores; ++i) {
            address store = handler.labelStores(i);
            uint256 labelhashCount = handler.writtenLabelhashCount(store);
            for (uint256 j; j < labelhashCount; ++j) {
                bytes32 labelhash = handler.writtenLabelhashAt(store, j);
                assertTrue(ILabelStore(store).isLocked(labelhash));
            }
        }
    }

    /// @notice The label text stored alongside a locked labelhash must equal the frozen value
    ///         first observed by the handler at write time.
    function invariant_locked_label_text_never_changes() public view {
        uint256 stores = handler.labelStoreCount();
        for (uint256 i; i < stores; ++i) {
            address store = handler.labelStores(i);
            uint256 labelhashCount = handler.writtenLabelhashCount(store);
            for (uint256 j; j < labelhashCount; ++j) {
                bytes32 labelhash = handler.writtenLabelhashAt(store, j);
                assertEq(
                    ILabelStore(store).getLabel(labelhash), handler.frozenLabel(store, labelhash)
                );
            }
        }
    }

    /// @notice Each user owns at most one label store and at most one user store, and the
    ///         factory's canonical lookup stays consistent with the handler's ghost arrays.
    function invariant_at_most_one_store_of_each_type_per_user() public view {
        uint256 userCount = handler.userCount();
        for (uint256 i; i < userCount; ++i) {
            address user = handler.users(i);
            address labelStore = storeFactory.getLabelStore(user);
            address userStore = storeFactory.getUserStore(user);
            // Tautological that at most one exists because mappings are scalar; the
            // property we assert is that observed ghost arrays stay consistent with
            // the factory's canonical lookup.
            if (labelStore != address(0)) {
                assertEq(ILabelStore(labelStore).owner(), user);
            }
            if (userStore != address(0)) {
                assertEq(IUserStore(userStore).owner(), user);
                assertEq(handler.userStoreOwnerOf(userStore), user);
            }
        }
    }

    /// @notice The store factory must remain the sole owner of both beacons it deployed.
    function invariant_factory_owns_both_beacons() public view {
        assertEq(UpgradeableBeacon(storeFactory.labelStoreBeacon()).owner(), address(storeFactory));
        assertEq(UpgradeableBeacon(storeFactory.userStoreBeacon()).owner(), address(storeFactory));
    }

    /// @notice The factory's enumeration counters must equal the number of stores tracked
    ///         by the handler.
    function invariant_enumeration_matches_counters() public view {
        assertEq(storeFactory.getLabelStoreCount(), handler.labelStoreCount());
        assertEq(storeFactory.getUserStoreCount(), handler.userStoreCount());
    }
}
