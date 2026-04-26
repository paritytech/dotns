// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns, IDotnsRegistrarController} from "../../base/BaseDotns.t.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";

contract DotnsNameEscrowFuzzTest is BaseDotns {
    /// @notice Fuzz deposit tracking across multiple registrations with varying label lengths.
    /// @dev Registers multiple NoStatus names with different lengths (9-20 chars) and verifies
    ///      each deposit is tracked correctly in both the position and the global reserves.
    function testFuzz_deposit_amount(uint256 seed) public {
        address registrant = ed;

        // PopRules classifies names as NoStatus only when base >= 9 chars AND
        // the name ends with exactly 2 digits. All prefixes here are 9+ chars
        // so the seed-selected base always qualifies.
        string[5] memory prefixes =
            ["escrowfza", "escrowfzab", "escrowfzabc", "escrowfzabcd", "escrowfzabcde"];
        string memory prefix = prefixes[seed % prefixes.length];
        // 10..99, exactly 2 digits.
        string memory suffix = vm.toString(10 + (seed % 90));
        string memory nameLabel = string(abi.encodePacked(prefix, suffix));

        IDotnsRegistrarController.Registration memory registration =
            _commitFor(nameLabel, registrant, true);

        uint256 requiredPrice = popRules.priceWithCheck(nameLabel, registrant).price;
        assertGt(requiredPrice, 0, "NoStatus names must have a non-zero price");

        uint256 reservesBefore = dotnsNameEscrow.reserves(address(0));

        vm.prank(registrant);
        dotnsRegistrarController.register{value: requiredPrice}(registration);

        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelhash);
        uint256 tokenId = uint256(node);

        IDotnsNameEscrow.ReleasePosition memory position =
            dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(position.amount, requiredPrice, "Position amount must match price paid");
        assertEq(position.asset, address(0), "Position asset must be native token");
        assertFalse(position.released, "Position must not be released");
        assertFalse(position.claimed, "Position must not be claimed");

        uint256 reservesAfter = dotnsNameEscrow.reserves(address(0));
        assertEq(
            reservesAfter - reservesBefore,
            requiredPrice,
            "Reserves must increase by the deposited amount"
        );

        assertGe(
            address(dotnsNameEscrow).balance,
            reservesAfter,
            "Escrow balance must cover total reserves"
        );
    }

    /// @notice Fuzz withdrawal timing: warp by random amount after release, expect revert or success.
    /// @dev Registers a NoStatus name, releases it into escrow, then fuzzes the warp amount.
    ///      If warpAmount < ESCROW_COOLDOWN (7 days), expects WithdrawalTooEarly revert.
    ///      If warpAmount >= ESCROW_COOLDOWN, expects successful withdrawal.
    function testFuzz_withdraw_timing(uint256 warpAmount) public {
        warpAmount = bound(warpAmount, 0, 30 days);

        address registrant = ed;
        string memory nameLabel = "escrowtimelab12";

        IDotnsRegistrarController.Registration memory registration =
            _commitFor(nameLabel, registrant, true);

        uint256 requiredPrice = popRules.priceWithCheck(nameLabel, registrant).price;
        assertGt(requiredPrice, 0, "NoStatus names must have a non-zero price");

        vm.prank(registrant);
        dotnsRegistrarController.register{value: requiredPrice}(registration);

        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelhash);
        uint256 tokenId = uint256(node);

        vm.prank(registrant);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);

        vm.prank(registrant);
        dotnsNameEscrow.release(tokenId);

        assertEq(
            dotnsRegistrar.ownerOf(tokenId),
            address(dotnsNameEscrow),
            "Escrow must own the released token"
        );

        IDotnsNameEscrow.ReleasePosition memory position =
            dotnsNameEscrow.getReleasePosition(tokenId);
        uint256 releaseTimestamp = block.timestamp;
        vm.warp(releaseTimestamp + warpAmount);

        if (warpAmount < ESCROW_COOLDOWN) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IDotnsNameEscrow.WithdrawalTooEarly.selector,
                    tokenId,
                    position.withdrawAvailableAt,
                    block.timestamp
                )
            );
            vm.prank(registrant);
            dotnsNameEscrow.withdraw(tokenId);
        } else {
            uint256 balanceBefore = registrant.balance;

            vm.prank(registrant);
            dotnsNameEscrow.withdraw(tokenId);

            // Pull-payment: balance only changes once claimWithdrawal is called.
            vm.prank(registrant);
            dotnsNameEscrow.claimWithdrawal();

            uint256 balanceAfter = registrant.balance;
            assertEq(
                balanceAfter - balanceBefore, requiredPrice, "Registrant must receive full refund"
            );

            IDotnsNameEscrow.ReleasePosition memory positionAfter =
                dotnsNameEscrow.getReleasePosition(tokenId);
            assertEq(positionAfter.amount, 0, "Position amount must be zero after withdrawal");
            assertTrue(positionAfter.claimed, "Position must be marked as claimed");
        }
    }

    function _commitFor(
        string memory nameLabel,
        address nameOwner,
        bool reserved
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

        vm.prank(nameOwner);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
    }
}
