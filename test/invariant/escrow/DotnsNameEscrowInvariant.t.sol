// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";
import {EscrowHandler} from "./EscrowHandler.t.sol";

/// @title dotNS Name Escrow Invariant Suite
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

        bytes4[] memory selectors = new bytes4[](12);
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
        // The two halves of the redeem window. Without both, the fuzzer can only reach reclaim by
        // way of a withdrawal, which is precisely the assumption the reclaim deadlock rested on.
        selectors[10] = handler.redeemReleased.selector;
        selectors[11] = handler.reRegisterReleased.selector;
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
    /// reserves, the protocol fees, unclaimed pull-payment balances, and the time-locked
    /// refund-ledger entries credited by the refund-on-leave path. Under the deposit-binds-
    /// to-depositor model these four flows are economically distinct; solvency is only
    /// meaningful against their sum.
    function invariant_solvency() public view {
        uint256 escrowBalance = address(dotnsNameEscrow).balance;
        uint256 reservedAmount = dotnsNameEscrow.reserves(address(0));
        uint256 protocolFees = dotnsNameEscrow.protocolFees();
        uint256 pending = handler.totalPendingWithdrawals();
        uint256 refundEntries = handler.totalPendingRefundEntries();

        assertGe(
            escrowBalance,
            reservedAmount + protocolFees + pending + refundEntries,
            "Escrow balance must cover reserves + protocol fees + pending withdrawals + refund entries"
        );
    }

    /// @notice The handler's mirror of protocol-fee inflows must equal the escrow's on-chain
    ///         protocol-fee balance. Protocol fees only ever accrue, so every inflow the handler
    ///         tracks (cross-tier register and payable transfer) must sum to exactly the balance.
    function invariant_protocol_fees_match_tracked_inflows() public view {
        assertEq(
            handler.ghost_protocolFeesPaidIn(),
            dotnsNameEscrow.protocolFees(),
            "Tracked protocol-fee inflows must equal on-chain protocol fees"
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

    /// @notice Every withdrawn-but-not-reclaimed token must be held by escrow, and available
    ///         exactly when its redeem window has elapsed.
    /// @dev Withdrawn tokens stay in escrow custody until a new registrant reclaims them. Custody
    ///      alone no longer implies availability: withdrawing does not shorten the previous
    ///      holder's redeem window, so a withdrawn position can still be inside it. Availability
    ///      is therefore asserted against the window rather than unconditionally.
    function invariant_withdrawn_tokens_are_in_escrow_custody_and_available() public view {
        uint256[] memory withdrawn = handler.getWithdrawnTokenIds();

        for (uint256 i; i < withdrawn.length; ++i) {
            uint256 tokenId = withdrawn[i];

            assertEq(
                dotnsRegistrar.ownerOf(tokenId),
                address(dotnsNameEscrow),
                "Withdrawn token must be held by escrow"
            );

            IDotnsNameEscrow.ReleasePosition memory position =
                dotnsNameEscrow.getReleasePosition(tokenId);

            assertEq(
                dotnsRegistrar.available(tokenId),
                position.released && block.timestamp >= position.redeemableUntil,
                "Withdrawn token is available exactly once its redeem window has elapsed"
            );
        }
    }

    /// @notice No released token can ever be stuck: it is always either redeemable or reclaimable.
    /// @dev This is the property the bug violated, stated directly. Under the old
    ///      `released && claimed` reclaim gate a released position whose holder never withdrew was
    ///      neither redeemable (no such call existed) nor reclaimable (the flag was never set), so
    ///      the name left circulation permanently. The two phases must tile the whole timeline with
    ///      no gap, and must not overlap -- an overlap would mean the previous holder and a new
    ///      registrant could both act on the same name.
    function invariant_released_tokens_are_never_stuck() public view {
        // Withdrawn tokens are still released positions, and a position settled while inside its
        // window is the only state with no action available right now. Iterating released tokens
        // alone would skip exactly that state, because the handler moves a token out of
        // `_releasedTokenIds` the moment it is withdrawn, so the invariant meant to prove nothing
        // gets stuck would never evaluate the one state that pauses.
        _assertNotStuck(handler.getReleasedTokenIds());
        _assertNotStuck(handler.getWithdrawnTokenIds());
    }

    /// @notice Anything the escrow reports reclaimable can actually be paid out when reclaimed.
    /// @dev Lifecycle state only. `reclaim` also settles the deposit and can revert
    ///     `InsufficientFunds` when the reserved balance cannot cover the amount owed, so a true
    ///     answer is a claim about the window rather than a guarantee that the call is funded. The
    ///     two coincide because `tokenReserved` is by construction the
    ///     exact sum of live position amounts: only `deposit` credits it, and only `_settleDeposit`
    ///     debits
    ///     it, by exactly the amount it zeroes. `invariant_reserves_match_positions` holds that
    ///     construction and `invariant_reclaimable_positions_are_fundable` asserts the implication,
    ///     so a change breaking the coincidence fails the suite rather than surfacing as a name
    ///     advertised and then unregisterable.
    function invariant_reclaimable_positions_are_fundable() public view {
        _assertFundable(handler.getReleasedTokenIds());
        _assertFundable(handler.getWithdrawnTokenIds());
    }

    /// @notice Asserts settlement solvency for every reclaimable token in a set.
    function _assertFundable(uint256[] memory tokenIds) private view {
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];

            if (!dotnsNameEscrow.isReclaimable(tokenId)) continue;

            IDotnsNameEscrow.ReleasePosition memory position =
                dotnsNameEscrow.getReleasePosition(tokenId);

            assertLe(
                position.amount,
                dotnsNameEscrow.reserves(position.asset),
                "a reclaimable position must be settleable from reserves"
            );
        }
    }

    /// @notice Asserts the never-stuck property across a set of token ids.
    function _assertNotStuck(uint256[] memory tokenIds) private view {
        uint256 maxWindow = dotnsNameEscrow.MAX_REDEEM_WINDOW();

        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];

            IDotnsNameEscrow.ReleasePosition memory position =
                dotnsNameEscrow.getReleasePosition(tokenId);

            if (!position.released) continue;

            // A release always stamps a deadline. Without one the position would sit released with
            // nothing to wait for, which is the shape of the deadlock this invariant exists to
            // rule out.
            assertNotEq(position.redeemableUntil, 0, "a released position must carry a deadline");

            // And the wait is bounded by policy: no position can be parked further out than the
            // longest window the owner is allowed to configure.
            assertLe(
                position.redeemableUntil,
                block.timestamp + maxWindow,
                "the wait must not exceed the maximum configurable window"
            );

            // The escrow's own answer, checked against the property restated independently from
            // the position's fields. Comparing two locally-derived expressions would hold by
            // construction and assert nothing.
            assertEq(
                dotnsNameEscrow.isReclaimable(tokenId),
                block.timestamp >= position.redeemableUntil,
                "a released position is reclaimable exactly once its deadline has passed"
            );

            // Two contracts, one answer. The registrar advertises a name held by the escrow as
            // registrable exactly when the escrow would let it be reclaimed, so a client can never
            // be sent through a commit-reveal cycle that cannot succeed.
            assertEq(
                dotnsRegistrar.available(tokenId),
                dotnsNameEscrow.isReclaimable(tokenId),
                "availability must agree with reclaimability"
            );
        }
    }
}
