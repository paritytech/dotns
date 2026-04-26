// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {
    IDotnsRegistrarController
} from "../../../contracts/registrars/IDotnsRegistrarController.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {StringUtils} from "../../../contracts/utils/StringUtils.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title DotnsPopControllerFuzz
/// @notice Property-based tests for {DotnsPopController}.
/// @dev Each fuzz replaces a family of near-identical unit tests with a single
///      property assertion the fuzzer explores across inputs.
contract DotnsPopControllerFuzz is BaseDotns {
    // Decimal string of `value` padded to exactly two digits when `value < 10`.
    // Callers bound `value` to `[0, 99]` so the resulting suffix matches the
    // `NAMEXX` contract used throughout the PoP controller tests; above 99 the
    // string is still valid (digits-only) but wider than two characters.
    function _twoDigitDecimal(uint256 value) internal pure returns (string memory s) {
        if (value < 10) return string.concat("0", StringUtils.uintToString(value));
        return StringUtils.uintToString(value);
    }

    // Any well-formed `alicex.<NN>` lite label (`NN` exactly 2 digits) mints.
    // Stem `alicex` (baselength 6) keeps the label classification-valid as
    // PopLite under the PopRules classification rules. Replaces a family of
    // hand-picked suffix unit tests.
    function testFuzz_reserveBaseName_accepts_any_two_digit_suffix(uint8 suffix) public {
        suffix = uint8(bound(uint256(suffix), 0, 99));
        string memory label = string.concat("alicex", _twoDigitDecimal(uint256(suffix)));

        // Lite-tier label requires ed to hold PopLite (or PopFull) status so the
        // `priceWithCheck` guard inside the controller accepts the reservation.
        _grantPopLite(ed);

        _reservePop(ed, label, "", "");

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(label))), ed);
    }

    // Any 65-byte chat-key payload is persisted verbatim on the resolver;
    // empty payloads skip the resolver write. The resolver enforces a strict
    // 65-byte length (uncompressed secp256k1 key), so the fuzzer seeds that
    // payload via `_validChatKey` and only toggles empty-vs-set.
    function testFuzz_reserveBaseName_persists_chat_key_exact_bytes(
        uint8 suffix,
        bytes1 keySeed,
        bool useKey
    )
        public
    {
        suffix = uint8(bound(uint256(suffix), 0, 99));
        string memory label = string.concat("bobxyz", _twoDigitDecimal(uint256(suffix)));

        _grantPopLite(ed);

        bytes memory chatKey = useKey ? _validChatKey(keySeed) : bytes("");
        _reservePop(ed, label, chatKey, "");

        bytes32 node = _nodeOf(label);
        if (chatKey.length == 0) {
            assertEq(dotnsPopResolver.chatKey(node).length, 0);
        } else {
            assertEq(dotnsPopResolver.chatKey(node), chatKey);
        }
    }

    // A random stranger's public register succeeds exactly when PopRules
    // permits: if the stem is reserved for someone else, the register reverts
    // with the PopRules reservation error; otherwise it succeeds. Drives the
    // commit-reveal flow inline so the revert (if any) lands on `register`.
    function testFuzz_public_register_respects_popRules_reservation(bool reserveFirst) public {
        string memory stem = "longnamebob";
        string memory fullLabel = "longnamebob01";

        if (reserveFirst) {
            // The reserved base label `longnamebob` classifies as PopFull
            // (baselength 11 with no trailing digits); the lite label has to be
            // PopLite-eligible. Tiago needs PopFull status so both
            // `priceWithCheck` calls inside `reserveBaseName` succeed.
            _grantPopFull(tiago);
            _reservePop(tiago, LITE_LABEL_A, "", stem);
        }

        bytes32 secret = keccak256(abi.encodePacked(fullLabel, ed, block.timestamp));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: fullLabel, owner: ed, secret: secret, reserved: true
            });
        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);

        vm.prank(ed);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        if (reserveFirst) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IPopRules.PopError.selector, "Base name reserved for original Lite registrant"
                )
            );
            vm.prank(ed);
            dotnsRegistrarController.register{value: 1 ether}(registration);
        } else {
            uint256 cost = popRules.priceWithCheck(fullLabel, ed).price;
            vm.prank(ed);
            dotnsRegistrarController.register{value: cost}(registration);
            assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(fullLabel))), ed);
        }
    }

    // `isReservedForClaim` tracks the `joinedAt + duration` boundary for
    // the queue head across the full duration/elapsed space.
    function testFuzz_isReservedForClaim_tracks_duration_boundary(
        uint64 duration,
        uint64 elapsed
    )
        public
    {
        duration = uint64(bound(uint256(duration), 1, 365 days));
        elapsed = uint64(bound(uint256(elapsed), 0, 365 days));

        vm.prank(owner);
        dotnsPopController.setReservationDuration(duration);

        // Reserving `BASE_LABEL_A` (PopFull classification) alongside the
        // lite leg requires ed to hold PopFull status so both `priceWithCheck`
        // calls succeed.
        _grantPopFull(ed);
        _reservePop(ed, LITE_LABEL_A, "", BASE_LABEL_A);

        vm.warp(block.timestamp + uint256(elapsed));

        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(BASE_LABEL_A);
        if (uint256(elapsed) < uint256(duration)) {
            assertTrue(reserved);
            assertEq(holder, ed);
        } else {
            assertFalse(reserved);
            assertEq(holder, address(0));
        }
    }
}
