// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

contract PopRulesFuzzTest is BaseDotns {
    function testFuzz_popfull_user_can_access_poplite(uint256 seed, uint256 length) public {
        length = bound(length, 6, 8);
        string memory nameLabel = string(abi.encodePacked(_makeAlpha(seed, length), "01"));

        vm.prank(ed);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);

        IPopRules.PriceWithMeta memory priceMetadata = popRules.priceWithCheck(nameLabel, ed);

        assertEq(uint256(priceMetadata.status), uint256(IPopRules.PopStatus.PopLite));
        assertEq(uint256(priceMetadata.userStatus), uint256(IPopRules.PopStatus.PopFull));
    }

    function testFuzz_popfull_user_can_access_nostatus(uint256 seed, uint256 length) public {
        length = bound(length, 9, 14);
        string memory nameLabel = string(abi.encodePacked(_makeAlpha(seed, length), "01"));

        vm.prank(ed);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);

        IPopRules.PriceWithMeta memory priceMetadata = popRules.priceWithCheck(nameLabel, ed);

        assertEq(uint256(priceMetadata.status), uint256(IPopRules.PopStatus.NoStatus));
        assertEq(uint256(priceMetadata.userStatus), uint256(IPopRules.PopStatus.PopFull));
    }

    function testFuzz_nostatus_user_cannot_access_popfull(uint256 seed) public {
        string memory nameLabel = _makeAlpha(seed, 8);

        vm.prank(ed);
        popRules.setUserPopStatus(IPopRules.PopStatus.NoStatus);

        vm.expectPartialRevert(IPopRules.PopError.selector);
        popRules.priceWithCheck(nameLabel, ed);
    }

    function testFuzz_governance_names_always_revert(
        uint256 seed,
        uint256 length,
        uint8 statusSeed
    )
        public
    {
        length = bound(length, 3, 5);
        string memory nameLabel = _makeAlpha(seed, length);

        IPopRules.PopStatus userStatus = IPopRules.PopStatus(bound(statusSeed, 0, 3));

        vm.prank(ed);
        popRules.setUserPopStatus(userStatus);

        vm.expectPartialRevert(IPopRules.PopError.selector);
        popRules.priceWithCheck(nameLabel, ed);
    }

    function testFuzz_reservation_blocks_other_users(uint256 seed) public {
        string memory nameLabel = string(abi.encodePacked(_makeAlpha(seed, 6), "01"));

        _authoriseTestAsController();

        popRules.reserveBaseName(nameLabel, leonardo);

        string memory baseName = _makeAlpha(seed, 6);

        (bool isReserved, address reservedFor,) = popRules.isBaseNameReserved(baseName);

        assertTrue(isReserved);
        assertEq(reservedFor, leonardo);

        vm.expectPartialRevert(IPopRules.PopError.selector);
        popRules.priceWithCheck(baseName, tiago);
    }

    function testFuzz_price_without_check_returns_price(uint256 seed, uint256 length) public view {
        length = bound(length, 3, 16);
        string memory nameLabel = _makeAlpha(seed, length);

        IPopRules.PriceWithMeta memory priceMetadata = popRules.priceWithoutCheck(nameLabel, ed);

        assertEq(priceMetadata.price, popRules.price(nameLabel));
    }

    function testFuzz_expired_reservation_rolls_forward_to_next_lite_registrant(uint256 seed)
        public
    {
        string memory baseName = _makeAlpha(seed, 6);
        string memory firstName = string(abi.encodePacked(baseName, "01"));
        string memory secondName = string(abi.encodePacked(baseName, "02"));

        _authoriseTestAsController();

        popRules.reserveBaseName(firstName, leonardo);

        (bool isReserved, address firstOwner, uint64 firstExpiry) =
            popRules.isBaseNameReserved(baseName);

        assertTrue(isReserved);
        assertEq(firstOwner, leonardo);

        vm.warp(uint256(firstExpiry) + 1);

        popRules.reserveBaseName(secondName, tiago);

        (bool rolledReserved, address rolledOwner, uint64 rolledExpiry) =
            popRules.isBaseNameReserved(baseName);

        assertTrue(rolledReserved);
        assertEq(rolledOwner, tiago);
        assertGt(rolledExpiry, firstExpiry);
    }

    function testFuzz_mixed_case_names_are_rejected(uint256 seed) public {
        bytes memory baseName = bytes(_makeAlpha(seed, 6));
        baseName[0] = bytes1(uint8(baseName[0]) - 32);
        string memory mixedCaseName = string(abi.encodePacked(string(baseName), "01"));

        vm.prank(ed);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopLite);

        vm.expectPartialRevert(IPopRules.PopError.selector);
        popRules.priceWithCheck(mixedCaseName, ed);
    }

    function _makeAlpha(uint256 seed, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            buffer[i] = bytes1(uint8(97 + (uint256(keccak256(abi.encodePacked(seed, i))) % 26)));
        }
        return string(buffer);
    }

    function testFuzz_reachFee_NoStatus_label_returns_zero_for_any_status(
        uint256 seed,
        uint256 length,
        uint8 statusSeed
    )
        public
    {
        // NoStatus-tier labels: long alpha + 2 trailing digits, length 9..14.
        // The open tier has no verification gate, so reachFee returns zero for any caller status.
        length = bound(length, 9, 14);
        string memory nameLabel = string(abi.encodePacked(_makeAlpha(seed, length), "01"));

        IPopRules.PopStatus userStatus = IPopRules.PopStatus(bound(statusSeed, 0, 2));
        vm.prank(ed);
        popRules.setUserPopStatus(userStatus);

        assertEq(popRules.reachFee(nameLabel, ed), 0);
    }

    function testFuzz_reachFee_PopFull_label_charges_below_full(
        uint256 seed,
        uint256 length,
        uint8 statusSeed
    )
        public
    {
        // PopFull-tier base names: alpha only, length 9..14 so _priceValidatedName is non-zero.
        // Any caller below PopFull (NoStatus or PopLite) owes the same length-scaled rate.
        length = bound(length, 9, 14);
        string memory nameLabel = _makeAlpha(seed, length);

        IPopRules.PopStatus userStatus = IPopRules.PopStatus(bound(statusSeed, 0, 1));
        vm.prank(ed);
        popRules.setUserPopStatus(userStatus);

        uint256 expected = popRules.price(nameLabel);
        assertEq(popRules.reachFee(nameLabel, ed), expected);
    }

    function testFuzz_reachFee_PopFull_user_pays_zero_anywhere(
        uint256 seed,
        uint256 length
    )
        public
    {
        // A PopFull-verified caller meets reach for every label tier the public path can
        // produce, so reachFee is uniformly zero across the random length range.
        length = bound(length, 6, 14);
        string memory nameLabel = _makeAlpha(seed, length);

        vm.prank(ed);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);

        assertEq(popRules.reachFee(nameLabel, ed), 0);
    }
}
