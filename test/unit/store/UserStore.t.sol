// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IUserStore} from "../../../contracts/store/IUserStore.sol";
import {UserStore} from "../../../contracts/store/UserStore.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title UserStoreTests
/// @notice Unit tests for the per-user UserStore beacon proxy: initialisation, owner-only writes,
/// history snapshotting, and pagination.
contract UserStoreTests is BaseDotns {
    /// @notice Fixture key used as the primary entry in setValue/history tests.
    bytes32 internal constant KEY_A = keccak256("cid.v1");
    /// @notice Fixture key used alongside KEY_A to cover multi-key enumeration.
    bytes32 internal constant KEY_B = keccak256("cid.v2");

    /// @notice Claims a brand-new UserStore beacon proxy on behalf of `user`.
    /// @param user The address that will both call `claimUserStore` and own the resulting store.
    /// @return store The newly claimed UserStore proxy cast to the IUserStore interface.
    function _freshUserStore(address user) internal returns (IUserStore store) {
        vm.prank(user);
        store = IUserStore(storeFactory.claimUserStore());
    }

    function test_initialize_binds_owner() public {
        IUserStore store = _freshUserStore(ed);
        assertEq(store.owner(), ed);
    }

    function test_initialize_reverts_on_zero_user() public {
        IUserStore uninitialised =
            IUserStore(address(new BeaconProxy(storeFactory.userStoreBeacon(), "")));
        vm.expectRevert(abi.encodeWithSelector(IUserStore.InvalidUser.selector, address(0)));
        uninitialised.initialize(address(0));
    }

    function test_initialize_reverts_on_second_call() public {
        IUserStore store = _freshUserStore(ed);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        store.initialize(ed);
    }

    function test_implementation_cannot_be_initialised_directly() public {
        UserStore impl = new UserStore();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(ed);
    }

    function test_setValue_reverts_for_non_owner() public {
        IUserStore store = _freshUserStore(ed);
        vm.prank(tiago);
        vm.expectRevert(abi.encodeWithSelector(IUserStore.NotOwner.selector, tiago));
        store.setValue(KEY_A, bytes("hello"));
    }

    function test_setValue_reverts_for_zero_key() public {
        IUserStore store = _freshUserStore(ed);
        vm.prank(ed);
        vm.expectRevert(IUserStore.InvalidKey.selector);
        store.setValue(bytes32(0), bytes("x"));
    }

    function test_setValue_first_write_leaves_history_empty() public {
        IUserStore store = _freshUserStore(ed);
        vm.prank(ed);
        vm.expectEmit(true, true, false, true, address(store));
        emit IUserStore.ValueSet(ed, KEY_A, bytes("v1"));
        store.setValue(KEY_A, bytes("v1"));

        assertEq(store.getValue(KEY_A), bytes("v1"));
        assertTrue(store.hasValue(KEY_A));
        assertEq(store.getHistoryCount(KEY_A), 0);
        assertEq(store.getKeyCount(), 1);
        assertEq(store.getKeyAt(0), KEY_A);
    }

    function test_setValue_second_write_snapshots_prev_into_history() public {
        IUserStore store = _freshUserStore(ed);
        vm.startPrank(ed);
        store.setValue(KEY_A, bytes("v1"));

        vm.warp(block.timestamp + 100);
        store.setValue(KEY_A, bytes("v2"));
        uint256 supersededAt = block.timestamp;
        vm.stopPrank();

        assertEq(store.getValue(KEY_A), bytes("v2"));
        assertEq(store.getHistoryCount(KEY_A), 1);

        IUserStore.Entry memory entry = store.getHistoryAt(KEY_A, 0);
        assertEq(entry.value, bytes("v1"));
        assertEq(entry.timestamp, supersededAt);
    }

    function test_setValue_does_not_duplicate_key_list_entries() public {
        IUserStore store = _freshUserStore(ed);
        vm.startPrank(ed);
        store.setValue(KEY_A, bytes("v1"));
        store.setValue(KEY_A, bytes("v2"));
        store.setValue(KEY_A, bytes("v3"));
        vm.stopPrank();

        assertEq(store.getKeyCount(), 1);
    }

    function test_setValue_empty_bytes_after_nonempty_snapshots_prior_value() public {
        IUserStore store = _freshUserStore(ed);
        vm.startPrank(ed);
        store.setValue(KEY_A, bytes("v1"));
        store.setValue(KEY_A, bytes(""));
        vm.stopPrank();

        assertEq(store.getValue(KEY_A).length, 0);
        assertFalse(store.hasValue(KEY_A));
        assertEq(store.getHistoryCount(KEY_A), 1);
        assertEq(store.getHistoryAt(KEY_A, 0).value, bytes("v1"));
    }

    function test_setValue_fresh_key_with_empty_bytes_writes_no_history() public {
        IUserStore store = _freshUserStore(ed);
        vm.prank(ed);
        store.setValue(KEY_A, bytes(""));

        assertEq(store.getHistoryCount(KEY_A), 0);
        assertFalse(store.hasValue(KEY_A));
        assertEq(store.getKeyCount(), 1);
    }

    function test_getHistory_pagination_bounds() public {
        IUserStore store = _freshUserStore(ed);
        vm.startPrank(ed);
        store.setValue(KEY_A, bytes("v1"));
        store.setValue(KEY_A, bytes("v2"));
        store.setValue(KEY_A, bytes("v3"));
        vm.stopPrank();

        IUserStore.Entry[] memory slice = store.getHistory(KEY_A, 1, 10);
        assertEq(slice.length, 1);
        assertEq(slice[0].value, bytes("v2"));

        IUserStore.Entry[] memory past = store.getHistory(KEY_A, 10, 5);
        assertEq(past.length, 0);
    }

    function test_getKeys_pagination() public {
        IUserStore store = _freshUserStore(ed);
        vm.startPrank(ed);
        store.setValue(KEY_A, bytes("a"));
        store.setValue(KEY_B, bytes("b"));
        vm.stopPrank();

        bytes32[] memory keys = store.getKeys(0, 10);
        assertEq(keys.length, 2);
        assertEq(keys[0], KEY_A);
        assertEq(keys[1], KEY_B);

        bytes32[] memory second = store.getKeys(1, 10);
        assertEq(second.length, 1);
        assertEq(second[0], KEY_B);
    }
}
