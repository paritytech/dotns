// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsPopController} from "../../../contracts/registrars/IDotnsPopController.sol";
import {IDotnsRegistrar} from "../../../contracts/registrars/IDotnsRegistrar.sol";
import {
    IDotnsRegistrarController
} from "../../../contracts/registrars/IDotnsRegistrarController.sol";
import {IDotnsRegistry} from "../../../contracts/registry/IDotnsRegistry.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Vm} from "forge-std/Vm.sol";

// @title DotnsPopControllerTests
// @notice Behavioural unit tests for the dedicated PoP controller driving the
//         gateway flow. Parameterised coverage (label format, chat-key payload,
//         duration boundary) lives in the sibling fuzz file; these tests assert
//         specific behaviours that do not benefit from input variation.
contract DotnsPopControllerTests is BaseDotns {
    function test_reserveBaseName_mints_and_wires_registry_and_resolver() public {
        // Lite path requires PopLite tier and a classification-valid lite label.
        _grantPopFull(ed);
        bytes memory chatKey = _validChatKey(0x01);

        _reservePop(ed, LITE_LABEL_A, chatKey, "");

        bytes32 node = _nodeOf(LITE_LABEL_A);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(node)), ed);
        assertEq(dotnsRegistry.owner(node), ed);
        assertEq(dotnsPopResolver.chatKey(node), chatKey);
    }

    function test_reserveBaseName_reverts_for_non_gateway_caller() public {
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsPopController.NotGateway.selector, ed));
        dotnsPopController.reserveBaseName(
            IDotnsPopController.BaseReservation({
                lite: IDotnsPopController.LiteRegistration({
                    liteLabel: LITE_LABEL_A, user: ed, chatKey: ""
                }),
                reservedBaseLabel: ""
            })
        );
    }

    function test_reserveBaseName_enqueues_when_reserved_label_provided() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), BASE_LABEL_A);

        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(BASE_LABEL_A);
        assertTrue(reserved);
        assertEq(holder, ed);
    }

    function test_registerBaseName_claim_emits_claim_event_and_not_standalone() public {
        // PopRules.priceWithCheck now forbids a second user queueing behind the
        // live head on the same base stem, so the queue is effectively
        // single-user. Kept as a single-reserver claim to assert the claim
        // event path; multi-user queue coverage lives in the invariant suite.
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        IDotnsPopController.Link memory link = _linkWithLite(LITE_LABEL_A);

        vm.recordLogs();
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertEventEmittedOnce(logs, keccak256("BaseNameClaimed(bytes32,address,string)"));
        _assertEventNotEmitted(logs, keccak256("StandaloneNameRegistered(bytes32,address,string)"));

        (bool reserved,) = dotnsPopController.isReservedForClaim(BASE_LABEL_A);
        assertFalse(reserved);
    }

    function test_registerBaseName_standalone_emits_standalone_event_and_not_claim() public {
        _grantPopFull(tiago);
        _reservePop(tiago, LITE_LABEL_B, _validChatKey(0x01), BASE_LABEL_A);

        // ed gets a different PopFull-classified base label via standalone mint.
        _grantPopFull(ed);
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));

        vm.recordLogs();
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_C, user: ed, link: link})
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertEventEmittedOnce(logs, keccak256("StandaloneNameRegistered(bytes32,address,string)"));
        _assertEventNotEmitted(logs, keccak256("BaseNameClaimed(bytes32,address,string)"));
    }

    function test_registerBaseName_claim_inherits_chat_key_from_lite_node() public {
        _grantPopFull(ed);
        bytes memory liteChatKey = _validChatKey(0xaa);
        _reservePop(ed, LITE_LABEL_A, liteChatKey, BASE_LABEL_A);

        IDotnsPopController.Link memory link = _linkWithLite(LITE_LABEL_A);
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );

        bytes32 fullNode = _nodeOf(BASE_LABEL_A);
        assertEq(dotnsPopResolver.chatKey(fullNode), liteChatKey);
        assertEq(dotnsPopResolver.liteLink(fullNode), keccak256(bytes(LITE_LABEL_A)));
    }

    function test_registerBaseName_claim_wipes_entire_queue() public {
        // Under the new priceWithCheck gate, only the reservation holder can
        // sit in the base queue, so the "wipe entire queue" assertion reduces
        // to "wipe the single live entry and free the stem". After the claim,
        // a different user must be free to reserve a fresh stem via the
        // gateway without seeing any leaked state.
        _grantPopFull(ed);
        _grantPopFull(tiago);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        IDotnsPopController.Link memory link = _linkWithLite(LITE_LABEL_A);
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );

        _reservePop(tiago, LITE_LABEL_D, _validChatKey(0x04), BASE_LABEL_B);
        (, address wonderHolder) = dotnsPopController.isReservedForClaim(BASE_LABEL_B);
        assertEq(wonderHolder, tiago);
    }

    function test_registerBaseName_standalone_auto_relinquishes_users_other_reservation() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        // Promote ed to PopFull so the standalone PopFull-classified mint passes.
        _grantPopFull(ed);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0x02));

        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_B, user: ed, link: link})
        );

        (bool reserved,) = dotnsPopController.isReservedForClaim(BASE_LABEL_A);
        assertFalse(reserved);
    }

    function test_registerBaseName_standalone_with_lite_link_silently_relinquishes() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        _grantPopFull(ed);
        IDotnsPopController.Link memory link = _linkWithLite(LITE_LABEL_A);

        vm.recordLogs();
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_B, user: ed, link: link})
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertEventEmittedOnce(logs, keccak256("StandaloneNameRegistered(bytes32,address,string)"));
        _assertEventEmittedOnce(logs, keccak256("LiteToFullLinked(bytes32,bytes32)"));
        _assertEventNotEmitted(logs, keccak256("BaseNameClaimed(bytes32,address,string)"));
        _assertEventNotEmitted(logs, keccak256("ReservationRelinquished(bytes32,address)"));

        bytes32 fullNode = _nodeOf(BASE_LABEL_B);
        assertEq(dotnsPopResolver.liteLink(fullNode), keccak256(bytes(LITE_LABEL_A)));

        (bool reserved,) = dotnsPopController.isReservedForClaim(BASE_LABEL_A);
        assertFalse(reserved);
    }

    function test_registerBaseName_reverts_for_non_gateway_caller() public {
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xaa));

        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsPopController.NotGateway.selector, ed));
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );
    }

    function test_relinquishReservation_promotes_next_waiter_when_head_leaves() public {
        // priceWithCheck now admits only the current reservation holder on a
        // live stem, so the queue cannot contain a second waiter. After the
        // holder relinquishes, the slot is cleared and a fresh user must be
        // free to reserve the same stem from scratch.
        _grantPopFull(ed);
        _grantPopFull(tiago);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        vm.prank(ed);
        dotnsPopController.relinquishReservation();

        (bool empty,) = dotnsPopController.isReservedForClaim(BASE_LABEL_A);
        assertFalse(empty);

        _reservePop(tiago, LITE_LABEL_B, _validChatKey(0x02), BASE_LABEL_A);
        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(BASE_LABEL_A);
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

    // The previous test was a write-then-read tautology. This version pins the
    // real governance risk: `_isExpired` reads the CURRENT `reservationDuration`
    // on every check, so shrinking the duration retroactively expires entries
    // that were live under the old window. Documenting this explicitly prevents
    // a silent regression if the field is ever changed to absolute expiry.
    function test_setReservationDuration_shortening_retroactively_expires_live_entries() public {
        _grantPopFull(ed);
        // Enqueue alice under the default duration (7 days).
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        (bool liveBefore, address holderBefore) =
            dotnsPopController.isReservedForClaim(BASE_LABEL_A);
        assertTrue(liveBefore);
        assertEq(holderBefore, ed);

        // Warp 2 days forward (still well within the original 7-day window).
        vm.warp(block.timestamp + 2 days);

        // Governance shrinks the window to 1 day. The entry's `joinedAt` plus
        // the new duration is now in the past, so the slot is expired.
        vm.prank(owner);
        dotnsPopController.setReservationDuration(1 days);

        (bool liveAfter,) = dotnsPopController.isReservedForClaim(BASE_LABEL_A);
        assertFalse(liveAfter);
    }

    function test_setReservationDuration_reverts_for_non_owner() public {
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ed));
        dotnsPopController.setReservationDuration(14 days);
    }

    // NOTE: Queue-full coverage via the public entry point is no longer
    // reachable: priceWithCheck blocks every user except the live holder, so
    // the base queue can never hold more than one live entry and the 65th
    // enqueue path is structurally unreachable from outside. The invariant
    // suite still exercises bounded queue length under randomised
    // relinquish/expire interleavings, and `MAX_RESERVATION_QUEUE` remains a
    // defence-in-depth constant on the internal `_enqueueReservation`. This
    // test instead pins the complementary guard: the same user cannot hold
    // two simultaneous reservations, which is the only multi-enqueue shape
    // still observable from the public surface.
    function test_enqueueReservation_same_user_second_call_replaces_first() public {
        // Two independent reads must agree: the per-user reservation pointer
        // (`userReservation`) and the per-base claim view (`isReservedForClaim`).
        // Both change atomically when the same user re-reserves on a new stem.
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        IDotnsPopController.UserReservation memory firstReservation =
            dotnsPopController.userReservation(ed);
        assertEq(firstReservation.labelhash, keccak256(bytes(BASE_LABEL_A)));

        // Second reservation by the same user on a different stem drops the
        // first slot and installs the new one.
        _reservePop(ed, LITE_LABEL_B, _validChatKey(0x02), BASE_LABEL_B);

        IDotnsPopController.UserReservation memory secondReservation =
            dotnsPopController.userReservation(ed);
        assertEq(secondReservation.labelhash, keccak256(bytes(BASE_LABEL_B)));

        (bool firstReserved,) = dotnsPopController.isReservedForClaim(BASE_LABEL_A);
        assertFalse(firstReserved);

        (bool secondReserved, address secondHolder) =
            dotnsPopController.isReservedForClaim(BASE_LABEL_B);
        assertTrue(secondReserved);
        assertEq(secondHolder, ed);
    }

    function test_reEnqueue_after_own_expiry_promotes_same_user_to_head() public {
        string memory baseStem = BASE_LABEL_A;
        _grantPopFull(ed);

        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), baseStem);

        // Warp past the reservation window and fire the GC so ed's pointer gets
        // cleared by `_advanceExpiredHead`. If the expiry path forgets the
        // per-user pointer, the second reserve call below hits `AlreadyReserved`
        // and the account is permanently stuck.
        vm.warp(block.timestamp + dotnsPopController.reservationDuration() + 1);
        dotnsPopController.expireReservation(baseStem);

        (bool expiredReserved,) = dotnsPopController.isReservedForClaim(baseStem);
        assertFalse(expiredReserved);

        // Same user reserves the same stem again with a fresh lite label.
        _reservePop(ed, LITE_LABEL_B, _validChatKey(0x02), baseStem);

        (bool nowReserved, address holder) = dotnsPopController.isReservedForClaim(baseStem);
        assertTrue(nowReserved);
        assertEq(holder, ed);
    }

    function test_claim_then_reEnqueue_on_same_stem_resets_cleanly() public {
        string memory baseStem = BASE_LABEL_A;
        _grantPopFull(ed);
        _grantPopFull(tiago);

        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), baseStem);

        // Claim wipes the queue via `_clearQueue` which must also drop
        // `_reservedBaseLabel[labelhash]` and release the PopRules slot. Missing
        // any one of those lets the next reservation inherit stale state.
        IDotnsPopController.Link memory link = _linkWithLite(LITE_LABEL_A);
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: baseStem, user: ed, link: link})
        );

        (bool oldSlot, address oldHolder) = dotnsPopController.isReservedForClaim(baseStem);
        assertFalse(oldSlot);
        assertEq(oldHolder, address(0));

        // Fresh stem, different user. If the previous queue leaked, this enqueue
        // would either revert or land the wrong head address on PopRules.
        _reservePop(tiago, LITE_LABEL_B, _validChatKey(0x02), BASE_LABEL_B);
        (bool newSlot, address newHolder) = dotnsPopController.isReservedForClaim(BASE_LABEL_B);
        assertTrue(newSlot);
        assertEq(newHolder, tiago);

        (address popHolder,) = popRules.getBaseNameReservation(BASE_LABEL_B);
        assertEq(popHolder, tiago);
    }

    function test_expireReservation_is_permissionless() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        vm.warp(block.timestamp + dotnsPopController.reservationDuration() + 1);

        // Anyone can call. Pinning this prevents a future patch from silently
        // adding `onlyGateway` and breaking permissionless garbage collection.
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        dotnsPopController.expireReservation(BASE_LABEL_A);

        (bool reserved,) = dotnsPopController.isReservedForClaim(BASE_LABEL_A);
        assertFalse(reserved);
    }

    // Multi-user queue construction is no longer reachable through the public
    // entry point (priceWithCheck blocks all non-holders on a live stem), so
    // the tombstone-in-middle scenario cannot be constructed here. The
    // equivalent GC path is covered by the invariant suite's head-walk
    // checks. This test now pins the minimal GC behaviour of the public
    // surface: after the head expires, a different user can reserve the
    // stem from scratch.
    function test_head_expires_clears_slot_for_next_reserver() public {
        string memory baseStem = BASE_LABEL_A;
        _grantPopFull(ed);
        _grantPopFull(leonardo);

        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), baseStem);

        vm.warp(block.timestamp + dotnsPopController.reservationDuration() + 1);
        dotnsPopController.expireReservation(baseStem);

        _reservePop(leonardo, LITE_LABEL_C, _validChatKey(0x03), baseStem);

        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(baseStem);
        assertTrue(reserved);
        assertEq(holder, leonardo);

        (address popHolder,) = popRules.getBaseNameReservation(baseStem);
        assertEq(popHolder, leonardo);
    }

    // Format constraints for the two entry points are complementary rather
    // than disjoint: `reserveLiteName` demands a lite label (>= 2 trailing
    // digits on a DNS label) and `registerBaseName` demands a single DNS
    // label. After priceWithCheck was added to both entry points, the
    // canonical-label guard inside PopRules is reached first on pathological
    // shapes, so the dotted-label rejection surfaces as a PopError rather
    // than the controller's own InvalidBaseLabel. This test pins both
    // surfaces: the controller's lite-format rejection (reachable because
    // priceWithCheck admits PopFull-classified single-label shapes without
    // trailing digits) and the PopRules canonical-label rejection on a
    // multi-label string.
    function test_entry_point_format_rejections() public {
        _grantPopFull(ed);
        // `reserveLiteName` admits priceWithCheck first because "aliceli"
        // classifies as PopFull and ed is PopFull; the isLitePersonLabel
        // guard then rejects the zero trailing digits.
        vm.prank(popGateway);
        vm.expectRevert(IDotnsPopController.InvalidLiteLabel.selector);
        dotnsPopController.reserveLiteName(
            IDotnsPopController.LiteRegistration({liteLabel: "aliceli", user: ed, chatKey: ""})
        );

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xaa));
        vm.prank(popGateway);
        // Multi-label string fails the canonical-label guard inside
        // PopRules.priceWithCheck before reaching the controller's own
        // isSingleLabel check.
        vm.expectPartialRevert(IPopRules.PopError.selector);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: "not.valid", user: ed, link: link})
        );
    }

    function test_same_stem_lite_and_base_occupy_distinct_registrar_tokens() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "");

        // "aliceli" (baselength 7, no trailing digits) classifies as PopFull
        // and shares the lite's stem, so both tokens coexist on the registrar.
        _grantPopFull(tiago);
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xbb));
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: "aliceli", user: tiago, link: link})
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(LITE_LABEL_A))), ed);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("aliceli"))), tiago);
    }

    function test_both_controllers_can_mint_on_shared_registrar() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), "");
        _commitAndRegister("longnamebob01", tiago, true);

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(LITE_LABEL_A))), ed);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("longnamebob01"))), tiago);
    }

    // Gateway reservation now locks the base name on PopRules, so the public
    // commit-reveal flow rejects another user's attempt to mint the same stem
    // for the lifetime of the reservation.
    function test_gateway_reserved_name_rejects_public_register_by_other_user() public {
        _grantPopFull(tiago);
        // Gateway reserves the bare stem; PopRules.priceWithCheck strips the two
        // trailing digits from "longnamebob01" and matches against reservations["longnamebob"].
        _reservePop(tiago, LITE_LABEL_A, _validChatKey(0x11), "longnamebob");

        (address holder,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, tiago);

        // The revert surface is PopRules.priceWithCheck, reached only when the
        // public controller pulls the price during register. We therefore drive
        // the commit-reveal flow by hand so the expectRevert cheatcode lands on
        // the register call rather than on makeCommitment (a view).
        string memory label = "longnamebob01";
        bytes32 secret = keccak256(abi.encodePacked(label, ed, block.timestamp));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label, owner: ed, secret: secret, reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        vm.prank(ed);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPopRules.PopError.selector, "Base name reserved for original Lite registrant"
            )
        );
        vm.prank(ed);
        dotnsRegistrarController.register{value: 1 ether}(registration);
    }

    // Symmetric check: the reservation holder can still commit-reveal the base
    // name themselves. The PopRules guard only rejects OTHER users; the holder
    // owns the slot and passes the `reservation.owner == userAddress` branch.
    function test_gateway_reserved_name_allows_holder_to_register_via_public() public {
        _grantPopFull(tiago);
        _reservePop(tiago, LITE_LABEL_A, _validChatKey(0x11), "longnamebob");

        _commitAndRegister("longnamebob01", tiago, true);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("longnamebob01"))), tiago);
    }

    // A second PoP lite-mint of the same label reverts at the registrar's
    // ERC721 availability check, because the token was already minted.
    function test_second_pop_lite_mint_of_same_label_reverts_at_registrar() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "");

        _grantPopFull(tiago);
        vm.prank(popGateway);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrar.NameNotAvailable.selector, uint256(_nodeOf(LITE_LABEL_A))
            )
        );
        dotnsPopController.reserveBaseName(
            IDotnsPopController.BaseReservation({
                lite: IDotnsPopController.LiteRegistration({
                    liteLabel: LITE_LABEL_A, user: tiago, chatKey: _validChatKey(0xbb)
                }),
                reservedBaseLabel: ""
            })
        );
    }

    // After a PoP full-person mint of a base label, a subsequent public
    // commit-reveal registration of the same label reverts on the
    // registrar's availability check rather than any PoP-level guard.
    function test_public_register_after_pop_full_mint_reverts_at_registrar() public {
        // "longnamebob01" is classification-NoStatus, so ed keeps default status.
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: "longnamebob01", user: ed, link: link})
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("longnamebob01"))), ed);

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: "longnamebob01", owner: tiago, secret: keccak256("secret"), reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        vm.prank(tiago);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 price = popRules.priceWithCheck("longnamebob01", tiago).price;

        vm.prank(tiago);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrarController.NameNotAvailable.selector, "longnamebob01"
            )
        );
        dotnsRegistrarController.register{value: price}(registration);
    }

    // The owner of a PoP-minted full-person name can create subnames under
    // it via the existing `DotnsRegistry.setSubnodeOwner` path.
    function test_owner_of_pop_minted_name_can_create_subname() public {
        _grantPopFull(ed);
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );

        bytes32 parentNode = _nodeOf(BASE_LABEL_A);
        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "app", parentLabel: BASE_LABEL_A, owner: leonardo
        });

        vm.prank(ed);
        bytes32 subnode = dotnsRegistry.setSubnodeOwner(subnodeRecord);

        assertEq(dotnsRegistry.owner(subnode), leonardo);
    }

    // A non-owner cannot create subnames under a PoP-minted name.
    function test_non_owner_cannot_create_subname_under_pop_minted_name() public {
        _grantPopFull(ed);
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );

        bytes32 parentNode = _nodeOf(BASE_LABEL_A);
        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "app", parentLabel: BASE_LABEL_A, owner: tiago
        });

        vm.prank(tiago);
        vm.expectRevert(IDotnsRegistry.NotAuthorised.selector);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);
    }

    // A PoP reservation can be queued for a label already minted by the
    // public controller (queue is intra-PoP only). The later claim attempt
    // reverts at the registrar's availability check.
    function test_pop_reservation_of_already_public_minted_name_fails_on_claim() public {
        _commitAndRegister("longnamebob01", ed, true);

        _grantPopFull(tiago);
        _reservePop(tiago, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob01");

        (bool reserved, address holder) = dotnsPopController.isReservedForClaim("longnamebob01");
        assertTrue(reserved);
        assertEq(holder, tiago);

        IDotnsPopController.Link memory link = _linkWithLite(LITE_LABEL_A);
        vm.prank(popGateway);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrar.NameNotAvailable.selector, uint256(_nodeOf("longnamebob01"))
            )
        );
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: "longnamebob01", user: tiago, link: link})
        );
    }

    // Enqueue that becomes the head writes the holder into PopRules.reservations
    // so the public commit-reveal flow blocks other users on the same stem.
    function test_enqueue_becomesHead_writes_popRules_reservation() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        (address holder, uint64 expires) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, ed);
        assertEq(expires, uint64(block.timestamp + popRules.MAX_RESERVATION_TIME()));
    }

    // Tail enqueue by a different user is no longer possible: priceWithCheck
    // rejects the second reserver before the queue is touched. The test now
    // asserts the revert surface on the rejected call rather than the
    // preserved first reservation.
    function test_enqueue_not_head_rejected_by_priceCheck() public {
        _grantPopFull(ed);
        _grantPopFull(tiago);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob");
        (address firstHolder, uint64 originalExpiry) =
            popRules.getBaseNameReservation("longnamebob");
        assertEq(firstHolder, ed);

        vm.prank(popGateway);
        vm.expectPartialRevert(IPopRules.PopError.selector);
        dotnsPopController.reserveBaseName(
            IDotnsPopController.BaseReservation({
                lite: IDotnsPopController.LiteRegistration({
                    liteLabel: LITE_LABEL_B, user: tiago, chatKey: _validChatKey(0xbb)
                }),
                reservedBaseLabel: "longnamebob"
            })
        );

        // Slot is unchanged.
        (address holder, uint64 expires) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, ed);
        assertEq(expires, originalExpiry);
    }

    // Successful claim wipes the queue and releases the PopRules slot so the
    // public commit-reveal flow is unblocked for every other user.
    function test_claim_releases_popRules_slot() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        IDotnsPopController.Link memory link = _linkWithLite(LITE_LABEL_A);
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: "longnamebob", user: ed, link: link})
        );

        (address holder,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, address(0));
    }

    // Final relinquish (no other queued waiter) releases the PopRules slot.
    function test_relinquish_last_releases_popRules_slot() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        vm.prank(ed);
        dotnsPopController.relinquishReservation();

        (address holder,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, address(0));
    }

    // Last-remaining head expires and the queue empties; PopRules slot clears.
    function test_advanceExpiredHead_last_expire_releases_popRules_slot() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        vm.warp(block.timestamp + dotnsPopController.reservationDuration() + 1);
        dotnsPopController.expireReservation("longnamebob");

        (address holder,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, address(0));
    }

    // The controller passes `reservedBaseLabel` to PopRules verbatim. If the
    // gateway supplies a label with trailing digits, the public controller's
    // `_stripDigits` check reads the stem and misses the reservation. This
    // locks the current behaviour so gateway-side misuse surfaces loudly.
    function test_controller_does_not_mutate_reservedBaseLabel_string() public {
        _grantPopFull(ed);
        // "longnamebob01" has two trailing digits. PopRules stores it as-is,
        // but `priceWithCheck` queries reservations keyed by "longnamebob".
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob01");

        // Slot is written under the raw label.
        (address rawHolder,) = popRules.getBaseNameReservation("longnamebob01");
        assertEq(rawHolder, ed);

        // Stripped-stem slot is empty; public flow for "longnamebob01" is
        // NOT blocked for other users (documented misuse surface).
        (address strippedHolder,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(strippedHolder, address(0));
    }

    // After a claim clears the slot, a different user can mint the stem via
    // the public commit-reveal flow.
    function test_public_stranger_can_mint_after_claim_clears_reservation() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        IDotnsPopController.Link memory link = _linkWithLite(LITE_LABEL_A);
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: "longnamebob", user: ed, link: link})
        );

        // Now the stem is clear on PopRules, so tiago can register the
        // digit-suffixed variant "longnamebob01" via the public flow.
        _commitAndRegister("longnamebob01", tiago, true);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("longnamebob01"))), tiago);
    }

    // After natural expiry of the head the slot must be cleared before the
    // public flow admits a stranger.
    function test_public_stranger_can_mint_after_reservation_expires() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        vm.warp(block.timestamp + dotnsPopController.reservationDuration() + 1);
        dotnsPopController.expireReservation("longnamebob");

        _commitAndRegister("longnamebob01", tiago, true);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("longnamebob01"))), tiago);
    }

    // A registered controller on `DotnsRegistrar` that is NOT the PoP gateway
    // must not be able to reach the sync path through the PoP controller's
    // entrypoints; the `onlyGateway` check is independent of controller
    // authorisation on the registrar.
    function test_controller_authorised_but_not_gateway_cannot_enter_pop_flow() public {
        // The public commit-reveal controller is already a registered controller.
        address otherController = address(dotnsRegistrarController);

        vm.prank(otherController);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsPopController.NotGateway.selector, otherController)
        );
        dotnsPopController.reserveBaseName(
            IDotnsPopController.BaseReservation({
                lite: IDotnsPopController.LiteRegistration({
                    liteLabel: LITE_LABEL_A, user: ed, chatKey: ""
                }),
                reservedBaseLabel: "longnamebob"
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

    // Expired heads do not block standalone mints. Both the controller's
    // internal queue entry and the PopRules reservation slot must expire
    // before a stranger's priceWithCheck admits the mint; PopRules uses a
    // wider MAX_RESERVATION_TIME window than the controller's own duration,
    // so we warp past the PopRules window.
    function test_registerBaseName_standalone_succeeds_when_head_is_expired() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        // Walk past both the controller and PopRules expiry windows so
        // nothing blocks tiago's priceWithCheck.
        vm.warp(block.timestamp + popRules.MAX_RESERVATION_TIME() + 1);

        _grantPopFull(tiago);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: tiago, link: link})
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(BASE_LABEL_A))), tiago);
    }

    // No reservation exists for the stem; standalone mint should succeed.
    function test_registerBaseName_standalone_succeeds_when_queue_empty() public {
        _grantPopFull(ed);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(BASE_LABEL_A))), ed);
    }

    // Regression: the claim path for the user who holds the live head still
    // works after the standalone-mint holder guard is in place.
    function test_registerBaseName_claim_still_works_after_guard() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        IDotnsPopController.Link memory link = _linkWithLite(LITE_LABEL_A);
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(BASE_LABEL_A))), ed);
    }

    // Full chain: A reserves, B's standalone mint reverts via the
    // PopRules reservation guard, A can still claim.
    function test_registerBaseName_guard_blocks_stranger_and_preserves_claim() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        _grantPopFull(tiago);
        IDotnsPopController.Link memory strangerLink = _linkFresh(_validChatKey(0xbb));
        vm.prank(popGateway);
        vm.expectPartialRevert(IPopRules.PopError.selector);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({
                label: BASE_LABEL_A, user: tiago, link: strangerLink
            })
        );

        // A's reservation is intact; A claims successfully.
        IDotnsPopController.Link memory claimLink = _linkWithLite(LITE_LABEL_A);
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: claimLink})
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(BASE_LABEL_A))), ed);
    }

    // Governance-reserved labels (baselength <= 5) must revert through
    // priceWithCheck regardless of user tier.
    function test_registerBaseName_reverts_for_governance_length_name() public {
        _grantPopFull(ed);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xaa));
        vm.prank(popGateway);
        vm.expectPartialRevert(IPopRules.PopError.selector);
        // Stem "alice" has baselength 5; `Reserved for Governance`.
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: "alice", user: ed, link: link})
        );
    }

    // A PopFull-classified label (baselength 6-8, no trailing 2-digit suffix)
    // must reject a PopLite-only user via the tier guard.
    function test_registerBaseName_reverts_for_popLite_user_on_popFull_label() public {
        _grantPopLite(ed);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xaa));
        vm.prank(popGateway);
        vm.expectPartialRevert(IPopRules.PopError.selector);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );
    }

    // The reservedBaseLabel path is now classification-checked too.
    function test_reserveBaseName_reserved_label_classification_reverts() public {
        _grantPopFull(ed);

        // Lite leg uses a valid lite label; reserved leg uses a <=5-char stem.
        vm.prank(popGateway);
        vm.expectPartialRevert(IPopRules.PopError.selector);
        dotnsPopController.reserveBaseName(
            IDotnsPopController.BaseReservation({
                lite: IDotnsPopController.LiteRegistration({
                    liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
                }),
                reservedBaseLabel: "alice"
            })
        );
    }

    // A lite label whose classification does not match the user's tier must
    // revert. ed has NoStatus by default; LITE_LABEL_A classifies as PopLite.
    function test_reserveBaseName_lite_tier_mismatch_reverts() public {
        vm.prank(popGateway);
        vm.expectPartialRevert(IPopRules.PopError.selector);
        dotnsPopController.reserveBaseName(
            IDotnsPopController.BaseReservation({
                lite: IDotnsPopController.LiteRegistration({
                    liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
                }),
                reservedBaseLabel: ""
            })
        );
    }

    // Happy path: a PopFull user registering a PopFull-classified base label
    // succeeds, no eth moved, no revert.
    function test_registerBaseName_popFull_user_on_popFull_label_succeeds() public {
        _grantPopFull(ed);

        uint256 controllerBalanceBefore = address(dotnsPopController).balance;

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xaa));
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );

        // No native token moves on the PoP path.
        assertEq(address(dotnsPopController).balance, controllerBalanceBefore);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(BASE_LABEL_A))), ed);
    }

    // reserveLiteName must be unaffected by pressure on an unrelated base
    // stem. Under the new priceWithCheck gate, that pressure now takes the
    // shape of a single live reservation rather than a full queue; a fresh
    // user calling reserveLiteName on a different lite label must still
    // succeed.
    function test_reserveLiteName_succeeds_regardless_of_base_reservation() public {
        string memory baseStem = BASE_LABEL_A;

        // Occupy the base stem with a live reservation.
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), baseStem);

        // A different user calls reserveLiteName on a different lite label.
        address fresh = makeAddr("freshLite");
        _grantPopLite(fresh);

        vm.prank(popGateway);
        dotnsPopController.reserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: "freshli01", user: fresh, chatKey: _validChatKey(0xcc)
            })
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("freshli01"))), fresh);
    }

    // reserveLiteName rejects a non-lite-format label. Classification via
    // priceWithCheck runs first; a governance-length stem trips the
    // "Reserved for Governance" branch and reverts before the PoP
    // controller's own lite-format validator runs.
    function test_reserveLiteName_reverts_for_non_lite_format() public {
        _grantPopFull(ed);

        vm.prank(popGateway);
        vm.expectPartialRevert(IPopRules.PopError.selector);
        dotnsPopController.reserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: "alice", user: ed, chatKey: _validChatKey(0xaa)
            })
        );
    }

    // Non-gateway callers are rejected even if they are otherwise authorised
    // controllers on the registrar.
    function test_reserveLiteName_reverts_for_non_gateway_caller() public {
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsPopController.NotGateway.selector, ed));
        dotnsPopController.reserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
            })
        );
    }

    // Regression: reserveBaseName (compound lite + reservation) still works
    // end-to-end on the happy path.
    function test_reserveBaseName_compound_happy_path_still_works() public {
        _grantPopFull(ed);

        vm.prank(popGateway);
        dotnsPopController.reserveBaseName(
            IDotnsPopController.BaseReservation({
                lite: IDotnsPopController.LiteRegistration({
                    liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
                }),
                reservedBaseLabel: BASE_LABEL_A
            })
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(LITE_LABEL_A))), ed);

        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(BASE_LABEL_A);
        assertTrue(reserved);
        assertEq(holder, ed);
    }

    // Atomicity of the compound entrypoint: if the reservedBaseLabel guard
    // rejects the caller (e.g. because another user already holds a live
    // reservation on the same stem), the lite leg must not be persisted. The
    // old queue-full shape is no longer reachable from outside; the
    // priceWithCheck reservation guard is the new atomic failure surface and
    // carries the same all-or-nothing semantics.
    function test_reserveBaseName_compound_reverts_atomically_when_base_blocked() public {
        string memory baseStem = BASE_LABEL_A;

        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), baseStem);

        address overflow = makeAddr("compoundOverflow");
        _grantPopFull(overflow);

        vm.prank(popGateway);
        vm.expectPartialRevert(IPopRules.PopError.selector);
        dotnsPopController.reserveBaseName(
            IDotnsPopController.BaseReservation({
                lite: IDotnsPopController.LiteRegistration({
                    liteLabel: "overli01", user: overflow, chatKey: _validChatKey(0x02)
                }),
                reservedBaseLabel: baseStem
            })
        );

        // The lite name was not minted because the whole call reverted.
        vm.expectRevert();
        IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("overli01")));
    }

    // Zero-length base label fails the shape check before anything else runs.
    function test_registerBaseName_zero_length_label_reverts() public {
        _grantPopFull(ed);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xaa));
        vm.prank(popGateway);
        // Classification runs first; empty string fails canonical label check
        // in PopRules before reaching the PoP controller's own shape guard.
        vm.expectPartialRevert(IPopRules.PopError.selector);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: "", user: ed, link: link})
        );
    }

    // A 65-byte chat key is accepted on the resolver. Previously this test
    // served double duty as "documenting 65-byte acceptance"; now that the
    // resolver hard-requires 65 bytes, it doubles as a happy-path smoke.
    function test_reserveBaseName_accepts_65_byte_chat_key() public {
        _grantPopFull(ed);

        bytes memory chatKey = _validChatKey(0x42);

        vm.prank(popGateway);
        dotnsPopController.reserveBaseName(
            IDotnsPopController.BaseReservation({
                lite: IDotnsPopController.LiteRegistration({
                    liteLabel: LITE_LABEL_A, user: ed, chatKey: chatKey
                }),
                reservedBaseLabel: ""
            })
        );

        bytes32 node = _nodeOf(LITE_LABEL_A);
        assertEq(dotnsPopResolver.chatKey(node), chatKey);
    }

    // Builds a unique classification-valid PopLite lite label for the i-th
    // filler in a queue-fill loop. Shape: `fill<l1><l2>01`. Letters encode
    // i so labels stay unique across the loop; the fixed 2-digit tail keeps
    // trailing digit count at exactly 2 regardless of the decimal width of i.
    function _fillerLiteLabel(uint256 i) internal pure returns (string memory) {
        bytes memory letters = new bytes(2);
        letters[0] = bytes1(uint8(0x61 + (i % 26)));
        letters[1] = bytes1(uint8(0x61 + ((i / 26) % 26)));
        return string.concat("fill", string(letters), "01");
    }

    function testFuzz_bytes_overloads_reject_non_gateway(uint8 which) public {
        // `which` selects which of the three bytes overloads to invoke; the
        // `onlyGateway` modifier must reject a non-gateway caller on each.
        // Single fuzz replaces three near-identical unit tests.
        which = uint8(bound(uint256(which), 0, 2));

        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsPopController.NotGateway.selector, ed));

        if (which == 0) {
            dotnsPopController.reserveLiteName(
                abi.encode(
                    IDotnsPopController.LiteRegistration({
                        liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
                    })
                )
            );
        } else if (which == 1) {
            dotnsPopController.reserveBaseName(
                abi.encode(
                    IDotnsPopController.BaseReservation({
                        lite: IDotnsPopController.LiteRegistration({
                            liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
                        }),
                        reservedBaseLabel: ""
                    })
                )
            );
        } else {
            dotnsPopController.registerBaseName(
                abi.encode(
                    IDotnsPopController.FullRegistration({
                        label: BASE_LABEL_A,
                        user: ed,
                        link: IDotnsPopController.Link({
                            kind: IDotnsPopController.LinkKind.None,
                            liteLabel: "",
                            chatKey: _validChatKey(0xaa)
                        })
                    })
                )
            );
        }
    }

    function test_reserveLiteName_bytes_reverts_on_malformed_payload() public {
        // Truncated payload cannot be ABI-decoded into the target struct, so the
        // typed entrypoint reverts inside `abi.decode` (panic-style, no return
        // data); `_dispatchTyped` re-throws via assembly so the outer call
        // surfaces the same empty revert. Asserting "any revert" is intentional;
        // locking the exact error string would couple the test to solc internals.
        bytes memory truncated = hex"deadbeef";
        vm.prank(popGateway);
        vm.expectRevert();
        dotnsPopController.reserveLiteName(truncated);
    }

    function test_setReservationDuration_zero_makes_new_reservations_immediately_expired() public {
        // `reservationDuration` has no zero-guard. Setting it to 0 means every
        // freshly enqueued reservation is classified expired by `_isExpired`
        // on the same block.
        vm.prank(owner);
        dotnsPopController.setReservationDuration(0);

        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        (bool reserved,) = dotnsPopController.isReservedForClaim(BASE_LABEL_A);
        assertFalse(reserved);
    }
}
