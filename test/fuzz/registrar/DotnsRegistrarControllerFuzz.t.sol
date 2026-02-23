// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns, IDotnsRegistrarController} from "../../base/BaseDotns.t.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

contract DotnsRegistrarControllerFuzzTest is BaseDotns {
    function testFuzz_register_refunds_overpayment(uint256 extra, uint256 salt) public {
        address registrant = ed;
        string memory nameLabel = _labelNoStatusPriced(bound(salt, 0, 64));

        // NoStatus is the default — no precompile status needed

        IDotnsRegistrarController.Registration memory registration =
            _commitFor(nameLabel, registrant, true);

        uint256 requiredPrice = popRules.priceWithCheck(nameLabel, registrant).price;
        assertGt(requiredPrice, 0);

        extra = bound(extra, 0, 5 ether);
        uint256 balanceBefore = registrant.balance;

        vm.startPrank(registrant);
        dotnsRegistrarController.register{value: requiredPrice + extra}(registration);
        vm.stopPrank();

        uint256 balanceAfter = registrant.balance;
        assertEq(balanceBefore - balanceAfter, requiredPrice);

        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelhash);
        uint256 tokenId = uint256(node);

        assertEq(dotnsRegistrar.ownerOf(tokenId), registrant);
    }

    function testFuzz_register_accepts_overpayment_when_price_is_zero(
        uint256 extra,
        uint256 salt
    )
        public
    {
        address registrant = tiago;
        string memory nameLabel = _labelPriceZero(bound(salt, 0, 64));

        _setPersonhoodStatus(registrant, IPopRules.PopStatus.PopLite);

        IDotnsRegistrarController.Registration memory registration =
            _commitFor(nameLabel, registrant, false);

        uint256 requiredPrice = popRules.priceWithCheck(nameLabel, registrant).price;
        assertEq(requiredPrice, 0);

        extra = bound(extra, 0, 5 ether);
        uint256 balanceBefore = registrant.balance;

        vm.startPrank(registrant);
        dotnsRegistrarController.register{value: extra}(registration);
        vm.stopPrank();

        uint256 balanceAfter = registrant.balance;
        assertEq(balanceBefore, balanceAfter);

        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelhash);
        uint256 tokenId = uint256(node);

        assertEq(dotnsRegistrar.ownerOf(tokenId), registrant);
    }

    function testFuzz_register_refunds_to_payer_not_owner_when_registering_for_other(
        uint256 extra,
        uint256 salt
    )
        public
    {
        address nameOwner = ed;
        address payer = leonardo;
        string memory nameLabel = _labelPopfull(bound(salt, 0, 64));

        _setPersonhoodStatus(nameOwner, IPopRules.PopStatus.PopFull);
        _setPersonhoodStatus(payer, IPopRules.PopStatus.PopFull);

        IDotnsRegistrarController.Registration memory registration =
            _commitFor(nameLabel, nameOwner, true, payer);

        uint256 requiredPrice = popRules.priceWithCheck(nameLabel, nameOwner).price;
        assertEq(requiredPrice, 0);

        extra = bound(extra, 0, 5 ether);

        uint256 payerBalanceBefore = payer.balance;
        uint256 ownerBalanceBefore = nameOwner.balance;

        vm.startPrank(payer);
        dotnsRegistrarController.register{value: requiredPrice + extra}(registration);
        vm.stopPrank();

        uint256 payerBalanceAfter = payer.balance;
        uint256 ownerBalanceAfter = nameOwner.balance;

        assertEq(payerBalanceBefore, payerBalanceAfter);
        assertEq(ownerBalanceBefore, ownerBalanceAfter);

        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelhash);
        uint256 tokenId = uint256(node);

        assertEq(dotnsRegistrar.ownerOf(tokenId), nameOwner);
    }

    function _commitFor(
        string memory nameLabel,
        address nameOwner,
        bool reserved
    )
        internal
        returns (IDotnsRegistrarController.Registration memory registration)
    {
        return _commitFor(nameLabel, nameOwner, reserved, nameOwner);
    }

    function _commitFor(
        string memory nameLabel,
        address nameOwner,
        bool reserved,
        address commitmentSender
    )
        internal
        returns (IDotnsRegistrarController.Registration memory registration)
    {
        bytes32 secret =
            keccak256(abi.encodePacked(nameLabel, nameOwner, block.timestamp, address(this)));

        registration = IDotnsRegistrarController.Registration({
            label: nameLabel, owner: nameOwner, secret: secret, reserved: reserved
        });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);

        vm.startPrank(commitmentSender);
        dotnsRegistrarController.commit(commitment);
        vm.stopPrank();

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
    }

    function _labelPopfull(uint256 salt) internal pure returns (string memory label) {
        return string(abi.encodePacked("popfull", _uintToAlphaFixed(salt, 2), "9"));
    }

    function _labelNoStatusPriced(uint256 salt) internal pure returns (string memory label) {
        return string(abi.encodePacked("nostatus", _uintToAlphaFixed(salt, 2), "01"));
    }

    function _labelPriceZero(uint256 salt) internal pure returns (string memory label) {
        return string(abi.encodePacked("free", _uintToAlphaFixed(salt, 2), "01"));
    }

    function _uintToAlphaFixed(
        uint256 value,
        uint256 length
    )
        internal
        pure
        returns (string memory output)
    {
        bytes memory buffer = new bytes(length);
        uint256 remaining = value;

        for (uint256 index = 0; index < length; index++) {
            buffer[index] = bytes1(uint8(97 + (remaining % 26)));
            remaining /= 26;
        }

        return string(buffer);
    }
}
