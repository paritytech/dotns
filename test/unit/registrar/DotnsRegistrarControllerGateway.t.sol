// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns, IDotnsRegistrarController} from "../../base/BaseDotns.t.sol";
import {IDotnsRegistrar} from "../../../contracts/registrars/IDotnsRegistrar.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {IStore, Store} from "../../../contracts/store/Store.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {StoreUtils} from "../../../contracts/utils/StoreUtils.sol";

/// @title Gateway flow tests for DotnsRegistrarController 1.5.0
/// @notice Covers the PoP-gateway entry points introduced by individuality#755:
///         `reserveBaseName`, `registerBaseName`, `expireReservation`,
///         `relinquishReservation`, `isReservedForClaim`, and the public `register`
///         reservation head-check.
contract DotnsRegistrarControllerGatewayTests is BaseDotns {
    // ---------- helpers ----------

    function _nodeOf(string memory label) internal pure returns (bytes32) {
        bytes32 labelhash = keccak256(bytes(label));
        return keccak256(abi.encodePacked(DOT_NODE, labelhash));
    }

    function _reserveFor(
        address user,
        string memory label,
        bytes memory chatKey,
        string memory reservedLabel
    )
        internal
    {
        vm.prank(popGateway);
        dotnsRegistrarController.reserveBaseName(label, user, chatKey, reservedLabel);
    }

    // Solidity forbids calling `string.concat` with storage constants, so a mutable
    // local DOT_NODE constant is mirrored from BaseDotns for cleanliness.
    bytes32 internal constant DOT_NODE =
        0x3fce7d1364a893e213bc4212792b517ffc88f5b13b86c8ef9c8d390c3a1370ce;

    // ---------- reserveBaseName ----------

    function test_reserveBaseName_mints_and_writes_chat_key() public {
        string memory label = "alice001";
        bytes memory chatKey = hex"01020304";

        _reserveFor(ed, label, chatKey, "");

        bytes32 labelhash = keccak256(bytes(label));
        bytes32 node = _nodeOf(label);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(node)), ed);
        assertEq(dotnsRegistry.owner(node), ed);

        Store store = Store(address(storeFactory.getDeployedStore(ed)));
        string memory written = store.getValueFor(ed, StoreUtils.chatKeyStoreKey(labelhash));
        assertEq(bytes(written), chatKey);
    }

    function test_reserveBaseName_skips_chat_key_when_empty() public {
        string memory label = "alice002";

        _reserveFor(ed, label, "", "");

        bytes32 labelhash = keccak256(bytes(label));
        Store store = Store(address(storeFactory.getDeployedStore(ed)));
        assertEq(bytes(store.getValueFor(ed, StoreUtils.chatKeyStoreKey(labelhash))).length, 0);
    }

    function test_reserveBaseName_reverts_for_non_gateway_caller() public {
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsRegistrarController.NotGateway.selector, ed));
        dotnsRegistrarController.reserveBaseName("alice003", ed, "", "");
    }

    function test_reserveBaseName_enqueues_reservation_when_reserved_label_provided() public {
        _reserveFor(ed, "alice004", hex"aa", "alice");

        (bool reserved, address holder) = dotnsRegistrarController.isReservedForClaim("alice");
        assertTrue(reserved);
        assertEq(holder, ed);
    }

    function test_reserveBaseName_relinquishes_prior_reservation_when_user_reserves_again() public {
        _reserveFor(ed, "alice005", hex"aa", "alice");
        _reserveFor(ed, "alice006", hex"bb", "wonder");

        (bool aliceReserved,) = dotnsRegistrarController.isReservedForClaim("alice");
        assertFalse(aliceReserved);

        (bool wonderReserved, address wonderHolder) =
            dotnsRegistrarController.isReservedForClaim("wonder");
        assertTrue(wonderReserved);
        assertEq(wonderHolder, ed);
    }

    function test_reserveBaseName_reverts_when_label_is_reserved_by_another_user() public {
        // tiago reserves `alicebob` first.
        _reserveFor(tiago, "lite0001", hex"11", "alicebob");

        // ed cannot now register the name `alicebob` as a lite-person username.
        vm.prank(popGateway);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrarController.LabelReservedForPop.selector, "alicebob"
            )
        );
        dotnsRegistrarController.reserveBaseName("alicebob", ed, hex"22", "");
    }

    function test_reserveBaseName_builds_up_queue_across_multiple_users() public {
        _reserveFor(ed, "lite01", hex"01", "alicebob");
        _reserveFor(tiago, "lite02", hex"02", "alicebob");
        _reserveFor(leonardo, "lite03", hex"03", "alicebob");

        (bool reserved, address head) = dotnsRegistrarController.isReservedForClaim("alicebob");
        assertTrue(reserved);
        assertEq(head, ed);
    }

    // ---------- registerBaseName: Path A (claim reserved) ----------

    function test_registerBaseName_pathA_claim_wipes_entire_queue() public {
        _reserveFor(ed, "lite01", hex"01", "alicebob");
        _reserveFor(tiago, "lite02", hex"02", "alicebob");
        _reserveFor(leonardo, "lite03", hex"03", "alicebob");

        IDotnsRegistrarController.Link memory link = IDotnsRegistrarController.Link({
            kind: IDotnsRegistrarController.LinkKind.LiteUsername, liteLabel: "lite01", chatKey: ""
        });

        vm.prank(popGateway);
        dotnsRegistrarController.registerBaseName("alicebob", ed, link);

        // ed owns the name.
        bytes32 node = _nodeOf("alicebob");
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(node)), ed);

        // Queue is empty — nobody can claim it anymore.
        (bool reserved,) = dotnsRegistrarController.isReservedForClaim("alicebob");
        assertFalse(reserved);

        // Other waiters can now reserve something else (their user-slot is cleared).
        _reserveFor(tiago, "lite04", hex"04", "wonder");
        (bool wonderReserved, address wonderHolder) =
            dotnsRegistrarController.isReservedForClaim("wonder");
        assertTrue(wonderReserved);
        assertEq(wonderHolder, tiago);
    }

    function test_registerBaseName_pathA_writes_lite_link_into_store() public {
        _reserveFor(ed, "lite01", hex"aa", "alicebob");

        IDotnsRegistrarController.Link memory link = IDotnsRegistrarController.Link({
            kind: IDotnsRegistrarController.LinkKind.LiteUsername, liteLabel: "lite01", chatKey: ""
        });

        vm.prank(popGateway);
        dotnsRegistrarController.registerBaseName("alicebob", ed, link);

        bytes32 fullLabelhash = keccak256(bytes("alicebob"));
        Store store = Store(address(storeFactory.getDeployedStore(ed)));
        string memory stored = store.getValueFor(ed, StoreUtils.liteLinkStoreKey(fullLabelhash));
        bytes32 expected = keccak256(bytes("lite01"));
        assertEq(keccak256(bytes(stored)), keccak256(abi.encodePacked(expected)));
    }

    function test_registerBaseName_pathA_reverts_when_user_has_no_reservation() public {
        IDotnsRegistrarController.Link memory link = IDotnsRegistrarController.Link({
            kind: IDotnsRegistrarController.LinkKind.LiteUsername, liteLabel: "lite01", chatKey: ""
        });

        vm.prank(popGateway);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrarController.NoActiveReservation.selector, ed)
        );
        dotnsRegistrarController.registerBaseName("alicebob", ed, link);
    }

    function test_registerBaseName_pathA_reverts_when_user_is_not_head() public {
        _reserveFor(ed, "lite01", hex"aa", "alicebob");
        _reserveFor(tiago, "lite02", hex"bb", "alicebob");

        IDotnsRegistrarController.Link memory link = IDotnsRegistrarController.Link({
            kind: IDotnsRegistrarController.LinkKind.LiteUsername, liteLabel: "lite02", chatKey: ""
        });

        vm.prank(popGateway);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrarController.NotHolder.selector, tiago, keccak256(bytes("alicebob"))
            )
        );
        dotnsRegistrarController.registerBaseName("alicebob", tiago, link);
    }

    // ---------- registerBaseName: Path B (standalone) ----------

    function test_registerBaseName_pathB_standalone_without_prior_reservation() public {
        bytes memory chatKey = hex"deadbeef";
        IDotnsRegistrarController.Link memory link = IDotnsRegistrarController.Link({
            kind: IDotnsRegistrarController.LinkKind.None, liteLabel: "", chatKey: chatKey
        });

        vm.prank(popGateway);
        dotnsRegistrarController.registerBaseName("alicebob", ed, link);

        bytes32 node = _nodeOf("alicebob");
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(node)), ed);

        bytes32 labelhash = keccak256(bytes("alicebob"));
        Store store = Store(address(storeFactory.getDeployedStore(ed)));
        string memory storedChat = store.getValueFor(ed, StoreUtils.chatKeyStoreKey(labelhash));
        assertEq(bytes(storedChat), chatKey);

        // No lite link written.
        assertEq(bytes(store.getValueFor(ed, StoreUtils.liteLinkStoreKey(labelhash))).length, 0);
    }

    function test_registerBaseName_pathB_auto_relinquishes_users_other_reservation() public {
        _reserveFor(ed, "lite01", hex"01", "alicebob");

        IDotnsRegistrarController.Link memory link = IDotnsRegistrarController.Link({
            kind: IDotnsRegistrarController.LinkKind.None, liteLabel: "", chatKey: hex"02"
        });

        vm.prank(popGateway);
        dotnsRegistrarController.registerBaseName("wonderland01", ed, link);

        // ed's former reservation on `alicebob` is gone.
        (bool reserved,) = dotnsRegistrarController.isReservedForClaim("alicebob");
        assertFalse(reserved);
    }

    function test_registerBaseName_pathB_wipes_queue_when_self_standalone_on_reserved_label()
        public
    {
        _reserveFor(ed, "lite01", hex"01", "alicebob");
        _reserveFor(tiago, "lite02", hex"02", "alicebob");

        IDotnsRegistrarController.Link memory link = IDotnsRegistrarController.Link({
            kind: IDotnsRegistrarController.LinkKind.None, liteLabel: "", chatKey: hex"aa"
        });

        vm.prank(popGateway);
        dotnsRegistrarController.registerBaseName("alicebob", ed, link);

        // ed now owns the name.
        bytes32 node = _nodeOf("alicebob");
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(node)), ed);

        // Queue is cleared — tiago no longer holds an orphaned entry pointing at this label.
        _reserveFor(tiago, "lite03", hex"03", "wonder");
        (, address holder) = dotnsRegistrarController.isReservedForClaim("wonder");
        assertEq(holder, tiago);
    }

    function test_registerBaseName_pathB_reverts_when_label_reserved_by_other_user() public {
        _reserveFor(tiago, "lite01", hex"11", "alicebob");

        IDotnsRegistrarController.Link memory link = IDotnsRegistrarController.Link({
            kind: IDotnsRegistrarController.LinkKind.None, liteLabel: "", chatKey: hex"22"
        });

        vm.prank(popGateway);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrarController.LabelReservedForPop.selector, "alicebob"
            )
        );
        dotnsRegistrarController.registerBaseName("alicebob", ed, link);
    }

    function test_registerBaseName_reverts_for_non_gateway_caller() public {
        IDotnsRegistrarController.Link memory link = IDotnsRegistrarController.Link({
            kind: IDotnsRegistrarController.LinkKind.None, liteLabel: "", chatKey: hex"aa"
        });

        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsRegistrarController.NotGateway.selector, ed));
        dotnsRegistrarController.registerBaseName("alicebob", ed, link);
    }

    // ---------- expireReservation ----------

    function test_expireReservation_advances_head_past_expired_entries() public {
        _reserveFor(ed, "lite01", hex"01", "alicebob");
        _reserveFor(tiago, "lite02", hex"02", "alicebob");

        // ed and tiago reserved at the same timestamp; warp past expiry.
        vm.warp(block.timestamp + 30 days + 1);

        // Permissionless call.
        vm.prank(leonardo);
        dotnsRegistrarController.expireReservation("alicebob");

        (bool reserved,) = dotnsRegistrarController.isReservedForClaim("alicebob");
        assertFalse(reserved);
    }

    function test_expireReservation_stops_at_first_non_expired_entry() public {
        _reserveFor(ed, "lite01", hex"01", "alicebob");
        vm.warp(block.timestamp + 30 days + 1);
        _reserveFor(tiago, "lite02", hex"02", "alicebob");

        vm.prank(leonardo);
        dotnsRegistrarController.expireReservation("alicebob");

        (bool reserved, address holder) = dotnsRegistrarController.isReservedForClaim("alicebob");
        assertTrue(reserved);
        assertEq(holder, tiago);
    }

    function test_expireReservation_is_noop_on_empty_queue() public {
        // Should not revert.
        vm.prank(leonardo);
        dotnsRegistrarController.expireReservation("neverreserved");
    }

    // ---------- relinquishReservation ----------

    function test_relinquishReservation_removes_head_and_promotes_next() public {
        _reserveFor(ed, "lite01", hex"01", "alicebob");
        _reserveFor(tiago, "lite02", hex"02", "alicebob");

        vm.prank(ed);
        dotnsRegistrarController.relinquishReservation();

        (bool reserved, address holder) = dotnsRegistrarController.isReservedForClaim("alicebob");
        assertTrue(reserved);
        assertEq(holder, tiago);

        // ed can now reserve something new.
        _reserveFor(ed, "lite03", hex"03", "newname");
        (, address newHolder) = dotnsRegistrarController.isReservedForClaim("newname");
        assertEq(newHolder, ed);
    }

    function test_relinquishReservation_removes_non_head_without_promotion() public {
        _reserveFor(ed, "lite01", hex"01", "alicebob");
        _reserveFor(tiago, "lite02", hex"02", "alicebob");

        vm.prank(tiago);
        dotnsRegistrarController.relinquishReservation();

        // Head unchanged.
        (, address holder) = dotnsRegistrarController.isReservedForClaim("alicebob");
        assertEq(holder, ed);

        // tiago can reserve a new label.
        _reserveFor(tiago, "lite03", hex"03", "wonder");
        (, address wonderHolder) = dotnsRegistrarController.isReservedForClaim("wonder");
        assertEq(wonderHolder, tiago);
    }

    function test_relinquishReservation_reverts_when_caller_has_no_reservation() public {
        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrarController.NoActiveReservation.selector, ed)
        );
        dotnsRegistrarController.relinquishReservation();
    }

    // ---------- isReservedForClaim ----------

    function test_isReservedForClaim_returns_false_when_queue_empty() public view {
        (bool reserved, address holder) = dotnsRegistrarController.isReservedForClaim("nothing");
        assertFalse(reserved);
        assertEq(holder, address(0));
    }

    function test_isReservedForClaim_returns_false_when_head_expired() public {
        _reserveFor(ed, "lite01", hex"01", "alicebob");

        vm.warp(block.timestamp + 30 days + 1);

        (bool reserved,) = dotnsRegistrarController.isReservedForClaim("alicebob");
        assertFalse(reserved);
    }

    // ---------- public register head-check ----------

    function test_public_register_reverts_when_label_reserved_for_another() public {
        _reserveFor(tiago, "lite01", hex"11", "alicebob");

        vm.startPrank(ed);
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: "alicebob", owner: ed, secret: keccak256("secret"), reserved: true
            });
        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrarController.LabelReservedForPop.selector, "alicebob"
            )
        );
        dotnsRegistrarController.register{value: 0}(registration);
        vm.stopPrank();
    }

    function test_public_register_succeeds_when_head_reservation_belongs_to_caller() public {
        // Use a NoStatus-compatible label (length ≥9 with 2 trailing digits) so the public
        // path is open regardless of PoP tier.
        _reserveFor(ed, "lite01", hex"aa", "longnamebob01");

        vm.startPrank(ed);
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: "longnamebob01", owner: ed, secret: keccak256("secret"), reserved: true
            });
        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 price = popRules.priceWithCheck("longnamebob01", ed).price;
        dotnsRegistrarController.register{value: price}(registration);
        vm.stopPrank();

        bytes32 node = _nodeOf("longnamebob01");
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(node)), ed);
    }

    function test_public_register_ignores_expired_head_reservation() public {
        _reserveFor(tiago, "lite01", hex"11", "longnamebob01");

        // Warp past reservation duration so tiago's head entry is considered expired.
        vm.warp(block.timestamp + 30 days + 1);

        vm.startPrank(ed);
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: "longnamebob01", owner: ed, secret: keccak256("secret"), reserved: true
            });
        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 price = popRules.priceWithCheck("longnamebob01", ed).price;
        dotnsRegistrarController.register{value: price}(registration);
        vm.stopPrank();

        bytes32 node = _nodeOf("longnamebob01");
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(node)), ed);
    }

    // ---------- setReservationDuration ----------

    function test_setReservationDuration_updates_value_and_emits_event() public {
        vm.expectEmit(false, false, false, true, address(dotnsRegistrarController));
        emit IDotnsRegistrarController.ReservationDurationSet(7 days);

        vm.prank(owner);
        dotnsRegistrarController.setReservationDuration(7 days);

        assertEq(dotnsRegistrarController.reservationDuration(), 7 days);
    }

    function test_setReservationDuration_reverts_for_non_owner() public {
        vm.prank(ed);
        vm.expectRevert();
        dotnsRegistrarController.setReservationDuration(7 days);
    }
}
