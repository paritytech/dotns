// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsPopController} from "../../../contracts/registrars/IDotnsPopController.sol";
import {
    IDotnsPopControllerLegacy
} from "../../../contracts/registrars/IDotnsPopControllerLegacy.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DotnsPopControllerLegacyTests
/// @notice The legacy entrypoints, and the reservation-queue events.
/// @dev The legacy selectors and error selectors are pinned as literals, because the legacy
///      interface exists to keep them unchanged. Each legacy entrypoint is checked against its
///      replacement from the same state: identical events and state on success, identical revert
///      data on every shared error. Every `InvalidLiteLabel` / `InvalidBaseLabel` revert reachable
///      from a legacy entrypoint is exercised from both the legacy entrypoint and its replacement,
///      which reverts with the new error instead. The shape check inside `_validateDeviceLabel` is
///      preceded by the same check at each of its callers, so it is reached through them and has no
///      test of its own.
contract DotnsPopControllerLegacyTests is BaseDotns {
    // Selectors and interfaces

    function test_legacy_selectors_are_pinned() public pure {
        assertEq(
            IDotnsPopControllerLegacy.reserveLiteName.selector, SELECTOR_LEGACY_RESERVE_LITE_NAME
        );
        assertEq(
            IDotnsPopControllerLegacy.reserveBaseName.selector, SELECTOR_LEGACY_RESERVE_BASE_NAME
        );
        assertEq(
            IDotnsPopControllerLegacy.registerBaseName.selector, SELECTOR_LEGACY_REGISTER_BASE_NAME
        );
    }

    function test_legacy_error_selectors_are_pinned() public pure {
        assertEq(IDotnsPopControllerLegacy.InvalidLiteLabel.selector, bytes4(0x5c6c2eea));
        assertEq(IDotnsPopControllerLegacy.InvalidBaseLabel.selector, bytes4(0x39e67d31));
    }

    function test_new_selectors_differ_from_the_legacy_ones() public pure {
        assertTrue(
            IDotnsPopController.issueDeviceName.selector != SELECTOR_LEGACY_RESERVE_LITE_NAME
        );
        assertTrue(
            IDotnsPopController.issueDeviceNameWithReservation.selector
                != SELECTOR_LEGACY_RESERVE_BASE_NAME
        );
        assertTrue(
            IDotnsPopController.issuePersonhoodName.selector != SELECTOR_LEGACY_REGISTER_BASE_NAME
        );
    }

    function test_supports_both_interfaces() public view {
        assertTrue(
            dotnsPopController.supportsInterface(type(IDotnsPopController).interfaceId),
            "current interface"
        );
        assertTrue(
            dotnsPopController.supportsInterface(type(IDotnsPopControllerLegacy).interfaceId),
            "legacy interface"
        );
    }

    // Legacy entrypoints have the same effect as their replacements

    function test_reserveLiteName_matches_issueDeviceName() public {
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: ed, label: PERSONHOOD_LABEL_A})
        );
        IDotnsPopController.DeviceNameIssuance memory issuance =
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0x01)
            });

        _assertSameEffect(
            abi.encodeCall(IDotnsPopControllerLegacy.reserveLiteName, (issuance)),
            abi.encodeCall(IDotnsPopController.issueDeviceName, (issuance)),
            ed,
            DEVICE_LABEL_A,
            PERSONHOOD_LABEL_A
        );
    }

    function test_reserveBaseName_matches_issueDeviceNameWithReservation() public {
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: tiago, label: PERSONHOOD_LABEL_A})
        );
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: ed, label: PERSONHOOD_LABEL_B})
        );
        IDotnsPopController.DeviceNameIssuanceWithReservation memory params =
            IDotnsPopController.DeviceNameIssuanceWithReservation({
                issuance: IDotnsPopController.DeviceNameIssuance({
                    label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0x01)
                }),
                reservedLabel: PERSONHOOD_LABEL_A
            });

        _assertSameEffect(
            abi.encodeCall(IDotnsPopControllerLegacy.reserveBaseName, (params)),
            abi.encodeCall(IDotnsPopController.issueDeviceNameWithReservation, (params)),
            ed,
            DEVICE_LABEL_A,
            PERSONHOOD_LABEL_A
        );
    }

    function test_registerBaseName_matches_issuePersonhoodName_on_a_linked_claim() public {
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), PERSONHOOD_LABEL_A);
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: tiago, label: PERSONHOOD_LABEL_A})
        );
        IDotnsPopController.PersonhoodNameIssuance memory params =
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkWithDeviceName(DEVICE_LABEL_A)
            });

        _assertSameEffect(
            abi.encodeCall(IDotnsPopControllerLegacy.registerBaseName, (params)),
            abi.encodeCall(IDotnsPopController.issuePersonhoodName, (params)),
            ed,
            DEVICE_LABEL_A,
            PERSONHOOD_LABEL_A
        );
    }

    function test_registerBaseName_matches_issuePersonhoodName_without_a_reservation() public {
        IDotnsPopController.PersonhoodNameIssuance memory params =
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkFresh(_validChatKey(0x02))
            });

        _assertSameEffect(
            abi.encodeCall(IDotnsPopControllerLegacy.registerBaseName, (params)),
            abi.encodeCall(IDotnsPopController.issuePersonhoodName, (params)),
            ed,
            DEVICE_LABEL_A,
            PERSONHOOD_LABEL_A
        );
    }

    function test_legacy_reserveLiteName_issues_a_device_name() public {
        vm.recordLogs();
        _rootLegacyReserveLiteName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0x01)
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(dotnsRegistry.owner(_deviceNodeOf(DEVICE_LABEL_A)), ed);
        assertTrue(dotnsPopController.isPopIssued(DEVICE_LABEL_A));
        assertEq(dotnsPopResolver.chatKey(_deviceNodeOf(DEVICE_LABEL_A)), _validChatKey(0x01));
        assertEq(_countEvents(logs, keccak256("DeviceNameIssued(bytes32,address,string)")), 1);
    }

    function test_legacy_reserveBaseName_issues_and_reserves() public {
        _rootLegacyReserveBaseName(
            IDotnsPopController.DeviceNameIssuanceWithReservation({
                issuance: IDotnsPopController.DeviceNameIssuance({
                    label: DEVICE_LABEL_A, user: ed, chatKey: ""
                }),
                reservedLabel: PERSONHOOD_LABEL_A
            })
        );

        assertEq(dotnsRegistry.owner(_deviceNodeOf(DEVICE_LABEL_A)), ed);
        assertEq(
            dotnsPopController.userReservation(ed).labelhash,
            keccak256(bytes(PERSONHOOD_LABEL_A)),
            "the reservation is queued"
        );
        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertTrue(reserved);
        assertEq(holder, ed);
    }

    function test_legacy_registerBaseName_issues_a_personhood_name() public {
        vm.recordLogs();
        _rootLegacyRegisterBaseName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkFresh(_validChatKey(0x02))
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(dotnsRegistry.owner(_nodeOf(PERSONHOOD_LABEL_A)), ed);
        assertTrue(dotnsPopController.isPopIssued(PERSONHOOD_LABEL_A));
        assertEq(_countEvents(logs, keccak256("PersonhoodNameIssued(bytes32,address,string)")), 1);
    }

    // Label errors: legacy entrypoints revert with the legacy errors, replacements with the new
    // ones

    /// @notice `_issueDeviceName`, shape check: a label with no separator.
    function test_device_name_shape_error_on_both_paths() public {
        IDotnsPopController.DeviceNameIssuance memory issuance =
            IDotnsPopController.DeviceNameIssuance({label: "michael", user: ed, chatKey: ""});

        vm.expectRevert(IDotnsPopControllerLegacy.InvalidLiteLabel.selector);
        _rootLegacyReserveLiteName(issuance);
        vm.expectRevert(IDotnsPopController.InvalidDeviceLabel.selector);
        _rootIssueDeviceName(issuance);

        IDotnsPopController.DeviceNameIssuanceWithReservation memory combined =
            IDotnsPopController.DeviceNameIssuanceWithReservation({
                issuance: issuance, reservedLabel: ""
            });
        vm.expectRevert(IDotnsPopControllerLegacy.InvalidLiteLabel.selector);
        _rootLegacyReserveBaseName(combined);
        vm.expectRevert(IDotnsPopController.InvalidDeviceLabel.selector);
        _rootIssueDeviceNameWithReservation(combined);
    }

    /// @notice `_issueDeviceName`, classification check: a stem short enough to be reserved.
    function test_device_name_reserved_stem_error_on_both_paths() public {
        IDotnsPopController.DeviceNameIssuance memory issuance =
            IDotnsPopController.DeviceNameIssuance({label: "abc.01", user: ed, chatKey: ""});

        vm.expectRevert(IDotnsPopControllerLegacy.InvalidLiteLabel.selector);
        _rootLegacyReserveLiteName(issuance);
        vm.expectRevert(IDotnsPopController.InvalidDeviceLabel.selector);
        _rootIssueDeviceName(issuance);
    }

    /// @notice `_issuePersonhoodName`, classification check: a governance-reserved length.
    function test_personhood_name_reserved_length_error_on_both_paths() public {
        IDotnsPopController.PersonhoodNameIssuance memory issuance =
            IDotnsPopController.PersonhoodNameIssuance({
                label: "abcde", user: ed, link: _linkFresh("")
            });

        vm.expectRevert(IDotnsPopControllerLegacy.InvalidBaseLabel.selector);
        _rootLegacyRegisterBaseName(issuance);
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootIssuePersonhoodName(issuance);
    }

    /// @notice `_issuePersonhoodName`, device-link shape check.
    function test_device_link_shape_error_on_both_paths() public {
        IDotnsPopController.PersonhoodNameIssuance memory issuance =
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkWithDeviceName("michael")
            });

        vm.expectRevert(IDotnsPopControllerLegacy.InvalidLiteLabel.selector);
        _rootLegacyRegisterBaseName(issuance);
        vm.expectRevert(IDotnsPopController.InvalidDeviceLabel.selector);
        _rootIssuePersonhoodName(issuance);
    }

    /// @notice `_validatePersonhoodLabel`, shape check, from the personhood issuance and from the
    ///         reservation of the combined entrypoint.
    function test_personhood_name_shape_error_on_both_paths() public {
        IDotnsPopController.PersonhoodNameIssuance memory issuance =
            IDotnsPopController.PersonhoodNameIssuance({
                label: "alice1", user: ed, link: _linkFresh("")
            });
        vm.expectRevert(IDotnsPopControllerLegacy.InvalidBaseLabel.selector);
        _rootLegacyRegisterBaseName(issuance);
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootIssuePersonhoodName(issuance);

        IDotnsPopController.DeviceNameIssuanceWithReservation memory combined =
            _combined(DEVICE_LABEL_A, "alice1");
        vm.expectRevert(IDotnsPopControllerLegacy.InvalidBaseLabel.selector);
        _rootLegacyReserveBaseName(combined);
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootIssueDeviceNameWithReservation(combined);
    }

    /// @notice `_validatePersonhoodLabel` from the callers that are not legacy entrypoints: always
    ///         the new error.
    function test_personhood_name_shape_error_on_non_legacy_callers() public {
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        dotnsPopController.expireReservation("alice1");
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        dotnsPopController.isReservedForClaim("alice1");
    }

    /// @notice `_validateReservablePersonhoodLabel`, classification check: a reserved length.
    function test_reservable_label_classification_error_on_both_paths() public {
        IDotnsPopController.DeviceNameIssuanceWithReservation memory combined =
            _combined(DEVICE_LABEL_A, "abcde");
        vm.expectRevert(IDotnsPopControllerLegacy.InvalidBaseLabel.selector);
        _rootLegacyReserveBaseName(combined);
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootIssueDeviceNameWithReservation(combined);

        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: ed, label: "abcde"})
        );
    }

    // Errors the legacy entrypoints share with their replacements

    function test_non_root_callers_are_rejected_on_both_paths() public {
        IDotnsPopController.DeviceNameIssuance memory issuance =
            IDotnsPopController.DeviceNameIssuance({label: DEVICE_LABEL_A, user: ed, chatKey: ""});
        bytes memory expected = abi.encodeWithSelector(IDotnsPopController.NotRoot.selector);

        vm.expectRevert(expected);
        IDotnsPopControllerLegacy(address(dotnsPopController)).reserveLiteName(issuance);
        vm.expectRevert(expected);
        dotnsPopController.issueDeviceName(issuance);
    }

    function test_invalid_chat_key_error_on_both_paths() public {
        IDotnsPopController.DeviceNameIssuance memory issuance =
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: hex"01"
            });
        bytes memory expected =
            abi.encodeWithSelector(IDotnsPopController.InvalidChatKey.selector, uint256(1));
        _assertBothRevertWith(
            abi.encodeCall(IDotnsPopControllerLegacy.reserveLiteName, (issuance)),
            abi.encodeCall(IDotnsPopController.issueDeviceName, (issuance)),
            expected
        );

        IDotnsPopController.PersonhoodNameIssuance memory personhood =
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkFresh(hex"01")
            });
        _assertBothRevertWith(
            abi.encodeCall(IDotnsPopControllerLegacy.registerBaseName, (personhood)),
            abi.encodeCall(IDotnsPopController.issuePersonhoodName, (personhood)),
            expected
        );
    }

    function test_second_device_name_issuance_error_on_both_paths() public {
        IDotnsPopController.DeviceNameIssuance memory issuance =
            IDotnsPopController.DeviceNameIssuance({label: DEVICE_LABEL_A, user: ed, chatKey: ""});
        _rootIssueDeviceName(issuance);

        bytes memory expected =
            abi.encodeWithSelector(IDotnsPopController.DeviceNameAlreadyIssued.selector);
        _assertBothRevertWith(
            abi.encodeCall(IDotnsPopControllerLegacy.reserveLiteName, (issuance)),
            abi.encodeCall(IDotnsPopController.issueDeviceName, (issuance)),
            expected
        );
        IDotnsPopController.DeviceNameIssuanceWithReservation memory combined =
            _combined(DEVICE_LABEL_A, PERSONHOOD_LABEL_A);
        _assertBothRevertWith(
            abi.encodeCall(IDotnsPopControllerLegacy.reserveBaseName, (combined)),
            abi.encodeCall(IDotnsPopController.issueDeviceNameWithReservation, (combined)),
            expected
        );
    }

    function test_device_link_the_user_does_not_own_error_on_both_paths() public {
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: tiago, chatKey: ""
            })
        );
        IDotnsPopController.PersonhoodNameIssuance memory params =
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkWithDeviceName(DEVICE_LABEL_A)
            });

        _assertBothRevertWith(
            abi.encodeCall(IDotnsPopControllerLegacy.registerBaseName, (params)),
            abi.encodeCall(IDotnsPopController.issuePersonhoodName, (params)),
            abi.encodeWithSelector(
                IDotnsPopController.DeviceNameNotOwned.selector,
                ed,
                keccak256(bytes(DEVICE_LABEL_A))
            )
        );
    }

    function test_registered_reserved_label_error_on_both_paths() public {
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: tiago, link: _linkFresh("")
            })
        );
        IDotnsPopController.DeviceNameIssuanceWithReservation memory combined =
            _combined(DEVICE_LABEL_A, PERSONHOOD_LABEL_A);

        _assertBothRevertWith(
            abi.encodeCall(IDotnsPopControllerLegacy.reserveBaseName, (combined)),
            abi.encodeCall(IDotnsPopController.issueDeviceNameWithReservation, (combined)),
            abi.encodeWithSelector(IDotnsPopController.PersonhoodNameUnavailable.selector)
        );
    }

    function test_label_held_by_another_waiter_error_on_both_paths() public {
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: tiago, label: PERSONHOOD_LABEL_A})
        );
        IDotnsPopController.PersonhoodNameIssuance memory params =
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkFresh("")
            });

        _assertBothRevertWith(
            abi.encodeCall(IDotnsPopControllerLegacy.registerBaseName, (params)),
            abi.encodeCall(IDotnsPopController.issuePersonhoodName, (params)),
            abi.encodeWithSelector(
                IDotnsPopController.NotHolder.selector, ed, keccak256(bytes(PERSONHOOD_LABEL_A))
            )
        );
    }

    function test_full_queue_error_on_both_paths() public {
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

        _assertBothRevertWith(
            abi.encodeCall(IDotnsPopControllerLegacy.reserveBaseName, (combined)),
            abi.encodeCall(IDotnsPopController.issueDeviceNameWithReservation, (combined)),
            abi.encodeWithSelector(
                IDotnsPopController.QueueFull.selector, keccak256(bytes(PERSONHOOD_LABEL_A))
            )
        );
    }

    // Every reservation-queue exit emits an event

    function test_claim_emits_claimed_and_evicts_every_other_waiter() public {
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

        bytes32 claimed = keccak256("ReservationClaimed(bytes32,address)");
        bytes32 evicted = keccak256("ReservationEvicted(bytes32,address)");
        assertEq(_countEventsFor(logs, claimed, ed), 1, "the claimant's claim");
        assertEq(_countEventsFor(logs, evicted, tiago), 1, "first waiter evicted");
        assertEq(_countEventsFor(logs, evicted, leonardo), 1, "second waiter evicted");
        assertEq(_countEventsFor(logs, evicted, ed), 0, "the claimant is not evicted");
        assertEq(dotnsPopController.userReservation(tiago).labelhash, bytes32(0));
        assertEq(dotnsPopController.userReservation(leonardo).labelhash, bytes32(0));
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

    /// @dev Runs `legacyPayload` and `replacementPayload` from the same state and requires the same
    ///      events, in order and byte for byte, and the same observable state afterwards.
    function _assertSameEffect(
        bytes memory legacyPayload,
        bytes memory replacementPayload,
        address user,
        string memory deviceLabel,
        string memory personhoodLabel
    )
        internal
    {
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        _dispatchFromRoot(legacyPayload);
        Vm.Log[] memory legacyLogs = vm.getRecordedLogs();
        bytes memory legacyState = _observableState(user, deviceLabel, personhoodLabel);

        vm.revertToState(snapshot);
        vm.recordLogs();
        _dispatchFromRoot(replacementPayload);
        Vm.Log[] memory replacementLogs = vm.getRecordedLogs();

        assertGt(legacyLogs.length, 0, "the call emits events");
        assertEq(legacyLogs.length, replacementLogs.length, "same number of events");
        for (uint256 i; i < legacyLogs.length; ++i) {
            assertEq(legacyLogs[i].emitter, replacementLogs[i].emitter, "same emitter");
            assertEq(
                abi.encode(legacyLogs[i].topics),
                abi.encode(replacementLogs[i].topics),
                "same topics"
            );
            assertEq(legacyLogs[i].data, replacementLogs[i].data, "same data");
        }
        assertEq(_observableState(user, deviceLabel, personhoodLabel), legacyState, "same state");
    }

    /// @dev Records, reservation and pending claims the gateway entrypoints write for `user`.
    function _observableState(
        address user,
        string memory deviceLabel,
        string memory personhoodLabel
    )
        internal
        view
        returns (bytes memory)
    {
        bytes32 deviceNode = _deviceNodeOf(deviceLabel);
        bytes32 personhoodNode = _nodeOf(personhoodLabel);
        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(personhoodLabel);
        return bytes.concat(
            abi.encode(
                dotnsRegistry.owner(deviceNode),
                dotnsRegistry.owner(personhoodNode),
                dotnsPopController.isPopIssued(deviceLabel),
                dotnsPopController.isPopIssued(personhoodLabel),
                dotnsPopResolver.chatKey(deviceNode),
                dotnsPopResolver.chatKey(personhoodNode)
            ),
            abi.encode(
                dotnsPopResolver.deviceLabelhashOf(personhoodNode),
                dotnsPopResolver.personhoodNodeOf(keccak256(bytes(deviceLabel))),
                dotnsPopController.userReservation(user),
                reserved,
                holder,
                dotnsPopController.pendingClaimCountOf(user)
            )
        );
    }

    /// @dev Requires both payloads to revert under Root with exactly `expected`.
    function _assertBothRevertWith(
        bytes memory legacyPayload,
        bytes memory replacementPayload,
        bytes memory expected
    )
        internal
    {
        assertEq(_rootRevertData(legacyPayload), expected, "legacy entrypoint");
        assertEq(_rootRevertData(replacementPayload), expected, "replacement");
    }

    function _rootRevertData(bytes memory payload) internal returns (bytes memory data) {
        _mockOriginIsRoot(true);
        bool ok;
        (ok, data) = address(dotnsPopController).call(payload);
        _mockOriginIsRoot(false);
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
