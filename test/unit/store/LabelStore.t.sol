// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {ILabelStore} from "../../../contracts/store/ILabelStore.sol";
import {LabelStore} from "../../../contracts/store/LabelStore.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title LabelStoreTests
/// @notice Unit tests for the per-user LabelStore beacon proxy: initialisation, authorisation,
/// write-once semantics, and pagination.
contract LabelStoreTests is BaseDotns {
    /// @notice Fixture labelhash for label "alpha".
    bytes32 internal constant LABELHASH_A = keccak256("alpha");
    /// @notice Fixture labelhash for label "bravo".
    bytes32 internal constant LABELHASH_B = keccak256("bravo");
    /// @notice Fixture label string paired with LABELHASH_A.
    string internal constant LABEL_A = "alpha.dot";
    /// @notice Fixture label string paired with LABELHASH_B.
    string internal constant LABEL_B = "bravo.dot";

    /// @notice Deploys a brand-new LabelStore beacon proxy for `user` via the factory, pranked as
    /// `owner`. @param user The address that will own the freshly deployed LabelStore.
    /// @return store The newly deployed LabelStore proxy cast to the ILabelStore interface.
    function _freshLabelStore(address user) internal returns (ILabelStore store) {
        vm.prank(owner);
        store = ILabelStore(storeFactory.deployLabelStoreFor(user));
    }

    function test_initialize_binds_owner_and_registry() public {
        ILabelStore store = _freshLabelStore(ed);
        assertEq(store.owner(), ed);
        assertEq(store.protocolRegistry(), address(protocolRegistry));
    }

    function test_initialize_reverts_on_zero_user() public {
        ILabelStore uninitialised =
            ILabelStore(address(new BeaconProxy(storeFactory.labelStoreBeacon(), "")));
        vm.expectRevert(abi.encodeWithSelector(ILabelStore.InvalidUser.selector, address(0)));
        uninitialised.initialize(address(0), address(protocolRegistry));
    }

    function test_initialize_reverts_on_zero_registry() public {
        ILabelStore uninitialised =
            ILabelStore(address(new BeaconProxy(storeFactory.labelStoreBeacon(), "")));
        vm.expectRevert(
            abi.encodeWithSelector(ILabelStore.InvalidProtocolRegistry.selector, address(0))
        );
        uninitialised.initialize(ed, address(0));
    }

    function test_initialize_reverts_on_second_call() public {
        ILabelStore store = _freshLabelStore(ed);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        store.initialize(ed, address(protocolRegistry));
    }

    function test_implementation_cannot_be_initialised_directly() public {
        LabelStore impl = new LabelStore();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(ed, address(protocolRegistry));
    }

    function test_storeLabel_reverts_when_caller_not_registered() public {
        ILabelStore store = _freshLabelStore(ed);
        vm.prank(tiago);
        vm.expectRevert(abi.encodeWithSelector(ILabelStore.NotAuthorised.selector, tiago));
        store.storeLabel(LABELHASH_A, LABEL_A);
    }

    function test_storeLabel_reverts_when_labelhash_zero() public {
        ILabelStore store = _freshLabelStore(ed);
        vm.prank(address(dotnsRegistrarController));
        vm.expectRevert(abi.encodeWithSelector(ILabelStore.InvalidLabel.selector, bytes32(0)));
        store.storeLabel(bytes32(0), LABEL_A);
    }

    function test_storeLabel_writes_locks_and_enumerates() public {
        ILabelStore store = _freshLabelStore(ed);

        vm.prank(address(dotnsRegistrarController));
        vm.expectEmit(true, true, false, true, address(store));
        emit ILabelStore.LabelStored(ed, LABELHASH_A, LABEL_A);
        store.storeLabel(LABELHASH_A, LABEL_A);

        assertTrue(store.hasLabel(LABELHASH_A));
        assertTrue(store.isLocked(LABELHASH_A));
        assertEq(store.getLabel(LABELHASH_A), LABEL_A);
        assertEq(store.getLabelCount(), 1);
        assertEq(store.getLabelAt(0), LABEL_A);
        assertEq(store.getLabelhashAt(0), LABELHASH_A);
    }

    function test_storeLabel_reverts_on_second_write_same_labelhash() public {
        ILabelStore store = _freshLabelStore(ed);
        vm.startPrank(address(dotnsRegistrarController));
        store.storeLabel(LABELHASH_A, LABEL_A);
        vm.expectRevert(
            abi.encodeWithSelector(ILabelStore.LabelAlreadyExists.selector, LABELHASH_A)
        );
        store.storeLabel(LABELHASH_A, LABEL_B);
        vm.stopPrank();
    }

    function test_caller_becoming_unregistered_rejects_subsequent_write() public {
        // Give the attacker a temporary registered slot, then rotate the slot
        // to someone else so the attacker is no longer registered.
        address attacker = makeAddr("attacker");
        bytes32 tempKey = keccak256("temp.key");

        vm.startPrank(owner);
        protocolRegistry.set(tempKey, attacker);
        vm.stopPrank();

        ILabelStore store = _freshLabelStore(ed);

        vm.prank(attacker);
        store.storeLabel(LABELHASH_A, LABEL_A);
        assertTrue(store.hasLabel(LABELHASH_A));

        // Rotate the slot away from attacker.
        vm.startPrank(owner);
        protocolRegistry.set(tempKey, leonardo);
        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ILabelStore.NotAuthorised.selector, attacker));
        store.storeLabel(LABELHASH_B, LABEL_B);
    }

    function test_getLabels_returns_empty_when_offset_past_end() public {
        ILabelStore store = _freshLabelStore(ed);
        vm.startPrank(address(dotnsRegistrarController));
        store.storeLabel(LABELHASH_A, LABEL_A);
        vm.stopPrank();

        string[] memory labels = store.getLabels(10, 5);
        assertEq(labels.length, 0);

        bytes32[] memory hashes = store.getLabelhashes(10, 5);
        assertEq(hashes.length, 0);
    }

    function test_getLabels_caps_at_available() public {
        ILabelStore store = _freshLabelStore(ed);
        vm.startPrank(address(dotnsRegistrarController));
        store.storeLabel(LABELHASH_A, LABEL_A);
        store.storeLabel(LABELHASH_B, LABEL_B);
        vm.stopPrank();

        string[] memory labels = store.getLabels(1, 100);
        assertEq(labels.length, 1);
        assertEq(labels[0], LABEL_B);
    }
}
