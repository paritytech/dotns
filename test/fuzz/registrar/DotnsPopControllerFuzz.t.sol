// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {
    IDotnsRegistrarController
} from "../../../contracts/registrars/IDotnsRegistrarController.sol";
import {IDotnsPopController} from "../../../contracts/registrars/IDotnsPopController.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {StringUtils} from "../../../contracts/utils/StringUtils.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Vm} from "forge-std/Vm.sol";

// @title DotnsPopControllerFuzz
// @notice Property-based tests for {DotnsPopController}.
// @dev Each fuzz replaces a family of near-identical unit tests with a single
//      property assertion the fuzzer explores across inputs.
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

    function testFuzz_reserveLiteName_overloads_equivalent(uint8 suffix, bytes1 keySeed) public {
        suffix = uint8(bound(uint256(suffix), 0, 99));
        string memory liteLabel = string.concat("dualli", _twoDigitDecimal(uint256(suffix)));
        bytes memory chatKey = _validChatKey(keySeed);

        _grantPopLite(ed);

        IDotnsPopController.LiteRegistration memory params = IDotnsPopController.LiteRegistration({
            liteLabel: liteLabel, user: ed, chatKey: chatKey
        });

        bytes32 node = _nodeOf(liteLabel);
        // Snapshot the world once and run both dispatch paths from the same starting
        // state; post-state and full event log must match for the typed and bytes
        // overloads to be observably equivalent.
        uint256 baseline = vm.snapshotState();

        vm.recordLogs();
        vm.prank(popGateway);
        dotnsPopController.reserveLiteName(params);
        Vm.Log[] memory typedLogs = vm.getRecordedLogs();
        address typedOwner = IERC721(address(dotnsRegistrar)).ownerOf(uint256(node));
        bytes memory typedKey = dotnsPopResolver.chatKey(node);

        vm.revertToState(baseline);

        vm.recordLogs();
        vm.prank(popGateway);
        dotnsPopController.reserveLiteName(abi.encode(params));
        Vm.Log[] memory bytesLogs = vm.getRecordedLogs();

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(node)), typedOwner);
        assertEq(dotnsPopResolver.chatKey(node), typedKey);
        _assertLogsEqual(typedLogs, bytesLogs);
    }

    function testFuzz_reserveBaseName_overloads_equivalent(
        uint8 suffix,
        bytes1 keySeed,
        bool useReservation
    )
        public
    {
        suffix = uint8(bound(uint256(suffix), 0, 99));
        string memory liteLabel = string.concat("dualbs", _twoDigitDecimal(uint256(suffix)));
        bytes memory chatKey = _validChatKey(keySeed);
        // `useReservation` toggles between the lite-only branch and the lite-plus-
        // reservation branch so both legs of the entrypoint are exercised.
        string memory reservedBase = useReservation ? BASE_LABEL_A : "";

        // PopFull covers both legs: the lite label requires PopLite-or-Full and
        // the base label (PopFull-classified) requires PopFull.
        _grantPopFull(ed);

        IDotnsPopController.BaseReservation memory params = IDotnsPopController.BaseReservation({
            lite: IDotnsPopController.LiteRegistration({
                liteLabel: liteLabel, user: ed, chatKey: chatKey
            }),
            reservedBaseLabel: reservedBase
        });

        bytes32 liteNode = _nodeOf(liteLabel);
        bytes32 reservedHash = useReservation ? keccak256(bytes(reservedBase)) : bytes32(0);
        uint256 baseline = vm.snapshotState();

        vm.recordLogs();
        vm.prank(popGateway);
        dotnsPopController.reserveBaseName(params);
        Vm.Log[] memory typedLogs = vm.getRecordedLogs();
        address typedOwner = IERC721(address(dotnsRegistrar)).ownerOf(uint256(liteNode));
        bytes memory typedKey = dotnsPopResolver.chatKey(liteNode);
        IDotnsPopController.UserReservation memory typedUserRes =
            dotnsPopController.userReservation(ed);
        (uint64 typedHead, uint64 typedTail) = useReservation
            ? dotnsPopController.reservationMeta(reservedHash)
            : (uint64(0), uint64(0));

        vm.revertToState(baseline);

        vm.recordLogs();
        vm.prank(popGateway);
        dotnsPopController.reserveBaseName(abi.encode(params));
        Vm.Log[] memory bytesLogs = vm.getRecordedLogs();

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(liteNode)), typedOwner);
        assertEq(dotnsPopResolver.chatKey(liteNode), typedKey);
        IDotnsPopController.UserReservation memory bytesUserRes =
            dotnsPopController.userReservation(ed);
        assertEq(bytesUserRes.labelhash, typedUserRes.labelhash);
        assertEq(uint256(bytesUserRes.index), uint256(typedUserRes.index));
        if (useReservation) {
            (uint64 bytesHead, uint64 bytesTail) = dotnsPopController.reservationMeta(reservedHash);
            assertEq(bytesHead, typedHead);
            assertEq(bytesTail, typedTail);
        }
        _assertLogsEqual(typedLogs, bytesLogs);
    }

    function testFuzz_registerBaseName_overloads_equivalent(
        uint8 suffix,
        bytes1 keySeed,
        bool useLiteLink
    )
        public
    {
        suffix = uint8(bound(uint256(suffix), 0, 99));
        // Stem `dualbase` (baselength 8) plus a 2-digit suffix classifies as PopLite,
        // so a single `_grantPopLite(ed)` covers both classification gates the
        // entrypoint runs. `useLiteLink` toggles between the `None` (fresh chat key)
        // and `LiteUsername` (inherit from prior lite) branches.
        string memory baseLabel = string.concat("dualbase", _twoDigitDecimal(uint256(suffix)));
        bytes memory chatKey = _validChatKey(keySeed);

        _grantPopLite(ed);

        // Pre-register a lite label so the LiteUsername-link branch has a
        // node to inherit a chat key from. Skipped for the None branch so
        // the two branches stay isolated under fuzzing.
        IDotnsPopController.Link memory link;
        if (useLiteLink) {
            vm.prank(popGateway);
            dotnsPopController.reserveLiteName(
                IDotnsPopController.LiteRegistration({
                    liteLabel: LITE_LABEL_A, user: ed, chatKey: chatKey
                })
            );
            link = IDotnsPopController.Link({
                kind: IDotnsPopController.LinkKind.LiteUsername,
                liteLabel: LITE_LABEL_A,
                chatKey: ""
            });
        } else {
            link = IDotnsPopController.Link({
                kind: IDotnsPopController.LinkKind.None, liteLabel: "", chatKey: chatKey
            });
        }

        IDotnsPopController.FullRegistration memory params =
            IDotnsPopController.FullRegistration({label: baseLabel, user: ed, link: link});

        bytes32 baseNode = _nodeOf(baseLabel);
        uint256 baseline = vm.snapshotState();

        vm.recordLogs();
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(params);
        Vm.Log[] memory typedLogs = vm.getRecordedLogs();
        address typedOwner = IERC721(address(dotnsRegistrar)).ownerOf(uint256(baseNode));
        bytes memory typedKey = dotnsPopResolver.chatKey(baseNode);
        bytes32 typedLiteLink = dotnsPopResolver.liteLink(baseNode);

        vm.revertToState(baseline);

        vm.recordLogs();
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(abi.encode(params));
        Vm.Log[] memory bytesLogs = vm.getRecordedLogs();

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(baseNode)), typedOwner);
        assertEq(dotnsPopResolver.chatKey(baseNode), typedKey);
        assertEq(dotnsPopResolver.liteLink(baseNode), typedLiteLink);
        // Event equivalence catches axis-classification drift between the two
        // paths (e.g. one path emitting `BaseNameClaimed` while the other
        // emits `StandaloneNameRegistered` would be a regression).
        _assertLogsEqual(typedLogs, bytesLogs);
    }

    function _assertLogsEqual(Vm.Log[] memory a, Vm.Log[] memory b) internal {
        // Compares two recorded log arrays element-wise so any divergence (count,
        // ordering, emitter, topics, or unindexed payload) fails the test.
        assertEq(a.length, b.length, "log count mismatch");
        for (uint256 i = 0; i < a.length; ++i) {
            assertEq(a[i].emitter, b[i].emitter, "log emitter mismatch");
            assertEq(a[i].topics.length, b[i].topics.length, "log topic count mismatch");
            for (uint256 t = 0; t < a[i].topics.length; ++t) {
                assertEq(a[i].topics[t], b[i].topics[t], "log topic mismatch");
            }
            assertEq(keccak256(a[i].data), keccak256(b[i].data), "log data mismatch");
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
