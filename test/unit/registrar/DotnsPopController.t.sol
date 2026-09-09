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

    function test_reserveBaseName_reverts_when_origin_is_not_root() public {
        _mockOriginIsRoot(false);
        vm.expectRevert(IDotnsPopController.NotRoot.selector);
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
        // `PopRules.priceWithCheck` admits only the live reservation holder on
        // a given base stem, so the queue is single-occupant. Multi-occupant
        // queue coverage lives in the invariant suite.
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), BASE_LABEL_A);

        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(BASE_LABEL_A);
        assertTrue(reserved);
        assertEq(holder, ed);
    }

    function test_registerBaseName_claim_emits_claim_event_and_not_standalone() public {
        // ed gets a different PopFull-classified base label via standalone mint.
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        IDotnsPopController.Link memory link = _linkWithLite(LITE_LABEL_A);

        vm.recordLogs();
        _rootRegisterBaseName(
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
        // `priceWithCheck` admits only the live reservation holder on a given
        // base stem, so the standalone mint runs against a separate, free stem
        // owned by a different user; this asserts neither user sees state leak
        // from the other.
        _grantPopFull(ed);
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));

        vm.recordLogs();
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_C, user: ed, link: link})
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertEventEmittedOnce(logs, keccak256("StandaloneNameRegistered(bytes32,address,string)"));
        _assertEventNotEmitted(logs, keccak256("BaseNameClaimed(bytes32,address,string)"));
    }

    function test_registerBaseName_claim_inherits_chat_key_from_lite_node() public {
        // Promote ed to PopFull so the standalone PopFull-classified mint passes.
        _grantPopFull(ed);
        bytes memory liteChatKey = _validChatKey(0xaa);
        _reservePop(ed, LITE_LABEL_A, liteChatKey, BASE_LABEL_A);

        IDotnsPopController.Link memory link = _linkWithLite(LITE_LABEL_A);
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );

        bytes32 fullNode = _nodeOf(BASE_LABEL_A);
        assertEq(dotnsPopResolver.chatKey(fullNode), liteChatKey);
        assertEq(dotnsPopResolver.liteLink(fullNode), keccak256(bytes(LITE_LABEL_A)));
    }

    function test_registerBaseName_claim_wipes_entire_queue() public {
        // `priceWithCheck` admits only the live reservation holder on a given
        // base stem, so the queue stays single-occupant; after the holder
        // claims, the stem is free for a fresh reservation from any user.
        _grantPopFull(ed);
        _grantPopFull(tiago);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        IDotnsPopController.Link memory link = _linkWithLite(LITE_LABEL_A);
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );

        _reservePop(tiago, LITE_LABEL_D, _validChatKey(0x04), BASE_LABEL_B);
        (, address wonderHolder) = dotnsPopController.isReservedForClaim(BASE_LABEL_B);
        assertEq(wonderHolder, tiago);
    }

    function test_registerBaseName_standalone_auto_relinquishes_users_other_reservation() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        _grantPopFull(ed);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0x02));

        _rootRegisterBaseName(
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
        _rootRegisterBaseName(
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

    function test_registerBaseName_reverts_when_origin_is_not_root() public {
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xaa));

        _mockOriginIsRoot(false);
        vm.expectRevert(IDotnsPopController.NotRoot.selector);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );
    }

    function test_relinquishReservation_promotes_next_waiter_when_head_leaves() public {
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
        _rootRegisterBaseName(
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
        // adding `onlyRoot` and breaking permissionless garbage collection.
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        dotnsPopController.expireReservation(BASE_LABEL_A);

        (bool reserved,) = dotnsPopController.isReservedForClaim(BASE_LABEL_A);
        assertFalse(reserved);
    }

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

    function test_entry_point_format_rejections() public {
        _grantPopFull(ed);

        // The shape check runs before any pricing, so "michael" is rejected for carrying no
        // separator rather than for anything about its tier.
        vm.expectRevert(IDotnsPopController.InvalidLiteLabel.selector);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({liteLabel: "michael", user: ed, chatKey: ""})
        );

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xaa));
        vm.expectRevert(IDotnsPopController.InvalidBaseLabel.selector);
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: "not.valid", user: ed, link: link})
        );
    }

    function test_same_stem_lite_and_base_occupy_distinct_registrar_tokens() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "");
        // "michael" (baselength 7, no trailing digits) classifies as PopFull
        // and shares the lite's stem, so both tokens coexist on the registrar.
        _grantPopFull(tiago);
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xbb));
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: "michael", user: tiago, link: link})
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(LITE_LABEL_A))), ed);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("michael"))), tiago);
    }

    function test_both_controllers_can_mint_on_shared_registrar() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), "");
        _commitAndRegister("longnamebob01", tiago, true);

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(LITE_LABEL_A))), ed);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("longnamebob01"))), tiago);
    }

    function test_gateway_reserved_name_rejects_public_register_by_other_user() public {
        _grantPopFull(tiago);
        // The gateway reserves the stem, and the stem is what the reservation blocks: a public
        // registrant contends for `longnamebob` itself.
        _reservePop(tiago, LITE_LABEL_A, _validChatKey(0x11), "longnamebob");

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
                IPopRules.PopError.selector, "Base name reserved for original Lite registrant"
            )
        );
        vm.prank(ed);
        dotnsRegistrarController.register{value: 1 ether}(registration);
    }

    function test_gateway_reserved_name_allows_holder_to_register_via_public() public {
        _grantPopFull(tiago);
        _reservePop(tiago, LITE_LABEL_A, _validChatKey(0x11), "longnamebob");

        _commitAndRegister("longnamebob", tiago, true);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("longnamebob"))), tiago);
    }

    /// @notice A digit-suffixed spelling of a reserved stem is an unrelated name.
    /// @dev The reservation covers `longnamebob`. `longnamebob01` is measured as written, so it
    ///      shares no stem with it and a stranger may take it. This is the guarantee that
    ///      replaces the old cross-flow, where the two spellings collided.
    function test_gateway_reservation_does_not_cover_a_digit_suffixed_name() public {
        _grantPopFull(tiago);
        _reservePop(tiago, LITE_LABEL_A, _validChatKey(0x11), "longnamebob");

        _grantPopFull(ed);
        _commitAndRegister("longnamebob01", ed, true);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("longnamebob01"))), ed);
    }

    function test_second_pop_lite_mint_of_same_label_reverts_at_registrar() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "");

        _grantPopFull(tiago);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrar.NameNotAvailable.selector, uint256(_nodeOf(LITE_LABEL_A))
            )
        );
        _rootReserveBaseName(
            IDotnsPopController.BaseReservation({
                lite: IDotnsPopController.LiteRegistration({
                    liteLabel: LITE_LABEL_A, user: tiago, chatKey: _validChatKey(0xbb)
                }),
                reservedBaseLabel: ""
            })
        );
    }

    /// @notice A lite name cannot host a subname.
    /// @dev The registry derives a parent's node by splitting the path on the separator, so
    ///      `michael.01` as a parent label resolves to `michael` beneath `01` and never to the
    ///      node the gateway minted. The holder of a lite name therefore has no subname tree,
    ///      and no caller can graft one onto their identity.
    function test_lite_name_cannot_host_a_subname() public {
        _grantPopLite(ed);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0xb4)
            })
        );

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: _nodeOf(LITE_LABEL_A),
            subLabel: "blog",
            parentLabel: LITE_LABEL_A,
            owner: ed
        });

        vm.prank(ed);
        vm.expectRevert(IDotnsRegistry.ParentLabelMismatch.selector);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);
    }

    /// @notice A public registration blocks the gateway from the same label, and leaves no
    ///         provenance behind.
    /// @dev The reverse of the gateway-first case below. `_popIssued` is written before the mint
    ///      inside the same call, so the assertion that it still reads false is what proves the
    ///      failed mint took the provenance write with it. A public name that answered
    ///      `isPopIssued` would pass for a person.
    function test_pop_full_mint_after_public_register_reverts_and_writes_no_provenance() public {
        string memory label = "longnamebobx";

        _grantPopFull(tiago);
        _commitAndRegister(label, tiago, true);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xd1));
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrar.NameNotAvailable.selector, uint256(_nodeOf(label))
            )
        );
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: label, user: ed, link: link})
        );

        assertFalse(dotnsPopController.isPopIssued(label), "provenance survived a failed mint");
        assertFalse(dotnsRegistrar.isSoulbound(uint256(_nodeOf(label))), "public name locked");
    }

    function test_public_register_after_pop_full_mint_reverts_at_registrar() public {
        // "longnamebobx" is classification-NoStatus, so ed keeps default status. A full-person
        // label carries no digit suffix.
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: "longnamebobx", user: ed, link: link})
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
        _grantPopFull(ed);
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));
        _rootRegisterBaseName(
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

    function test_non_owner_cannot_create_subname_under_pop_minted_name() public {
        _grantPopFull(ed);
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));
        _rootRegisterBaseName(
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

    function test_pop_reservation_of_already_public_minted_name_reverts_at_reserve_time() public {
        // A name minted through the public commit-reveal flow already has an owner, so a PoP
        // reservation over it could never be redeemed. The guard rejects it at reserve time
        // rather than admitting it and only failing at claim, which would have locked every
        // lite name built on that stem for the full reservation window.
        _commitAndRegister("longnamebob", ed, true);

        _grantPopFull(tiago);
        vm.expectRevert(IDotnsPopController.BaseNameAlreadyRegistered.selector);
        _reservePop(tiago, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        // The guard runs before the lite mint, so the whole call aborts and no lite name is
        // minted for the candidate.
        assertFalse(dotnsRegistrar.exists(uint256(_nodeOf(LITE_LABEL_A))));

        // No reservation was recorded, so the stem family stays open to other candidates.
        (bool reserved,) = dotnsPopController.isReservedForClaim("longnamebob");
        assertFalse(reserved);
    }

    function test_enqueue_becomesHead_writes_popRules_reservation() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        (address holder, uint64 expires) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, ed);
        assertEq(expires, uint64(block.timestamp + popRules.MAX_RESERVATION_TIME()));
    }

    function test_claim_releases_popRules_slot() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        IDotnsPopController.Link memory link = _linkWithLite(LITE_LABEL_A);
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: "longnamebob", user: ed, link: link})
        );

        (address holder,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, address(0));
    }

    function test_relinquish_last_releases_popRules_slot() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        vm.prank(ed);
        dotnsPopController.relinquishReservation();

        (address holder,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, address(0));
    }

    function test_advanceExpiredHead_last_expire_releases_popRules_slot() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        vm.warp(block.timestamp + dotnsPopController.reservationDuration() + 1);
        dotnsPopController.expireReservation("longnamebob");

        (address holder,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, address(0));
    }

    function test_reserveBaseName_reverts_for_digit_suffixed_reserved_base_label() public {
        _grantPopFull(ed);
        vm.expectRevert(IDotnsPopController.InvalidBaseLabel.selector);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob01");
    }

    function test_reserveBaseName_reverts_when_reserved_label_already_registered() public {
        // George worked example: ed reserves and then claims the base name, which frees the
        // stem slot on PopRules. A later lite candidate must not be able to queue a reservation
        // over the now-registered name: the queue keys by stem, so an unclaimable reservation
        // would hold that stem for the full reservation window and block every lite name built
        // on it.
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob");
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({
                label: "longnamebob", user: ed, link: _linkWithLite(LITE_LABEL_A)
            })
        );

        _grantPopFull(tiago);
        vm.expectRevert(IDotnsPopController.BaseNameAlreadyRegistered.selector);
        _reservePop(tiago, LITE_LABEL_B, _validChatKey(0xbb), "longnamebob");
    }

    /// @dev Claiming the stem takes the name, so nothing is left for a stranger to register.
    ///      What the claim releases is the reservation slot on PopRules, which is what this
    ///      asserts; a digit-suffixed spelling would prove nothing, being an unrelated name.
    function test_claim_clears_the_reservation_slot() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        (address beforeClaim,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(beforeClaim, ed, "reserved for the claimant");

        IDotnsPopController.Link memory link = _linkWithLite(LITE_LABEL_A);
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: "longnamebob", user: ed, link: link})
        );

        (address afterClaim,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(afterClaim, address(0), "slot released by the claim");
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("longnamebob"))), ed);
    }

    function test_public_stranger_can_mint_after_reservation_expires() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob");

        vm.warp(block.timestamp + dotnsPopController.reservationDuration() + 1);
        dotnsPopController.expireReservation("longnamebob");

        _grantPopFull(tiago);
        _commitAndRegister("longnamebob", tiago, true);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("longnamebob"))), tiago);
    }

    function test_registered_controller_without_root_origin_cannot_enter_pop_flow() public {
        // The public commit-reveal controller is already a registered controller.
        // Even from that origin, the Root-gate must reject the call.
        _mockOriginIsRoot(false);
        vm.prank(address(dotnsRegistrarController));
        vm.expectRevert(IDotnsPopController.NotRoot.selector);
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

    function test_registerBaseName_standalone_succeeds_when_head_is_expired() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);
        // Walk past both the controller and PopRules expiry windows so
        // nothing blocks tiago's priceWithCheck.
        vm.warp(block.timestamp + popRules.MAX_RESERVATION_TIME() + 1);

        _grantPopFull(tiago);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: tiago, link: link})
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(BASE_LABEL_A))), tiago);
    }

    function test_registerBaseName_standalone_succeeds_when_queue_empty() public {
        _grantPopFull(ed);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xcf));
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(BASE_LABEL_A))), ed);
    }

    function test_registerBaseName_claim_path_bypasses_standalone_holder_guard() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        IDotnsPopController.Link memory link = _linkWithLite(LITE_LABEL_A);
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(BASE_LABEL_A))), ed);
    }

    function test_registerBaseName_guard_blocks_stranger_and_preserves_claim() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        _grantPopFull(tiago);
        IDotnsPopController.Link memory strangerLink = _linkFresh(_validChatKey(0xbb));
        vm.expectPartialRevert(IDotnsPopController.NotHolder.selector);
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({
                label: BASE_LABEL_A, user: tiago, link: strangerLink
            })
        );
        // A's reservation is intact; A claims successfully.
        IDotnsPopController.Link memory claimLink = _linkWithLite(LITE_LABEL_A);
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: claimLink})
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(BASE_LABEL_A))), ed);
    }

    function test_registerBaseName_reverts_for_governance_length_name() public {
        _grantPopFull(ed);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xaa));
        // Stem "alice" has baselength 5; classifies as `Reserved for Governance`,
        // which the PoP controller's governance guard rejects.
        vm.expectRevert(IDotnsPopController.InvalidBaseLabel.selector);

        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: "alice", user: ed, link: link})
        );
    }

    function test_reserveBaseName_reserved_label_classification_reverts() public {
        _grantPopFull(ed);

        // Lite leg uses a valid lite label; reserved leg uses a <=5-char stem,
        // which classifies as `Reserved for Governance` and is rejected by the
        // PoP controller's governance guard.
        vm.expectRevert(IDotnsPopController.InvalidBaseLabel.selector);
        _rootReserveBaseName(
            IDotnsPopController.BaseReservation({
                lite: IDotnsPopController.LiteRegistration({
                    liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
                }),
                reservedBaseLabel: "alice"
            })
        );
    }

    function test_registerBaseName_popFull_user_on_popFull_label_succeeds() public {
        _grantPopFull(ed);

        uint256 controllerBalanceBefore = address(dotnsPopController).balance;

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xaa));
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );
        // No native token moves on the PoP path.
        assertEq(address(dotnsPopController).balance, controllerBalanceBefore);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(BASE_LABEL_A))), ed);
    }

    function test_reserveLiteName_succeeds_regardless_of_base_reservation() public {
        string memory baseStem = BASE_LABEL_A;
        // Occupy the base stem with a live reservation.
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), baseStem);
        // A different user calls reserveLiteName on a different lite label.
        address fresh = makeAddr("freshLite");
        _grantPopLite(fresh);

        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: "stephen.01", user: fresh, chatKey: _validChatKey(0xcc)
            })
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("stephen.01"))), fresh);
    }

    function test_reserveLiteName_reverts_for_non_lite_format() public {
        _grantPopFull(ed);

        vm.expectRevert(IDotnsPopController.InvalidLiteLabel.selector);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: "alice", user: ed, chatKey: _validChatKey(0xaa)
            })
        );
    }

    function test_reserveLiteName_reverts_when_suffix_is_not_exactly_two_digits() public {
        _grantPopFull(ed);

        vm.expectRevert(IDotnsPopController.InvalidLiteLabel.selector);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: "michael.001", user: ed, chatKey: _validChatKey(0xaa)
            })
        );
    }

    function test_reserveLiteName_reverts_when_the_stem_is_governance_reserved() public {
        _grantPopFull(ed);

        // `abcd.12` is a well-formed lite label whose four-letter stem classifies as Reserved,
        // so classification is what rejects it rather than the shape.
        vm.expectRevert(IDotnsPopController.InvalidLiteLabel.selector);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: "abcd.12", user: ed, chatKey: _validChatKey(0xaa)
            })
        );
    }

    function test_reserveLiteName_succeeds_for_long_stem() public {
        _grantPopLite(ed);

        // `andrewsays.01` has a stem of 10, which classifies as NoStatus. The gateway may issue
        // it as a lite username regardless of stem length.
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: "andrewsays.01", user: ed, chatKey: _validChatKey(0xaa)
            })
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf("andrewsays.01"))), ed);
    }

    /// @notice A public registration is not an identity and appears in neither listing.
    /// @dev Both listings require provenance, so a name the gateway never minted is absent from
    ///      both however it is spelled. Without that, `joseph42` would read as a full-person
    ///      identity purely because it is a single label.
    function test_lens_omits_a_public_registration_from_both_listings() public {
        _grantPopFull(ed);
        _commitAndRegister("joseph42", ed, true);

        assertFalse(dotnsPopController.isPopIssued("joseph42"), "the gateway did not mint it");

        assertEq(dotnsPopLens.fullNamesOf(ed, 0, 10).length, 0, "not a full-person identity");
        assertEq(dotnsPopLens.liteNamesOf(ed, 0, 10).length, 0, "nor a lite one");
        assertEq(dotnsPopLens.fullNameCountOf(ed), 0);
        assertEq(dotnsPopLens.liteNameCountOf(ed), 0);
    }

    /// @notice A full-person gateway name lists as full, not lite.
    /// @dev `isPopIssued` covers every name the controller mints, lite and full alike, so it
    ///      cannot say which kind a name is. The separator does that. Keying the lite listing on
    ///      provenance alone would move every full-person identity into it.
    function test_lens_lists_a_full_person_name_as_full() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), "");

        IDotnsPopController.Link memory link = _linkWithLite(LITE_LABEL_A);
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );

        assertTrue(dotnsPopController.isPopIssued(BASE_LABEL_A), "both kinds carry provenance");
        assertTrue(dotnsPopController.isPopIssued(LITE_LABEL_A), "both kinds carry provenance");

        IDotnsPopLens.Name[] memory full = dotnsPopLens.fullNamesOf(ed, 0, 10);
        assertEq(full.length, 1, "the full-person name is in the full listing");
        assertEq(full[0].label, BASE_LABEL_A);

        IDotnsPopLens.Name[] memory lite = dotnsPopLens.liteNamesOf(ed, 0, 10);
        assertEq(lite.length, 1, "and the lite name is in the lite listing");
        assertEq(lite[0].label, LITE_LABEL_A);
    }

    /// @notice A full-person name is letters only, the same rule a lite stem follows.
    /// @dev The hyphen and interior-digit cases are the ones a trailing-digit check misses:
    ///      `alice-bob` and `micha3l` are valid DNS labels and would otherwise be issued as
    ///      identities, while being impossible as lite stems. All three revert with this
    ///      interface's own error.
    function test_registerBaseName_rejects_a_label_that_is_not_letters_only() public {
        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xa1));

        vm.expectRevert(IDotnsPopController.InvalidBaseLabel.selector);
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: "alice-bob", user: ed, link: link})
        );

        vm.expectRevert(IDotnsPopController.InvalidBaseLabel.selector);
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: "micha3l", user: ed, link: link})
        );

        vm.expectRevert(IDotnsPopController.InvalidBaseLabel.selector);
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: "Joseph", user: ed, link: link})
        );
    }

    /// @dev The reservation entrypoints share `_validateBaseLabel`, so a hyphen is rejected
    ///      there too rather than resolving to an empty queue.
    function test_reservation_entrypoints_reject_a_label_that_is_not_letters_only() public {
        _grantPopFull(ed);

        vm.expectRevert(IDotnsPopController.InvalidBaseLabel.selector);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xa2), "alice-bob");

        vm.expectRevert(IDotnsPopController.InvalidBaseLabel.selector);
        dotnsPopController.expireReservation("alice-bob");

        vm.expectRevert(IDotnsPopController.InvalidBaseLabel.selector);
        dotnsPopController.isReservedForClaim("micha3l");

        vm.expectRevert(IDotnsPopController.InvalidBaseLabel.selector);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xa3), "Joseph");
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
    function test_reserveLiteName_stores_the_label_with_its_separator() public {
        _grantPopLite(ed);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: "michael.01", user: ed, chatKey: _validChatKey(0xaa)
            })
        );

        bytes32 wholeLabelNode = _nodeOf("michael.01");
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(wholeLabelNode)), ed);

        bytes32 subnamePathNode = _namehash(_nodeOf("01"), keccak256(bytes("michael")));
        assertTrue(wholeLabelNode != subnamePathNode, "whole label and subname path differ");
    }

    function test_isPopIssued_is_set_at_mint() public {
        _grantPopLite(ed);
        assertFalse(dotnsPopController.isPopIssued("michael.01"), "not issued before the mint");

        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: "michael.01", user: ed, chatKey: _validChatKey(0xaa)
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
        _grantPopLite(cold);

        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: "william.03", user: cold, chatKey: _validChatKey(0xbb)
            })
        );

        assertTrue(dotnsPopController.isPopIssued("william.03"), "true while still pending");

        vm.prank(cold);
        dotnsPopController.claimLabelStore();
        dotnsPopController.settlePendingClaims(cold, type(uint256).max);

        assertTrue(dotnsPopController.isPopIssued("william.03"), "still true once settled");
    }

    /// @dev Provenance covers every name this controller mints, not only the lite ones, because
    ///      it records who issued the name rather than which tier it sits in.
    function test_isPopIssued_covers_full_person_names() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), "");

        IDotnsPopController.Link memory link = _linkWithLite(LITE_LABEL_A);
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: ed, link: link})
        );

        assertTrue(dotnsPopController.isPopIssued(BASE_LABEL_A));
    }

    function test_reserveLiteName_reverts_when_origin_is_not_root() public {
        _mockOriginIsRoot(false);
        vm.expectRevert(IDotnsPopController.NotRoot.selector);
        dotnsPopController.reserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
            })
        );
    }

    function test_reserveBaseName_lite_and_base_legs_both_succeed_in_one_call() public {
        _grantPopFull(ed);

        _rootReserveBaseName(
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

    function test_split_gateway_flow_mints_lite_then_reserves_base() public {
        _grantPopFull(ed);

        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
            })
        );

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(LITE_LABEL_A))), ed);
        assertFalse(dotnsRegistrar.exists(uint256(_nodeOf(BASE_LABEL_A))));

        _rootReserveBaseNameOnly(
            IDotnsPopController.BaseNameReservation({user: ed, reservedBaseLabel: BASE_LABEL_A})
        );

        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(BASE_LABEL_A);
        assertTrue(reserved);
        assertEq(holder, ed);
        assertFalse(dotnsRegistrar.exists(uint256(_nodeOf(BASE_LABEL_A))));
    }

    function test_reserveBaseNameOnly_reverts_when_origin_is_not_root() public {
        _mockOriginIsRoot(false);
        vm.expectRevert(IDotnsPopController.NotRoot.selector);
        dotnsPopController.reserveBaseNameOnly(
            IDotnsPopController.BaseNameReservation({user: ed, reservedBaseLabel: BASE_LABEL_A})
        );
    }

    function test_reserveBaseNameOnly_reverts_for_reserved_or_suffixed_labels() public {
        vm.expectRevert(IDotnsPopController.InvalidBaseLabel.selector);
        _rootReserveBaseNameOnly(
            IDotnsPopController.BaseNameReservation({user: ed, reservedBaseLabel: "alice"})
        );

        vm.expectRevert(IDotnsPopController.InvalidBaseLabel.selector);
        _rootReserveBaseNameOnly(
            IDotnsPopController.BaseNameReservation({user: ed, reservedBaseLabel: "longnamebob01"})
        );
    }

    function test_reserveBaseNameOnly_reverts_when_label_already_registered() public {
        // The standalone reservation entrypoint shares the same guard: a base name that already
        // has an owner on the registrar can never be redeemed, so the reservation is rejected up
        // front rather than discovered to be unusable at claim time.
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0xaa), "longnamebob");
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({
                label: "longnamebob", user: ed, link: _linkWithLite(LITE_LABEL_A)
            })
        );

        vm.expectRevert(IDotnsPopController.BaseNameAlreadyRegistered.selector);
        _rootReserveBaseNameOnly(
            IDotnsPopController.BaseNameReservation({user: tiago, reservedBaseLabel: "longnamebob"})
        );
    }

    function test_reserveBaseNameOnly_does_not_mint_lite_or_base_name() public {
        _rootReserveBaseNameOnly(
            IDotnsPopController.BaseNameReservation({user: ed, reservedBaseLabel: BASE_LABEL_A})
        );

        assertFalse(dotnsRegistrar.exists(uint256(_nodeOf(LITE_LABEL_A))));
        assertFalse(dotnsRegistrar.exists(uint256(_nodeOf(BASE_LABEL_A))));

        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(BASE_LABEL_A);
        assertTrue(reserved);
        assertEq(holder, ed);
    }

    function test_reserveBaseNameOnly_same_user_can_replace_prior_reservation() public {
        _rootReserveBaseNameOnly(
            IDotnsPopController.BaseNameReservation({user: ed, reservedBaseLabel: BASE_LABEL_A})
        );
        _rootReserveBaseNameOnly(
            IDotnsPopController.BaseNameReservation({user: ed, reservedBaseLabel: BASE_LABEL_B})
        );

        (bool firstReserved,) = dotnsPopController.isReservedForClaim(BASE_LABEL_A);
        assertFalse(firstReserved);

        (bool secondReserved, address holder) = dotnsPopController.isReservedForClaim(BASE_LABEL_B);
        assertTrue(secondReserved);
        assertEq(holder, ed);
    }

    function test_third_party_settles_pending_claim_into_user_store() public {
        // Settlement is permissionless: a third party who is neither the beneficiary nor the
        // gateway can settle a user's pending claim, deploying the user's store and writing the
        // stashed label. The settled name lands in the beneficiary's store, and the settlement
        // event records the third party as the settler.
        _grantPopFull(ed);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
            })
        );

        bytes32 labelhash = keccak256(bytes(LITE_LABEL_A));
        address expectedStore =
            vm.computeCreateAddress(address(storeFactory), vm.getNonce(address(storeFactory)));

        vm.prank(leonardo);
        vm.expectEmit(true, true, false, true, address(dotnsPopController));
        emit IDotnsPopController.PendingClaimSettled(ed, labelhash, expectedStore, leonardo);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        address store = storeFactory.getLabelStore(ed);
        assertEq(store, expectedStore);
        assertEq(
            ILabelStore(store).getLabel(_nodeOf(LITE_LABEL_A)), string.concat(LITE_LABEL_A, ".dot")
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function test_user_settles_own_pending_claim_after_gateway_mint() public {
        _grantPopFull(ed);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
            })
        );

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(_nodeOf(LITE_LABEL_A)), string.concat(LITE_LABEL_A, ".dot")
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function test_claimLabelStore_settles_callers_own_pending_claim() public {
        _grantPopFull(ed);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
            })
        );

        vm.prank(ed);
        bool moreRemaining = dotnsPopController.claimLabelStore();
        assertFalse(moreRemaining);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(_nodeOf(LITE_LABEL_A)),
            string.concat(LITE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function test_settle_deploys_store_when_user_has_none() public {
        _grantPopFull(ed);

        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0xaa)
            })
        );

        assertEq(dotnsPopController.pendingClaims(ed, 0, 1)[0].label, LITE_LABEL_A);
        assertEq(storeFactory.getLabelStore(ed), address(0));

        (uint256 settledCount, bool moreRemaining) =
            dotnsPopController.settlePendingClaims(ed, type(uint256).max);
        assertEq(settledCount, 1);
        assertFalse(moreRemaining);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(_nodeOf(LITE_LABEL_A)), string.concat(LITE_LABEL_A, ".dot")
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function test_registerBaseName_zero_length_label_reverts() public {
        _grantPopFull(ed);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xaa));
        vm.expectRevert(IDotnsPopController.InvalidBaseLabel.selector);
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: "", user: ed, link: link})
        );
    }

    function test_reserveBaseName_accepts_65_byte_chat_key() public {
        _grantPopFull(ed);

        bytes memory chatKey = _validChatKey(0x42);

        _rootReserveBaseName(
            IDotnsPopController.BaseReservation({
                lite: IDotnsPopController.LiteRegistration({
                    liteLabel: LITE_LABEL_A, user: ed, chatKey: chatKey
                }),
                reservedBaseLabel: ""
            })
        );

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        bytes32 node = _nodeOf(LITE_LABEL_A);
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
        _grantPopFull(ed);
        bytes memory chatKey = _validChatKey(0x01);

        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: chatKey
            })
        );

        bytes32 node = _nodeOf(LITE_LABEL_A);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(node)), ed);
        assertEq(storeFactory.getLabelStore(ed), address(0));
        // Chat key is now persisted eagerly on the resolver at reserve time, even when
        // the user has no LabelStore yet.
        assertEq(dotnsPopResolver.chatKey(node), chatKey);

        IDotnsPopController.PendingClaim[] memory pending =
            dotnsPopController.pendingClaims(ed, 0, type(uint256).max);
        assertEq(pending[0].label, LITE_LABEL_A);
        assertGt(pending[0].mintedAt, 0);
    }

    function test_settle_deploys_store_and_writes_label_and_chat_key() public {
        _grantPopFull(ed);
        bytes memory chatKey = _validChatKey(0x07);

        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: chatKey
            })
        );

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));

        bytes32 node = _nodeOf(LITE_LABEL_A);
        assertEq(
            ILabelStore(store).getLabel(node), string.concat(LITE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(dotnsPopResolver.chatKey(node), chatKey);

        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function test_settle_emits_settled_and_name_registered() public {
        _grantPopFull(ed);
        bytes memory chatKey = _validChatKey(0x03);

        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: chatKey
            })
        );

        bytes32 labelhash = keccak256(bytes(LITE_LABEL_A));
        address expectedStore =
            vm.computeCreateAddress(address(storeFactory), vm.getNonce(address(storeFactory)));

        vm.prank(ed);
        vm.expectEmit(true, true, false, true, address(dotnsPopController));
        emit IDotnsPopController.PendingClaimSettled(ed, labelhash, expectedStore, ed);
        vm.expectEmit(true, true, true, true, address(dotnsPopController));
        emit IDotnsPopController.NameRegistered(LITE_LABEL_A, labelhash, ed, expectedStore);
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
        _grantPopFull(ed);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x05)
            })
        );
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_B, user: ed, chatKey: _validChatKey(0x06)
            })
        );
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_C, user: ed, chatKey: _validChatKey(0x07)
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
        _grantPopFull(ed);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x02)
            })
        );

        vm.warp(block.timestamp + DEFAULT_RESERVATION_DURATION + 1);

        bytes32 labelhash = keccak256(bytes(LITE_LABEL_A));
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
            ILabelStore(store).getLabel(_nodeOf(LITE_LABEL_A)),
            string.concat(LITE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
        assertEq(dotnsPopController.pendingClaimUserCount(), 0);
    }

    function test_settle_after_reservation_duration_still_writes_label() public {
        // The old model dropped lapsed entries; stores now always settle. Warping past the
        // reservation duration and settling writes the label into the store rather than
        // discarding it.
        _grantPopFull(ed);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x04)
            })
        );

        vm.warp(block.timestamp + DEFAULT_RESERVATION_DURATION + 1);

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(_nodeOf(LITE_LABEL_A)),
            string.concat(LITE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
        assertEq(dotnsPopController.pendingClaimUserCount(), 0);
    }

    function test_reserveLiteName_piles_second_pending_claim_when_caller_has_no_store() public {
        // The Root gateway origin cannot deploy a LabelStore, so a store-less user keeps
        // accumulating deferred names instead of reverting; a single signed-origin
        // settlement writes them all at once.
        _grantPopFull(ed);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x05)
            })
        );
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_B, user: ed, chatKey: _validChatKey(0x06)
            })
        );

        IDotnsPopController.PendingClaim[] memory pending =
            dotnsPopController.pendingClaims(ed, 0, type(uint256).max);
        assertEq(pending.length, 2);
        assertEq(pending[0].label, LITE_LABEL_A);
        assertEq(pending[1].label, LITE_LABEL_B);
        assertEq(dotnsPopController.pendingClaimUserCount(), 1);

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(_nodeOf(LITE_LABEL_A)),
            string.concat(LITE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(
            ILabelStore(store).getLabel(_nodeOf(LITE_LABEL_B)),
            string.concat(LITE_LABEL_B, protocolRegistry.tld())
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
        assertEq(dotnsPopController.pendingClaimUserCount(), 0);
    }

    function test_pendingClaims_returns_empty_array_for_fresh_user() public view {
        assertEq(dotnsPopController.pendingClaims(ed, 0, type(uint256).max).length, 0);
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function test_registerBaseName_claim_by_store_less_full_person_piles_then_settles() public {
        // Regression: a store-less full person reserves a lite name plus a base reservation
        // (the lite leg stashes a deferred claim because Root cannot deploy the store), then
        // claims the base name. The base mint stashes a second deferred claim instead of
        // reverting; one signed-origin settlement deploys the store and settles both.
        _grantPopFull(ed);
        _rootReserveBaseName(
            IDotnsPopController.BaseReservation({
                lite: IDotnsPopController.LiteRegistration({
                    liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x31)
                }),
                reservedBaseLabel: BASE_LABEL_A
            })
        );
        assertEq(storeFactory.getLabelStore(ed), address(0));
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 1);

        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({
                label: BASE_LABEL_A, user: ed, link: _linkWithLite(LITE_LABEL_A)
            })
        );

        IDotnsPopController.PendingClaim[] memory pending =
            dotnsPopController.pendingClaims(ed, 0, type(uint256).max);
        assertEq(pending.length, 2);
        assertEq(pending[0].label, LITE_LABEL_A);
        assertEq(pending[1].label, BASE_LABEL_A);

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(_nodeOf(LITE_LABEL_A)),
            string.concat(LITE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(
            ILabelStore(store).getLabel(_nodeOf(BASE_LABEL_A)),
            string.concat(BASE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function test_pendingClaimUsers_enumeration_mirrors_stash_and_settle() public {
        _grantPopFull(ed);
        _grantPopFull(tiago);
        _grantPopFull(leonardo);

        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x01)
            })
        );
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_B, user: tiago, chatKey: _validChatKey(0x02)
            })
        );
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_C, user: leonardo, chatKey: _validChatKey(0x03)
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
        _grantPopFull(ed);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x01)
            })
        );

        address[] memory empty = dotnsPopController.pendingClaimUsers(5, 10);
        assertEq(empty.length, 0);
    }

    function test_settle_at_exact_expiry_boundary_writes_label() public {
        // Age is irrelevant to settlement: at the exact reservation deadline the claim still
        // settles and writes its label rather than being treated as forfeit.
        _grantPopFull(ed);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x11)
            })
        );

        uint64 mintedAt = dotnsPopController.pendingClaims(ed, 0, 1)[0].mintedAt;
        vm.warp(uint256(mintedAt) + uint256(DEFAULT_RESERVATION_DURATION));

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(_nodeOf(LITE_LABEL_A)),
            string.concat(LITE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function test_settle_is_keyed_by_user_arg_other_stash_untouched() public {
        // Settlement targets the `user` argument, not the caller: settling for a user with no
        // stash is a no-op and does not disturb another user's pending claim.
        _grantPopFull(ed);
        bytes memory chatKey = _validChatKey(0x12);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: chatKey
            })
        );

        vm.prank(tiago);
        (uint256 settledCount, bool moreRemaining) =
            dotnsPopController.settlePendingClaims(tiago, type(uint256).max);
        assertEq(settledCount, 0);
        assertFalse(moreRemaining);

        IDotnsPopController.PendingClaim[] memory pending =
            dotnsPopController.pendingClaims(ed, 0, type(uint256).max);
        assertEq(pending[0].label, LITE_LABEL_A);
        assertGt(pending[0].mintedAt, 0);
        assertEq(storeFactory.getLabelStore(ed), address(0));
        assertEq(storeFactory.getLabelStore(tiago), address(0));
        assertEq(dotnsPopController.pendingClaimUserCount(), 1);
    }

    function test_pendingClaimUsers_pagination_boundary_cases() public {
        _grantPopFull(ed);
        _grantPopFull(tiago);
        _grantPopFull(leonardo);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x01)
            })
        );
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_B, user: tiago, chatKey: _validChatKey(0x02)
            })
        );
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_C, user: leonardo, chatKey: _validChatKey(0x03)
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
        _grantPopFull(ed);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({liteLabel: LITE_LABEL_A, user: ed, chatKey: ""})
        );

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        bytes32 node = _nodeOf(LITE_LABEL_A);
        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(node), string.concat(LITE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(dotnsPopResolver.chatKey(node).length, 0);
    }

    function test_gatewayReserve_warm_user_after_settle_writes_directly_without_stashing() public {
        _grantPopFull(ed);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x21)
            })
        );

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);
        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));

        bytes memory secondChatKey = _validChatKey(0x22);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_B, user: ed, chatKey: secondChatKey
            })
        );

        bytes32 node = _nodeOf(LITE_LABEL_B);
        assertEq(
            ILabelStore(store).getLabel(node), string.concat(LITE_LABEL_B, protocolRegistry.tld())
        );
        assertEq(dotnsPopResolver.chatKey(node), secondChatKey);
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
        assertEq(dotnsPopController.pendingClaimUserCount(), 0);
    }

    function test_advanceExpiredHead_promotes_waiter_and_resyncs_popRules() public {
        string memory stem = "longnamebob";
        uint64 duration = dotnsPopController.reservationDuration();
        _grantPopFull(ed);
        _grantPopFull(tiago);

        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), stem);
        vm.warp(block.timestamp + uint256(duration) / 2);
        _reservePop(tiago, LITE_LABEL_B, _validChatKey(0x02), stem);

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
        _grantPopFull(ed);
        _grantPopFull(tiago);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);
        _reservePop(tiago, LITE_LABEL_B, _validChatKey(0x02), BASE_LABEL_A);

        IDotnsPopController.Link memory link = _linkFresh(_validChatKey(0xbb));
        vm.expectPartialRevert(IDotnsPopController.NotHolder.selector);
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: BASE_LABEL_A, user: tiago, link: link})
        );
    }

    function test_liteNamesOf_and_fullNamesOf_split_issued_names_by_shape() public {
        // Settled names read back from the store; a pending gateway name reads from the queue with
        // a live deadline; the two shapes never cross into each other's list; an untouched account
        // returns empty lists and zero counts.
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), "");
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({
                label: BASE_LABEL_A, user: ed, link: _linkFresh(_validChatKey(0x02))
            })
        );

        _grantPopFull(leonardo);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_C, user: leonardo, chatKey: _validChatKey(0x03)
            })
        );

        IDotnsPopLens.Name[] memory edLite = dotnsPopLens.liteNamesOf(ed, 0, type(uint256).max);
        assertEq(edLite.length, 1);
        assertEq(edLite[0].node, _nodeOf(LITE_LABEL_A));
        assertEq(edLite[0].label, LITE_LABEL_A);
        assertTrue(edLite[0].settled);
        assertEq(edLite[0].deadline, 0);

        IDotnsPopLens.Name[] memory edFull = dotnsPopLens.fullNamesOf(ed, 0, type(uint256).max);
        assertEq(edFull.length, 1);
        assertEq(edFull[0].node, _nodeOf(BASE_LABEL_A));
        assertEq(edFull[0].label, BASE_LABEL_A);
        assertTrue(edFull[0].settled);

        assertEq(dotnsPopLens.liteNameCountOf(ed), 1);
        assertEq(dotnsPopLens.fullNameCountOf(ed), 1);

        IDotnsPopLens.Name[] memory leoLite =
            dotnsPopLens.liteNamesOf(leonardo, 0, type(uint256).max);
        assertEq(leoLite.length, 1);
        assertEq(leoLite[0].node, _nodeOf(LITE_LABEL_C));
        assertEq(leoLite[0].label, LITE_LABEL_C);
        assertFalse(leoLite[0].settled);
        assertGt(leoLite[0].deadline, 0);
        assertEq(dotnsPopLens.liteNameCountOf(leonardo), 1);
        assertEq(dotnsPopLens.fullNameCountOf(leonardo), 0);

        assertEq(dotnsPopLens.liteNamesOf(tiago, 0, type(uint256).max).length, 0);
        assertEq(dotnsPopLens.fullNamesOf(tiago, 0, type(uint256).max).length, 0);
        assertEq(dotnsPopLens.liteNameCountOf(tiago), 0);
        assertEq(dotnsPopLens.fullNameCountOf(tiago), 0);
    }

    function test_liteNamesOf_pagination_slices_and_clamps() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), "");
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_B, user: ed, chatKey: _validChatKey(0x02)
            })
        );

        assertEq(dotnsPopLens.liteNameCountOf(ed), 2);

        IDotnsPopLens.Name[] memory first = dotnsPopLens.liteNamesOf(ed, 0, 1);
        assertEq(first.length, 1);
        IDotnsPopLens.Name[] memory second = dotnsPopLens.liteNamesOf(ed, 1, 1);
        assertEq(second.length, 1);
        assertTrue(first[0].node != second[0].node);

        assertEq(dotnsPopLens.liteNamesOf(ed, 2, 1).length, 0);

        // A limit above the internal page ceiling is clamped rather than reverting; the account
        // holds fewer names than the ceiling, so the full set still comes back.
        IDotnsPopLens.Name[] memory clamped =
            dotnsPopLens.liteNamesOf(ed, 0, DotnsConstants.MAX_PAGE_SIZE + 1);
        assertEq(clamped.length, 2);
    }

    function test_name_listings_exclude_names_owned_by_others() public {
        // The listing re-checks registrar ownership per entry, so a name owned by another account
        // never surfaces in this account's list.
        _grantPopFull(ed);
        _grantPopFull(tiago);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), "");
        _reservePop(tiago, LITE_LABEL_C, _validChatKey(0x02), "");

        IDotnsPopLens.Name[] memory edLite = dotnsPopLens.liteNamesOf(ed, 0, type(uint256).max);
        assertEq(edLite.length, 1);
        assertFalse(_namesContainNode(edLite, _nodeOf(LITE_LABEL_C)));

        IDotnsPopLens.Name[] memory tiagoLite =
            dotnsPopLens.liteNamesOf(tiago, 0, type(uint256).max);
        assertEq(tiagoLite.length, 1);
        assertFalse(_namesContainNode(tiagoLite, _nodeOf(LITE_LABEL_A)));
    }

    function test_nameDetail_and_nameDetailByNode_report_record() public {
        _grantPopFull(ed);
        bytes memory liteChatKey = _validChatKey(0xaa);
        _reservePop(ed, LITE_LABEL_A, liteChatKey, BASE_LABEL_A);
        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({
                label: BASE_LABEL_A, user: ed, link: _linkWithLite(LITE_LABEL_A)
            })
        );

        bytes32 fullNode = _nodeOf(BASE_LABEL_A);
        IDotnsPopLens.NameDetail memory full = dotnsPopLens.nameDetail(BASE_LABEL_A);
        assertEq(full.node, fullNode);
        assertEq(full.label, BASE_LABEL_A);
        assertEq(full.owner, ed);
        assertTrue(full.exists);
        assertTrue(full.settled);
        assertTrue(full.tier == IPopRules.PopStatus.PopFull);
        assertEq(full.chatKey, liteChatKey);
        assertEq(full.liteLink, keccak256(bytes(LITE_LABEL_A)));
        // A base label is never a lite labelhash, so no promoted node is keyed under it.
        assertEq(full.fullClaim, bytes32(0));

        // Holding the lite label lets nameDetail recover the promoted full node.
        IDotnsPopLens.NameDetail memory lite = dotnsPopLens.nameDetail(LITE_LABEL_A);
        assertEq(lite.fullClaim, fullNode);

        // A settled lite name that was never promoted carries no full claim, and the by-node
        // overload leaves it zero.
        _grantPopFull(leonardo);
        _reservePop(leonardo, LITE_LABEL_C, _validChatKey(0xbb), "");
        IDotnsPopLens.NameDetail memory coldByNode =
            dotnsPopLens.nameDetailByNode(_nodeOf(LITE_LABEL_C));
        assertTrue(coldByNode.exists);
        assertEq(coldByNode.fullClaim, bytes32(0));

        // Unknown name and node never revert and return a zeroed record.
        IDotnsPopLens.NameDetail memory unknownName = dotnsPopLens.nameDetail("nothingxx");
        assertFalse(unknownName.exists);
        assertEq(unknownName.owner, address(0));
        assertEq(bytes(unknownName.label).length, 0);
        assertEq(unknownName.fullClaim, bytes32(0));

        IDotnsPopLens.NameDetail memory unknownNode =
            dotnsPopLens.nameDetailByNode(bytes32(uint256(0xdead)));
        assertFalse(unknownNode.exists);
        assertEq(unknownNode.owner, address(0));
        assertEq(unknownNode.fullClaim, bytes32(0));
    }

    function test_profileOf_reports_store_pending_and_reservation() public {
        // A store-less user with a staged claim, a settled user holding a reservation, and an
        // untouched account each report distinct profile facts.
        _grantPopFull(leonardo);
        _rootReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_C, user: leonardo, chatKey: _validChatKey(0x01)
            })
        );
        IDotnsPopLens.PopProfile memory cold = dotnsPopLens.profileOf(leonardo);
        assertFalse(cold.hasLabelStore);
        assertEq(cold.pendingClaimCount, 1);
        assertEq(cold.reservationLabelhash, bytes32(0));

        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x02), BASE_LABEL_A);
        IDotnsPopLens.PopProfile memory warm = dotnsPopLens.profileOf(ed);
        assertTrue(warm.hasLabelStore);
        assertEq(warm.pendingClaimCount, 0);
        assertEq(warm.reservationLabelhash, keccak256(bytes(BASE_LABEL_A)));

        IDotnsPopLens.PopProfile memory empty = dotnsPopLens.profileOf(tiago);
        assertFalse(empty.hasLabelStore);
        assertEq(empty.pendingClaimCount, 0);
        assertEq(empty.reservationLabelhash, bytes32(0));
    }

    function test_reservedBaseLabelOf_returns_label_or_empty() public {
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, _validChatKey(0x01), BASE_LABEL_A);

        assertEq(
            dotnsPopController.reservedBaseLabelOf(keccak256(bytes(BASE_LABEL_A))), BASE_LABEL_A
        );
        assertEq(
            bytes(dotnsPopController.reservedBaseLabelOf(keccak256(bytes("unknownbase")))).length, 0
        );
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
