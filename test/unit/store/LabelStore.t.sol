// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {ILabelStore} from "../../../contracts/store/ILabelStore.sol";
import {LabelStore} from "../../../contracts/store/LabelStore.sol";
import {IStoreFactory} from "../../../contracts/store/IStoreFactory.sol";
import {IDotnsController} from "../../../contracts/registrars/IDotnsController.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {Multicall3} from "../../../contracts/utils/Multicall3.sol";

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

    function test_storeLabel_reverts_for_an_unrelated_account() public {
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

    /// @notice Registry membership on its own grants nothing. An address held under a key that
    /// carries no write authority cannot write, however it got there.
    function test_storeLabel_rejects_an_address_under_an_unrelated_key() public {
        address attacker = makeAddr("attacker");

        vm.prank(owner);
        protocolRegistry.set(keccak256("temp.key"), attacker);
        assertTrue(protocolRegistry.isRegisteredAddress(attacker));

        ILabelStore store = _freshLabelStore(ed);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ILabelStore.NotAuthorised.selector, attacker));
        store.storeLabel(LABELHASH_A, LABEL_A);
    }

    /// @notice Holding the `CONTROLLER` registry key is not authority. Authority is the set the
    /// registrar itself accepts, so a key alone writes nothing.
    function test_storeLabel_rejects_the_controller_key_holder() public {
        address keyOnly = makeAddr("keyOnly");

        vm.prank(owner);
        protocolRegistry.set(DotnsConstants.CONTROLLER, keyOnly);
        assertFalse(dotnsRegistrar.controllers(IDotnsController(keyOnly)));

        ILabelStore store = _freshLabelStore(ed);

        vm.prank(keyOnly);
        vm.expectRevert(abi.encodeWithSelector(ILabelStore.NotAuthorised.selector, keyOnly));
        store.storeLabel(LABELHASH_A, LABEL_A);
    }

    /// @notice Authority follows the registrar's current controller set rather than a snapshot:
    /// a controller can write while authorised, and stops the moment it is removed.
    function test_caller_losing_its_controller_rights_rejects_subsequent_write() public {
        address rotatingWriter = makeAddr("rotatingWriter");

        vm.prank(owner);
        dotnsRegistrar.addController(IDotnsController(rotatingWriter));

        ILabelStore store = _freshLabelStore(ed);

        vm.prank(rotatingWriter);
        store.storeLabel(LABELHASH_A, LABEL_A);
        assertTrue(store.hasLabel(LABELHASH_A));

        vm.prank(owner);
        dotnsRegistrar.removeController(IDotnsController(rotatingWriter));

        vm.prank(rotatingWriter);
        vm.expectRevert(abi.encodeWithSelector(ILabelStore.NotAuthorised.selector, rotatingWriter));
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

    /// @notice The factory's gate accepts the same writers as the store's, so both entrypoints
    /// are covered on the accept side rather than only on the reject side.
    function test_deployLabelStoreFor_accepts_every_write_bearing_component() public {
        address[3] memory writers =
            [address(dotnsRegistrar), address(dotnsRegistrarController), address(dotnsRegistry)];
        address[3] memory users = [ed, leonardo, tiago];

        for (uint256 i; i < writers.length; ++i) {
            vm.prank(writers[i]);
            address store = storeFactory.deployLabelStoreFor(users[i]);
            assertEq(ILabelStore(store).owner(), users[i], "a write-bearing component was refused");
        }
    }

    /// @notice A registry key pointing at a codeless address fails closed. The controller lookup
    /// is a high-level call, so the compiler's code-size check reverts rather than reading a
    /// bare `false` and silently widening or narrowing the writer set.
    function test_storeLabel_reverts_when_the_registrar_key_has_no_code() public {
        ILabelStore store = _freshLabelStore(ed);

        vm.prank(owner);
        protocolRegistry.set(DotnsConstants.REGISTRAR, makeAddr("noCodeRegistrar"));

        vm.prank(address(dotnsRegistrarController));
        vm.expectRevert();
        store.storeLabel(LABELHASH_A, LABEL_A);
    }

    /// @notice Each protocol component that legitimately writes a label may do so: the registrar
    /// on a mint or transfer, the registrar controller on a public registration, the PoP
    /// controller on a gateway name, and the registry on a subname.
    function test_storeLabel_accepts_every_write_bearing_component() public {
        ILabelStore store = _freshLabelStore(ed);

        address[4] memory writers = [
            address(dotnsRegistrar),
            address(dotnsRegistrarController),
            address(dotnsPopController),
            address(dotnsRegistry)
        ];

        for (uint256 i; i < writers.length; ++i) {
            bytes32 labelhash = keccak256(abi.encodePacked("writer", i));
            vm.prank(writers[i]);
            store.storeLabel(labelhash, LABEL_A);
            assertTrue(store.hasLabel(labelhash), "a write-bearing component was refused");
        }
    }

    /// @notice Registry membership is not write authority. These are all registered so consumers
    /// can discover them, and none of them writes a label.
    function test_storeLabel_rejects_a_registered_non_writer() public {
        ILabelStore store = _freshLabelStore(ed);

        address[3] memory registeredNonWriters =
            [address(dotnsReverseResolver), address(dotnsNameEscrow), address(popRules)];

        for (uint256 i; i < registeredNonWriters.length; ++i) {
            address caller = registeredNonWriters[i];
            assertTrue(
                protocolRegistry.isRegisteredAddress(caller), "fixture is not registered at all"
            );
            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(ILabelStore.NotAuthorised.selector, caller));
            store.storeLabel(LABELHASH_A, LABEL_A);
        }
    }

    /// @notice Regression for the store-poisoning path: a call forwarder registered purely for
    /// discovery makes the call anyone asks it to, so the store sees the forwarder as its caller.
    /// Gating on registry membership let any account write any store through it; gating on the
    /// registrar and its controllers does not.
    function test_storeLabel_rejects_a_registered_call_forwarder() public {
        ILabelStore store = _freshLabelStore(ed);

        Multicall3 forwarder = new Multicall3();
        vm.prank(owner);
        protocolRegistry.set(DotnsConstants.MULTICALL3, address(forwarder));
        assertTrue(protocolRegistry.isRegisteredAddress(address(forwarder)));

        Multicall3.Call[] memory calls = new Multicall3.Call[](1);
        calls[0] = Multicall3.Call({
            target: address(store),
            callData: abi.encodeCall(ILabelStore.storeLabel, (LABELHASH_A, LABEL_A))
        });

        vm.prank(tiago);
        vm.expectRevert(bytes("Multicall3: call failed"));
        forwarder.aggregate(calls);

        assertFalse(store.hasLabel(LABELHASH_A), "an unauthorised write landed");

        // Pin the gate itself rather than the forwarder's generic bubble-up.
        vm.prank(address(forwarder));
        vm.expectRevert(
            abi.encodeWithSelector(ILabelStore.NotAuthorised.selector, address(forwarder))
        );
        store.storeLabel(LABELHASH_A, LABEL_A);

        // The same authority mistake reached `StoreFactory`: a registered forwarder must not be
        // able to create a store for someone either.
        vm.prank(address(forwarder));
        vm.expectRevert(
            abi.encodeWithSelector(IStoreFactory.NotAuthorised.selector, address(forwarder))
        );
        storeFactory.deployLabelStoreFor(leonardo);
    }

    /// @notice The factory owner deploys stores but is not a label writer: owning the factory is
    /// a deployment power, not authority over what a user's store says.
    function test_storeLabel_rejects_the_factory_owner() public {
        ILabelStore store = _freshLabelStore(ed);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ILabelStore.NotAuthorised.selector, owner));
        store.storeLabel(LABELHASH_A, LABEL_A);
    }
}
