// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsPopController} from "../../../contracts/registrars/IDotnsPopController.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DotnsPopControllerEntrypointsTests
/// @notice The gateway entrypoints' label and shared errors, the removed pre-1.0.0 entrypoints,
///         the reservation-queue events, and a place freed from the back of a queue.
/// @dev The shape check inside `_validateDeviceLabel` is preceded by the same check at each of its
///      callers, so it is reached through them and has no test of its own.
contract DotnsPopControllerEntrypointsTests is BaseDotns {
    /// @notice Selectors of the pre-1.0.0 entrypoints `reserveLiteName`, `reserveBaseName` and
    ///         `registerBaseName`, and the interface id they formed.
    bytes4 internal constant REMOVED_RESERVE_LITE_NAME = 0x220015c0;
    bytes4 internal constant REMOVED_RESERVE_BASE_NAME = 0xd89f1bce;
    bytes4 internal constant REMOVED_REGISTER_BASE_NAME = 0x7c4b376b;
    bytes4 internal constant REMOVED_LEGACY_INTERFACE_ID = 0x86d43965;

    // Removed entrypoints

    function test_the_removed_interface_id_is_the_xor_of_its_selectors() public pure {
        assertEq(
            REMOVED_RESERVE_LITE_NAME ^ REMOVED_RESERVE_BASE_NAME ^ REMOVED_REGISTER_BASE_NAME,
            REMOVED_LEGACY_INTERFACE_ID
        );
    }

    function test_the_legacy_interface_is_no_longer_reported() public view {
        assertFalse(dotnsPopController.supportsInterface(REMOVED_LEGACY_INTERFACE_ID));
        assertTrue(
            dotnsPopController.supportsInterface(type(IDotnsPopController).interfaceId),
            "current interface"
        );
    }

    /// @notice Root reaching a removed selector reverts with no data: the controller has no
    ///         fallback, so nothing answers it.
    function test_the_removed_entrypoints_revert_under_root() public {
        IDotnsPopController.DeviceNameIssuance memory issuance =
            IDotnsPopController.DeviceNameIssuance({label: DEVICE_LABEL_A, user: ed, chatKey: ""});
        assertEq(_rootRevertData(abi.encodeWithSelector(REMOVED_RESERVE_LITE_NAME, issuance)), "");
        assertEq(
            _rootRevertData(
                abi.encodeWithSelector(
                    REMOVED_RESERVE_BASE_NAME, _combined(DEVICE_LABEL_A, PERSONHOOD_LABEL_A)
                )
            ),
            ""
        );
        assertEq(
            _rootRevertData(
                abi.encodeWithSelector(
                    REMOVED_REGISTER_BASE_NAME,
                    IDotnsPopController.PersonhoodNameIssuance({
                        label: PERSONHOOD_LABEL_A, user: ed, link: _linkFresh("")
                    })
                )
            ),
            ""
        );
    }

    // Label errors

    /// @notice `_issueDeviceName`, shape check: a label with no separator.
    function test_device_name_shape_error() public {
        IDotnsPopController.DeviceNameIssuance memory issuance =
            IDotnsPopController.DeviceNameIssuance({label: "michael", user: ed, chatKey: ""});
        vm.expectRevert(IDotnsPopController.InvalidDeviceLabel.selector);
        _rootIssueDeviceName(issuance);

        IDotnsPopController.DeviceNameIssuanceWithReservation memory combined =
            IDotnsPopController.DeviceNameIssuanceWithReservation({
                issuance: issuance, reservedLabel: ""
            });
        vm.expectRevert(IDotnsPopController.InvalidDeviceLabel.selector);
        _rootIssueDeviceNameWithReservation(combined);
    }

    /// @notice `_issueDeviceName`, classification check: a stem short enough to be reserved.
    function test_device_name_reserved_stem_error() public {
        IDotnsPopController.DeviceNameIssuance memory issuance =
            IDotnsPopController.DeviceNameIssuance({label: "abc.01", user: ed, chatKey: ""});
        vm.expectRevert(IDotnsPopController.InvalidDeviceLabel.selector);
        _rootIssueDeviceName(issuance);
    }

    /// @notice `_issuePersonhoodName`, classification check: a governance-reserved length.
    function test_personhood_name_reserved_length_error() public {
        IDotnsPopController.PersonhoodNameIssuance memory issuance =
            IDotnsPopController.PersonhoodNameIssuance({
                label: "abcde", user: ed, link: _linkFresh("")
            });
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootIssuePersonhoodName(issuance);
    }

    /// @notice `_issuePersonhoodName`, device-link shape check.
    function test_device_link_shape_error() public {
        IDotnsPopController.PersonhoodNameIssuance memory issuance =
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkWithDeviceName("michael")
            });
        vm.expectRevert(IDotnsPopController.InvalidDeviceLabel.selector);
        _rootIssuePersonhoodName(issuance);
    }

    /// @notice `_validatePersonhoodLabel`, shape check, from the personhood issuance and from the
    ///         reservation of the combined entrypoint.
    function test_personhood_name_shape_error() public {
        IDotnsPopController.PersonhoodNameIssuance memory issuance =
            IDotnsPopController.PersonhoodNameIssuance({
                label: "alice1", user: ed, link: _linkFresh("")
            });
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootIssuePersonhoodName(issuance);

        IDotnsPopController.DeviceNameIssuanceWithReservation memory combined =
            _combined(DEVICE_LABEL_A, "alice1");
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootIssueDeviceNameWithReservation(combined);
    }

    /// @notice `_validatePersonhoodLabel` from the signed callers.
    function test_personhood_name_shape_error_on_signed_callers() public {
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        dotnsPopController.expireReservation("alice1");
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        dotnsPopController.isReservedForClaim("alice1");
    }

    /// @notice `_validateReservablePersonhoodLabel`, classification check: a reserved length.
    function test_reservable_label_classification_error() public {
        IDotnsPopController.DeviceNameIssuanceWithReservation memory combined =
            _combined(DEVICE_LABEL_A, "abcde");
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootIssueDeviceNameWithReservation(combined);

        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: ed, label: "abcde"})
        );
    }

    // Other errors

    function test_non_root_callers_are_rejected() public {
        IDotnsPopController.DeviceNameIssuance memory issuance =
            IDotnsPopController.DeviceNameIssuance({label: DEVICE_LABEL_A, user: ed, chatKey: ""});
        vm.expectRevert(abi.encodeWithSelector(IDotnsPopController.NotRoot.selector));
        dotnsPopController.issueDeviceName(issuance);
    }

    function test_invalid_chat_key_error() public {
        IDotnsPopController.DeviceNameIssuance memory issuance =
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: hex"01"
            });
        bytes memory expected =
            abi.encodeWithSelector(IDotnsPopController.InvalidChatKey.selector, uint256(1));
        _assertRevertsWith(
            abi.encodeCall(IDotnsPopController.issueDeviceName, (issuance)), expected
        );

        IDotnsPopController.PersonhoodNameIssuance memory personhood =
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkFresh(hex"01")
            });
        _assertRevertsWith(
            abi.encodeCall(IDotnsPopController.issuePersonhoodName, (personhood)), expected
        );
    }

    function test_second_device_name_issuance_error() public {
        IDotnsPopController.DeviceNameIssuance memory issuance =
            IDotnsPopController.DeviceNameIssuance({label: DEVICE_LABEL_A, user: ed, chatKey: ""});
        _rootIssueDeviceName(issuance);

        bytes memory expected =
            abi.encodeWithSelector(IDotnsPopController.DeviceNameAlreadyIssued.selector);
        _assertRevertsWith(
            abi.encodeCall(IDotnsPopController.issueDeviceName, (issuance)), expected
        );
        IDotnsPopController.DeviceNameIssuanceWithReservation memory combined =
            _combined(DEVICE_LABEL_A, PERSONHOOD_LABEL_A);
        _assertRevertsWith(
            abi.encodeCall(IDotnsPopController.issueDeviceNameWithReservation, (combined)), expected
        );
    }

    function test_device_link_the_user_does_not_own_error() public {
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: tiago, chatKey: ""
            })
        );
        IDotnsPopController.PersonhoodNameIssuance memory params =
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkWithDeviceName(DEVICE_LABEL_A)
            });

        _assertRevertsWith(
            abi.encodeCall(IDotnsPopController.issuePersonhoodName, (params)),
            abi.encodeWithSelector(
                IDotnsPopController.DeviceNameNotOwned.selector,
                ed,
                keccak256(bytes(DEVICE_LABEL_A))
            )
        );
    }

    function test_registered_reserved_label_error() public {
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: tiago, link: _linkFresh("")
            })
        );
        IDotnsPopController.DeviceNameIssuanceWithReservation memory combined =
            _combined(DEVICE_LABEL_A, PERSONHOOD_LABEL_A);

        _assertRevertsWith(
            abi.encodeCall(IDotnsPopController.issueDeviceNameWithReservation, (combined)),
            abi.encodeWithSelector(IDotnsPopController.PersonhoodNameUnavailable.selector)
        );
    }

    function test_label_held_by_another_waiter_error() public {
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: tiago, label: PERSONHOOD_LABEL_A})
        );
        IDotnsPopController.PersonhoodNameIssuance memory params =
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkFresh("")
            });

        _assertRevertsWith(
            abi.encodeCall(IDotnsPopController.issuePersonhoodName, (params)),
            abi.encodeWithSelector(
                IDotnsPopController.NotHolder.selector, ed, keccak256(bytes(PERSONHOOD_LABEL_A))
            )
        );
    }

    function test_full_queue_error() public {
        for (uint256 i; i < dotnsPopController.MAX_RESERVATION_QUEUE(); ++i) {
            _rootReservePersonhoodName(
                IDotnsPopController.PersonhoodNameReservation({
                    user: makeAddr(string.concat("waiter", vm.toString(i))),
                    label: PERSONHOOD_LABEL_A
                })
            );
        }
        IDotnsPopController.DeviceNameIssuanceWithReservation memory combined =
            _combined(DEVICE_LABEL_A, PERSONHOOD_LABEL_A);

        _assertRevertsWith(
            abi.encodeCall(IDotnsPopController.issueDeviceNameWithReservation, (combined)),
            abi.encodeWithSelector(
                IDotnsPopController.QueueFull.selector, keccak256(bytes(PERSONHOOD_LABEL_A))
            )
        );
    }

    // Every reservation-queue exit emits an event

    function test_claim_emits_claimed_and_ends_every_other_waiters_reservation() public {
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), PERSONHOOD_LABEL_A);
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: tiago, label: PERSONHOOD_LABEL_A})
        );
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({
                user: leonardo, label: PERSONHOOD_LABEL_A
            })
        );

        vm.recordLogs();
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkFresh(_validChatKey(0x02))
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The claim evicts every waiter at once: `ReservationClaimed` is the only event, so its
        // cost does not grow with the queue.
        bytes32 claimed = keccak256("ReservationClaimed(bytes32,address)");
        bytes32 evicted = keccak256("ReservationEvicted(bytes32,address)");
        assertEq(_countEventsFor(logs, claimed, ed), 1, "the claimant's claim");
        assertEq(_countEvents(logs, evicted), 0, "no per-waiter event");
        assertEq(dotnsPopController.userReservation(tiago).labelhash, bytes32(0));
        assertEq(dotnsPopController.userReservation(leonardo).labelhash, bytes32(0));

        // An evicted waiter holds no reservation, and can reserve again.
        vm.prank(tiago);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsPopController.NoActiveReservation.selector, tiago)
        );
        dotnsPopController.relinquishReservation();
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: tiago, label: PERSONHOOD_LABEL_B})
        );
        assertEq(
            dotnsPopController.userReservation(tiago).labelhash,
            keccak256(bytes(PERSONHOOD_LABEL_B))
        );
    }

    function test_standalone_issuance_relinquishes_the_users_other_reservation() public {
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), PERSONHOOD_LABEL_A);

        vm.recordLogs();
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_B, user: ed, link: _linkFresh(_validChatKey(0x02))
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 relinquished = keccak256("ReservationRelinquished(bytes32,address)");
        assertEq(_countEventsFor(logs, relinquished, ed), 1, "the dropped entry is recorded");
        assertEq(_countEvents(logs, keccak256("ReservationClaimed(bytes32,address)")), 0);
        assertEq(dotnsPopController.userReservation(ed).labelhash, bytes32(0));
    }

    function test_re_reservation_relinquishes_the_previous_entry() public {
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: ed, label: PERSONHOOD_LABEL_A})
        );

        vm.recordLogs();
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: ed, label: PERSONHOOD_LABEL_B})
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 relinquished = keccak256("ReservationRelinquished(bytes32,address)");
        assertEq(_countEventsFor(logs, relinquished, ed), 1);
        assertEq(
            dotnsPopController.userReservation(ed).labelhash, keccak256(bytes(PERSONHOOD_LABEL_B))
        );
    }

    function test_relinquishReservation_emits_exactly_once() public {
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: ed, label: PERSONHOOD_LABEL_A})
        );

        vm.recordLogs();
        vm.prank(ed);
        dotnsPopController.relinquishReservation();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countEvents(logs, keccak256("ReservationRelinquished(bytes32,address)")), 1);
    }

    function test_issuance_without_a_reservation_emits_no_relinquish() public {
        vm.recordLogs();
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkFresh(_validChatKey(0x02))
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countEvents(logs, keccak256("ReservationRelinquished(bytes32,address)")), 0);
    }

    // A user leaving from the back frees their place

    /// @notice Leaving from the back frees the place, so one account alternating between two
    ///         labels behind someone else's reservation leaves no holes.
    function test_leaving_from_the_back_frees_the_place() public {
        bytes32 labelhash = keccak256(bytes(PERSONHOOD_LABEL_A));
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: tiago, label: PERSONHOOD_LABEL_A})
        );
        for (uint256 i; i < 3; ++i) {
            _rootReservePersonhoodName(
                IDotnsPopController.PersonhoodNameReservation({user: ed, label: PERSONHOOD_LABEL_A})
            );
            _rootReservePersonhoodName(
                IDotnsPopController.PersonhoodNameReservation({user: ed, label: PERSONHOOD_LABEL_B})
            );
        }

        (uint64 head, uint64 tail) = dotnsPopController.reservationMeta(labelhash);
        assertEq(tail - head, 1, "only the first reservation counts toward capacity");
    }

    /// @notice A hole behind a later entry still counts until the front passes it.
    function test_leaving_from_the_middle_keeps_the_back() public {
        bytes32 labelhash = keccak256(bytes(PERSONHOOD_LABEL_A));
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: tiago, label: PERSONHOOD_LABEL_A})
        );
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: ed, label: PERSONHOOD_LABEL_A})
        );
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({
                user: leonardo, label: PERSONHOOD_LABEL_A
            })
        );

        vm.prank(ed);
        dotnsPopController.relinquishReservation();

        (uint64 head, uint64 tail) = dotnsPopController.reservationMeta(labelhash);
        assertEq(tail - head, 3);
        (address back,) = dotnsPopController.reservationEntry(labelhash, tail - 1);
        assertEq(back, leonardo);
    }

    // Helpers

    function _combined(
        string memory deviceLabel,
        string memory reservedLabel
    )
        internal
        view
        returns (IDotnsPopController.DeviceNameIssuanceWithReservation memory)
    {
        return IDotnsPopController.DeviceNameIssuanceWithReservation({
            issuance: IDotnsPopController.DeviceNameIssuance({
                label: deviceLabel, user: ed, chatKey: ""
            }),
            reservedLabel: reservedLabel
        });
    }

    /// @dev Requires `payload` to revert under Root with exactly `expected`.
    function _assertRevertsWith(bytes memory payload, bytes memory expected) internal {
        assertEq(_rootRevertData(payload), expected);
    }

    function _rootRevertData(bytes memory payload) internal returns (bytes memory data) {
        _mockCallerIsRoot(true);
        bool ok;
        (ok, data) = address(dotnsPopController).call(payload);
        _mockCallerIsRoot(false);
        assertFalse(ok, "the call reverts");
    }

    function _countEvents(Vm.Log[] memory logs, bytes32 sig) internal pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == sig) ++count;
        }
    }

    /// @dev Counts `sig` events whose second indexed topic is `user`; every reservation event
    ///      indexes the labelhash first and the user second.
    function _countEventsFor(
        Vm.Log[] memory logs,
        bytes32 sig,
        address user
    )
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].topics.length > 2 && logs[i].topics[0] == sig
                    && logs[i].topics[2] == bytes32(uint256(uint160(user)))
            ) ++count;
        }
    }
}
