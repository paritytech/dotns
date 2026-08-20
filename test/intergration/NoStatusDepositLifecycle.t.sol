// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../base/BaseDotns.t.sol";
import {IDotnsNameEscrow} from "../../contracts/escrow/IDotnsNameEscrow.sol";

/// @title NoStatusDepositLifecycle
/// @notice Integration coverage for the NoStatus refundable-deposit hurdle as it
///         follows the NFT across registration, transfer, release, cooldown, and
///         withdrawal.
/// @dev Asserts the post-redesign rule: a NoStatus depositor's stake travels with
///      the NFT on every transfer. The escrow position rebinds to the new holder
///      rather than refunding the original payer, and only the current holder can
///      release into escrow and pull the deposit after the cooldown elapses. This
///      closes the same-tier recycle that would otherwise let one D underwrite an
///      unbounded number of NoStatus names over time.
contract NoStatusDepositLifecycle is BaseDotns {
    /// @notice NoStatus label fixture (baselength >= 9 classifies as NoStatus).
    string internal constant DEPOSIT_LABEL = "depositname01";

    function test_NoStatus_register_then_transfer_then_holder_claims_refund() public {
        address depositor = ed;
        address recipient = leonardo;

        uint256 ownerPrice = popRules.priceWithCheck(DEPOSIT_LABEL, depositor).price;
        assertEq(ownerPrice, RENT_PRICE, "NoStatus price baseline must match RENT_PRICE");

        // Register pays D = RENT_PRICE into the depositor's position.
        _commitAndRegister(DEPOSIT_LABEL, depositor, false);
        uint256 tokenId = _tokenIdForLabel(DEPOSIT_LABEL);

        IDotnsNameEscrow.ReleasePosition memory atMint = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(atMint.amount, RENT_PRICE, "position must hold full RENT_PRICE deposit");
        assertEq(atMint.recipient, depositor, "position recipient must be the depositor at mint");
        assertEq(
            dotnsNameEscrow.reserves(address(0)),
            RENT_PRICE,
            "tokenReserved must reflect the seeded deposit"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(depositor),
            0,
            "no refund must exist before the transfer"
        );

        // Transfer the NFT away from the depositor. Same-tier NoStatus floor is
        // zero, so msg.value is zero; the escrow is still consulted so the
        // position rebinds to the new holder.
        uint256 transferFee = dotnsRegistrar.quoteTransferFee(tokenId, recipient);
        assertEq(transferFee, 0, "NoStatus to NoStatus transfer floor is zero");

        vm.prank(depositor);
        dotnsRegistrar.transferFrom{value: 0}(depositor, recipient, tokenId);

        IDotnsNameEscrow.ReleasePosition memory afterTransfer =
            dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(
            afterTransfer.amount, RENT_PRICE, "deposit must travel with the NFT, not be cleared"
        );
        assertEq(
            afterTransfer.recipient, recipient, "position recipient must rebind to the new holder"
        );
        assertEq(
            dotnsNameEscrow.reserves(address(0)),
            RENT_PRICE,
            "tokenReserved must not move while the deposit follows the NFT"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(depositor),
            0,
            "original depositor must not be credited a refund at transfer time"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(recipient),
            0,
            "new holder must not be credited a refund at transfer time"
        );

        // Only the current holder can release into escrow.
        vm.startPrank(recipient);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();

        IDotnsNameEscrow.ReleasePosition memory released =
            dotnsNameEscrow.getReleasePosition(tokenId);
        assertTrue(released.released, "current holder may release into escrow");
        assertEq(released.recipient, recipient, "release recipient mirrors the current NFT holder");

        // Withdraw before cooldown is locked.
        vm.prank(recipient);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsNameEscrow.WithdrawalTooEarly.selector,
                tokenId,
                released.withdrawAvailableAt,
                block.timestamp
            )
        );
        dotnsNameEscrow.withdraw(tokenId);

        // Warp past the cooldown and pull the refund through the pull-payment
        // ledger. The current holder's balance must grow by exactly D.
        vm.warp(uint256(released.withdrawAvailableAt) + 1);

        vm.prank(recipient);
        dotnsNameEscrow.withdraw(tokenId);

        assertEq(
            dotnsNameEscrow.pendingWithdrawal(recipient),
            RENT_PRICE,
            "deposit lands on the current holder's pull-payment ledger"
        );
        assertEq(
            dotnsNameEscrow.pendingWithdrawal(depositor),
            0,
            "original depositor never accrues a pending withdrawal"
        );

        uint256 balanceBefore = recipient.balance;
        vm.prank(recipient);
        uint256 claimed = dotnsNameEscrow.claimWithdrawal();

        assertEq(claimed, RENT_PRICE, "claim must return the full deposit");
        assertEq(
            recipient.balance - balanceBefore,
            RENT_PRICE,
            "current holder balance must increase by the full deposit"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(depositor),
            0,
            "original depositor must never accrue a refund entry"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(recipient),
            0,
            "release-and-withdraw uses pendingWithdrawals, not the time-locked refund ledger"
        );
    }
}
