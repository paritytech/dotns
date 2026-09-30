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

/// @title DotnsPopControllerFuzz
/// @notice Property-based tests for @custom:contract DotnsPopController.
/// @dev Each fuzz replaces a family of near-identical unit tests with a single
///      property assertion the fuzzer explores across inputs.
contract DotnsPopControllerFuzz is BaseDotns {
    // Render `value` as a decimal string padded to at least two digits. Callers bound
    // `value` to `[0, 99]` so the suffix is exactly two digits, which the `stem.NN` shape
    // requires.
    function _twoDigitDecimal(uint256 value) internal pure returns (string memory s) {
        if (value < 10) {
            return string.concat("0", StringUtils.uintToString(value));
        }
        return StringUtils.uintToString(value);
    }

    function testFuzz_issueDeviceNameWithReservation_accepts_any_two_digit_suffix(uint8 suffix)
        public
    {
        suffix = uint8(bound(uint256(suffix), 0, 99));
        string memory label = string.concat("joseph", ".", _twoDigitDecimal(uint256(suffix)));

        // Device-name label requires ed to hold Devicehood (or Personhood) status so the
        // `priceWithCheck` guard inside the controller accepts the reservation.
        _grantDevicehood(ed);

        _reservePop(ed, label, "", "");

        assertEq(dotnsRegistry.owner(_deviceNodeOf(label)), ed);
    }

    function testFuzz_issueDeviceNameWithReservation_persists_chat_key_exact_bytes(
        uint8 suffix,
        bytes1 keySeed,
        bool useKey
    )
        public
    {
        suffix = uint8(bound(uint256(suffix), 0, 99));
        string memory label = string.concat("joseph", ".", _twoDigitDecimal(uint256(suffix)));

        _grantDevicehood(ed);

        bytes memory chatKey = useKey ? _validChatKey(keySeed) : bytes("");
        _reservePop(ed, label, chatKey, "");

        bytes32 node = _deviceNodeOf(label);
        if (chatKey.length == 0) {
            assertEq(dotnsPopResolver.chatKey(node).length, 0);
        } else {
            assertEq(dotnsPopResolver.chatKey(node), chatKey);
        }
    }

    /// @dev The reservation covers the base name, and the base name is what a public registrant
    ///      contends for: a digit-suffixed spelling is measured as written and so is an unrelated
    ///      name the reservation never sees.
    function testFuzz_public_register_respects_popRules_reservation(bool reserveFirst) public {
        string memory baseName = "longnamebob";

        if (reserveFirst) {
            // The reserved base label `longnamebob` classifies as NoStatus (11 characters); the
            // device name has to be Devicehood-eligible. Tiago needs Personhood status so both
            // `priceWithCheck` calls inside `reserveBaseName` succeed.
            _grantPersonhood(tiago);
            _reservePop(tiago, DEVICE_LABEL_A, "", baseName);
        }

        bytes32 secret = keccak256(abi.encodePacked(baseName, ed, block.timestamp));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: baseName,
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

        if (reserveFirst) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IPopRules.PopError.selector,
                    "Reserved for a device-name holder's personhood claim"
                )
            );
            vm.prank(ed);
            dotnsRegistrarController.register{value: 1 ether}(registration);
        } else {
            uint256 cost = popRules.priceWithCheck(baseName, ed).price;
            vm.prank(ed);
            dotnsRegistrarController.register{value: cost}(registration);
            assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(baseName))), ed);
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

        // Reserving `PERSONHOOD_LABEL_A` (Personhood classification) alongside the
        // the issuance requires ed to hold Personhood status so both `priceWithCheck`
        // calls succeed.
        _grantPersonhood(ed);
        _reservePop(ed, DEVICE_LABEL_A, "", PERSONHOOD_LABEL_A);

        vm.warp(block.timestamp + uint256(elapsed));

        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
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
        string memory label = string.concat("joseph", ".", _twoDigitDecimal(uint256(suffix)));
        bytes memory chatKey = _validChatKey(keySeed);

        _grantDevicehood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({label: label, user: ed, chatKey: chatKey})
        );

        IDotnsPopController.PendingClaim[] memory pending =
            dotnsPopController.pendingClaims(ed, 0, type(uint256).max);
        assertEq(pending[0].label, label);
        assertGt(pending[0].mintedAt, 0);
        assertEq(storeFactory.getLabelStore(ed), address(0));
        // Chat key is persisted eagerly on the resolver at reserve time, even though
        // the LabelStore write is deferred to settlement on the cold path.
        bytes32 node = _deviceNodeOf(label);
        assertEq(dotnsPopResolver.chatKey(node), chatKey);
    }

    function testFuzz_settle_settles_label_and_chat_key_exactly(
        uint8 suffix,
        bytes1 keySeed
    )
        public
    {
        suffix = uint8(bound(uint256(suffix), 0, 99));
        string memory label = string.concat("joseph", ".", _twoDigitDecimal(uint256(suffix)));
        bytes memory chatKey = _validChatKey(keySeed);

        _grantDevicehood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({label: label, user: ed, chatKey: chatKey})
        );

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        bytes32 node = _deviceNodeOf(label);
        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(ILabelStore(store).getLabel(node), string.concat(label, protocolRegistry.tld()));
        assertEq(dotnsPopResolver.chatKey(node), chatKey);
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }

    function testFuzz_settle_writes_label_regardless_of_age(
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

        _grantDevicehood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL_A, user: ed, chatKey: _validChatKey(0x77)
            })
        );

        uint64 mintedAt = dotnsPopController.pendingClaims(ed, 0, 1)[0].mintedAt;
        vm.warp(uint256(mintedAt) + uint256(elapsed));

        // Stores always settle: settlement writes the label into the store whether or not the
        // claim is older than `reservationDuration`, so age never strands a claim.
        vm.prank(ed);
        (uint256 settledCount, bool moreRemaining) =
            dotnsPopController.settlePendingClaims(ed, type(uint256).max);
        assertEq(settledCount, 1);
        assertFalse(moreRemaining);

        bytes32 node = _deviceNodeOf(DEVICE_LABEL_A);
        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(node), string.concat(DEVICE_LABEL_A, protocolRegistry.tld())
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
    }
}
