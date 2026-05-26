// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";
import {EscrowHandler} from "./EscrowHandler.t.sol";

/// @title Dotns Name Escrow Invariant Suite
/// @notice Asserts solvency, custody, and recipient-locking properties of the name escrow
///         across randomised registration, release, withdraw, claim, and transfer flows.
contract DotnsNameEscrowInvariantTest is BaseDotns {
    /// @notice Handler driving randomised actions against the escrow.
    EscrowHandler public handler;

    /// @notice Deploys the escrow handler, seeds it with native funds and a NoStatus actor
    ///         set, and configures the fuzzer to target the handler's action selectors only.
    function setUp() public override {
        super.setUp();

        handler =
            new EscrowHandler(dotnsRegistrarController, dotnsRegistrar, dotnsNameEscrow, popRules);

        vm.deal(address(handler), 1000 ether);

        // Add actors as NoStatus (default) so registrations produce deposits
        handler.addActor(ed);
        handler.addActor(leonardo);
        handler.addActor(tiago);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.commitRegisterAndDeposit.selector;
        selectors[1] = handler.registerCrossTier.selector;
        selectors[2] = handler.releaseToken.selector;
        selectors[3] = handler.withdrawRefund.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.setRandomPopStatus.selector;
        selectors[6] = handler.reRegisterReclaimed.selector;
        selectors[7] = handler.transferDeposited.selector;
        selectors[8] = handler.transferPayable.selector;
        selectors[9] = handler.advanceTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        excludeContract(address(dotnsRegistrarController));
        excludeContract(address(dotnsRegistry));
        excludeContract(address(dotnsRegistrar));
        excludeContract(address(dotnsNameEscrow));
        excludeContract(address(popRules));
        excludeContract(address(storeFactory));
        excludeContract(address(protocolRegistry));
    }

    /// @notice Escrow native balance must always cover the full liability set: tracked
    /// reserves, the insurance fund, unclaimed pull-payment balances, and the time-locked
    /// refund-ledger entries credited by the refund-on-leave path. Under the deposit-binds-
    /// to-depositor model these four flows are economically distinct; solvency is only
    /// meaningful against their sum.
    function invariant_solvency() public view {
        uint256 escrowBalance = address(dotnsNameEscrow).balance;
        uint256 reservedAmount = dotnsNameEscrow.reserves(address(0));
        uint256 insurance = dotnsNameEscrow.insuranceFund();
        uint256 pending = handler.totalPendingWithdrawals();
        uint256 refundEntries = handler.totalPendingRefundEntries();

        assertGe(
            escrowBalance,
            reservedAmount + insurance + pending + refundEntries,
            "Escrow balance must cover reserves + insurance + pending withdrawals + refund entries"
        );
    }

    /// @notice Sum of all active (deposited but not withdrawn) position amounts must equal
    /// reserves.
    function invariant_reserves_match_positions() public view {
        uint256 expectedReserves;

        uint256[] memory deposited = handler.getDepositedTokenIds();
        for (uint256 i; i < deposited.length; ++i) {
            expectedReserves += handler.depositAmounts(deposited[i]);
        }

        uint256[] memory released = handler.getReleasedTokenIds();
        for (uint256 i; i < released.length; ++i) {
            expectedReserves += handler.depositAmounts(released[i]);
        }

        uint256 actualReserves = dotnsNameEscrow.reserves(address(0));
        assertEq(
            actualReserves, expectedReserves, "Reserves must match sum of active position amounts"
        );
    }

    /// @notice Every token in the released ghost state must be owned by escrow.
    function invariant_released_tokens_in_escrow_custody() public view {
        uint256[] memory released = handler.getReleasedTokenIds();

        for (uint256 i; i < released.length; ++i) {
            address tokenOwner = dotnsRegistrar.ownerOf(released[i]);
            assertEq(tokenOwner, address(dotnsNameEscrow), "Released token must be owned by escrow");
        }
    }

    /// @notice On-chain releasedTokenCount must match released tokens still held by escrow.
    function invariant_released_count_consistent() public view {
        uint256[] memory released = handler.getReleasedTokenIds();
        uint256[] memory withdrawn = handler.getWithdrawnTokenIds();
        uint256 onChainCount = dotnsNameEscrow.releasedTokenCount();

        assertEq(
            onChainCount,
            released.length + withdrawn.length,
            "On-chain released count must match released and withdrawn ghost state"
        );
    }

    /// @notice The deposit follows the NFT: the active escrow position's recipient
    ///         must always equal the current NFT holder. Every transfer that moves a
    ///         name off the prior position recipient rebinds the position to the new
    ///         holder, so a depositor cannot recover D by transferring the name to a
    ///         fresh address.
    /// @dev Released positions are exempt because the NFT then sits in escrow custody
    ///      and `position.recipient` is the locked refund recipient for the
    ///      release-and-withdraw leg rather than the NFT holder. Positions whose slot
    ///      has been deleted (after reclaim) are also exempt via the `amount == 0`
    ///      and `recipient == address(0)` skip.
    function invariant_position_recipient_mirrors_current_nft_holder() public view {
        uint256[] memory deposited = handler.getDepositedTokenIds();
        for (uint256 i; i < deposited.length; ++i) {
            uint256 tokenId = deposited[i];
            IDotnsNameEscrow.ReleasePosition memory position =
                dotnsNameEscrow.getReleasePosition(tokenId);

            if (position.recipient == address(0) || position.released) continue;

            assertEq(
                position.recipient,
                dotnsRegistrar.ownerOf(tokenId),
                "active deposit recipient must mirror the current NFT holder"
            );
        }
    }

    /// @notice The controller must never hold native funds (all deposits flow to escrow).
    function invariant_no_funds_in_controller() public view {
        assertEq(address(dotnsRegistrarController).balance, 0, "Controller must not hold funds");
    }

    /// @notice Every withdrawn token must have a zero amount in its release position.
    function invariant_claimed_positions_have_zero_amount() public view {
        uint256[] memory withdrawn = handler.getWithdrawnTokenIds();

        for (uint256 i; i < withdrawn.length; ++i) {
            IDotnsNameEscrow.ReleasePosition memory position =
                dotnsNameEscrow.getReleasePosition(withdrawn[i]);

            assertEq(position.amount, 0, "Withdrawn position must have zero amount");
        }
    }

    /// @notice Every withdrawn-but-not-reclaimed token must be held by escrow and available.
    /// @dev Under the custody model, withdrawn tokens stay in escrow custody until a new
    ///      registrant reclaims them. They must remain `available()` for re-registration.
    function invariant_withdrawn_tokens_are_in_escrow_custody_and_available() public view {
        uint256[] memory withdrawn = handler.getWithdrawnTokenIds();

        for (uint256 i; i < withdrawn.length; ++i) {
            uint256 tokenId = withdrawn[i];

            assertEq(
                dotnsRegistrar.ownerOf(tokenId),
                address(dotnsNameEscrow),
                "Withdrawn token must be held by escrow"
            );
            assertTrue(
                dotnsRegistrar.available(tokenId), "Withdrawn token must be available for reclaim"
            );
        }
    }
}
