// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsPopController} from "../../../contracts/registrars/IDotnsPopController.sol";
import {IDotnsPopLens} from "../../../contracts/registrars/IDotnsPopLens.sol";
import {IDotnsRegistrar} from "../../../contracts/registrars/IDotnsRegistrar.sol";
import {
    IDotnsRegistrarController
} from "../../../contracts/registrars/IDotnsRegistrarController.sol";
import {IDotnsRegistry} from "../../../contracts/registry/IDotnsRegistry.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {ILabelStore} from "../../../contracts/store/ILabelStore.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DotnsPopControllerTests
/// @notice Behavioural unit tests for the dedicated PoP controller driving
///         the gateway flow. Parameterised coverage (label format, chat-key
///         payload, duration boundary) lives in the sibling fuzz file; these
///         tests assert specific behaviours that do not benefit from input
///         variation.
contract DotnsPopControllerTests is BaseDotns {
    function test_issueDeviceNameWithReservation_mints_and_wires_registry_and_resolver() public {
        // Device-name path requires Devicehood tier and a classification-valid device name.
        _grantPersonhood(ed);
        bytes memory chatKey = _validChatKey(0x01);

        _reservePop(ed, DEVICE_LABEL_A, chatKey, "");

        // A device name is a subnode under its numeric container, not a tokenised name, so its
        // ownership lives in the registry record rather than the registrar's ERC-721 ledger.
        bytes32 node = _deviceNodeOf(DEVICE_LABEL_A);
        assertEq(dotnsRegistry.owner(node), ed);
        assertEq(dotnsPopResolver.chatKey(node), chatKey);

        // The numeric container is minted on first use, owned by the PoP controller in the
        // registry, and soulbound so it cannot be moved out from under the names beneath it.
        bytes32 containerNode = _nodeOf("01");
        assertTrue(dotnsRegistrar.exists(uint256(containerNode)), "container minted on first use");
        assertEq(
            dotnsRegistry.owner(containerNode),
            address(dotnsPopController),
            "container owned by the controller"
        );
        assertTrue(dotnsRegistrar.isSoulbound(uint256(containerNode)), "container is soulbound");
    }

    /// @notice The numeric container is minted once and reused: a second stem under the same suffix
    ///         does not re-mint it.
    /// @dev A re-mint would revert on the already-registered container, so the second reservation
    ///      succeeding, with the container owner unchanged, is proof it took the reuse path.
    function test_second_device_stem_reuses_the_container() public {
        _grantPersonhood(ed);
        _grantPersonhood(leonardo);

        _reservePop(ed, "michael.01", _validChatKey(0x01), "");
        bytes32 containerNode = _nodeOf("01");
        address containerOwner = dotnsRegistry.owner(containerNode);

        _reservePop(leonardo, "matthew.01", _validChatKey(0x02), "");

        assertEq(dotnsRegistry.owner(containerNode), containerOwner, "container not re-owned");
        assertEq(dotnsRegistry.owner(_deviceNodeOf("michael.01")), ed, "first stem owned by ed");
        assertEq(
            dotnsRegistry.owner(_deviceNodeOf("matthew.01")),
            leonardo,
            "second stem owned by leonardo"
        );
    }

    function test_issueDeviceNameWithReservation_reverts_when_origin_is_not_root() public {
        _mockOriginIsRoot(false);
        vm.expectRevert(IDotnsPopController.NotRoot.selector);
        dotnsPopController.issueDeviceNameWithReservation(
            IDotnsPopController.DeviceNameIssuanceWithReservation({
                issuance: IDotnsPopController.DeviceNameIssuance({
                    label: DEVICE_LABEL_A, user: ed, chatKey: ""
                }),
                reservedLabel: ""
            })
        );
    }

    function test_issueDeviceNameWithReservation_enqueues_when_reserved_label_provided() public {
        // `PopRules.priceWithCheck` admits only the live reservation holder on
        // a given base stem, so the queue is single-occupant. Multi-occupant
        // queue coverage lives in the invariant suite.
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0xaa), PERSONHOOD_LABEL_A);

        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertTrue(reserved);
        assertEq(holder, ed);
    }

    function test_issuePersonhoodName_claim_emits_reservation_claimed() public {
        // ed gets a different Personhood-classified base label via standalone mint.
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), PERSONHOOD_LABEL_A);

        IDotnsPopController.Link memory link = _linkWithDeviceName(DEVICE_LABEL_A);

        vm.recordLogs();
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: link
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertEventEmittedOnce(logs, keccak256("ReservationClaimed(bytes32,address)"));
        _assertEventEmittedOnce(logs, keccak256("PersonhoodNameIssued(bytes32,address,string)"));

        (bool reserved,) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertFalse(reserved);
    }

    function test_issuePersonhoodName_standalone_emits_no_reservation_claimed() public {
        _grantPersonhood(tiago);
        _reservePop(tiago, DEVICE_LABEL_B, _validChatKey(0x01), PERSONHOOD_LABEL_A);
        // `priceWithCheck` admits only the live reservation holder on a given
        // base stem, so the standalone mint runs against a separate, free stem
        // owned by a different user; this asserts neither user sees state leak
        // from the other.
        _grantPersonhood(ed);
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));

        vm.recordLogs();
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_C, user: ed, link: link
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertEventEmittedOnce(logs, keccak256("PersonhoodNameIssued(bytes32,address,string)"));
        _assertEventNotEmitted(logs, keccak256("ReservationClaimed(bytes32,address)"));
    }

    function test_issuePersonhoodName_claim_inherits_chat_key_from_device_node() public {
        // Promote ed to Personhood so the standalone Personhood-classified mint passes.
        _grantPersonhood(ed);
        bytes memory deviceChatKey = _validChatKey(0xaa);
        _reservePop(ed, DEVICE_LABEL_A, deviceChatKey, PERSONHOOD_LABEL_A);

        IDotnsPopController.Link memory link = _linkWithDeviceName(DEVICE_LABEL_A);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: link
            })
        );

        bytes32 personhoodNode = _nodeOf(PERSONHOOD_LABEL_A);
        assertEq(dotnsPopResolver.chatKey(personhoodNode), deviceChatKey);
        assertEq(
            dotnsPopResolver.deviceLabelhashOf(personhoodNode), keccak256(bytes(DEVICE_LABEL_A))
        );
    }

    function test_issuePersonhoodName_claim_wipes_entire_queue() public {
        // `priceWithCheck` admits only the live reservation holder on a given
        // base stem, so the queue stays single-occupant; after the holder
        // claims, the stem is free for a fresh reservation from any user.
        _grantPersonhood(ed);
        _grantPersonhood(tiago);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), PERSONHOOD_LABEL_A);

        IDotnsPopController.Link memory link = _linkWithDeviceName(DEVICE_LABEL_A);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: link
            })
        );

        _reservePop(tiago, DEVICE_LABEL_D, _validChatKey(0x04), PERSONHOOD_LABEL_B);
        (, address wonderHolder) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_B);
        assertEq(wonderHolder, tiago);
    }

    function test_issuePersonhoodName_standalone_auto_relinquishes_users_other_reservation()
        public
    {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), PERSONHOOD_LABEL_A);

        _grantPersonhood(ed);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0x02));

        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_B, user: ed, link: link
            })
        );

        (bool reserved,) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertFalse(reserved);
    }

    function test_issuePersonhoodName_standalone_with_device_link_relinquishes_the_other_reservation()
        public
    {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), PERSONHOOD_LABEL_A);

        _grantPersonhood(ed);
        IDotnsPopController.Link memory link = _linkWithDeviceName(DEVICE_LABEL_A);

        vm.recordLogs();
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_B, user: ed, link: link
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertEventEmittedOnce(logs, keccak256("PersonhoodNameIssued(bytes32,address,string)"));
        _assertEventEmittedOnce(logs, keccak256("DeviceNameLinked(bytes32,bytes32)"));
        _assertEventNotEmitted(logs, keccak256("ReservationClaimed(bytes32,address)"));
        _assertEventEmittedOnce(logs, keccak256("ReservationRelinquished(bytes32,address)"));

        bytes32 personhoodNode = _nodeOf(PERSONHOOD_LABEL_B);
        assertEq(
            dotnsPopResolver.deviceLabelhashOf(personhoodNode), keccak256(bytes(DEVICE_LABEL_A))
        );

        (bool reserved,) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertFalse(reserved);
    }

    function test_issuePersonhoodName_reverts_when_origin_is_not_root() public {
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xaa));

        _mockOriginIsRoot(false);
        vm.expectRevert(IDotnsPopController.NotRoot.selector);
        dotnsPopController.issuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: link
            })
        );
    }

    function test_relinquishReservation_promotes_next_waiter_when_head_leaves() public {
        _grantPersonhood(ed);
        _grantPersonhood(tiago);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), PERSONHOOD_LABEL_A);

        vm.prank(ed);
        dotnsPopController.relinquishReservation();

        (bool empty,) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertFalse(empty);

        _reservePop(tiago, DEVICE_LABEL_B, _validChatKey(0x02), PERSONHOOD_LABEL_A);
        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertTrue(reserved);
        assertEq(holder, tiago);
    }

    function test_relinquishReservation_reverts_when_caller_has_no_reservation() public {
        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsPopController.NoActiveReservation.selector, ed)
        );
        dotnsPopController.relinquishReservation();
    }

    function test_setReservationDuration_shortening_retroactively_expires_live_entries() public {
        _grantPersonhood(ed);
        // Enqueue alice under the default duration (7 days).
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), PERSONHOOD_LABEL_A);

        (bool liveBefore, address holderBefore) =
            dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertTrue(liveBefore);
        assertEq(holderBefore, ed);
        // Warp 2 days forward (still well within the original 7-day window).
        vm.warp(block.timestamp + 2 days);
        // Governance shrinks the window to 1 day. The entry's `joinedAt` plus
        // the new duration is now in the past, so the slot is expired.
        vm.prank(owner);
        dotnsPopController.setReservationDuration(1 days);

        (bool liveAfter,) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertFalse(liveAfter);
    }

    function test_setReservationDuration_reverts_for_non_owner() public {
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ed));
        dotnsPopController.setReservationDuration(14 days);
    }

    function test_enqueueReservation_same_user_second_call_replaces_first() public {
        // Two independent reads must agree: the per-user reservation pointer
        // (`userReservation`) and the per-base claim view (`isReservedForClaim`).
        // Both change atomically when the same user re-reserves on a new stem.
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), PERSONHOOD_LABEL_A);

        IDotnsPopController.UserReservation memory firstReservation =
            dotnsPopController.userReservation(ed);
        assertEq(firstReservation.labelhash, keccak256(bytes(PERSONHOOD_LABEL_A)));
        // Second reservation by the same user on a different stem drops the
        // first slot and installs the new one.
        _reservePop(ed, DEVICE_LABEL_B, _validChatKey(0x02), PERSONHOOD_LABEL_B);

        IDotnsPopController.UserReservation memory secondReservation =
            dotnsPopController.userReservation(ed);
        assertEq(secondReservation.labelhash, keccak256(bytes(PERSONHOOD_LABEL_B)));

        (bool firstReserved,) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertFalse(firstReserved);

        (bool secondReserved, address secondHolder) =
            dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_B);
        assertTrue(secondReserved);
        assertEq(secondHolder, ed);
    }

    function test_reEnqueue_after_own_expiry_promotes_same_user_to_head() public {
        string memory baseStem = PERSONHOOD_LABEL_A;
        _grantPersonhood(ed);

        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), baseStem);
        // Warp past the reservation window and fire the GC so ed's pointer gets
        // cleared by `_advanceExpiredHead`. If the expiry path forgets the
        // per-user pointer, the second reserve call below hits `AlreadyReserved`
        // and the account is permanently stuck.
        vm.warp(block.timestamp + dotnsPopController.reservationDuration() + 1);
        dotnsPopController.expireReservation(baseStem);

        (bool expiredReserved,) = dotnsPopController.isReservedForClaim(baseStem);
        assertFalse(expiredReserved);
        // Same user reserves the same stem again with a fresh device name.
        _reservePop(ed, DEVICE_LABEL_B, _validChatKey(0x02), baseStem);

        (bool nowReserved, address holder) = dotnsPopController.isReservedForClaim(baseStem);
        assertTrue(nowReserved);
        assertEq(holder, ed);
    }

    function test_claim_then_reEnqueue_on_same_stem_resets_cleanly() public {
        string memory baseStem = PERSONHOOD_LABEL_A;
        _grantPersonhood(ed);
        _grantPersonhood(tiago);

        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), baseStem);
        // Claim wipes the queue via `_clearQueue` which must also drop
        // `_reservedBaseLabel[labelhash]` and release the PopRules slot. Missing
        // any one of those lets the next reservation inherit stale state.
        IDotnsPopController.Link memory link = _linkWithDeviceName(DEVICE_LABEL_A);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({label: baseStem, user: ed, link: link})
        );

        (bool oldSlot, address oldHolder) = dotnsPopController.isReservedForClaim(baseStem);
        assertFalse(oldSlot);
        assertEq(oldHolder, address(0));
        // Fresh stem, different user. If the previous queue leaked, this enqueue
        // would either revert or land the wrong head address on PopRules.
        _reservePop(tiago, DEVICE_LABEL_B, _validChatKey(0x02), PERSONHOOD_LABEL_B);
        (bool newSlot, address newHolder) =
            dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_B);
        assertTrue(newSlot);
        assertEq(newHolder, tiago);

        (address popHolder,) = popRules.getBaseNameReservation(PERSONHOOD_LABEL_B);
        assertEq(popHolder, tiago);
    }

    function test_expireReservation_is_permissionless() public {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), PERSONHOOD_LABEL_A);

        vm.warp(block.timestamp + dotnsPopController.reservationDuration() + 1);
        // Anyone can call. Pinning this prevents a future patch from silently
        // adding `onlyRoot` and breaking permissionless garbage collection.
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        dotnsPopController.expireReservation(PERSONHOOD_LABEL_A);

        (bool reserved,) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertFalse(reserved);
    }

    function test_head_expires_clears_slot_for_next_reserver() public {
        string memory baseStem = PERSONHOOD_LABEL_A;
        _grantPersonhood(ed);
        _grantPersonhood(leonardo);

        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), baseStem);

        vm.warp(block.timestamp + dotnsPopController.reservationDuration() + 1);
        dotnsPopController.expireReservation(baseStem);

        _reservePop(leonardo, DEVICE_LABEL_C, _validChatKey(0x03), baseStem);

        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(baseStem);
        assertTrue(reserved);
        assertEq(holder, leonardo);

        (address popHolder,) = popRules.getBaseNameReservation(baseStem);
        assertEq(popHolder, leonardo);
    }

    function test_entry_point_format_rejections() public {
        _grantPersonhood(ed);

        // The shape check runs before any pricing, so "michael" is rejected for carrying no
        // separator rather than for anything about its tier.
        vm.expectRevert(IDotnsPopController.InvalidDeviceLabel.selector);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({label: "michael", user: ed, chatKey: ""})
        );

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xaa));
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({label: "not.valid", user: ed, link: link})
        );
    }

    function test_same_stem_device_and_personhood_names_occupy_distinct_nodes() public {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0xaa), "");
        // "michael" (baselength 7, no trailing digits) classifies as Personhood
        // and shares the device name's stem, so both tokens coexist on the registrar.
        _grantPersonhood(tiago);
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xbb));
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({label: "michael", user: tiago, link: link})
        );

        assertEq(dotnsRegistry.owner(_deviceNodeOf(DEVICE_LABEL_A)), ed);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("michael"))), tiago);
    }

    function test_both_controllers_can_mint_on_shared_registrar() public {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), "");
        _commitAndRegister("longnamebob01", tiago, true);

        assertEq(dotnsRegistry.owner(_deviceNodeOf(DEVICE_LABEL_A)), ed);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("longnamebob01"))), tiago);
    }

    function test_gateway_reserved_name_rejects_public_register_by_other_user() public {
        _grantPersonhood(tiago);
        // The gateway reserves the stem, and the stem is what the reservation blocks: a public
        // registrant contends for `longnamebob` itself.
        _reservePop(tiago, DEVICE_LABEL_A, _validChatKey(0x11), "longnamebob");

        (address holder,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, tiago);
        // The revert surface is PopRules.priceWithCheck, reached only when the
        // public controller pulls the price during register. We therefore drive
        // the commit-reveal flow by hand so the expectRevert cheatcode lands on
        // the register call rather than on makeCommitment (a view).
        string memory label = "longnamebob";
        bytes32 secret = keccak256(abi.encodePacked(label, ed, block.timestamp));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label,
                owner: ed,
                secret: secret,
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        vm.prank(ed);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPopRules.PopError.selector, "Reserved for a device-name holder's personhood claim"
            )
        );
        vm.prank(ed);
        dotnsRegistrarController.register{value: 1 ether}(registration);
    }

    function test_gateway_reserved_name_allows_holder_to_register_via_public() public {
        _grantPersonhood(tiago);
        _reservePop(tiago, DEVICE_LABEL_A, _validChatKey(0x11), "longnamebob");

        _commitAndRegister("longnamebob", tiago, true);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("longnamebob"))), tiago);
    }

    /// @notice A digit-suffixed spelling of a reserved stem is an unrelated name.
    /// @dev The reservation covers `longnamebob`. `longnamebob01` is measured as written, so it
    ///      shares no stem with it and a stranger may take it. This is the guarantee that
    ///      replaces the old cross-flow, where the two spellings collided.
    function test_gateway_reservation_does_not_cover_a_digit_suffixed_name() public {
        _grantPersonhood(tiago);
        _reservePop(tiago, DEVICE_LABEL_A, _validChatKey(0x11), "longnamebob");

        _grantPersonhood(ed);
        _commitAndRegister("longnamebob01", ed, true);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("longnamebob01"))), ed);
    }

    function test_second_device_name_issuance_of_same_label_reverts() public {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0xaa), "");

        // Re-issuing a device name is rejected at the controller before any registry write, so a
        // duplicate dispatch cannot rehome the identity or overwrite its records.
        _grantPersonhood(tiago);
        vm.expectRevert(IDotnsPopController.DeviceNameAlreadyIssued.selector);
        _rootIssueDeviceNameWithReservation(
            IDotnsPopController.DeviceNameIssuanceWithReservation({
                issuance: IDotnsPopController.DeviceNameIssuance({
                    label: DEVICE_LABEL_A, user: tiago, chatKey: _validChatKey(0xbb)
                }),
                reservedLabel: ""
            })
        );
    }

    /// @notice A device name's owner can host a subname beneath it.
    /// @dev A device name is itself a subname the owner controls in the registry, so the owner
    ///      holds the parent authority @custom:function IDotnsRegistry.setSubnodeOwner requires and
    ///      can graft their own subnames beneath it, such as a device name `phone.michael.01`.
    function test_device_name_owner_can_host_a_subname() public {
        _grantDevicehood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0xb4)
            })
        );

        // A device name is a subname the owner controls, so they can host their own subnames
        // beneath it, such as a device name `phone.michael.01`.
        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: _deviceNodeOf(DEVICE_LABEL_A),
            subLabel: "phone",
            parentLabel: DEVICE_LABEL_A,
            owner: ed,
            persist: true
        });

        vm.prank(ed);
        bytes32 subnode = dotnsRegistry.setSubnodeOwner(subnodeRecord);
        assertEq(dotnsRegistry.owner(subnode), ed);
    }

    /// @notice A public registration blocks the gateway from the same label, and leaves no
    ///         provenance behind.
    /// @dev The reverse of the gateway-first case below. `_popIssued` is written before the mint
    ///      inside the same call, so the assertion that it still reads false is what proves the
    ///      failed mint took the provenance write with it. A public name that answered
    ///      `isPopIssued` would pass for a person.
    function test_personhood_mint_after_public_register_reverts_and_writes_no_provenance() public {
        string memory label = "longnamebobx";

        _grantPersonhood(tiago);
        _commitAndRegister(label, tiago, true);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xd1));
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrar.NameNotAvailable.selector, uint256(_nodeOf(label))
            )
        );
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({label: label, user: ed, link: link})
        );

        assertFalse(dotnsPopController.isPopIssued(label), "provenance survived a failed mint");
        assertFalse(dotnsRegistrar.isSoulbound(uint256(_nodeOf(label))), "public name locked");
    }

    function test_public_register_after_personhood_mint_reverts_at_registrar() public {
        // "longnamebobx" is classification-NoStatus, so ed keeps default status. A personhood
        // label carries no digit suffix.
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: "longnamebobx", user: ed, link: link
            })
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("longnamebobx"))), ed);

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: "longnamebobx",
                owner: tiago,
                secret: keccak256("secret"),
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        vm.prank(tiago);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 price = popRules.priceWithCheck("longnamebobx", tiago).price;

        vm.prank(tiago);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrarController.NameNotAvailable.selector, "longnamebobx"
            )
        );
        dotnsRegistrarController.register{value: price}(registration);
    }

    function test_owner_of_pop_minted_name_can_create_subname() public {
        _grantPersonhood(ed);
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: link
            })
        );

        bytes32 parentNode = _nodeOf(PERSONHOOD_LABEL_A);
        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode,
            subLabel: "app",
            parentLabel: PERSONHOOD_LABEL_A,
            owner: leonardo,
            persist: true
        });

        vm.prank(ed);
        bytes32 subnode = dotnsRegistry.setSubnodeOwner(subnodeRecord);

        assertEq(dotnsRegistry.owner(subnode), leonardo);
    }

    function test_non_owner_cannot_create_subname_under_pop_minted_name() public {
        _grantPersonhood(ed);
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: link
            })
        );

        bytes32 parentNode = _nodeOf(PERSONHOOD_LABEL_A);
        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode,
            subLabel: "app",
            parentLabel: PERSONHOOD_LABEL_A,
            owner: tiago,
            persist: true
        });

        vm.prank(tiago);
        vm.expectRevert(IDotnsRegistry.NotAuthorised.selector);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);
    }

    function test_pop_reservation_of_already_public_minted_name_reverts_at_reserve_time() public {
        // A name minted through the public commit-reveal flow already has an owner, so a PoP
        // reservation over it could never be redeemed. The guard rejects it at reserve time
        // rather than admitting it and only failing at claim, which would have locked every
        // device name built on that stem for the full reservation window.
        _commitAndRegister("longnamebob", ed, true);

        _grantPersonhood(tiago);
        vm.expectRevert(IDotnsPopController.PersonhoodNameUnavailable.selector);
        _reservePop(tiago, DEVICE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        // The guard runs before the device-name mint, so the whole call aborts and no device name
        // is minted for the candidate.
        assertFalse(dotnsRegistrar.exists(uint256(_nodeOf(DEVICE_LABEL_A))));

        // No reservation was recorded, so the stem family stays open to other candidates.
        (bool reserved,) = dotnsPopController.isReservedForClaim("longnamebob");
        assertFalse(reserved);
    }

    function test_enqueue_becomesHead_writes_popRules_reservation() public {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        (address holder, uint64 expires) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, ed);
        assertEq(expires, uint64(block.timestamp + popRules.MAX_RESERVATION_TIME()));
    }

    function test_claim_releases_popRules_slot() public {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        IDotnsPopController.Link memory link = _linkWithDeviceName(DEVICE_LABEL_A);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({label: "longnamebob", user: ed, link: link})
        );

        (address holder,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, address(0));
    }

    function test_relinquish_last_releases_popRules_slot() public {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        vm.prank(ed);
        dotnsPopController.relinquishReservation();

        (address holder,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, address(0));
    }

    function test_advanceExpiredHead_last_expire_releases_popRules_slot() public {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        vm.warp(block.timestamp + dotnsPopController.reservationDuration() + 1);
        dotnsPopController.expireReservation("longnamebob");

        (address holder,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, address(0));
    }

    function test_issueDeviceNameWithReservation_reverts_for_digit_suffixed_reserved_label()
        public
    {
        _grantPersonhood(ed);
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0xaa), "longnamebob01");
    }

    function test_issueDeviceNameWithReservation_reverts_when_reserved_label_already_registered()
        public
    {
        // George worked example: ed reserves and then claims the base name, which frees the stem
        // slot on PopRules. A later device-name candidate must not be able to queue a reservation
        // over the now-registered name: the queue keys by stem, so an unclaimable reservation would
        // hold that stem for the full reservation window and block every device name built on it.
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0xaa), "longnamebob");
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: "longnamebob", user: ed, link: _linkWithDeviceName(DEVICE_LABEL_A)
            })
        );

        _grantPersonhood(tiago);
        vm.expectRevert(IDotnsPopController.PersonhoodNameUnavailable.selector);
        _reservePop(tiago, DEVICE_LABEL_B, _validChatKey(0xbb), "longnamebob");
    }

    /// @dev Claiming the stem takes the name, so nothing is left for a stranger to register.
    ///      What the claim releases is the reservation slot on PopRules, which is what this
    ///      asserts; a digit-suffixed spelling would prove nothing, being an unrelated name.
    function test_claim_clears_the_reservation_slot() public {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        (address beforeClaim,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(beforeClaim, ed, "reserved for the claimant");

        IDotnsPopController.Link memory link = _linkWithDeviceName(DEVICE_LABEL_A);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({label: "longnamebob", user: ed, link: link})
        );

        (address afterClaim,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(afterClaim, address(0), "slot released by the claim");
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("longnamebob"))), ed);
    }

    function test_public_stranger_can_mint_after_reservation_expires() public {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        vm.warp(block.timestamp + dotnsPopController.reservationDuration() + 1);
        dotnsPopController.expireReservation("longnamebob");

        _grantPersonhood(tiago);
        _commitAndRegister("longnamebob", tiago, true);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("longnamebob"))), tiago);
    }

    function test_registered_controller_without_root_origin_cannot_enter_pop_flow() public {
        // The public commit-reveal controller is already a registered controller.
        // Even from that origin, the Root-gate must reject the call.
        _mockOriginIsRoot(false);
        vm.prank(address(dotnsRegistrarController));
        vm.expectRevert(IDotnsPopController.NotRoot.selector);
        dotnsPopController.issueDeviceNameWithReservation(
            IDotnsPopController.DeviceNameIssuanceWithReservation({
                issuance: IDotnsPopController.DeviceNameIssuance({
                    label: DEVICE_LABEL_A, user: ed, chatKey: ""
                }),
                reservedLabel: "longnamebob"
            })
        );
    }

    // Asserts exactly one entry in `logs` matches event signature `sig`.
    function _assertEventEmittedOnce(Vm.Log[] memory logs, bytes32 sig) internal pure {
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == sig) count++;
        }
        require(count == 1, "expected exactly one matching event");
    }

    // Asserts no entry in `logs` matches event signature `sig`.
    function _assertEventNotEmitted(Vm.Log[] memory logs, bytes32 sig) internal pure {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == sig) {
                revert("unexpected event emitted");
            }
        }
    }

    function test_expireReservation_on_empty_queue_is_noop() public {
        // Permissionless expire against a label with no reservations must be a
        // no-op. The path is cheap enough that a bot can spam it; reverting on
        // empty queues would turn that spam into an accidental DoS against
        // unrelated callers.
        string memory stem = "noqueue";

        (bool reservedBefore,) = dotnsPopController.isReservedForClaim(stem);
        assertFalse(reservedBefore);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        dotnsPopController.expireReservation(stem);

        (bool reservedAfter,) = dotnsPopController.isReservedForClaim(stem);
        assertFalse(reservedAfter);
    }

    function test_issuePersonhoodName_standalone_succeeds_when_head_is_expired() public {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), PERSONHOOD_LABEL_A);
        // Walk past both the controller and PopRules expiry windows so
        // nothing blocks tiago's priceWithCheck.
        vm.warp(block.timestamp + popRules.MAX_RESERVATION_TIME() + 1);

        _grantPersonhood(tiago);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: tiago, link: link
            })
        );

        assertEq(
            IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(PERSONHOOD_LABEL_A))), tiago
        );
    }

    function test_issuePersonhoodName_standalone_succeeds_when_queue_empty() public {
        _grantPersonhood(ed);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: link
            })
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(PERSONHOOD_LABEL_A))), ed);
    }

    function test_issuePersonhoodName_claim_path_bypasses_standalone_holder_guard() public {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), PERSONHOOD_LABEL_A);

        IDotnsPopController.Link memory link = _linkWithDeviceName(DEVICE_LABEL_A);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: link
            })
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(PERSONHOOD_LABEL_A))), ed);
    }

    function test_issuePersonhoodName_guard_blocks_stranger_and_preserves_claim() public {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), PERSONHOOD_LABEL_A);

        _grantPersonhood(tiago);
        IDotnsPopController.Link memory strangerLink = _linkFresh(_validChatKey(0xbb));
        vm.expectPartialRevert(IDotnsPopController.NotHolder.selector);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: tiago, link: strangerLink
            })
        );
        // A's reservation is intact; A claims successfully.
        IDotnsPopController.Link memory claimLink = _linkWithDeviceName(DEVICE_LABEL_A);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: claimLink
            })
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(PERSONHOOD_LABEL_A))), ed);
    }

    function test_issuePersonhoodName_reverts_for_governance_length_name() public {
        _grantPersonhood(ed);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xaa));
        // Stem "alice" has baselength 5; classifies as `Reserved for Governance`,
        // which the PoP controller's governance guard rejects.
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);

        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({label: "alice", user: ed, link: link})
        );
    }

    function test_issueDeviceNameWithReservation_reserved_label_classification_reverts() public {
        _grantPersonhood(ed);

        // The issuance uses a valid device name; reserved leg uses a <=5-char stem,
        // which classifies as `Reserved for Governance` and is rejected by the
        // PoP controller's governance guard.
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootIssueDeviceNameWithReservation(
            IDotnsPopController.DeviceNameIssuanceWithReservation({
                issuance: IDotnsPopController.DeviceNameIssuance({
                    label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
                }),
                reservedLabel: "alice"
            })
        );
    }

    function test_issuePersonhoodName_personhood_user_on_personhood_label_succeeds() public {
        _grantPersonhood(ed);

        uint256 controllerBalanceBefore = address(dotnsPopController).balance;

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xaa));
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: link
            })
        );
        // No native token moves on the PoP path.
        assertEq(address(dotnsPopController).balance, controllerBalanceBefore);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(PERSONHOOD_LABEL_A))), ed);
    }

    function test_issueDeviceName_succeeds_regardless_of_stem_reservation() public {
        string memory baseStem = PERSONHOOD_LABEL_A;
        // Occupy the base stem with a live reservation.
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), baseStem);
        // A different user calls issueDeviceName on a different device name.
        address fresh = makeAddr("freshDevice");
        _grantDevicehood(fresh);

        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: "stephen.01", user: fresh, chatKey: _validChatKey(0xcc)
            })
        );

        assertEq(dotnsRegistry.owner(_deviceNodeOf("stephen.01")), fresh);
    }

    function test_issueDeviceName_reverts_for_non_device_format() public {
        _grantPersonhood(ed);

        vm.expectRevert(IDotnsPopController.InvalidDeviceLabel.selector);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: "alice", user: ed, chatKey: _validChatKey(0xaa)
            })
        );
    }

    function test_issueDeviceName_reverts_when_suffix_is_not_exactly_two_digits() public {
        _grantPersonhood(ed);

        vm.expectRevert(IDotnsPopController.InvalidDeviceLabel.selector);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: "michael.001", user: ed, chatKey: _validChatKey(0xaa)
            })
        );
    }

    function test_issueDeviceName_reverts_when_the_stem_is_governance_reserved() public {
        _grantPersonhood(ed);

        // `abcd.12` is a well-formed device name whose four-letter stem classifies as Reserved,
        // so classification is what rejects it rather than the shape.
        vm.expectRevert(IDotnsPopController.InvalidDeviceLabel.selector);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: "abcd.12", user: ed, chatKey: _validChatKey(0xaa)
            })
        );
    }

    function test_issueDeviceName_succeeds_for_long_stem() public {
        _grantDevicehood(ed);

        // `andrewsays.01` has a stem of 10, which classifies as NoStatus. The gateway may issue
        // it as a device name regardless of stem length.
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: "andrewsays.01", user: ed, chatKey: _validChatKey(0xaa)
            })
        );

        assertEq(dotnsRegistry.owner(_deviceNodeOf("andrewsays.01")), ed);
    }

    /// @notice A public registration is not an identity and is not listed.
    /// @dev The listing requires provenance, so a name the gateway never minted is absent however
    ///      it is spelled. Without that, `joseph42` would read as a personhood name purely because
    ///      it is a single label.
    function test_lens_omits_a_public_registration() public {
        _grantPersonhood(ed);
        _commitAndRegister("joseph42", ed, true);

        assertFalse(dotnsPopController.isPopIssued("joseph42"), "the gateway did not mint it");

        assertEq(dotnsPopLens.namesOf(ed, 0, 10).length, 0, "not an identity");
        assertEq(dotnsPopLens.nameCountOf(ed), 0);
    }

    /// @notice Device names and personhood names come back in one listing.
    /// @dev `isPopIssued` covers every name the controller mints, of both kinds, and the label
    ///      shape tells them apart: a device name carries its separator.
    function test_lens_lists_device_and_personhood_names_together() public {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), "");

        IDotnsPopController.Link memory link = _linkWithDeviceName(DEVICE_LABEL_A);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: link
            })
        );

        assertTrue(
            dotnsPopController.isPopIssued(PERSONHOOD_LABEL_A), "both kinds carry provenance"
        );
        assertTrue(dotnsPopController.isPopIssued(DEVICE_LABEL_A), "both kinds carry provenance");

        IDotnsPopLens.Name[] memory names = dotnsPopLens.namesOf(ed, 0, 10);
        assertEq(names.length, 2, "both names are listed");
        assertTrue(_namesContainNode(names, _nodeOf(PERSONHOOD_LABEL_A)), "the personhood name");
        assertTrue(_namesContainNode(names, _deviceNodeOf(DEVICE_LABEL_A)), "and the device name");
        assertEq(dotnsPopLens.nameCountOf(ed), 2);
    }

    /// @notice A personhood name is letters only, the same rule a device-name stem follows.
    /// @dev The hyphen and interior-digit cases are the ones a trailing-digit check misses:
    ///      `alice-bob` and `micha3l` are valid DNS labels and would otherwise be issued as
    ///      identities, while being impossible as device-name stems. All three revert with this
    ///      interface's own error.
    function test_issuePersonhoodName_rejects_a_label_that_is_not_letters_only() public {
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xa1));

        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({label: "alice-bob", user: ed, link: link})
        );

        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({label: "micha3l", user: ed, link: link})
        );

        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({label: "Joseph", user: ed, link: link})
        );
    }

    /// @dev The reservation entrypoints share `_validatePersonhoodLabel`, so a hyphen is rejected
    ///      there too rather than resolving to an empty queue.
    function test_reservation_entrypoints_reject_a_label_that_is_not_letters_only() public {
        _grantPersonhood(ed);

        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0xa2), "alice-bob");

        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        dotnsPopController.expireReservation("alice-bob");

        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        dotnsPopController.isReservedForClaim("micha3l");

        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0xa3), "Joseph");
    }

    /// @notice The controller answers its own ERC-165 id and nothing else.
    function test_supportsInterface_answers_the_controller_id() public view {
        assertTrue(
            dotnsPopController.supportsInterface(type(IDotnsPopController).interfaceId),
            "controller id"
        );
        assertFalse(dotnsPopController.supportsInterface(bytes4(0xdeadbeef)), "unrelated id");
    }

    /// @notice The name reaches the chain in the form People Chain and the gateway hold it.
    /// @dev The node is the hash of the whole string, so it is not the node a subname path
    ///      would produce for the same text. Pinning both is what makes "keep the dot"
    ///      concrete rather than cosmetic.
    function test_issueDeviceName_stores_the_label_with_its_separator() public {
        _grantDevicehood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: "michael.01", user: ed, chatKey: _validChatKey(0xaa)
            })
        );

        // The name is a subname under its numeric container, owned in the registry record.
        bytes32 subnamePathNode = _deviceNodeOf("michael.01");
        assertEq(dotnsRegistry.owner(subnamePathNode), ed);

        // The whole-label reading is a different node and is never minted as a token.
        bytes32 wholeLabelNode = _nodeOf("michael.01");
        assertTrue(wholeLabelNode != subnamePathNode, "whole label and subname path differ");
        assertFalse(dotnsRegistrar.exists(uint256(wholeLabelNode)));
    }

    function test_isPopIssued_is_set_at_mint() public {
        _grantDevicehood(ed);
        assertFalse(dotnsPopController.isPopIssued("michael.01"), "not issued before the mint");

        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: "michael.01", user: ed, chatKey: _validChatKey(0xaa)
            })
        );

        assertTrue(dotnsPopController.isPopIssued("michael.01"), "issued after the mint");
    }

    /// @dev The signal must be false for anything the gateway did not mint, or it cannot tell a
    ///      person from a subname, which is the only reason it exists.
    function test_isPopIssued_is_false_for_a_name_the_gateway_did_not_issue() public {
        assertFalse(dotnsPopController.isPopIssued("michael.01"));
        assertFalse(dotnsPopController.isPopIssued(NOSTATUS_LABEL_A));
        assertFalse(dotnsPopController.isPopIssued(""));
    }

    /// @dev Provenance is written at mint, and the cold path mints before the store exists, so a
    ///      name stashed as a pending claim must already answer true.
    function test_isPopIssued_holds_across_cold_path_settlement() public {
        address cold = makeAddr("coldClaimant");
        _grantDevicehood(cold);

        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: "william.03", user: cold, chatKey: _validChatKey(0xbb)
            })
        );

        assertTrue(dotnsPopController.isPopIssued("william.03"), "true while still pending");

        vm.prank(cold);
        dotnsPopController.claimLabelStore();
        dotnsPopController.settlePendingClaims(cold, type(uint256).max);

        assertTrue(dotnsPopController.isPopIssued("william.03"), "still true once settled");
    }

    /// @dev Provenance covers every name this controller mints, not only the device-name ones,
    ///      because it records who issued the name rather than which tier it sits in.
    function test_isPopIssued_covers_personhood_names() public {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), "");

        IDotnsPopController.Link memory link = _linkWithDeviceName(DEVICE_LABEL_A);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: link
            })
        );

        assertTrue(dotnsPopController.isPopIssued(PERSONHOOD_LABEL_A));
    }

    function test_issueDeviceName_reverts_when_origin_is_not_root() public {
        _mockOriginIsRoot(false);
        vm.expectRevert(IDotnsPopController.NotRoot.selector);
        dotnsPopController.issueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
            })
        );
    }

    function test_issueDeviceNameWithReservation_issuance_and_reservation_both_succeed_in_one_call()
        public
    {
        _grantPersonhood(ed);

        _rootIssueDeviceNameWithReservation(
            IDotnsPopController.DeviceNameIssuanceWithReservation({
                issuance: IDotnsPopController.DeviceNameIssuance({
                    label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
                }),
                reservedLabel: PERSONHOOD_LABEL_A
            })
        );

        assertEq(dotnsRegistry.owner(_deviceNodeOf(DEVICE_LABEL_A)), ed);

        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertTrue(reserved);
        assertEq(holder, ed);
    }

    function test_split_gateway_flow_issues_device_name_then_reserves_personhood_name() public {
        _grantPersonhood(ed);

        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
            })
        );

        assertEq(dotnsRegistry.owner(_deviceNodeOf(DEVICE_LABEL_A)), ed);
        assertFalse(dotnsRegistrar.exists(uint256(_nodeOf(PERSONHOOD_LABEL_A))));

        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: ed, label: PERSONHOOD_LABEL_A})
        );

        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertTrue(reserved);
        assertEq(holder, ed);
        assertFalse(dotnsRegistrar.exists(uint256(_nodeOf(PERSONHOOD_LABEL_A))));
    }

    function test_reservePersonhoodName_reverts_when_origin_is_not_root() public {
        _mockOriginIsRoot(false);
        vm.expectRevert(IDotnsPopController.NotRoot.selector);
        dotnsPopController.reservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: ed, label: PERSONHOOD_LABEL_A})
        );
    }

    function test_reservePersonhoodName_reverts_for_reserved_or_suffixed_labels() public {
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: ed, label: "alice"})
        );

        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: ed, label: "longnamebob01"})
        );
    }

    function test_reservePersonhoodName_reverts_when_label_already_registered() public {
        // The standalone reservation entrypoint shares the same guard: a base name that already
        // has an owner on the registrar can never be redeemed, so the reservation is rejected up
        // front rather than discovered to be unusable at claim time.
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0xaa), "longnamebob");
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: "longnamebob", user: ed, link: _linkWithDeviceName(DEVICE_LABEL_A)
            })
        );

        vm.expectRevert(IDotnsPopController.PersonhoodNameUnavailable.selector);
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: tiago, label: "longnamebob"})
        );
    }

    function test_reservePersonhoodName_does_not_issue_a_name() public {
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: ed, label: PERSONHOOD_LABEL_A})
        );

        assertFalse(dotnsRegistrar.exists(uint256(_nodeOf(DEVICE_LABEL_A))));
        assertFalse(dotnsRegistrar.exists(uint256(_nodeOf(PERSONHOOD_LABEL_A))));

        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertTrue(reserved);
        assertEq(holder, ed);
    }

    function test_reservePersonhoodName_same_user_can_replace_prior_reservation() public {
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: ed, label: PERSONHOOD_LABEL_A})
        );
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: ed, label: PERSONHOOD_LABEL_B})
        );

        (bool firstReserved,) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertFalse(firstReserved);

        (bool secondReserved, address holder) =
            dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_B);
        assertTrue(secondReserved);
        assertEq(holder, ed);
    }

    function test_third_party_settles_pending_claim_into_user_store() public {
        // Settlement is permissionless: a third party who is neither the beneficiary nor the
        // gateway can settle a user's pending claim, deploying the user's store and writing the
        // stashed label. The settled name lands in the beneficiary's store, and the settlement
        // event records the third party as the settler.
        _grantPersonhood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
            })
        );

        bytes32 labelhash = keccak256(bytes(DEVICE_LABEL_A));
        address expectedStore =
            vm.computeCreateAddress(address(storeFactory), vm.getNonce(address(storeFactory)));

        vm.prank(leonardo);
        vm.expectEmit(true, true, false, true, address(dotnsPopController));
        emit IDotnsPopController.PendingClaimSettled(ed, labelhash, expectedStore, leonardo);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        address store = storeFactory.getLabelStore(ed);
        assertEq(store, expectedStore);
        assertEq(
            ILabelStore(store).getLabel(_deviceNodeOf(DEVICE_LABEL_A)),
            string.concat(DEVICE_LABEL_A, ".dot")
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function test_user_settles_own_pending_claim_after_gateway_mint() public {
        _grantPersonhood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
            })
        );

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(_deviceNodeOf(DEVICE_LABEL_A)),
            string.concat(DEVICE_LABEL_A, ".dot")
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function test_claimLabelStore_settles_callers_own_pending_claim() public {
        _grantPersonhood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
            })
        );

        vm.prank(ed);
        bool moreRemaining = dotnsPopController.claimLabelStore();
        assertFalse(moreRemaining);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(_deviceNodeOf(DEVICE_LABEL_A)),
            string.concat(DEVICE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function test_settle_deploys_store_when_user_has_none() public {
        _grantPersonhood(ed);

        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
            })
        );

        assertEq(dotnsPopController.pendingClaims(ed, 0, 1)[0].label, DEVICE_LABEL_A);
        assertEq(storeFactory.getLabelStore(ed), address(0));

        (uint256 settledCount, bool moreRemaining) =
            dotnsPopController.settlePendingClaims(ed, type(uint256).max);
        assertEq(settledCount, 1);
        assertFalse(moreRemaining);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(_deviceNodeOf(DEVICE_LABEL_A)),
            string.concat(DEVICE_LABEL_A, ".dot")
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function test_issuePersonhoodName_zero_length_label_reverts() public {
        _grantPersonhood(ed);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xaa));
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({label: "", user: ed, link: link})
        );
    }

    function test_issueDeviceNameWithReservation_accepts_65_byte_chat_key() public {
        _grantPersonhood(ed);

        bytes memory chatKey = _validChatKey(0x42);

        _rootIssueDeviceNameWithReservation(
            IDotnsPopController.DeviceNameIssuanceWithReservation({
                issuance: IDotnsPopController.DeviceNameIssuance({
                    label: DEVICE_LABEL_A, user: ed, chatKey: chatKey
                }),
                reservedLabel: ""
            })
        );

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        bytes32 node = _deviceNodeOf(DEVICE_LABEL_A);
        assertEq(dotnsPopResolver.chatKey(node), chatKey);
    }

    function test_revert_setReservationDuration_below_minimum() public {
        // The setter enforces a floor so a single owner call cannot retroactively
        // expire every live queue and pending-claim entry.
        uint64 minDuration = dotnsPopController.MIN_RESERVATION_DURATION();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsPopController.ReservationDurationTooLow.selector, 0)
        );
        dotnsPopController.setReservationDuration(0);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsPopController.ReservationDurationTooLow.selector, minDuration - 1
            )
        );
        dotnsPopController.setReservationDuration(minDuration - 1);
    }

    function test_gatewayReserve_stashes_pending_claim_when_user_has_no_label_store() public {
        _grantPersonhood(ed);
        bytes memory chatKey = _validChatKey(0x01);

        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: chatKey
            })
        );

        bytes32 node = _deviceNodeOf(DEVICE_LABEL_A);
        assertEq(dotnsRegistry.owner(node), ed);
        assertEq(storeFactory.getLabelStore(ed), address(0));
        // Chat key is now persisted eagerly on the resolver at reserve time, even when
        // the user has no LabelStore yet.
        assertEq(dotnsPopResolver.chatKey(node), chatKey);

        IDotnsPopController.PendingClaim[] memory pending =
            dotnsPopController.pendingClaims(ed, 0, type(uint256).max);
        assertEq(pending[0].label, DEVICE_LABEL_A);
        assertGt(pending[0].mintedAt, 0);
    }

    function test_settle_deploys_store_and_writes_label_and_chat_key() public {
        _grantPersonhood(ed);
        bytes memory chatKey = _validChatKey(0x07);

        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: chatKey
            })
        );

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));

        bytes32 node = _deviceNodeOf(DEVICE_LABEL_A);
        assertEq(
            ILabelStore(store).getLabel(node), string.concat(DEVICE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(dotnsPopResolver.chatKey(node), chatKey);

        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function test_settle_emits_settled_and_name_registered() public {
        _grantPersonhood(ed);
        bytes memory chatKey = _validChatKey(0x03);

        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: chatKey
            })
        );

        bytes32 labelhash = keccak256(bytes(DEVICE_LABEL_A));
        address expectedStore =
            vm.computeCreateAddress(address(storeFactory), vm.getNonce(address(storeFactory)));

        vm.prank(ed);
        vm.expectEmit(true, true, false, true, address(dotnsPopController));
        emit IDotnsPopController.PendingClaimSettled(ed, labelhash, expectedStore, ed);
        vm.expectEmit(true, true, true, true, address(dotnsPopController));
        emit IDotnsPopController.NameRegistered(DEVICE_LABEL_A, labelhash, ed, expectedStore);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);
    }

    function test_settlePendingClaims_on_empty_queue_returns_zero() public {
        // Settlement is permissionless and non-reverting: a call against a user with no staged
        // claims settles nothing and reports an empty queue rather than reverting.
        vm.prank(ed);
        (uint256 settledCount, bool moreRemaining) =
            dotnsPopController.settlePendingClaims(ed, type(uint256).max);
        assertEq(settledCount, 0);
        assertFalse(moreRemaining);
        assertEq(storeFactory.getLabelStore(ed), address(0));
    }

    function test_settlePendingClaims_bounded_settles_up_to_limit() public {
        // A large queue is drained in bounded batches so a single settlement can never exceed the
        // block gas limit. Settling with a limit below the queue length reports the residue and a
        // follow-up call clears it.
        _grantPersonhood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0x05)
            })
        );
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_B, user: ed, chatKey: _validChatKey(0x06)
            })
        );
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_C, user: ed, chatKey: _validChatKey(0x07)
            })
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 3);

        vm.prank(ed);
        (uint256 firstCount, bool moreAfterFirst) = dotnsPopController.settlePendingClaims(ed, 1);
        assertEq(firstCount, 1);
        assertTrue(moreAfterFirst);
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 2);

        vm.prank(ed);
        (uint256 secondCount, bool moreAfterSecond) =
            dotnsPopController.settlePendingClaims(ed, type(uint256).max);
        assertEq(secondCount, 2);
        assertFalse(moreAfterSecond);
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function test_settle_on_expiry_by_third_party_writes_label() public {
        // Age never gates settlement: a claim warped past its reservation deadline still settles
        // in full. A third party drives the settlement, the store is deployed for the beneficiary,
        // the label is written, the queue empties, the beneficiary leaves the enumeration set, and
        // the settler is recorded on the event.
        _grantPersonhood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0x02)
            })
        );

        vm.warp(block.timestamp + DEFAULT_RESERVATION_DURATION + 1);

        bytes32 labelhash = keccak256(bytes(DEVICE_LABEL_A));
        address expectedStore =
            vm.computeCreateAddress(address(storeFactory), vm.getNonce(address(storeFactory)));

        vm.prank(leonardo);
        vm.expectEmit(true, true, false, true, address(dotnsPopController));
        emit IDotnsPopController.PendingClaimSettled(ed, labelhash, expectedStore, leonardo);
        (uint256 settledCount, bool moreRemaining) =
            dotnsPopController.settlePendingClaims(ed, type(uint256).max);
        assertEq(settledCount, 1);
        assertFalse(moreRemaining);

        address store = storeFactory.getLabelStore(ed);
        assertEq(store, expectedStore);
        assertEq(
            ILabelStore(store).getLabel(_deviceNodeOf(DEVICE_LABEL_A)),
            string.concat(DEVICE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
        assertEq(dotnsPopController.pendingClaimUserCount(), 0);
    }

    function test_settle_after_reservation_duration_still_writes_label() public {
        // The old model dropped lapsed entries; stores now always settle. Warping past the
        // reservation duration and settling writes the label into the store rather than
        // discarding it.
        _grantPersonhood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0x04)
            })
        );

        vm.warp(block.timestamp + DEFAULT_RESERVATION_DURATION + 1);

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(_deviceNodeOf(DEVICE_LABEL_A)),
            string.concat(DEVICE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
        assertEq(dotnsPopController.pendingClaimUserCount(), 0);
    }

    function test_issueDeviceName_piles_second_pending_claim_when_caller_has_no_store() public {
        // The Root gateway origin cannot deploy a LabelStore, so a store-less user keeps
        // accumulating deferred names instead of reverting; a single signed-origin
        // settlement writes them all at once.
        _grantPersonhood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0x05)
            })
        );
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_B, user: ed, chatKey: _validChatKey(0x06)
            })
        );

        IDotnsPopController.PendingClaim[] memory pending =
            dotnsPopController.pendingClaims(ed, 0, type(uint256).max);
        assertEq(pending.length, 2);
        assertEq(pending[0].label, DEVICE_LABEL_A);
        assertEq(pending[1].label, DEVICE_LABEL_B);
        assertEq(dotnsPopController.pendingClaimUserCount(), 1);

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(_deviceNodeOf(DEVICE_LABEL_A)),
            string.concat(DEVICE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(
            ILabelStore(store).getLabel(_deviceNodeOf(DEVICE_LABEL_B)),
            string.concat(DEVICE_LABEL_B, protocolRegistry.tld())
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
        assertEq(dotnsPopController.pendingClaimUserCount(), 0);
    }

    function test_pendingClaims_returns_empty_array_for_fresh_user() public view {
        assertEq(dotnsPopController.pendingClaims(ed, 0, type(uint256).max).length, 0);
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function test_issuePersonhoodName_claim_by_store_less_personhood_piles_then_settles() public {
        // Regression: a store-less personhood holder reserves a device name plus a base reservation
        // (the device-name issuance stashes a deferred claim because Root cannot deploy the store),
        // then claims the base name. The base mint stashes a second deferred claim instead of
        // reverting; one signed-origin settlement deploys the store and settles both.
        _grantPersonhood(ed);
        _rootIssueDeviceNameWithReservation(
            IDotnsPopController.DeviceNameIssuanceWithReservation({
                issuance: IDotnsPopController.DeviceNameIssuance({
                    label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0x31)
                }),
                reservedLabel: PERSONHOOD_LABEL_A
            })
        );
        assertEq(storeFactory.getLabelStore(ed), address(0));
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 1);

        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkWithDeviceName(DEVICE_LABEL_A)
            })
        );

        IDotnsPopController.PendingClaim[] memory pending =
            dotnsPopController.pendingClaims(ed, 0, type(uint256).max);
        assertEq(pending.length, 2);
        assertEq(pending[0].label, DEVICE_LABEL_A);
        assertEq(pending[1].label, PERSONHOOD_LABEL_A);

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(_deviceNodeOf(DEVICE_LABEL_A)),
            string.concat(DEVICE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(
            ILabelStore(store).getLabel(_nodeOf(PERSONHOOD_LABEL_A)),
            string.concat(PERSONHOOD_LABEL_A, protocolRegistry.tld())
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function test_pendingClaimUsers_enumeration_mirrors_stash_and_settle() public {
        _grantPersonhood(ed);
        _grantPersonhood(tiago);
        _grantPersonhood(leonardo);

        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0x01)
            })
        );
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_B, user: tiago, chatKey: _validChatKey(0x02)
            })
        );
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_C, user: leonardo, chatKey: _validChatKey(0x03)
            })
        );

        assertEq(dotnsPopController.pendingClaimUserCount(), 3);

        address[] memory page = dotnsPopController.pendingClaimUsers(0, 10);
        assertEq(page.length, 3);
        assertTrue(_containsAddress(page, ed));
        assertTrue(_containsAddress(page, tiago));
        assertTrue(_containsAddress(page, leonardo));

        vm.prank(tiago);
        dotnsPopController.settlePendingClaims(tiago, type(uint256).max);

        assertEq(dotnsPopController.pendingClaimUserCount(), 2);
        address[] memory after_ = dotnsPopController.pendingClaimUsers(0, 10);
        assertEq(after_.length, 2);
        assertFalse(_containsAddress(after_, tiago));
        assertTrue(_containsAddress(after_, ed));
        assertTrue(_containsAddress(after_, leonardo));
    }

    function test_pendingClaimUsers_returns_empty_when_offset_past_count() public {
        _grantPersonhood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0x01)
            })
        );

        address[] memory empty = dotnsPopController.pendingClaimUsers(5, 10);
        assertEq(empty.length, 0);
    }

    function test_settle_at_exact_expiry_boundary_writes_label() public {
        // Age is irrelevant to settlement: at the exact reservation deadline the claim still
        // settles and writes its label rather than being treated as forfeit.
        _grantPersonhood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0x11)
            })
        );

        uint64 mintedAt = dotnsPopController.pendingClaims(ed, 0, 1)[0].mintedAt;
        vm.warp(uint256(mintedAt) + uint256(DEFAULT_RESERVATION_DURATION));

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(_deviceNodeOf(DEVICE_LABEL_A)),
            string.concat(DEVICE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function test_settle_is_keyed_by_user_arg_other_stash_untouched() public {
        // Settlement targets the `user` argument, not the caller: settling for a user with no
        // stash is a no-op and does not disturb another user's pending claim.
        _grantPersonhood(ed);
        bytes memory chatKey = _validChatKey(0x12);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: chatKey
            })
        );

        vm.prank(tiago);
        (uint256 settledCount, bool moreRemaining) =
            dotnsPopController.settlePendingClaims(tiago, type(uint256).max);
        assertEq(settledCount, 0);
        assertFalse(moreRemaining);

        IDotnsPopController.PendingClaim[] memory pending =
            dotnsPopController.pendingClaims(ed, 0, type(uint256).max);
        assertEq(pending[0].label, DEVICE_LABEL_A);
        assertGt(pending[0].mintedAt, 0);
        assertEq(storeFactory.getLabelStore(ed), address(0));
        assertEq(storeFactory.getLabelStore(tiago), address(0));
        assertEq(dotnsPopController.pendingClaimUserCount(), 1);
    }

    function test_pendingClaimUsers_pagination_boundary_cases() public {
        _grantPersonhood(ed);
        _grantPersonhood(tiago);
        _grantPersonhood(leonardo);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0x01)
            })
        );
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_B, user: tiago, chatKey: _validChatKey(0x02)
            })
        );
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_C, user: leonardo, chatKey: _validChatKey(0x03)
            })
        );

        uint256 count = dotnsPopController.pendingClaimUserCount();
        assertEq(count, 3);
        assertEq(dotnsPopController.pendingClaimUsers(count, 10).length, 0);
        assertEq(dotnsPopController.pendingClaimUsers(count - 1, 10).length, 1);
        assertEq(dotnsPopController.pendingClaimUsers(0, 0).length, 0);
        assertEq(dotnsPopController.pendingClaimUsers(1, 1).length, 1);
        assertEq(dotnsPopController.pendingClaimUsers(0, 100).length, 3);
    }

    function test_settle_with_empty_chat_key_skips_resolver_write() public {
        _grantPersonhood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({label: DEVICE_LABEL_A, user: ed, chatKey: ""})
        );

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        bytes32 node = _deviceNodeOf(DEVICE_LABEL_A);
        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(node), string.concat(DEVICE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(dotnsPopResolver.chatKey(node).length, 0);
    }

    function test_gatewayReserve_warm_user_after_settle_writes_directly_without_stashing() public {
        _grantPersonhood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0x21)
            })
        );

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);
        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));

        bytes memory secondChatKey = _validChatKey(0x22);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_B, user: ed, chatKey: secondChatKey
            })
        );

        bytes32 node = _deviceNodeOf(DEVICE_LABEL_B);
        assertEq(
            ILabelStore(store).getLabel(node), string.concat(DEVICE_LABEL_B, protocolRegistry.tld())
        );
        assertEq(dotnsPopResolver.chatKey(node), secondChatKey);
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
        assertEq(dotnsPopController.pendingClaimUserCount(), 0);
    }

    function test_advanceExpiredHead_promotes_waiter_and_resyncs_popRules() public {
        string memory stem = "longnamebob";
        uint64 duration = dotnsPopController.reservationDuration();
        _grantPersonhood(ed);
        _grantPersonhood(tiago);

        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), stem);
        vm.warp(block.timestamp + uint256(duration) / 2);
        _reservePop(tiago, DEVICE_LABEL_B, _validChatKey(0x02), stem);

        bytes32 labelhash = keccak256(bytes(stem));
        (uint64 head, uint64 tail) = dotnsPopController.reservationMeta(labelhash);
        assertEq(head, 0);
        assertEq(tail, 2);
        (address popHolderBefore,) = popRules.getBaseNameReservation(stem);
        assertEq(popHolderBefore, ed);

        vm.warp(block.timestamp + uint256(duration) / 2 + 1);

        vm.recordLogs();
        dotnsPopController.expireReservation(stem);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertEventEmittedOnce(logs, keccak256("ReservationExpired(bytes32,address)"));
        _assertEventEmittedOnce(logs, keccak256("ReservationHeadAdvanced(bytes32,address)"));

        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(stem);
        assertTrue(reserved);
        assertEq(holder, tiago);

        (address popHolderAfter,) = popRules.getBaseNameReservation(stem);
        assertEq(popHolderAfter, tiago);

        (head, tail) = dotnsPopController.reservationMeta(labelhash);
        assertEq(head, 1);
        assertEq(tail, 2);
    }

    function test_multiWaiter_standaloneGuard_rejects_non_head_user() public {
        _grantPersonhood(ed);
        _grantPersonhood(tiago);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), PERSONHOOD_LABEL_A);
        _reservePop(tiago, DEVICE_LABEL_B, _validChatKey(0x02), PERSONHOOD_LABEL_A);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xbb));
        vm.expectPartialRevert(IDotnsPopController.NotHolder.selector);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: tiago, link: link
            })
        );
    }

    function test_namesOf_lists_issued_names_with_settlement_state() public {
        // Settled names read back from the store; a pending gateway name reads from the queue with
        // a live deadline; an untouched account returns an empty list and a zero count.
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), "");
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkFresh(_validChatKey(0x02))
            })
        );

        _grantPersonhood(leonardo);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_C, user: leonardo, chatKey: _validChatKey(0x03)
            })
        );

        IDotnsPopLens.Name[] memory edNames = dotnsPopLens.namesOf(ed, 0, type(uint256).max);
        assertEq(edNames.length, 2);
        IDotnsPopLens.Name memory edDevice = _nameWithNode(edNames, _deviceNodeOf(DEVICE_LABEL_A));
        assertEq(edDevice.label, DEVICE_LABEL_A);
        assertTrue(edDevice.settled);
        assertEq(edDevice.deadline, 0);
        IDotnsPopLens.Name memory edPersonhood = _nameWithNode(edNames, _nodeOf(PERSONHOOD_LABEL_A));
        assertEq(edPersonhood.label, PERSONHOOD_LABEL_A);
        assertTrue(edPersonhood.settled);
        assertEq(dotnsPopLens.nameCountOf(ed), 2);

        IDotnsPopLens.Name[] memory leoNames = dotnsPopLens.namesOf(leonardo, 0, type(uint256).max);
        assertEq(leoNames.length, 1);
        assertEq(leoNames[0].node, _deviceNodeOf(DEVICE_LABEL_C));
        assertEq(leoNames[0].label, DEVICE_LABEL_C);
        assertFalse(leoNames[0].settled);
        assertGt(leoNames[0].deadline, 0);
        assertEq(dotnsPopLens.nameCountOf(leonardo), 1);

        assertEq(dotnsPopLens.namesOf(tiago, 0, type(uint256).max).length, 0);
        assertEq(dotnsPopLens.nameCountOf(tiago), 0);
    }

    function test_namesOf_pagination_slices_and_clamps() public {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), "");
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_B, user: ed, chatKey: _validChatKey(0x02)
            })
        );

        assertEq(dotnsPopLens.nameCountOf(ed), 2);

        IDotnsPopLens.Name[] memory first = dotnsPopLens.namesOf(ed, 0, 1);
        assertEq(first.length, 1);
        IDotnsPopLens.Name[] memory second = dotnsPopLens.namesOf(ed, 1, 1);
        assertEq(second.length, 1);
        assertTrue(first[0].node != second[0].node);

        assertEq(dotnsPopLens.namesOf(ed, 2, 1).length, 0);

        // A limit above the internal page ceiling is clamped rather than reverting; the account
        // holds fewer names than the ceiling, so the full set still comes back.
        IDotnsPopLens.Name[] memory clamped =
            dotnsPopLens.namesOf(ed, 0, DotnsConstants.MAX_PAGE_SIZE + 1);
        assertEq(clamped.length, 2);
    }

    function test_name_listings_exclude_names_owned_by_others() public {
        // The listing re-checks registrar ownership per entry, so a name owned by another account
        // never surfaces in this account's list.
        _grantPersonhood(ed);
        _grantPersonhood(tiago);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), "");
        _reservePop(tiago, DEVICE_LABEL_C, _validChatKey(0x02), "");

        IDotnsPopLens.Name[] memory edDevice = dotnsPopLens.namesOf(ed, 0, type(uint256).max);
        assertEq(edDevice.length, 1);
        assertFalse(_namesContainNode(edDevice, _deviceNodeOf(DEVICE_LABEL_C)));

        IDotnsPopLens.Name[] memory tiagoDevice = dotnsPopLens.namesOf(tiago, 0, type(uint256).max);
        assertEq(tiagoDevice.length, 1);
        assertFalse(_namesContainNode(tiagoDevice, _deviceNodeOf(DEVICE_LABEL_A)));
    }

    function test_nameDetail_and_nameDetailByNode_report_record() public {
        _grantPersonhood(ed);
        bytes memory deviceChatKey = _validChatKey(0xaa);
        _reservePop(ed, DEVICE_LABEL_A, deviceChatKey, PERSONHOOD_LABEL_A);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkWithDeviceName(DEVICE_LABEL_A)
            })
        );

        bytes32 personhoodNode = _nodeOf(PERSONHOOD_LABEL_A);
        IDotnsPopLens.NameDetail memory personhood = dotnsPopLens.nameDetail(PERSONHOOD_LABEL_A);
        assertEq(personhood.node, personhoodNode);
        assertEq(personhood.label, PERSONHOOD_LABEL_A);
        assertEq(personhood.owner, ed);
        assertTrue(personhood.exists);
        assertTrue(personhood.settled);
        assertTrue(personhood.requiredTier == IPopRules.PopStatus.Personhood);
        assertEq(personhood.chatKey, deviceChatKey);
        assertEq(personhood.deviceLabelhash, keccak256(bytes(DEVICE_LABEL_A)));
        // A base label is never a device-name labelhash, so no promoted node is keyed under it.
        assertEq(personhood.personhoodNode, bytes32(0));

        // Holding the device name lets nameDetail recover the promoted personhood node.
        IDotnsPopLens.NameDetail memory device = dotnsPopLens.nameDetail(DEVICE_LABEL_A);
        assertEq(device.personhoodNode, personhoodNode);

        // A settled device name that was never promoted carries no personhood claim, and the
        // by-node overload leaves it zero.
        _grantPersonhood(leonardo);
        _reservePop(leonardo, DEVICE_LABEL_C, _validChatKey(0xbb), "");
        IDotnsPopLens.NameDetail memory coldByNode =
            dotnsPopLens.nameDetailByNode(_deviceNodeOf(DEVICE_LABEL_C));
        assertTrue(coldByNode.exists);
        assertEq(coldByNode.personhoodNode, bytes32(0));

        // Unknown name and node never revert and return a zeroed record.
        IDotnsPopLens.NameDetail memory unknownName = dotnsPopLens.nameDetail("nothingxx");
        assertFalse(unknownName.exists);
        assertEq(unknownName.owner, address(0));
        assertEq(bytes(unknownName.label).length, 0);
        assertEq(unknownName.personhoodNode, bytes32(0));

        IDotnsPopLens.NameDetail memory unknownNode =
            dotnsPopLens.nameDetailByNode(bytes32(uint256(0xdead)));
        assertFalse(unknownNode.exists);
        assertEq(unknownNode.owner, address(0));
        assertEq(unknownNode.personhoodNode, bytes32(0));
    }

    /// @notice `nameDetail` classifies a cold-path device name before it settles, not only after.
    /// @dev A pending subname has no label recoverable from its node, so `nameDetail` classifies
    /// the caller-supplied label. Before this was wired the tier read `NoStatus` until settlement
    ///      wrote the label into the store.
    function test_nameDetail_classifies_a_cold_device_name_before_and_after_settlement() public {
        address fresh = makeAddr("colddevice");
        _grantDevicehood(fresh);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: fresh, chatKey: _validChatKey(0x01)
            })
        );

        // Cold path: the claim is staged and no store is deployed yet.
        assertEq(storeFactory.getLabelStore(fresh), address(0), "cold user has no store yet");
        IDotnsPopLens.NameDetail memory pending = dotnsPopLens.nameDetail(DEVICE_LABEL_A);
        assertTrue(pending.exists, "subname owned before settlement");
        assertFalse(pending.settled, "not settled yet");
        assertEq(pending.label, DEVICE_LABEL_A, "caller label supplied before settlement");
        assertTrue(
            pending.requiredTier == IPopRules.PopStatus.Devicehood,
            "classified as devicehood before settle"
        );

        vm.prank(fresh);
        dotnsPopController.settlePendingClaims(fresh, type(uint256).max);

        IDotnsPopLens.NameDetail memory settled = dotnsPopLens.nameDetail(DEVICE_LABEL_A);
        assertTrue(settled.settled, "settled after draining the queue");
        assertEq(settled.label, DEVICE_LABEL_A, "label recovered from the store after settlement");
        assertTrue(
            settled.requiredTier == IPopRules.PopStatus.Devicehood,
            "still devicehood after settlement"
        );
    }

    /// @notice A store row whose node key is not its own text's node is neither counted nor listed.
    /// @dev Ownership is keyed by node and provenance by text, and the store no longer binds the
    /// two, so the listings bind them. No production path can forge such a row (the key and text
    /// are
    ///      derived together), so this injects one directly to pin the guard.
    function test_lens_ignores_a_store_row_whose_node_does_not_match_its_text() public {
        _grantPersonhood(ed);
        _grantPersonhood(leonardo);

        // ed holds a legitimate device name, which deploys ed's store and counts once.
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), "");
        assertEq(dotnsPopLens.nameCountOf(ed), 1, "one legitimate device name");

        // A second device name, issued to leonardo, so its text reads as PoP-issued.
        _reservePop(leonardo, "another.01", _validChatKey(0x02), "");

        // ed owns a storeless subname beneath the numeric container. Only a registered controller
        // may defer the store write, so the controller, which owns the container, creates it with
        // persist false and ed as owner, leaving ed's store untouched at that node.
        vm.prank(address(dotnsPopController));
        bytes32 forgedNode = dotnsRegistry.setSubnodeOwner(
            IDotnsRegistry.SubnodeRecord({
                parentNode: _nodeOf("01"),
                subLabel: "sub",
                parentLabel: "01",
                owner: ed,
                persist: false
            })
        );

        // Forge a store row: ed's store, keyed at the storeless subname but carrying leonardo's
        // PoP-issued text. The PoP controller is an authorised store writer. The text is built
        // before the prank so the `tld()` read does not consume it.
        address edStore = storeFactory.getLabelStore(ed);
        string memory forgedText = string.concat("another.01", protocolRegistry.tld());
        vm.prank(address(dotnsPopController));
        ILabelStore(edStore).storeLabel(forgedNode, forgedText);

        // The forged row is owned by ed and its text is PoP-issued, but its node does not match the
        // text, so the listing excludes it and the count stays one.
        assertEq(dotnsPopLens.nameCountOf(ed), 1, "forged row excluded from the count");
        IDotnsPopLens.Name[] memory names = dotnsPopLens.namesOf(ed, 0, type(uint256).max);
        assertEq(names.length, 1, "forged row excluded from the listing");
        assertEq(
            names[0].node,
            _deviceNodeOf(DEVICE_LABEL_A),
            "only the legitimate device name is listed"
        );
    }

    function test_profileOf_reports_store_pending_and_reservation() public {
        // A store-less user with a staged claim, a settled user holding a reservation, and an
        // untouched account each report distinct profile facts.
        _grantPersonhood(leonardo);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_C, user: leonardo, chatKey: _validChatKey(0x01)
            })
        );
        IDotnsPopLens.PopProfile memory cold = dotnsPopLens.profileOf(leonardo);
        assertFalse(cold.hasLabelStore);
        assertEq(cold.pendingClaimCount, 1);
        assertEq(cold.reservationLabelhash, bytes32(0));

        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x02), PERSONHOOD_LABEL_A);
        IDotnsPopLens.PopProfile memory warm = dotnsPopLens.profileOf(ed);
        assertTrue(warm.hasLabelStore);
        assertEq(warm.pendingClaimCount, 0);
        assertEq(warm.reservationLabelhash, keccak256(bytes(PERSONHOOD_LABEL_A)));

        IDotnsPopLens.PopProfile memory empty = dotnsPopLens.profileOf(tiago);
        assertFalse(empty.hasLabelStore);
        assertEq(empty.pendingClaimCount, 0);
        assertEq(empty.reservationLabelhash, bytes32(0));
    }

    function test_reservedBaseLabelOf_returns_label_or_empty() public {
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, _validChatKey(0x01), PERSONHOOD_LABEL_A);

        assertEq(
            dotnsPopController.reservedLabelOf(keccak256(bytes(PERSONHOOD_LABEL_A))),
            PERSONHOOD_LABEL_A
        );
        assertEq(
            bytes(dotnsPopController.reservedLabelOf(keccak256(bytes("unknownbase")))).length, 0
        );
    }

    function _nameWithNode(
        IDotnsPopLens.Name[] memory names,
        bytes32 node
    )
        internal
        pure
        returns (IDotnsPopLens.Name memory)
    {
        for (uint256 i; i < names.length; ++i) {
            if (names[i].node == node) return names[i];
        }
        revert("no name with that node");
    }

    function _namesContainNode(
        IDotnsPopLens.Name[] memory names,
        bytes32 node
    )
        internal
        pure
        returns (bool)
    {
        for (uint256 i; i < names.length; ++i) {
            if (names[i].node == node) return true;
        }
        return false;
    }

    function _containsAddress(
        address[] memory haystack,
        address needle
    )
        internal
        pure
        returns (bool)
    {
        for (uint256 i; i < haystack.length; ++i) {
            if (haystack[i] == needle) return true;
        }
        return false;
    }
}
