// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {CallerAwareSystem, RootReachedContract} from "./RootGate.t.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {
    BootstrapOwnableUpgradeable
} from "../../../contracts/utils/BootstrapOwnableUpgradeable.sol";
import {ProtocolOwnedUpgradeable} from "../../../contracts/utils/ProtocolOwnedUpgradeable.sol";
import {IDotnsCostModelRegistry} from "../../../contracts/pop/IDotnsCostModelRegistry.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";
import {IDotnsPopController} from "../../../contracts/registrars/IDotnsPopController.sol";
import {IDotnsController} from "../../../contracts/registrars/IDotnsController.sol";
import {IDotnsRegistrar} from "../../../contracts/registrars/IDotnsRegistrar.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {IStoreFactory} from "../../../contracts/store/IStoreFactory.sol";
import {LabelStore} from "../../../contracts/store/LabelStore.sol";
import {UserStore} from "../../../contracts/store/UserStore.sol";
import {StoreFactory} from "../../../contracts/store/StoreFactory.sol";
import {PopRules} from "../../../contracts/pop/PopRules.sol";
import {DotnsPopController} from "../../../contracts/registrars/DotnsPopController.sol";
import {DotnsRegistrarController} from "../../../contracts/registrars/DotnsRegistrarController.sol";
import {DotnsContentResolver} from "../../../contracts/resolvers/DotnsContentResolver.sol";
import {DotnsPopResolver} from "../../../contracts/resolvers/DotnsPopResolver.sol";
import {DotnsResolver} from "../../../contracts/resolvers/DotnsResolver.sol";
import {DotnsReverseResolver} from "../../../contracts/resolvers/DotnsReverseResolver.sol";
import {DotnsNameWhitelist} from "../../../contracts/whitelist/DotnsNameWhitelist.sol";

/// @notice An implementation as it was before the shared owner: its owner sits in its own
///         `OwnableUpgradeable` slot and authorises its upgrades.
contract LegacyOwnedImplementation is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    IDotnsProtocolRegistry public protocolRegistry;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        IDotnsProtocolRegistry registry
    )
        external
        initializer
    {
        __Ownable_init(initialOwner);
        protocolRegistry = registry;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}

/// @notice The same contract after the migration: same layout, owner read from the registry.
contract MigratedImplementation is Initializable, UUPSUpgradeable, ProtocolOwnedUpgradeable {
    IDotnsProtocolRegistry public protocolRegistry;

    constructor() {
        _disableInitializers();
    }

    function _protocolRegistryAddress() internal view override returns (address registry) {
        return address(protocolRegistry);
    }

    function _authorizeUpgrade(address) internal override onlyRootOrOwner {}
}

/// @notice A superseded cost model registry with a plain owner of its own.
contract LegacyCostModelRegistry is Ownable {
    constructor(address owner_) Ownable(owner_) {}
}

contract NoOwnerContract {}

contract RevertingOwnerContract {
    function owner() external pure returns (address) {
        revert("no owner");
    }
}

