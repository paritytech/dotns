// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
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
        vm.prank(owner);
        protocolRegistry.renounceOwnership();

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
            vm.expectRevert(ProtocolOwnedUpgradeable.OwnershipHeldByProtocolRegistry.selector);
            OwnableUpgradeable(proxies[i]).renounceOwnership();

            vm.prank(owner);
            vm.expectRevert(ProtocolOwnedUpgradeable.OwnershipTransferDisabled.selector);
            OwnableUpgradeable(proxies[i]).transferOwnership(stranger);
        }
        assertEq(protocolRegistry.owner(), owner);
    }

    function test_every_gated_call_passes_for_a_direct_root_dispatch() public {
        GatedCall[] memory calls = _gatedCalls();
        for (uint256 i; i < calls.length; ++i) {
            SYSTEM.setRootTarget(calls[i].target);
            _assertPassesGate(calls[i], address(this));
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
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(reached)
            )
        );
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
            _assertPassesGate(calls[i], address(this));
        }
    }

    function test_every_gated_call_passes_for_the_bootstrap_owner() public {
        GatedCall[] memory calls = _gatedCalls();
        for (uint256 i; i < calls.length; ++i) {
            _assertPassesGate(calls[i], owner);
        }
    }

    function test_revert_every_gated_call_refuses_the_owner_after_it_renounces() public {
        _renounce();
        GatedCall[] memory calls = _gatedCalls();
        for (uint256 i; i < calls.length; ++i) {
            _assertRefused(calls[i], owner);
        }
    }

    /// @notice The handover: every follower upgrades while the owner is set, then the protocol
    ///         registry upgrades and renounces in one call.
    function test_handover_upgrades_everything_then_renounces_in_one_call() public {
        address[] memory proxies = _followers();
        for (uint256 i; i < proxies.length; ++i) {
            vm.prank(owner);
            UUPSUpgradeable(proxies[i]).upgradeToAndCall(_implementationOf(proxies[i]), "");
        }
        vm.prank(owner);
        UUPSUpgradeable(address(protocolRegistry))
            .upgradeToAndCall(
                _implementationOf(address(protocolRegistry)),
                abi.encodeCall(OwnableUpgradeable.renounceOwnership, ())
            );

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

    function test_revert_renounceOwnership_refuses_a_stranger() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger)
        );
        protocolRegistry.renounceOwnership();
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

    function _renounce() internal {
        vm.prank(owner);
        protocolRegistry.renounceOwnership();
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
