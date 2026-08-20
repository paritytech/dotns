// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsPopResolver} from "../../../contracts/resolvers/IDotnsPopResolver.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";

/// @title DotnsPopResolverTests
/// @notice Behavioural unit tests for @custom:contract DotnsPopResolver. Coverage of byte-exact
///         persistence across arbitrary payloads lives in the PoP-controller fuzz
///         file; here we only assert behaviour that is not a default-value check
///         or a tautological storage-read.
contract DotnsPopResolverTests is BaseDotns {
    function test_setChatKey_writes_and_emits() public {
        bytes32 node = _nodeOf("alice42");
        bytes memory chatKey = _validChatKey(0x04);

        vm.prank(address(dotnsPopController));
        vm.expectEmit(true, false, false, true);
        emit IDotnsPopResolver.ChatKeyUpdated(node, chatKey);
        dotnsPopResolver.setChatKey(node, chatKey);

        assertEq(dotnsPopResolver.chatKey(node), chatKey);
    }

    function test_setChatKey_reverts_for_unauthorised_caller() public {
        // Auth runs before the length check, so even a valid 65-byte payload
        // from an unauthorised caller must revert with `NotPopController`.
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsPopResolver.NotPopController.selector, ed));
        dotnsPopResolver.setChatKey(_nodeOf("alice42"), _validChatKey(0x04));
    }

    function test_setLiteLink_writes_and_emits() public {
        bytes32 fullNode = _nodeOf("alice");
        bytes32 liteLabelhash = keccak256(bytes("alice42"));

        vm.prank(address(dotnsPopController));
        vm.expectEmit(true, true, false, false);
        emit IDotnsPopResolver.LiteLinkUpdated(fullNode, liteLabelhash);
        dotnsPopResolver.setLiteLink(fullNode, liteLabelhash);
        // Both directions must be populated by a single write: forward
        // (full => lite) and reverse (lite => full). The reverse index is what
        // downstream consumers (Nova) use to answer "given this lite username,
        // which full name did they claim?".
        assertEq(dotnsPopResolver.liteLink(fullNode), liteLabelhash);
        assertEq(dotnsPopResolver.fullClaim(liteLabelhash), fullNode);
    }

    function test_setLiteLink_reverts_for_unauthorised_caller() public {
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsPopResolver.NotPopController.selector, ed));
        dotnsPopResolver.setLiteLink(_nodeOf("alice"), keccak256(bytes("alice42")));
    }

    function test_setChatKey_accepts_zero_node_as_passthrough() public {
        // `node` is never guarded against `bytes32(0)`: the PoP controller
        // validates labels before calling through, so the only way to reach a
        // zero-node write is for the controller itself to regress. Pin the
        // passthrough semantics so any future validator lands as a diff here.
        bytes memory key = _validChatKey(0x04);
        // Same passthrough expectation on the two-arg writer. Writing
        // (0, 0) must not revert and must populate both forward and reverse
        // indexes at the zero key.
        vm.prank(address(dotnsPopController));
        dotnsPopResolver.setChatKey(bytes32(0), key);
        assertEq(dotnsPopResolver.chatKey(bytes32(0)), key);
    }

    function test_setLiteLink_accepts_zero_inputs_as_passthrough() public {
        vm.prank(address(dotnsPopController));
        dotnsPopResolver.setLiteLink(bytes32(0), bytes32(0));
        assertEq(dotnsPopResolver.liteLink(bytes32(0)), bytes32(0));
        assertEq(dotnsPopResolver.fullClaim(bytes32(0)), bytes32(0));
    }

    function test_rotating_pop_controller_changes_authorised_writer() public {
        address replacement = makeAddr("replacement");
        bytes32 key = DotnsConstants.POP_CONTROLLER;

        vm.prank(owner);
        protocolRegistry.set(key, replacement);

        bytes memory first = _validChatKey(0x04);
        bytes memory second = _validChatKey(0x02);

        vm.prank(address(dotnsPopController));
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsPopResolver.NotPopController.selector, address(dotnsPopController)
            )
        );
        dotnsPopResolver.setChatKey(_nodeOf("alice42"), first);

        vm.prank(replacement);
        dotnsPopResolver.setChatKey(_nodeOf("alice42"), second);
        assertEq(dotnsPopResolver.chatKey(_nodeOf("alice42")), second);
    }

    function test_setChatKey_accepts_exactly_65_bytes() public {
        // Canonical uncompressed secp256k1 shape: 0x04 prefix, 32 X, 32 Y.
        bytes32 node = _nodeOf("alice42");
        bytes memory key = _validChatKey(0x04);

        vm.prank(address(dotnsPopController));
        dotnsPopResolver.setChatKey(node, key);

        assertEq(dotnsPopResolver.chatKey(node), key);
        assertEq(dotnsPopResolver.chatKey(node).length, 65);
    }

    function test_setChatKey_reverts_for_empty_payload() public {
        bytes memory key = new bytes(0);

        vm.prank(address(dotnsPopController));
        vm.expectRevert(abi.encodeWithSelector(IDotnsPopResolver.InvalidChatKeyLength.selector, 0));
        dotnsPopResolver.setChatKey(_nodeOf("alice42"), key);
    }

    function test_setChatKey_reverts_for_one_byte_payload() public {
        bytes memory key = new bytes(1);

        vm.prank(address(dotnsPopController));
        vm.expectRevert(abi.encodeWithSelector(IDotnsPopResolver.InvalidChatKeyLength.selector, 1));
        dotnsPopResolver.setChatKey(_nodeOf("alice42"), key);
    }

    function test_setChatKey_reverts_for_64_byte_payload() public {
        // One byte short of the uncompressed encoding: missing prefix.
        bytes memory key = new bytes(64);

        vm.prank(address(dotnsPopController));
        vm.expectRevert(abi.encodeWithSelector(IDotnsPopResolver.InvalidChatKeyLength.selector, 64));
        dotnsPopResolver.setChatKey(_nodeOf("alice42"), key);
    }

    function test_setChatKey_reverts_for_66_byte_payload() public {
        // One byte over: an attacker-controlled suffix that must not be stored.
        bytes memory key = new bytes(66);

        vm.prank(address(dotnsPopController));
        vm.expectRevert(abi.encodeWithSelector(IDotnsPopResolver.InvalidChatKeyLength.selector, 66));
        dotnsPopResolver.setChatKey(_nodeOf("alice42"), key);
    }

    function test_setChatKey_reverts_for_large_griefing_payload() public {
        // A 1024-byte payload is a cheap griefing vector against storage-copy
        // gas; the length guard must reject it before the SSTORE.
        bytes memory key = new bytes(1024);

        vm.prank(address(dotnsPopController));
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsPopResolver.InvalidChatKeyLength.selector, 1024)
        );
        dotnsPopResolver.setChatKey(_nodeOf("alice42"), key);
    }

    function test_setChatKey_auth_check_runs_before_length_check() public {
        // Unauthorised caller + valid 65-byte payload still reverts on auth.
        // Pinning the order of checks so that a future reorder lands as a diff.
        bytes memory key = _validChatKey(0x04);

        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsPopResolver.NotPopController.selector, ed));
        dotnsPopResolver.setChatKey(_nodeOf("alice42"), key);
    }

    function test_setChatKey_auth_check_precedes_length_check_on_bad_payload() public {
        // And the same with a clearly invalid payload: auth wins over length.
        bytes memory key = new bytes(0);

        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsPopResolver.NotPopController.selector, ed));
        dotnsPopResolver.setChatKey(_nodeOf("alice42"), key);
    }

    function test_setLiteLink_same_full_node_relink_clears_old_reverse() public {
        bytes32 fullA = _nodeOf("alice");
        bytes32 liteX = keccak256(bytes("alice42"));
        bytes32 liteY = keccak256(bytes("alice99"));

        vm.startPrank(address(dotnsPopController));
        dotnsPopResolver.setLiteLink(fullA, liteX);
        dotnsPopResolver.setLiteLink(fullA, liteY);
        vm.stopPrank();
        // Old reverse must be cleared so downstream consumers stop resolving
        // `liteX` to `fullA`.
        assertEq(dotnsPopResolver.fullClaim(liteX), bytes32(0));
        // New pair round-trips cleanly.
        assertEq(dotnsPopResolver.liteLink(fullA), liteY);
        assertEq(dotnsPopResolver.fullClaim(liteY), fullA);
    }

    function test_setLiteLink_same_lite_relink_clears_old_forward() public {
        bytes32 fullA = _nodeOf("alice");
        bytes32 fullB = _nodeOf("bob");
        bytes32 liteX = keccak256(bytes("alice42"));

        vm.startPrank(address(dotnsPopController));
        dotnsPopResolver.setLiteLink(fullA, liteX);
        dotnsPopResolver.setLiteLink(fullB, liteX);
        vm.stopPrank();
        // Old forward must be cleared so `fullA` no longer claims `liteX`.
        assertEq(dotnsPopResolver.liteLink(fullA), bytes32(0));
        // New pair round-trips.
        assertEq(dotnsPopResolver.liteLink(fullB), liteX);
        assertEq(dotnsPopResolver.fullClaim(liteX), fullB);
    }

    function test_setLiteLink_idempotent_relink_keeps_both_indices() public {
        bytes32 fullA = _nodeOf("alice");
        bytes32 liteX = keccak256(bytes("alice42"));

        vm.startPrank(address(dotnsPopController));
        dotnsPopResolver.setLiteLink(fullA, liteX);
        dotnsPopResolver.setLiteLink(fullA, liteX);
        vm.stopPrank();
        // Writing the same pair twice must not accidentally delete either
        // side: the `oldLite == liteLabelhash` and `oldFull == fullNode`
        // guards in the implementation are the things under test here.
        assertEq(dotnsPopResolver.liteLink(fullA), liteX);
        assertEq(dotnsPopResolver.fullClaim(liteX), fullA);
    }

    function test_setLiteLink_chain_returns_to_original_without_drift() public {
        bytes32 fullA = _nodeOf("alice");
        bytes32 liteX = keccak256(bytes("alice42"));
        bytes32 liteY = keccak256(bytes("alice99"));

        vm.startPrank(address(dotnsPopController));
        dotnsPopResolver.setLiteLink(fullA, liteX);
        dotnsPopResolver.setLiteLink(fullA, liteY);
        dotnsPopResolver.setLiteLink(fullA, liteX);
        vm.stopPrank();
        // After A -> X -> Y -> X, only the (A, X) pair survives.
        assertEq(dotnsPopResolver.liteLink(fullA), liteX);
        assertEq(dotnsPopResolver.fullClaim(liteX), fullA);
        assertEq(dotnsPopResolver.fullClaim(liteY), bytes32(0));
    }

    function test_setLiteLink_cross_chain_no_drift() public {
        bytes32 fullA = _nodeOf("alice");
        bytes32 fullB = _nodeOf("bob");
        bytes32 liteX = keccak256(bytes("alice42"));

        vm.startPrank(address(dotnsPopController));
        dotnsPopResolver.setLiteLink(fullA, liteX);
        dotnsPopResolver.setLiteLink(fullB, liteX);
        vm.stopPrank();
        // A must no longer appear as a claimant of anything, only B.
        assertEq(dotnsPopResolver.liteLink(fullA), bytes32(0));
        assertEq(dotnsPopResolver.liteLink(fullB), liteX);
        assertEq(dotnsPopResolver.fullClaim(liteX), fullB);
    }

    function test_setLiteLink_quadrangle_clears_both_stale_inverses() public {
        bytes32 fullA = _nodeOf("alice");
        bytes32 fullB = _nodeOf("bob");
        bytes32 liteX = keccak256(bytes("alice42"));
        bytes32 liteY = keccak256(bytes("bob42"));

        vm.startPrank(address(dotnsPopController));
        dotnsPopResolver.setLiteLink(fullA, liteX);
        dotnsPopResolver.setLiteLink(fullB, liteY);
        dotnsPopResolver.setLiteLink(fullA, liteY);
        vm.stopPrank();
        // After (A,X), (B,Y), (A,Y): only (A,Y) remains. B's forward link
        // and X's reverse link must both be cleared.
        assertEq(dotnsPopResolver.liteLink(fullA), liteY);
        assertEq(dotnsPopResolver.liteLink(fullB), bytes32(0));
        assertEq(dotnsPopResolver.fullClaim(liteY), fullA);
        assertEq(dotnsPopResolver.fullClaim(liteX), bytes32(0));
    }

    function test_setLiteLink_with_zero_lite_is_passthrough() public {
        bytes32 fullA = _nodeOf("alice");
        // Pin current behaviour for the zero-hash edge: the setter does not
        // revert on a zero `liteLabelhash` and writes both indices at the
        // zero key. Any future validator that rejects zero inputs lands
        // here as a failing assertion.
        vm.prank(address(dotnsPopController));
        dotnsPopResolver.setLiteLink(fullA, bytes32(0));

        assertEq(dotnsPopResolver.liteLink(fullA), bytes32(0));
        assertEq(dotnsPopResolver.fullClaim(bytes32(0)), fullA);
    }

    function test_setLiteLink_long_chain_invariant_holds_at_every_step() public {
        // Ten sequential re-links of the same `fullNode` to fresh lite
        // labelhashes. At each step the forward and reverse indices must
        // round-trip for the current pair, and the previous lite's reverse
        // entry must have been cleared.
        bytes32 fullA = _nodeOf("alice");
        bytes32 previousLite = bytes32(0);

        vm.startPrank(address(dotnsPopController));
        for (uint256 i = 1; i <= 10; i++) {
            bytes32 currentLite = keccak256(abi.encodePacked("alice", i));
            dotnsPopResolver.setLiteLink(fullA, currentLite);
            // Current pair round-trips.
            assertEq(dotnsPopResolver.liteLink(fullA), currentLite);
            assertEq(dotnsPopResolver.fullClaim(currentLite), fullA);
            // Previous reverse entry was nulled.
            if (previousLite != bytes32(0)) {
                assertEq(dotnsPopResolver.fullClaim(previousLite), bytes32(0));
            }

            previousLite = currentLite;
        }
        vm.stopPrank();
    }

    function test_setLiteLink_old_lite_reads_zero_after_relink() public {
        // Integration-shaped assertion: a consumer that cached the old lite
        // hash and later queries `fullClaim` must see `bytes32(0)`, not a
        // stale fullNode.
        bytes32 fullA = _nodeOf("alice");
        bytes32 liteX = keccak256(bytes("alice42"));
        bytes32 liteY = keccak256(bytes("alice99"));

        vm.startPrank(address(dotnsPopController));
        dotnsPopResolver.setLiteLink(fullA, liteX);
        dotnsPopResolver.setLiteLink(fullA, liteY);
        vm.stopPrank();

        assertEq(dotnsPopResolver.fullClaim(liteX), bytes32(0));
    }
    // 65-byte chat-key helper now lives on BaseDotns as `_validChatKey`.
}
