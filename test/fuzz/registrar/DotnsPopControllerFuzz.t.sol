// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {
    IDotnsRegistrarController
} from "../../../contracts/registrars/IDotnsRegistrarController.sol";
import {IDotnsPopController} from "../../../contracts/registrars/IDotnsPopController.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {ILabelStore} from "../../../contracts/store/ILabelStore.sol";
import {StringUtils} from "../../../contracts/utils/StringUtils.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DotnsPopControllerFuzz
/// @notice Property-based tests for @custom:contract DotnsPopController.
/// @dev Each fuzz replaces a family of near-identical unit tests with a single
///      property assertion the fuzzer explores across inputs.
contract DotnsPopControllerFuzz is BaseDotns {
    // Render `value` as a decimal string padded to at least two digits. Callers bound
    // `value` to `[0, 99]` so the resulting suffix matches the `NAMEXX` contract used
    // throughout the PoP controller tests.
    function _twoDigitDecimal(uint256 value) internal pure returns (string memory s) {
        if (value < 10) {
            return string.concat("0", StringUtils.uintToString(value));
        }
        return StringUtils.uintToString(value);
    }

    function testFuzz_reserveBaseName_accepts_any_two_digit_suffix(uint8 suffix) public {
        suffix = uint8(bound(uint256(suffix), 0, 99));
        string memory label = string.concat("alicex", _twoDigitDecimal(uint256(suffix)));

        // Lite-tier label requires ed to hold PopLite (or PopFull) status so the
        // `priceWithCheck` guard inside the controller accepts the reservation.
        _grantPopLite(ed);

        _reservePop(ed, label, "", "");

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(label))), ed);
    }

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

    function testFuzz_public_register_respects_popRules_reservation(bool reserveFirst) public {
        string memory stem = "longnamebob";
        string memory fullLabel = "longnamebob01";

        if (reserveFirst) {
            // The reserved base label `longnamebob` classifies as NoStatus
            // (baselength 11); the lite label has to be PopLite-eligible. Tiago needs
            // PopFull status so both `priceWithCheck` calls inside `reserveBaseName`
            // succeed.
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
        string memory digits = _twoDigitDecimal(uint256(suffix));
        // The gateway-facing entry point accepts the dotted `stem.digits` shape; the
        // on-chain stored label is the dot-stripped flat form.
        string memory liteLabelDotted = string.concat("dualli.", digits);
        string memory liteLabelFlat = string.concat("dualli", digits);
        bytes memory chatKey = _validChatKey(keySeed);

        _grantPopLite(ed);

        IDotnsPopController.LiteRegistration memory params = IDotnsPopController.LiteRegistration({
            liteLabel: liteLabelDotted, user: ed, chatKey: chatKey
        });

        bytes32 node = _nodeOf(liteLabelFlat);
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
        string memory digits = _twoDigitDecimal(uint256(suffix));
        // Gateway-facing dotted shape; flat form drives the on-chain node lookup.
        string memory liteLabelDotted = string.concat("dualbs.", digits);
        string memory liteLabelFlat = string.concat("dualbs", digits);
        bytes memory chatKey = _validChatKey(keySeed);
        // `useReservation` toggles between the lite-only branch and the lite-plus-
        // reservation branch so both legs of the entrypoint are exercised.
        string memory reservedBase = useReservation ? BASE_LABEL_A : "";

        // PopFull covers both legs: the lite label requires PopLite-or-Full and
        // the base label (PopFull-classified) requires PopFull.
        _grantPopFull(ed);

        IDotnsPopController.BaseReservation memory params = IDotnsPopController.BaseReservation({
            lite: IDotnsPopController.LiteRegistration({
                liteLabel: liteLabelDotted, user: ed, chatKey: chatKey
            }),
            reservedBaseLabel: reservedBase
        });

        bytes32 liteNode = _nodeOf(liteLabelFlat);
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
        // Stem `longnamebob` (stem length above the PopLite ceiling) plus a 2-digit suffix
        // classifies as NoStatus, the legitimate inhabitant of the base-name path. The
        // `useLiteLink` toggle picks between the `None` (fresh chat key) and `LiteUsername`
        // (inherit from prior lite) branches.
        string memory baseLabel = string.concat("longnamebob", _twoDigitDecimal(uint256(suffix)));
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
                    liteLabel: LITE_LABEL_A_DOTTED, user: ed, chatKey: chatKey
                })
            );
            vm.prank(ed);
            dotnsPopController.claimLabelStore();
            link = IDotnsPopController.Link({
                kind: IDotnsPopController.LinkKind.LiteUsername,
                liteLabel: LITE_LABEL_A_DOTTED,
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

    /// @notice Assert that two recorded log arrays are element-wise identical.
    /// @dev Compares count, ordering, emitter, topics and unindexed payload; any divergence
    ///      fails the test.
    function _assertLogsEqual(Vm.Log[] memory a, Vm.Log[] memory b) internal {
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

    function testFuzz_isReservedForClaim_tracks_duration_boundary(
        uint64 duration,
        uint64 elapsed
    )
        public
    {
        duration = uint64(
            bound(
                uint256(duration), uint256(dotnsPopController.MIN_RESERVATION_DURATION()), 365 days
            )
        );
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
        if (uint256(elapsed) <= uint256(duration)) {
            assertTrue(reserved);
            assertEq(holder, ed);
        } else {
            assertFalse(reserved);
            assertEq(holder, address(0));
        }
    }

    function testFuzz_gatewayReserve_cold_user_stashes_label_and_chat_key_exactly(
        uint8 suffix,
        bytes1 keySeed
    )
        public
    {
        suffix = uint8(bound(uint256(suffix), 0, 99));
        string memory label = string.concat("coldfu", _twoDigitDecimal(uint256(suffix)));
        bytes memory chatKey = _validChatKey(keySeed);

        _grantPopLite(ed);
        _gatewayReserveLiteName(
            IDotnsPopController.LiteRegistration({liteLabel: label, user: ed, chatKey: chatKey})
        );

        IDotnsPopController.PendingClaim[] memory pending = dotnsPopController.pendingClaims(ed);
        assertEq(pending[0].label, label);
        assertGt(pending[0].mintedAt, 0);
        assertEq(storeFactory.getLabelStore(ed), address(0));
        // Chat key is persisted eagerly on the resolver at reserve time, even though
        // the LabelStore write is deferred to settlement on the cold path.
        bytes32 node = _nodeOf(label);
        assertEq(dotnsPopResolver.chatKey(node), chatKey);
    }

    function testFuzz_claimLabelStore_settles_label_and_chat_key_exactly(
        uint8 suffix,
        bytes1 keySeed
    )
        public
    {
        suffix = uint8(bound(uint256(suffix), 0, 99));
        string memory label = string.concat("warmfu", _twoDigitDecimal(uint256(suffix)));
        bytes memory chatKey = _validChatKey(keySeed);

        _grantPopLite(ed);
        _gatewayReserveLiteName(
            IDotnsPopController.LiteRegistration({liteLabel: label, user: ed, chatKey: chatKey})
        );

        vm.prank(ed);
        dotnsPopController.claimLabelStore();

        bytes32 node = _nodeOf(label);
        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(ILabelStore(store).getLabel(node), string.concat(label, protocolRegistry.tld()));
        assertEq(dotnsPopResolver.chatKey(node), chatKey);
        assertEq(dotnsPopController.pendingClaims(ed).length, 0);
    }

    function testFuzz_pendingClaim_expiry_boundary_admits_or_lapses(
        uint64 duration,
        uint64 elapsed
    )
        public
    {
        duration = uint64(
            bound(
                uint256(duration), uint256(dotnsPopController.MIN_RESERVATION_DURATION()), 365 days
            )
        );
        elapsed = uint64(bound(uint256(elapsed), 0, 365 days));

        vm.prank(owner);
        dotnsPopController.setReservationDuration(duration);

        _grantPopLite(ed);
        _gatewayReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x77)
            })
        );

        uint64 mintedAt = dotnsPopController.pendingClaims(ed)[0].mintedAt;
        vm.warp(uint256(mintedAt) + uint256(elapsed));

        if (elapsed <= duration) {
            vm.expectRevert(
                abi.encodeWithSelector(IDotnsPopController.PendingClaimNotExpired.selector, ed)
            );
            dotnsPopController.expirePendingClaim(ed);
            vm.prank(ed);
            dotnsPopController.claimLabelStore();
            assertTrue(storeFactory.getLabelStore(ed) != address(0));
        } else {
            vm.expectRevert(abi.encodeWithSelector(IDotnsPopController.NoPendingClaim.selector, ed));
            vm.prank(ed);
            dotnsPopController.claimLabelStore();
            dotnsPopController.expirePendingClaim(ed);
            assertEq(storeFactory.getLabelStore(ed), address(0));
        }
    }
}
