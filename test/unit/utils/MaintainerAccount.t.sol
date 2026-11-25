// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {CallerAwareSystem, RootReachedContract} from "./RootGate.t.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {ProtocolOwnedUpgradeable} from "../../../contracts/utils/ProtocolOwnedUpgradeable.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";
import {IDotnsNameWhitelist} from "../../../contracts/whitelist/IDotnsNameWhitelist.sol";
import {IDotnsPopController} from "../../../contracts/registrars/IDotnsPopController.sol";
import {IDotnsPopGovernance} from "../../../contracts/registrars/IDotnsPopGovernance.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";

/// @notice The maintainer account tunes bounded operational values: it can move a value only in
///         the direction that cannot disrupt what is under way, while Root can move it either way.
///         It is off until Root sets it under `DotnsConstants.MAINTAINER`.
contract MaintainerAccountTests is BaseDotns {
    /// @notice A maintenance call, with what it should do for the maintainer.
    struct MaintenanceCall {
        string label;
        address target;
        bytes data;
    }

    CallerAwareSystem private constant SYSTEM = CallerAwareSystem(DotnsConstants.REVIVE_SYSTEM);

    address private maintainer;
    address private stranger;
    RootReachedContract private reached;

    function setUp() public override {
        super.setUp();
        vm.clearMockedCalls();
        vm.etch(DotnsConstants.REVIVE_SYSTEM, address(new CallerAwareSystem()).code);
        maintainer = makeAddr("maintainer");
        stranger = makeAddr("stranger");
        reached = new RootReachedContract();
    }

    // Who can call

    function test_revert_an_unset_maintainer_account_passes_nothing() public {
        assertEq(protocolRegistry.get(DotnsConstants.MAINTAINER), address(0));
        MaintenanceCall[] memory calls = _calls();
        for (uint256 i; i < calls.length; ++i) {
            _assertRefused(calls[i], maintainer);
        }
    }

    function test_the_maintainer_account_passes_every_maintenance_call() public {
        _setMaintainer(maintainer);
        _rootWindow(0, 7 days);
        MaintenanceCall[] memory calls = _calls();
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(maintainer);
            (bool ok,) = calls[i].target.call(calls[i].data);
            assertTrue(ok, calls[i].label);
        }
    }

    function test_revert_the_bootstrap_owner_keeps_no_maintenance_call() public {
        _setMaintainer(maintainer);
        MaintenanceCall[] memory calls = _calls();
        for (uint256 i; i < calls.length; ++i) {
            _assertRefused(calls[i], owner);
        }
    }

    function test_revert_strangers_and_contracts_root_reached_are_refused() public {
        _setMaintainer(maintainer);
        MaintenanceCall[] memory calls = _calls();
        SYSTEM.setRootTarget(address(reached));
        for (uint256 i; i < calls.length; ++i) {
            _assertRefused(calls[i], stranger);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ProtocolOwnedUpgradeable.NotRootOrMaintainer.selector, address(reached)
                )
            );
            reached.forward(calls[i].target, calls[i].data);
        }
    }

    function test_revert_removing_the_maintainer_account_turns_it_off() public {
        _setMaintainer(maintainer);
        vm.prank(owner);
        protocolRegistry.remove(DotnsConstants.MAINTAINER);

        MaintenanceCall[] memory calls = _calls();
        for (uint256 i; i < calls.length; ++i) {
            _assertRefused(calls[i], maintainer);
        }
    }

    // Values safe in either direction

    function test_the_maintainer_moves_snapshotted_and_new_request_values_either_way() public {
        _setMaintainer(maintainer);
        vm.startPrank(maintainer);

        dotnsNameEscrow.updateCooldown(dotnsNameEscrow.cooldown() / 2);
        dotnsNameEscrow.updateCooldown(dotnsNameEscrow.cooldown() * 2);
        dotnsNameEscrow.updateRedeemWindow(dotnsNameEscrow.MIN_REDEEM_WINDOW());
        dotnsNameEscrow.updateRedeemWindow(dotnsNameEscrow.MAX_REDEEM_WINDOW());

        dotnsNameWhitelist.setMaxClaimants(1);
        dotnsNameWhitelist.setMaxClaimants(DotnsConstants.WHITELIST_MAX_CLAIMANTS_LIMIT);
        dotnsNameWhitelist.setMaxReasonBytes(1);
        dotnsNameWhitelist.setMaxReasonBytes(DotnsConstants.WHITELIST_MAX_REASON_LIMIT);
        vm.stopPrank();

        assertEq(dotnsNameEscrow.redeemWindow(), dotnsNameEscrow.MAX_REDEEM_WINDOW());
        assertEq(dotnsNameWhitelist.maxClaimants(), DotnsConstants.WHITELIST_MAX_CLAIMANTS_LIMIT);
    }

    // Values the maintainer can only raise

    function test_revert_the_maintainer_cannot_lower_the_reservation_duration() public {
        _setMaintainer(maintainer);
        uint64 current = dotnsPopController.reservationDuration();

        vm.startPrank(maintainer);
        vm.expectRevert(ProtocolOwnedUpgradeable.MaintainerNotAllowed.selector);
        dotnsPopController.setReservationDuration(current - 1);

        dotnsPopController.setReservationDuration(current);
        dotnsPopController.setReservationDuration(current + 1 days);
        vm.stopPrank();
        assertEq(dotnsPopController.reservationDuration(), current + 1 days);

        _asRoot(address(dotnsPopController));
        dotnsPopController.setReservationDuration(current - 1);
        assertEq(dotnsPopController.reservationDuration(), current - 1);
    }

    function test_the_maintainer_sets_the_grant_duration_either_way() public {
        _setMaintainer(maintainer);
        uint64 current = dotnsNameWhitelist.grantDuration();

        vm.startPrank(maintainer);
        dotnsNameWhitelist.setGrantDuration(current - 1 days);
        dotnsNameWhitelist.setGrantDuration(current + 1 days);
        vm.stopPrank();
        assertEq(dotnsNameWhitelist.grantDuration(), current + 1 days);
    }

    /// @notice A grant keeps the expiry it was given: no later period moves it either way.
    function test_a_new_grant_duration_never_moves_a_live_grant() public {
        _setMaintainer(maintainer);
        _rootGrant("alpha", ed);
        uint64 expiresAt = dotnsNameWhitelist.grantExpiresAt("alpha");

        vm.startPrank(maintainer);
        dotnsNameWhitelist.setGrantDuration(DotnsConstants.WHITELIST_MAX_GRANT_DURATION);
        assertEq(dotnsNameWhitelist.grantExpiresAt("alpha"), expiresAt, "raising keeps it");
        dotnsNameWhitelist.setGrantDuration(DotnsConstants.WHITELIST_MIN_GRANT_DURATION);
        assertEq(dotnsNameWhitelist.grantExpiresAt("alpha"), expiresAt, "lowering keeps it");
        vm.stopPrank();
    }

    /// @notice A lapsed grant stays lapsed: raising the period cannot bring back its grantee.
    function test_raising_the_grant_duration_cannot_revive_a_lapsed_grant() public {
        _setMaintainer(maintainer);
        _rootGrant("alpha", ed);
        vm.warp(dotnsNameWhitelist.grantExpiresAt("alpha"));
        assertEq(dotnsNameWhitelist.granteeOf("alpha"), address(0));

        vm.prank(maintainer);
        dotnsNameWhitelist.setGrantDuration(DotnsConstants.WHITELIST_MAX_GRANT_DURATION);
        assertEq(dotnsNameWhitelist.granteeOf("alpha"), address(0), "the name stays open");
    }

    function test_revert_the_maintainer_cannot_lower_the_grant_batch_cap() public {
        _setMaintainer(maintainer);
        uint16 current = dotnsNameWhitelist.maxGrantBatch();

        vm.startPrank(maintainer);
        vm.expectRevert(ProtocolOwnedUpgradeable.MaintainerNotAllowed.selector);
        dotnsNameWhitelist.setMaxGrantBatch(current - 1);

        dotnsNameWhitelist.setMaxGrantBatch(current + 1);
        vm.stopPrank();
        assertEq(dotnsNameWhitelist.maxGrantBatch(), current + 1);

        _asRoot(address(dotnsNameWhitelist));
        dotnsNameWhitelist.setMaxGrantBatch(1);
        assertEq(dotnsNameWhitelist.maxGrantBatch(), 1);
    }

    function test_revert_raising_keeps_the_existing_bounds() public {
        _setMaintainer(maintainer);
        vm.startPrank(maintainer);
        uint64 maxReservation = dotnsPopController.MAX_RESERVATION_DURATION();
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsPopController.ReservationDurationTooHigh.selector, maxReservation + 1
            )
        );
        dotnsPopController.setReservationDuration(maxReservation + 1);

        vm.expectRevert(IDotnsNameWhitelist.GrantDurationOutOfRange.selector);
        dotnsNameWhitelist.setGrantDuration(DotnsConstants.WHITELIST_MAX_GRANT_DURATION + 1);
        vm.stopPrank();
    }

    // Request window

    function test_revert_the_maintainer_cannot_open_a_window() public {
        _setMaintainer(maintainer);
        vm.startPrank(maintainer);
        vm.expectRevert(ProtocolOwnedUpgradeable.MaintainerNotAllowed.selector);
        dotnsNameWhitelist.setWindow(0, 7 days);
        vm.expectRevert(ProtocolOwnedUpgradeable.MaintainerNotAllowed.selector);
        dotnsNameWhitelist.setWindow(1 days, 7 days);
        vm.stopPrank();
    }

    function test_revert_the_maintainer_cannot_reopen_a_window_root_closed() public {
        _setMaintainer(maintainer);
        _rootWindow(0, 3 days);
        vm.warp(block.timestamp + 3 days);
        (, uint64 closeAt) = dotnsNameWhitelist.window();
        assertEq(block.timestamp, closeAt, "a window is closed at its close timestamp");

        vm.prank(maintainer);
        vm.expectRevert(ProtocolOwnedUpgradeable.MaintainerNotAllowed.selector);
        dotnsNameWhitelist.setWindow(0, 7 days);
    }

    function test_the_maintainer_lengthens_an_open_window_and_keeps_its_opening() public {
        _setMaintainer(maintainer);
        _rootWindow(0, 3 days);
        (uint64 openAt,) = dotnsNameWhitelist.window();

        vm.warp(block.timestamp + 1 days);
        vm.prank(maintainer);
        dotnsNameWhitelist.setWindow(0, 10 days);

        (uint64 newOpenAt, uint64 newCloseAt) = dotnsNameWhitelist.window();
        assertEq(newOpenAt, openAt, "the opening stays");
        assertEq(newCloseAt, openAt + 10 days, "the duration counts from the opening");
    }

    function test_revert_the_maintainer_cannot_shorten_move_or_overextend_a_window() public {
        _setMaintainer(maintainer);
        _rootWindow(0, 10 days);
        vm.warp(block.timestamp + 1 days);

        vm.startPrank(maintainer);
        vm.expectRevert(ProtocolOwnedUpgradeable.MaintainerNotAllowed.selector);
        dotnsNameWhitelist.setWindow(0, 5 days);

        vm.expectRevert(ProtocolOwnedUpgradeable.MaintainerNotAllowed.selector);
        dotnsNameWhitelist.setWindow(1 days, 30 days);

        vm.expectRevert(IDotnsNameWhitelist.MaintainerWindowOutOfBounds.selector);
        dotnsNameWhitelist.setWindow(0, DotnsConstants.WHITELIST_MAINTAINER_MAX_WINDOW + 1);

        dotnsNameWhitelist.setWindow(0, DotnsConstants.WHITELIST_MAINTAINER_MAX_WINDOW);
        vm.stopPrank();
    }

    function test_the_maintainer_lengthens_a_scheduled_window_only() public {
        _setMaintainer(maintainer);
        _rootWindow(5 days, 10 days);
        (uint64 openAt,) = dotnsNameWhitelist.window();

        vm.startPrank(maintainer);
        vm.expectRevert(ProtocolOwnedUpgradeable.MaintainerNotAllowed.selector);
        dotnsNameWhitelist.setWindow(6 days, 10 days);

        vm.expectRevert(ProtocolOwnedUpgradeable.MaintainerNotAllowed.selector);
        dotnsNameWhitelist.setWindow(0, 9 days);

        dotnsNameWhitelist.setWindow(0, 20 days);
        vm.stopPrank();

        (uint64 newOpenAt, uint64 newCloseAt) = dotnsNameWhitelist.window();
        assertEq(newOpenAt, openAt);
        assertEq(newCloseAt, openAt + 20 days);
    }

    function test_root_sets_any_window() public {
        _asRoot(address(dotnsNameWhitelist));
        dotnsNameWhitelist.setWindow(0, 10 days);
        dotnsNameWhitelist.setWindow(0, 1);
        dotnsNameWhitelist.setWindow(365 days, 365 days);

        (uint64 openAt, uint64 closeAt) = dotnsNameWhitelist.window();
        assertEq(openAt, block.timestamp + 365 days);
        assertEq(closeAt, block.timestamp + 730 days);
    }

    // Claim and reason caps

    function test_revert_the_maintainer_cannot_lower_the_caps_while_a_window_is_live() public {
        _setMaintainer(maintainer);
        _rootWindow(1 days, 7 days);

        vm.startPrank(maintainer);
        vm.expectRevert(ProtocolOwnedUpgradeable.MaintainerNotAllowed.selector);
        dotnsNameWhitelist.setMaxClaimants(1);
        vm.expectRevert(ProtocolOwnedUpgradeable.MaintainerNotAllowed.selector);
        dotnsNameWhitelist.setMaxReasonBytes(1);

        dotnsNameWhitelist.setMaxClaimants(DotnsConstants.WHITELIST_MAX_CLAIMANTS_LIMIT);
        vm.stopPrank();
        assertEq(dotnsNameWhitelist.maxClaimants(), DotnsConstants.WHITELIST_MAX_CLAIMANTS_LIMIT);

        _asRoot(address(dotnsNameWhitelist));
        dotnsNameWhitelist.setMaxClaimants(1);
        assertEq(dotnsNameWhitelist.maxClaimants(), 1);
    }

    // Root-only decisions stay Root-only

    function test_revert_the_maintainer_makes_no_whitelist_decision() public {
        _setMaintainer(maintainer);
        string[] memory batch = new string[](1);
        batch[0] = "beta";
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeCall(IDotnsNameWhitelist.grantName, ("alpha", ed));
        calls[1] = abi.encodeCall(IDotnsNameWhitelist.grantNames, (batch, ed));
        calls[2] = abi.encodeCall(IDotnsNameWhitelist.accept, ("alpha", ed));
        calls[3] = abi.encodeCall(IDotnsNameWhitelist.reject, ("alpha", ed));
        calls[4] = abi.encodeCall(IDotnsNameWhitelist.revokeName, ("alpha"));
        calls[5] = abi.encodeCall(IDotnsNameWhitelist.setReserved, ("alpha", true));
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(maintainer);
            (bool ok, bytes memory ret) = address(dotnsNameWhitelist).call(calls[i]);
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(IDotnsNameWhitelist.NotGovernance.selector));
        }
    }

    function test_revert_the_maintainer_makes_no_pop_controller_decision() public {
        _setMaintainer(maintainer);
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(IDotnsPopGovernance.revokeName, ("alpha"));
        calls[1] = abi.encodeCall(IDotnsPopGovernance.evictReservations, ("alpha"));
        calls[2] = abi.encodeCall(IDotnsPopGovernance.evictReservation, (ed));
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(maintainer);
            (bool ok, bytes memory ret) = address(dotnsPopController).call(calls[i]);
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(IDotnsPopController.NotRoot.selector));
        }
    }

    // Renounce

    function test_root_renounces_with_a_maintainer_account_set() public {
        _setMaintainer(maintainer);
        _asRoot(address(protocolRegistry));
        protocolRegistry.renounceOwnership();
        assertEq(protocolRegistry.owner(), address(0));
        assertEq(protocolRegistry.get(DotnsConstants.MAINTAINER), maintainer);
    }

    function test_revert_the_owner_cannot_keep_the_setters_as_maintainer() public {
        _setMaintainer(owner);
        _asRoot(address(protocolRegistry));
        vm.expectRevert(IDotnsProtocolRegistry.MaintainerIsBootstrapOwner.selector);
        protocolRegistry.renounceOwnership();
        assertEq(protocolRegistry.owner(), owner);
    }

    // Helpers

    function _setMaintainer(address account) internal {
        vm.prank(owner);
        protocolRegistry.set(DotnsConstants.MAINTAINER, account);
    }

    function _asRoot(address target) internal {
        SYSTEM.setRootTarget(target);
    }

    function _rootWindow(uint64 startsIn, uint64 duration) internal {
        SYSTEM.setRootTarget(address(dotnsNameWhitelist));
        dotnsNameWhitelist.setWindow(startsIn, duration);
        SYSTEM.setRootTarget(address(0));
    }

    function _rootGrant(string memory label, address user) internal {
        SYSTEM.setRootTarget(address(dotnsNameWhitelist));
        dotnsNameWhitelist.grantName(label, user);
        SYSTEM.setRootTarget(address(0));
    }

    function _assertRefused(MaintenanceCall memory call, address caller) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = call.target.call(call.data);
        assertFalse(ok, call.label);
        assertEq(
            ret,
            abi.encodeWithSelector(ProtocolOwnedUpgradeable.NotRootOrMaintainer.selector, caller),
            call.label
        );
    }

    /// @notice Every maintenance call, with values the maintainer can set from a fresh deployment.
    function _calls() internal view returns (MaintenanceCall[] memory calls) {
        calls = new MaintenanceCall[](8);
        calls[0] = MaintenanceCall(
            "escrow.updateCooldown",
            address(dotnsNameEscrow),
            abi.encodeCall(IDotnsNameEscrow.updateCooldown, (dotnsNameEscrow.cooldown()))
        );
        calls[1] = MaintenanceCall(
            "escrow.updateRedeemWindow",
            address(dotnsNameEscrow),
            abi.encodeCall(IDotnsNameEscrow.updateRedeemWindow, (dotnsNameEscrow.redeemWindow()))
        );
        calls[2] = MaintenanceCall(
            "popController.setReservationDuration",
            address(dotnsPopController),
            abi.encodeCall(
                IDotnsPopController.setReservationDuration,
                (dotnsPopController.reservationDuration())
            )
        );
        calls[3] = MaintenanceCall(
            "whitelist.setMaxClaimants",
            address(dotnsNameWhitelist),
            abi.encodeCall(IDotnsNameWhitelist.setMaxClaimants, (dotnsNameWhitelist.maxClaimants()))
        );
        calls[4] = MaintenanceCall(
            "whitelist.setMaxReasonBytes",
            address(dotnsNameWhitelist),
            abi.encodeCall(
                IDotnsNameWhitelist.setMaxReasonBytes, (dotnsNameWhitelist.maxReasonBytes())
            )
        );
        calls[5] = MaintenanceCall(
            "whitelist.setMaxGrantBatch",
            address(dotnsNameWhitelist),
            abi.encodeCall(
                IDotnsNameWhitelist.setMaxGrantBatch, (dotnsNameWhitelist.maxGrantBatch())
            )
        );
        calls[6] = MaintenanceCall(
            "whitelist.setGrantDuration",
            address(dotnsNameWhitelist),
            abi.encodeCall(
                IDotnsNameWhitelist.setGrantDuration, (dotnsNameWhitelist.grantDuration())
            )
        );
        calls[7] = MaintenanceCall(
            "whitelist.setWindow",
            address(dotnsNameWhitelist),
            abi.encodeCall(IDotnsNameWhitelist.setWindow, (0, 7 days))
        );
    }
}
