// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

/// @title PopRulesFuzzTest
/// @notice Property-based tests for @custom:contract PopRules classification, reservation and
/// pricing.
contract PopRulesFuzzTest is BaseDotns {
    function testFuzz_popfull_user_can_access_poplite(uint256 seed, uint256 length) public {
        length = bound(length, 6, 8);
        string memory nameLabel = string(abi.encodePacked(_makeAlpha(seed, length), "01"));

        _grantPopFull(ed);

        IPopRules.PriceWithMeta memory priceMetadata = popRules.priceWithCheck(nameLabel, ed);

        assertEq(uint256(priceMetadata.status), uint256(IPopRules.PopStatus.PopLite));
        assertEq(uint256(priceMetadata.userStatus), uint256(IPopRules.PopStatus.PopFull));
    }

    function testFuzz_popfull_user_can_access_nostatus(uint256 seed, uint256 length) public {
        length = bound(length, 9, 14);
        string memory nameLabel = string(abi.encodePacked(_makeAlpha(seed, length), "01"));

        _grantPopFull(ed);

        IPopRules.PriceWithMeta memory priceMetadata = popRules.priceWithCheck(nameLabel, ed);

        assertEq(uint256(priceMetadata.status), uint256(IPopRules.PopStatus.NoStatus));
        assertEq(uint256(priceMetadata.userStatus), uint256(IPopRules.PopStatus.PopFull));
    }

    function testFuzz_nostatus_user_cannot_access_popfull(uint256 seed) public {
        string memory nameLabel = _makeAlpha(seed, 8);

        _grantNoStatus(ed);

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

        _setUserPopStatus(ed, userStatus);

        vm.expectPartialRevert(IPopRules.PopError.selector);
        popRules.priceWithCheck(nameLabel, ed);
    }

    function testFuzz_reservation_blocks_other_users(uint256 seed) public {
        string memory baseName = _makeAlpha(seed, 6);

        _authoriseTestAsController();

        popRules.reserveBaseName(baseName, leonardo);

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

        _authoriseTestAsController();

        popRules.reserveBaseName(baseName, leonardo);

        (bool isReserved, address firstOwner, uint64 firstExpiry) =
            popRules.isBaseNameReserved(baseName);

        assertTrue(isReserved);
        assertEq(firstOwner, leonardo);

        vm.warp(uint256(firstExpiry) + 1);

        popRules.reserveBaseName(baseName, tiago);

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

        _grantPopLite(ed);

        vm.expectPartialRevert(IPopRules.PopError.selector);
        popRules.priceWithCheck(mixedCaseName, ed);
    }

    /// @notice Generate a lowercase ASCII string of `length` characters deterministically from
    ///         `seed`.
    function _makeAlpha(uint256 seed, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            buffer[i] = bytes1(uint8(97 + (uint256(keccak256(abi.encodePacked(seed, i))) % 26)));
        }
        return string(buffer);
    }
}
