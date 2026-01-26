// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns, IDotnsRegistrarController} from "../../base/BaseDotns.t.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

contract DotnsRegistrarControllerFuzzTest is BaseDotns {
    function testFuzz_register_succeeds_when_payment_equals_price(uint256 salt) public {
        address registrant = ed;
        string memory nameLabel = _labelNoStatusPriced(bound(salt, 0, 64));

        // Pricing is only charged for NoStatus
        vm.prank(registrant);
        popRules.setUserPopStatus(IPopRules.PopStatus.NoStatus);

        IDotnsRegistrarController.Registration memory registration =
            _commitFor(nameLabel, registrant, true);

        uint256 requiredPrice = popRules.priceWithCheck(nameLabel, registrant).price;
        assertGt(requiredPrice, 0);

        vm.prank(registrant);
        dotnsRegistrarController.register{value: requiredPrice}(registration);

        assertEq(dotnsRegistrar.ownerOf(uint256(keccak256(bytes(nameLabel)))), registrant);
    }

    function testFuzz_register_refunds_overpayment(uint256 extra, uint256 salt) public {
        address registrant = ed;
        string memory nameLabel = _labelNoStatusPriced(bound(salt, 0, 64));

        // Pricing is only charged for NoStatus
        vm.prank(registrant);
        popRules.setUserPopStatus(IPopRules.PopStatus.NoStatus);

        IDotnsRegistrarController.Registration memory registration =
            _commitFor(nameLabel, registrant, true);

        uint256 requiredPrice = popRules.priceWithCheck(nameLabel, registrant).price;
        assertGt(requiredPrice, 0);

        extra = bound(extra, 1, 5 ether);

        uint256 balanceBefore = registrant.balance;

        vm.prank(registrant);
        dotnsRegistrarController.register{value: requiredPrice + extra}(registration);

        uint256 balanceAfter = registrant.balance;
        assertEq(balanceBefore - balanceAfter, requiredPrice);
    }

    function testFuzz_register_accepts_exact_zero_payment_when_price_is_zero(uint256 salt) public {
        address registrant = tiago;
        string memory nameLabel = _labelPriceZero(bound(salt, 0, 64));

        // PopLite pays 0 under PopRules.priceWithCheck
        vm.prank(registrant);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopLite);

        IDotnsRegistrarController.Registration memory registration =
            _commitFor(nameLabel, registrant, false);

        uint256 requiredPrice = popRules.priceWithCheck(nameLabel, registrant).price;
        assertEq(requiredPrice, 0);

        vm.prank(registrant);
        dotnsRegistrarController.register{value: 0}(registration);

        assertEq(dotnsRegistrar.ownerOf(uint256(keccak256(bytes(nameLabel)))), registrant);
    }

    function testFuzz_register_accepts_overpayment_when_price_is_zero(
        uint256 extra,
        uint256 salt
    )
        public
    {
        address registrant = tiago;
        string memory nameLabel = _labelPriceZero(bound(salt, 0, 64));

        // PopLite pays 0 under PopRules.priceWithCheck
        vm.prank(registrant);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopLite);

        IDotnsRegistrarController.Registration memory registration =
            _commitFor(nameLabel, registrant, false);

        uint256 requiredPrice = popRules.priceWithCheck(nameLabel, registrant).price;
        assertEq(requiredPrice, 0);

        extra = bound(extra, 1, 5 ether);
        uint256 balanceBefore = registrant.balance;

        vm.prank(registrant);
        dotnsRegistrarController.register{value: extra}(registration);

        uint256 balanceAfter = registrant.balance;
        // Full refund expected because price is 0
        assertEq(balanceBefore, balanceAfter);
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

        // PopFull pays 0 under PopRules.priceWithCheck
        vm.prank(nameOwner);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);

        vm.prank(payer);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);

        // Commit from payer to satisfy any controller-side committer checks
        IDotnsRegistrarController.Registration memory registration =
            _commitFor(nameLabel, nameOwner, true, payer);

        uint256 requiredPrice = popRules.priceWithCheck(nameLabel, nameOwner).price;
        assertEq(requiredPrice, 0);

        extra = bound(extra, 1, 5 ether);

        uint256 payerBalanceBefore = payer.balance;
        uint256 ownerBalanceBefore = nameOwner.balance;

        vm.prank(payer);
        dotnsRegistrarController.register{value: requiredPrice + extra}(registration);

        uint256 payerBalanceAfter = payer.balance;
        uint256 ownerBalanceAfter = nameOwner.balance;

        // Full refund expected because price is 0
        assertEq(payerBalanceBefore, payerBalanceAfter);
        assertEq(ownerBalanceBefore, ownerBalanceAfter);

        assertEq(dotnsRegistrar.ownerOf(uint256(keccak256(bytes(nameLabel)))), nameOwner);
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

        vm.prank(commitmentSender);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
    }

    /// @notice Builds a PopFull-required label.
    /// @dev Exactly 1 trailing digit and base length >= 9 ensures PopFull classification.
    ///      Format: "popfull" + alpha2 + "9" => base length 9, total length 10.
    function _labelPopfull(uint256 salt) internal pure returns (string memory label) {
        return string(abi.encodePacked("popfull", _uintToAlphaFixed(salt, 2), "9"));
    }

    /// @notice Builds a NoStatus-required label with non-zero price for NoStatus users.
    /// @dev NoStatus classification requires trailingDigits == 2 and baselength >= 9.
    ///      Total length >= 9 ensures PopRules.price(name) > 0.
    ///      Format: "nostatus" + alpha2 + "01" => base length 10, total length 12.
    function _labelNoStatusPriced(uint256 salt) internal pure returns (string memory label) {
        return string(abi.encodePacked("nostatus", _uintToAlphaFixed(salt, 2), "01"));
    }

    /// @notice Builds a zero-price PopLite-eligible label.
    /// @dev Total length < 9 ensures PopRules.price(name) == 0 (even for NoStatus),
    ///      and trailingDigits == 2 with baselength in [6..8] makes it PopLite.
    ///      Format: "free" + alpha2 + "01" => total length 8.
    function _labelPriceZero(uint256 salt) internal pure returns (string memory label) {
        return string(abi.encodePacked("free", _uintToAlphaFixed(salt, 2), "01"));
    }

    /// @notice Converts uint256 to a fixed-length alphabetic string.
    /// @dev Maps base-26 digits to 'a'..'z' to avoid numeric characters in the base portion.
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
