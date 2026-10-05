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

    function test_setDeviceLink_writes_and_emits() public {
        bytes32 personhoodNode = _nodeOf("alice");
        bytes32 deviceLabelhash = keccak256(bytes("alice42"));

        vm.prank(address(dotnsPopController));
        vm.expectEmit(true, true, false, false);
        emit IDotnsPopResolver.DeviceLinkUpdated(personhoodNode, deviceLabelhash);
        dotnsPopResolver.setDeviceLink(personhoodNode, deviceLabelhash);
        // Both directions must be populated by a single write: forward
        // (personhood => device) and reverse (device => personhood). The reverse index is what
        // downstream consumers (Nova) use to answer "given this device name,
        // which personhood name did they claim?".
        assertEq(dotnsPopResolver.deviceLabelhashOf(personhoodNode), deviceLabelhash);
        assertEq(dotnsPopResolver.personhoodNodeOf(deviceLabelhash), personhoodNode);
    }

    function test_setDeviceLink_reverts_for_unauthorised_caller() public {
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsPopResolver.NotPopController.selector, ed));
        dotnsPopResolver.setDeviceLink(_nodeOf("alice"), keccak256(bytes("alice42")));
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

    function test_setDeviceLink_accepts_zero_inputs_as_passthrough() public {
        vm.prank(address(dotnsPopController));
        dotnsPopResolver.setDeviceLink(bytes32(0), bytes32(0));
        assertEq(dotnsPopResolver.deviceLabelhashOf(bytes32(0)), bytes32(0));
        assertEq(dotnsPopResolver.personhoodNodeOf(bytes32(0)), bytes32(0));
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

    function test_setDeviceLink_same_personhood_node_relink_clears_old_reverse() public {
        bytes32 personhoodA = _nodeOf("alice");
        bytes32 deviceX = keccak256(bytes("alice42"));
        bytes32 deviceY = keccak256(bytes("alice99"));

        vm.startPrank(address(dotnsPopController));
        dotnsPopResolver.setDeviceLink(personhoodA, deviceX);
        dotnsPopResolver.setDeviceLink(personhoodA, deviceY);
        vm.stopPrank();
        // Old reverse must be cleared so downstream consumers stop resolving
        // `deviceX` to `personhoodA`.
        assertEq(dotnsPopResolver.personhoodNodeOf(deviceX), bytes32(0));
        // New pair round-trips cleanly.
        assertEq(dotnsPopResolver.deviceLabelhashOf(personhoodA), deviceY);
        assertEq(dotnsPopResolver.personhoodNodeOf(deviceY), personhoodA);
    }

    function test_setDeviceLink_same_device_relink_clears_old_forward() public {
        bytes32 personhoodA = _nodeOf("alice");
        bytes32 personhoodB = _nodeOf("bob");
        bytes32 deviceX = keccak256(bytes("alice42"));

        vm.startPrank(address(dotnsPopController));
        dotnsPopResolver.setDeviceLink(personhoodA, deviceX);
        dotnsPopResolver.setDeviceLink(personhoodB, deviceX);
        vm.stopPrank();
        // Old forward must be cleared so `personhoodA` no longer claims `deviceX`.
        assertEq(dotnsPopResolver.deviceLabelhashOf(personhoodA), bytes32(0));
        // New pair round-trips.
        assertEq(dotnsPopResolver.deviceLabelhashOf(personhoodB), deviceX);
        assertEq(dotnsPopResolver.personhoodNodeOf(deviceX), personhoodB);
    }

    function test_setDeviceLink_idempotent_relink_keeps_both_indices() public {
        bytes32 personhoodA = _nodeOf("alice");
        bytes32 deviceX = keccak256(bytes("alice42"));

        vm.startPrank(address(dotnsPopController));
        dotnsPopResolver.setDeviceLink(personhoodA, deviceX);
        dotnsPopResolver.setDeviceLink(personhoodA, deviceX);
        vm.stopPrank();
        // Writing the same pair twice must not accidentally delete either
        // side: the `oldDevice == deviceLabelhash` and `oldPersonhood == personhoodNode`
        // guards in the implementation are the things under test here.
        assertEq(dotnsPopResolver.deviceLabelhashOf(personhoodA), deviceX);
        assertEq(dotnsPopResolver.personhoodNodeOf(deviceX), personhoodA);
    }

    function test_setDeviceLink_chain_returns_to_original_without_drift() public {
        bytes32 personhoodA = _nodeOf("alice");
        bytes32 deviceX = keccak256(bytes("alice42"));
        bytes32 deviceY = keccak256(bytes("alice99"));

        vm.startPrank(address(dotnsPopController));
        dotnsPopResolver.setDeviceLink(personhoodA, deviceX);
        dotnsPopResolver.setDeviceLink(personhoodA, deviceY);
        dotnsPopResolver.setDeviceLink(personhoodA, deviceX);
        vm.stopPrank();
        // After A -> X -> Y -> X, only the (A, X) pair survives.
        assertEq(dotnsPopResolver.deviceLabelhashOf(personhoodA), deviceX);
        assertEq(dotnsPopResolver.personhoodNodeOf(deviceX), personhoodA);
        assertEq(dotnsPopResolver.personhoodNodeOf(deviceY), bytes32(0));
    }

    function test_setDeviceLink_cross_chain_no_drift() public {
        bytes32 personhoodA = _nodeOf("alice");
        bytes32 personhoodB = _nodeOf("bob");
        bytes32 deviceX = keccak256(bytes("alice42"));

        vm.startPrank(address(dotnsPopController));
        dotnsPopResolver.setDeviceLink(personhoodA, deviceX);
        dotnsPopResolver.setDeviceLink(personhoodB, deviceX);
        vm.stopPrank();
        // A must no longer appear as a claimant of anything, only B.
        assertEq(dotnsPopResolver.deviceLabelhashOf(personhoodA), bytes32(0));
        assertEq(dotnsPopResolver.deviceLabelhashOf(personhoodB), deviceX);
        assertEq(dotnsPopResolver.personhoodNodeOf(deviceX), personhoodB);
    }

    function test_setDeviceLink_quadrangle_clears_both_stale_inverses() public {
        bytes32 personhoodA = _nodeOf("alice");
        bytes32 personhoodB = _nodeOf("bob");
        bytes32 deviceX = keccak256(bytes("alice42"));
        bytes32 deviceY = keccak256(bytes("bob42"));

        vm.startPrank(address(dotnsPopController));
        dotnsPopResolver.setDeviceLink(personhoodA, deviceX);
        dotnsPopResolver.setDeviceLink(personhoodB, deviceY);
        dotnsPopResolver.setDeviceLink(personhoodA, deviceY);
        vm.stopPrank();
        // After (A,X), (B,Y), (A,Y): only (A,Y) remains. B's forward link
        // and X's reverse link must both be cleared.
        assertEq(dotnsPopResolver.deviceLabelhashOf(personhoodA), deviceY);
        assertEq(dotnsPopResolver.deviceLabelhashOf(personhoodB), bytes32(0));
        assertEq(dotnsPopResolver.personhoodNodeOf(deviceY), personhoodA);
        assertEq(dotnsPopResolver.personhoodNodeOf(deviceX), bytes32(0));
    }

    function test_setDeviceLink_with_zero_device_is_passthrough() public {
        bytes32 personhoodA = _nodeOf("alice");
        // Pin current behaviour for the zero-hash edge: the setter does not
        // revert on a zero `deviceLabelhash` and writes both indices at the
        // zero key. Any future validator that rejects zero inputs lands
        // here as a failing assertion.
        vm.prank(address(dotnsPopController));
        dotnsPopResolver.setDeviceLink(personhoodA, bytes32(0));

        assertEq(dotnsPopResolver.deviceLabelhashOf(personhoodA), bytes32(0));
        assertEq(dotnsPopResolver.personhoodNodeOf(bytes32(0)), personhoodA);
    }

    function test_setDeviceLink_long_chain_invariant_holds_at_every_step() public {
        // Ten sequential re-links of the same `personhoodNode` to fresh device-name
        // labelhashes. At each step the forward and reverse indices must
        // round-trip for the current pair, and the previous device name's reverse
        // entry must have been cleared.
        bytes32 personhoodA = _nodeOf("alice");
        bytes32 previousDevice = bytes32(0);

        vm.startPrank(address(dotnsPopController));
        for (uint256 i = 1; i <= 10; i++) {
            bytes32 currentDevice = keccak256(abi.encodePacked("alice", i));
            dotnsPopResolver.setDeviceLink(personhoodA, currentDevice);
            // Current pair round-trips.
            assertEq(dotnsPopResolver.deviceLabelhashOf(personhoodA), currentDevice);
            assertEq(dotnsPopResolver.personhoodNodeOf(currentDevice), personhoodA);
            // Previous reverse entry was nulled.
            if (previousDevice != bytes32(0)) {
                assertEq(dotnsPopResolver.personhoodNodeOf(previousDevice), bytes32(0));
            }

            previousDevice = currentDevice;
        }
        vm.stopPrank();
    }

    function test_setDeviceLink_old_device_reads_zero_after_relink() public {
        // Integration-shaped assertion: a consumer that cached the old device-name
        // hash and later queries `personhoodNodeOf` must see `bytes32(0)`, not a
        // stale personhoodNode.
        bytes32 personhoodA = _nodeOf("alice");
        bytes32 deviceX = keccak256(bytes("alice42"));
        bytes32 deviceY = keccak256(bytes("alice99"));

        vm.startPrank(address(dotnsPopController));
        dotnsPopResolver.setDeviceLink(personhoodA, deviceX);
        dotnsPopResolver.setDeviceLink(personhoodA, deviceY);
        vm.stopPrank();

        assertEq(dotnsPopResolver.personhoodNodeOf(deviceX), bytes32(0));
    }
    // 65-byte chat-key helper now lives on BaseDotns as `_validChatKey`.
}