/// @notice Every function behind the bootstrap owner gate, including the upgrade of every proxy,
///         accepts a direct Root dispatch and the owner while one is set, and refuses everyone
/// else.
contract BootstrapOwnerGateTests is BaseDotns {
    /// @notice A call behind the gate. `afterGate` is the revert data the call returns once it
    ///         passes the gate, or empty when it succeeds.
    struct GatedCall {
        string label;
        address target;
        bytes data;
        bytes afterGate;
    }

    CallerAwareSystem private constant SYSTEM = CallerAwareSystem(DotnsConstants.REVIVE_SYSTEM);
    bytes32 private constant TEST_KEY = bytes32("bootstrapGateTest");
    /// @dev Slot of the length of `DotnsProtocolRegistry._keys`.
    bytes32 private constant KEYS_LENGTH_SLOT = bytes32(uint256(6));
    /// @dev ERC-7201 slot of `OwnableUpgradeable`'s owner.
    bytes32 private constant OWNABLE_STORAGE =
        0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    RootReachedContract private reached;
    address private stranger;

    function setUp() public override {
        super.setUp();
        vm.clearMockedCalls();
        vm.etch(DotnsConstants.REVIVE_SYSTEM, address(new CallerAwareSystem()).code);
        reached = new RootReachedContract();
        stranger = _createUser("stranger");
    }

    function test_every_contract_reports_the_protocol_registry_owner() public view {
        address[] memory owned = _ownedContracts();
        for (uint256 i; i < owned.length; ++i) {
            assertEq(OwnableUpgradeable(owned[i]).owner(), owner, vm.toString(owned[i]));
        }
    }

    function test_one_renounce_on_the_protocol_registry_ends_the_bootstrap_everywhere() public {
        _renounce();

        address[] memory owned = _ownedContracts();
        for (uint256 i; i < owned.length; ++i) {
            assertEq(OwnableUpgradeable(owned[i]).owner(), address(0), vm.toString(owned[i]));
        }
    }

    function test_revert_a_forged_local_owner_slot_grants_nothing() public {
        address[] memory proxies = _followers();
        for (uint256 i; i < proxies.length; ++i) {
            vm.store(proxies[i], OWNABLE_STORAGE, bytes32(uint256(uint160(stranger))));
        }
        GatedCall[] memory calls = _gatedCalls();
        for (uint256 i; i < calls.length; ++i) {
            if (calls[i].target == address(protocolRegistry)) continue;
            _assertRefused(calls[i], stranger);
        }
    }

    function test_revert_followers_cannot_renounce_or_transfer() public {
        address[] memory proxies = _followers();
        for (uint256 i; i < proxies.length; ++i) {
            vm.prank(owner);
            (bool renounced,) =
                proxies[i].call(abi.encodeCall(OwnableUpgradeable.renounceOwnership, ()));
            assertFalse(renounced, vm.toString(proxies[i]));

            vm.prank(owner);
            (bool transferred,) =
                proxies[i].call(abi.encodeCall(OwnableUpgradeable.transferOwnership, (stranger)));
            assertFalse(transferred, vm.toString(proxies[i]));
        }
        assertEq(protocolRegistry.owner(), owner);
    }

    function test_every_gated_call_passes_for_a_direct_root_dispatch() public {
        GatedCall[] memory calls = _gatedCalls();
        for (uint256 i; i < calls.length; ++i) {
            SYSTEM.setRootTarget(calls[i].target);
            _assertPassesGate(calls[i], stranger);
        }
    }

    function test_revert_every_gated_call_refuses_a_contract_root_reached() public {
        GatedCall[] memory calls = _gatedCalls();
        SYSTEM.setRootTarget(address(reached));
        for (uint256 i; i < calls.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(reached)
                )
            );
            reached.forward(calls[i].target, calls[i].data);
        }
    }

    function test_root_removes_the_bootstrap_owner() public {
        SYSTEM.setRootTarget(address(protocolRegistry));
        protocolRegistry.renounceOwnership();

        assertEq(protocolRegistry.owner(), address(0));
        assertEq(dotnsRegistrar.owner(), address(0));
    }

    function test_revert_root_reached_contract_cannot_renounce() public {
        SYSTEM.setRootTarget(address(reached));
        vm.expectRevert(BootstrapOwnableUpgradeable.RenounceRequiresRoot.selector);
        reached.forward(
            address(protocolRegistry), abi.encodeCall(OwnableUpgradeable.renounceOwnership, ())
        );
        assertEq(protocolRegistry.owner(), owner);
    }

    function test_root_keeps_every_gated_call_after_the_owner_renounces() public {
        _renounce();
        GatedCall[] memory calls = _gatedCalls();
        for (uint256 i; i < calls.length; ++i) {
            SYSTEM.setRootTarget(calls[i].target);
            _assertPassesGate(calls[i], stranger);
        }
    }

    function test_every_gated_call_passes_for_the_bootstrap_owner() public {
        GatedCall[] memory calls = _gatedCalls();
        for (uint256 i; i < calls.length; ++i) {
            _assertPassesGate(calls[i], owner);
        }
        // No gated call moves the registry a follower reads its owner from.
        address[] memory owned = _ownedContracts();
        for (uint256 i; i < owned.length; ++i) {
            if (owned[i] == address(protocolRegistry)) continue;
            assertEq(OwnableUpgradeable(owned[i]).owner(), owner, vm.toString(owned[i]));
        }
    }

    function test_revert_every_gated_call_refuses_the_owner_after_it_renounces() public {
        _renounce();
        GatedCall[] memory calls = _gatedCalls();
        for (uint256 i; i < calls.length; ++i) {
            _assertRefused(calls[i], owner);
        }
    }

    /// @notice The handover: every proxy upgrades while the owner is set, then Root renounces.
    function test_handover_upgrades_everything_then_renounces_in_one_call() public {
        address[] memory proxies = _followers();
        for (uint256 i; i < proxies.length; ++i) {
            vm.prank(owner);
            UUPSUpgradeable(proxies[i]).upgradeToAndCall(_implementationOf(proxies[i]), "");
        }
        vm.prank(owner);
        UUPSUpgradeable(address(protocolRegistry))
            .upgradeToAndCall(_implementationOf(address(protocolRegistry)), "");
        _renounce();

        address[] memory owned = _ownedContracts();
        for (uint256 i; i < owned.length; ++i) {
            assertEq(OwnableUpgradeable(owned[i]).owner(), address(0), vm.toString(owned[i]));
        }
    }

    function test_revert_transferOwnership_is_disabled_on_the_protocol_registry() public {
        vm.prank(owner);
        vm.expectRevert(BootstrapOwnableUpgradeable.OwnershipTransferDisabled.selector);
        protocolRegistry.transferOwnership(stranger);

        SYSTEM.setRootTarget(address(protocolRegistry));
        vm.expectRevert(BootstrapOwnableUpgradeable.OwnershipTransferDisabled.selector);
        protocolRegistry.transferOwnership(stranger);

        assertEq(protocolRegistry.owner(), owner);
    }

    function test_revert_every_gated_call_refuses_a_stranger() public {
        GatedCall[] memory calls = _gatedCalls();
        for (uint256 i; i < calls.length; ++i) {
            _assertRefused(calls[i], stranger);
        }
    }

    function test_revert_renounceOwnership_refuses_everyone_but_root() public {
        vm.prank(stranger);
        vm.expectRevert(BootstrapOwnableUpgradeable.RenounceRequiresRoot.selector);
        protocolRegistry.renounceOwnership();

        // The owner cannot renounce: on a runtime where Root cannot pass the gate behind a proxy,
        // an owner renounce would leave no account able to upgrade.
        vm.prank(owner);
        vm.expectRevert(BootstrapOwnableUpgradeable.RenounceRequiresRoot.selector);
        protocolRegistry.renounceOwnership();

        assertEq(protocolRegistry.owner(), owner);
    }

    function test_revert_renounce_fails_on_a_runtime_where_root_cannot_pass_behind_a_proxy()
        public
    {
        // Without the runtime fix, `callerIsRoot` is false behind a proxy: model it by letting the
        // precompile answer true for no contract.
        SYSTEM.setRootTarget(address(0));
        vm.expectRevert(BootstrapOwnableUpgradeable.RenounceRequiresRoot.selector);
        protocolRegistry.renounceOwnership();
        assertEq(protocolRegistry.owner(), owner);
    }

    function test_revert_renounce_checks_known_keys_when_the_key_list_is_empty() public {
        address legacy = _deployLegacyFollower();
        vm.prank(owner);
        protocolRegistry.set(DotnsConstants.RESOLVER, legacy);
        // A registry upgraded from a release without the key list starts with it empty until
        // `initializeKeys` runs. The known keys still cover it.
        vm.store(address(protocolRegistry), KEYS_LENGTH_SLOT, bytes32(0));
        assertEq(protocolRegistry.keys().length, 0);

        SYSTEM.setRootTarget(address(protocolRegistry));
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsProtocolRegistry.OwnerStillSet.selector,
                DotnsConstants.RESOLVER,
                legacy,
                owner
            )
        );
        protocolRegistry.renounceOwnership();
    }

    function test_revert_renounce_fails_while_a_registered_contract_keeps_its_own_owner() public {
        address legacy = _deployLegacyFollower();
        vm.prank(owner);
        protocolRegistry.set(TEST_KEY, legacy);

        SYSTEM.setRootTarget(address(protocolRegistry));
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsProtocolRegistry.OwnerStillSet.selector, TEST_KEY, legacy, owner
            )
        );
        protocolRegistry.renounceOwnership();

        assertEq(protocolRegistry.owner(), owner);
    }

    function test_revert_renounce_fails_while_a_superseded_cost_model_registry_is_registered()
        public
    {
        address legacy = address(new LegacyCostModelRegistry(owner));
        vm.prank(owner);
        protocolRegistry.set(DotnsConstants.COST_MODEL, legacy);

        SYSTEM.setRootTarget(address(protocolRegistry));
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsProtocolRegistry.OwnerStillSet.selector,
                DotnsConstants.COST_MODEL,
                legacy,
                owner
            )
        );
        protocolRegistry.renounceOwnership();
        SYSTEM.setRootTarget(address(0));

        vm.prank(owner);
        protocolRegistry.set(DotnsConstants.COST_MODEL, address(costModelRegistry));
        _renounce();
        assertEq(costModelRegistry.owner(), address(0));
    }

    function test_renounce_skips_registered_contracts_without_an_owner() public {
        vm.startPrank(owner);
        protocolRegistry.set(TEST_KEY, address(new NoOwnerContract()));
        protocolRegistry.set(bytes32("revertingOwner"), address(new RevertingOwnerContract()));
        vm.stopPrank();
        _renounce();

        assertEq(protocolRegistry.owner(), address(0));
    }

    /// @notice The live migration: the old code authorises the upgrade through its own owner, the
    ///         new code reads the registry's owner, and the renounce then ends it.
    function test_migration_from_a_legacy_owner_to_the_shared_owner() public {
        address follower = _deployLegacyFollower();
        vm.prank(owner);
        protocolRegistry.set(TEST_KEY, follower);

        address migrated = address(new MigratedImplementation());
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger)
        );
        UUPSUpgradeable(follower).upgradeToAndCall(migrated, "");

        vm.prank(owner);
        UUPSUpgradeable(follower).upgradeToAndCall(migrated, "");
        assertEq(MigratedImplementation(follower).owner(), owner);
        // The old slot keeps the old owner as dead storage.
        assertEq(address(uint160(uint256(vm.load(follower, OWNABLE_STORAGE)))), owner);

        _renounce();
        assertEq(MigratedImplementation(follower).owner(), address(0));

        address next = address(new MigratedImplementation());
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolOwnedUpgradeable.OwnableUnauthorizedAccount.selector, owner
            )
        );
        UUPSUpgradeable(follower).upgradeToAndCall(next, "");

        SYSTEM.setRootTarget(follower);
        vm.prank(stranger);
        UUPSUpgradeable(follower).upgradeToAndCall(next, "");
        assertEq(_implementationOf(follower), next);
    }

    function test_deployLabelStoreFor_accepts_root_and_the_bootstrap_owner_only() public {
        address alice = _createUser("labelStoreAlice");
        address bob = _createUser("labelStoreBob");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IStoreFactory.NotAuthorised.selector, stranger));
        storeFactory.deployLabelStoreFor(alice);

        vm.prank(owner);
        storeFactory.deployLabelStoreFor(alice);

        _renounce();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStoreFactory.NotAuthorised.selector, owner));
        storeFactory.deployLabelStoreFor(bob);

        SYSTEM.setRootTarget(address(storeFactory));
        vm.prank(stranger);
        storeFactory.deployLabelStoreFor(bob);
        assertTrue(storeFactory.getLabelStore(bob) != address(0));
    }

    function test_revert_initialisers_refuse_a_zero_protocol_registry() public {
        IDotnsProtocolRegistry zero = IDotnsProtocolRegistry(address(0));
        address[8] memory implementations = [
            address(new PopRules()),
            address(new DotnsPopController()),
            address(new DotnsRegistrarController()),
            address(new DotnsContentResolver()),
            address(new DotnsPopResolver()),
            address(new DotnsResolver()),
            address(new DotnsReverseResolver()),
            address(new DotnsNameWhitelist())
        ];
        bytes[8] memory inits = [
            abi.encodeCall(PopRules.initialize, (zero)),
            abi.encodeCall(DotnsPopController.initialize, (zero, DEFAULT_RESERVATION_DURATION)),
            abi.encodeCall(DotnsRegistrarController.initialize, (zero, 6 seconds, 1 days)),
            abi.encodeCall(DotnsContentResolver.initialize, (zero)),
            abi.encodeCall(DotnsPopResolver.initialize, (zero)),
            abi.encodeCall(DotnsResolver.initialize, (zero)),
            abi.encodeCall(DotnsReverseResolver.initialize, (zero)),
            abi.encodeCall(DotnsNameWhitelist.initialize, (zero))
        ];
        for (uint256 i; i < implementations.length; ++i) {
            vm.expectRevert(ProtocolOwnedUpgradeable.ZeroProtocolRegistry.selector);
            new ERC1967Proxy(implementations[i], inits[i]);
        }
    }

    /// @notice Calls `gated` as `caller` and checks that it passed the gate.
    function _assertPassesGate(GatedCall memory gated, address caller) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = gated.target.call(gated.data);
        if (gated.afterGate.length == 0) {
            assertTrue(ok, gated.label);
        } else {
            assertFalse(ok, gated.label);
            assertEq(ret, gated.afterGate, gated.label);
        }
    }

    /// @notice Calls `gated` as `caller` and checks that the gate refused it.
    function _assertRefused(GatedCall memory gated, address caller) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = gated.target.call(gated.data);
        assertFalse(ok, gated.label);
        assertEq(
            ret,
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, caller),
            gated.label
        );
    }

    function _deployLegacyFollower() internal returns (address follower) {
        follower = address(
            new ERC1967Proxy(
                address(new LegacyOwnedImplementation()),
                abi.encodeCall(
                    LegacyOwnedImplementation.initialize,
                    (owner, IDotnsProtocolRegistry(address(protocolRegistry)))
                )
            )
        );
    }

    /// @notice Renounces as Root, the only party that can.
    function _renounce() internal {
        SYSTEM.setRootTarget(address(protocolRegistry));
        protocolRegistry.renounceOwnership();
        SYSTEM.setRootTarget(address(0));
    }

    function _implementationOf(address proxy) internal view returns (address implementation) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function _proxies() internal view returns (address[] memory proxies) {
        proxies = new address[](13);
        proxies[0] = address(dotnsNameEscrow);
        proxies[1] = address(popRules);
        proxies[2] = address(dotnsPopController);
        proxies[3] = address(dotnsRegistrar);
        proxies[4] = address(dotnsRegistrarController);
        proxies[5] = address(protocolRegistry);
        proxies[6] = address(dotnsRegistry);
        proxies[7] = address(dotnsContentResolver);
        proxies[8] = address(dotnsPopResolver);
        proxies[9] = address(dotnsResolver);
        proxies[10] = address(dotnsReverseResolver);
        proxies[11] = address(storeFactory);
        proxies[12] = address(dotnsNameWhitelist);
    }

    function _followers() internal view returns (address[] memory followers) {
        address[] memory proxies = _proxies();
        followers = new address[](proxies.length - 1);
        uint256 n;
        for (uint256 i; i < proxies.length; ++i) {
            if (proxies[i] != address(protocolRegistry)) followers[n++] = proxies[i];
        }
    }

    function _ownedContracts() internal view returns (address[] memory owned) {
        address[] memory proxies = _proxies();
        owned = new address[](proxies.length + 1);
        for (uint256 i; i < proxies.length; ++i) {
            owned[i] = proxies[i];
        }
        owned[proxies.length] = address(costModelRegistry);
    }

    /// @notice Every call behind the gate, in an order that lets each one pass after the others.
    function _gatedCalls() internal returns (GatedCall[] memory calls) {
        address[] memory proxies = _proxies();
        calls = new GatedCall[](proxies.length + 16);
        uint256 n;

        for (uint256 i; i < proxies.length; ++i) {
            calls[n++] = GatedCall(
                string.concat("upgradeToAndCall ", vm.toString(proxies[i])),
                proxies[i],
                abi.encodeCall(
                    UUPSUpgradeable.upgradeToAndCall, (_implementationOf(proxies[i]), "")
                ),
                ""
            );
        }

        calls[n++] = GatedCall(
            "escrow.updateCooldown",
            address(dotnsNameEscrow),
            abi.encodeCall(IDotnsNameEscrow.updateCooldown, (dotnsNameEscrow.cooldown())),
            ""
        );
        calls[n++] = GatedCall(
            "escrow.updateRedeemWindow",
            address(dotnsNameEscrow),
            abi.encodeCall(IDotnsNameEscrow.updateRedeemWindow, (dotnsNameEscrow.redeemWindow())),
            ""
        );
        calls[n++] = GatedCall(
            "escrow.clearCustodyOnUpgrade",
            address(dotnsNameEscrow),
            abi.encodeWithSignature("clearCustodyOnUpgrade()"),
            ""
        );
        calls[n++] = GatedCall(
            "costModelRegistry.setCurrentVersion",
            address(costModelRegistry),
            abi.encodeCall(
                IDotnsCostModelRegistry.setCurrentVersion, (costModelRegistry.currentVersion())
            ),
            ""
        );
        uint256 registeredVersion = costModelRegistry.currentVersion();
        calls[n++] = GatedCall(
            "costModelRegistry.register",
            address(costModelRegistry),
            abi.encodeCall(
                IDotnsCostModelRegistry.register, (costModelRegistry.modelOf(registeredVersion))
            ),
            abi.encodeWithSelector(
                IDotnsCostModelRegistry.AlreadyRegistered.selector, registeredVersion
            )
        );
        calls[n++] = GatedCall(
            "popController.setReservationDuration",
            address(dotnsPopController),
            abi.encodeCall(
                IDotnsPopController.setReservationDuration,
                (dotnsPopController.reservationDuration())
            ),
            ""
        );
        calls[n++] = GatedCall(
            "registrar.addController",
            address(dotnsRegistrar),
            abi.encodeCall(IDotnsRegistrar.addController, (IDotnsController(address(0xC0)))),
            ""
        );
        calls[n++] = GatedCall(
            "registrar.removeController",
            address(dotnsRegistrar),
            abi.encodeCall(IDotnsRegistrar.removeController, (IDotnsController(address(0xC0)))),
            ""
        );
        calls[n++] = GatedCall(
            "protocolRegistry.set",
            address(protocolRegistry),
            abi.encodeCall(IDotnsProtocolRegistry.set, (TEST_KEY, address(0xBEEF))),
            ""
        );
        calls[n++] = GatedCall(
            "protocolRegistry.setExpectedCodehash",
            address(protocolRegistry),
            abi.encodeCall(
                IDotnsProtocolRegistry.setExpectedCodehash, (TEST_KEY, bytes32(uint256(1)))
            ),
            ""
        );
        calls[n++] = GatedCall(
            "protocolRegistry.remove",
            address(protocolRegistry),
            abi.encodeCall(IDotnsProtocolRegistry.remove, (TEST_KEY)),
            ""
        );
        calls[n++] = GatedCall(
            "protocolRegistry.setProtocolVersion",
            address(protocolRegistry),
            abi.encodeCall(IDotnsProtocolRegistry.setProtocolVersion, ("9.9.9")),
            ""
        );
        calls[n++] = GatedCall(
            "protocolRegistry.initializeKeys",
            address(protocolRegistry),
            abi.encodeCall(IDotnsProtocolRegistry.initializeKeys, ()),
            ""
        );
        calls[n++] = GatedCall(
            "storeFactory.upgradeLabelStoreImplementation",
            address(storeFactory),
            abi.encodeCall(
                IStoreFactory.upgradeLabelStoreImplementation, (address(new LabelStore()))
            ),
            ""
        );
        calls[n++] = GatedCall(
            "storeFactory.upgradeUserStoreImplementation",
            address(storeFactory),
            abi.encodeCall(
                IStoreFactory.upgradeUserStoreImplementation, (address(new UserStore()))
            ),
            ""
        );
        // The grant clock already runs on a fresh whitelist, so the call reverts once it passes
        // the gate.
        calls[n++] = GatedCall(
            "whitelist.initializeGrantExpiry",
            address(dotnsNameWhitelist),
            abi.encodeWithSignature("initializeGrantExpiry()"),
            abi.encodeWithSelector(Initializable.InvalidInitialization.selector)
        );
        assert(n == calls.length);
    }
}
