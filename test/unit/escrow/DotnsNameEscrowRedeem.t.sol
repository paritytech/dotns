// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";
import {
    IDotnsRegistrarController
} from "../../../contracts/registrars/IDotnsRegistrarController.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

/// @title DotnsNameEscrowRedeemTest
/// @notice Unit tests for the two-phase release lifecycle on @custom:contract DotnsNameEscrow:
///         the previous holder's exclusive redeem window, permissionless reclaim once it elapses,
///         and the deposit settlement that makes the second possible without stranding value.
/// @dev The defect these cover: reclaim used to gate on the `claimed` flag, which is only set by
///      `withdraw`. A holder who released a name and never withdrew removed the label from
///      circulation permanently. For the zero-amount positions seeded by cross-payer registrations
///      there is nothing to withdraw, so that was the default outcome rather than an edge case.
contract DotnsNameEscrowRedeemTest is BaseDotns {
    /// @notice 14-char label classifying as NoStatus, so registration seeds a funded position.
    string internal constant FUNDED_LABEL = "redeemlabela01";

    /// @notice 6-char digit-free label classifying as Personhood, registered on the cross-payer
    ///         path so its deposit position carries a zero amount.
    string internal constant FREE_LABEL = "redeem";

    /// @notice Register `label` for `nameOwner` at `status` and return its tokenId.
    function _registerAt(
        string memory label,
        address nameOwner,
        IPopRules.PopStatus status
    )
        internal
        returns (uint256 tokenId)
    {
        _register(label, nameOwner, status);
        tokenId = _tokenIdForLabel(label);
    }

    /// @notice Register `label` for `nameOwner` on the cross-payer path (`payer` pays, `nameOwner`
    ///         receives the name) and return its tokenId.
    /// @dev A cross-payer registration routes the whole charge to the protocol fee pot and seeds a
    ///      zero-amount refundable position keyed to `nameOwner`, which is the registration shape
    ///      that produces a zero-amount position. `nameOwner` must carry `status`, because the
    ///      controller prices the owner's tier on this path.
    function _registerCrossPayer(
        string memory label,
        address nameOwner,
        address payer,
        IPopRules.PopStatus status
    )
        internal
        returns (uint256 tokenId)
    {
        _setUserPopStatus(nameOwner, status);

        bytes32 secret = keccak256(abi.encodePacked(label, nameOwner, block.timestamp));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label,
                owner: nameOwner,
                secret: secret,
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        vm.prank(payer);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 charge = popRules.priceWithoutCheck(label, nameOwner).price;
        vm.prank(payer);
        dotnsRegistrarController.register{value: charge}(registration);

        tokenId = _tokenIdForLabel(label);
    }

    /// @notice Approve the escrow for `tokenId` and release it as `caller`.
    function _approveAndRelease(uint256 tokenId, address caller) internal {
        vm.startPrank(caller);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();
    }

    function _positionOf(uint256 tokenId)
        internal
        view
        returns (IDotnsNameEscrow.ReleasePosition memory position)
    {
        position = dotnsNameEscrow.getReleasePosition(tokenId);
    }

    // release stamps both clocks

    function test_release_stamps_independent_withdraw_and_redeem_clocks() public {
        uint256 tokenId = _registerAt(FUNDED_LABEL, ed, IPopRules.PopStatus.NoStatus);

        uint256 releasedAt = block.timestamp;
        _approveAndRelease(tokenId, ed);

        IDotnsNameEscrow.ReleasePosition memory position = _positionOf(tokenId);

        assertEq(
            position.withdrawAvailableAt,
            releasedAt + ESCROW_COOLDOWN,
            "withdraw clock is release + cooldown"
        );
        assertEq(
            position.redeemableUntil,
            releasedAt + ESCROW_REDEEM_WINDOW,
            "redeem clock is release + redeem window"
        );
        assertGt(
            position.redeemableUntil,
            position.withdrawAvailableAt,
            "the redeem window must outlast the withdraw cooldown for the phases to be distinct"
        );
    }

    /// @dev The event carries both clocks, and `redeemableUntil` is what clients watch to know when
    ///      a released name becomes registrable. An indexer reading a wrong value here would
    ///      advertise the name at the wrong moment, so the emitted timestamp is asserted rather
    ///      than only the stored one.
    function test_release_emits_both_clocks_on_NameReleased() public {
        uint256 tokenId = _registerAt(FUNDED_LABEL, ed, IPopRules.PopStatus.NoStatus);

        IDotnsNameEscrow.ReleasePosition memory before = _positionOf(tokenId);
        uint256 releasedAt = block.timestamp;

        vm.startPrank(ed);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);

        vm.expectEmit(true, true, true, true, address(dotnsNameEscrow));
        emit IDotnsNameEscrow.NameReleased(
            tokenId,
            ed,
            before.asset,
            before.amount,
            releasedAt + ESCROW_COOLDOWN,
            releasedAt + ESCROW_REDEEM_WINDOW
        );
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();

        // The emitted deadline and the stored one must be the same value; a client acting on the
        // event must not reach a different conclusion from one reading state directly.
        assertEq(
            _positionOf(tokenId).redeemableUntil,
            releasedAt + ESCROW_REDEEM_WINDOW,
            "the stored deadline matches the emitted one"
        );
    }

    function test_release_reverts_when_redeem_window_is_unseeded() public {
        uint256 tokenId = _registerAt(FUNDED_LABEL, ed, IPopRules.PopStatus.NoStatus);

        // Simulate a proxy upgraded without pairing the upgrade with `updateRedeemWindow`. The
        // release must fail closed rather than stamp `redeemableUntil` at the current timestamp,
        // which would open permissionless reclaim the instant the name was released.
        vm.store(address(dotnsNameEscrow), _redeemWindowSlot(), bytes32(0));
        assertEq(dotnsNameEscrow.redeemWindow(), 0, "redeem window is unseeded for this case");

        vm.startPrank(ed);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        vm.expectRevert(IDotnsNameEscrow.RedeemWindowNotConfigured.selector);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();
    }

    /// @dev `redeemWindow` sits immediately after `_nextEntryId` in the layout. Located by scanning
    ///      rather than hardcoded so the test fails loudly on a layout change instead of silently
    ///      poking an unrelated slot.
    function _redeemWindowSlot() internal view returns (bytes32 slot) {
        uint256 expected = dotnsNameEscrow.redeemWindow();
        for (uint256 i = 0; i < 64; ++i) {
            if (uint256(vm.load(address(dotnsNameEscrow), bytes32(i))) == expected) {
                return bytes32(i);
            }
        }
        revert("redeemWindow slot not found; storage layout changed");
    }

    // redeem: the previous holder's undo

    function test_redeem_returns_the_name_and_moves_no_value() public {
        uint256 tokenId = _registerAt(FUNDED_LABEL, ed, IPopRules.PopStatus.NoStatus);
        _approveAndRelease(tokenId, ed);

        IDotnsNameEscrow.ReleasePosition memory before = _positionOf(tokenId);
        uint256 reservedBefore = dotnsNameEscrow.reserves(address(0));
        uint256 escrowBalanceBefore = address(dotnsNameEscrow).balance;
        uint256 edBalanceBefore = ed.balance;

        vm.expectEmit(true, true, true, true, address(dotnsNameEscrow));
        emit IDotnsNameEscrow.NameRedeemed(tokenId, ed);
        vm.prank(ed);
        dotnsNameEscrow.redeem(tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), ed, "custody returns to the previous holder");
        assertEq(ed.balance, edBalanceBefore, "redeem must not pay the holder anything");
        assertEq(
            address(dotnsNameEscrow).balance,
            escrowBalanceBefore,
            "redeem must not move value out of escrow"
        );
        assertEq(
            dotnsNameEscrow.reserves(address(0)),
            reservedBefore,
            "the deposit stays reserved against the name"
        );
        assertEq(
            dotnsNameEscrow.pendingWithdrawal(ed),
            0,
            "redeem must not credit the pull-payment ledger"
        );

        IDotnsNameEscrow.ReleasePosition memory position = _positionOf(tokenId);
        assertFalse(position.released, "released flag cleared");
        assertEq(position.withdrawAvailableAt, 0, "withdraw clock cleared");
        assertEq(position.redeemableUntil, 0, "redeem clock cleared");
        assertEq(position.recipient, before.recipient, "recipient preserved");
        assertEq(position.asset, before.asset, "asset preserved");
        assertEq(position.amount, before.amount, "deposit still locked against the name");
        assertFalse(position.claimed, "position is not marked settled by a redeem");
    }

    function test_redeem_removes_the_token_from_released_enumeration() public {
        uint256 tokenId = _registerAt(FUNDED_LABEL, ed, IPopRules.PopStatus.NoStatus);
        _approveAndRelease(tokenId, ed);

        assertEq(dotnsNameEscrow.releasedTokenCount(), 1, "released set holds the token");

        vm.prank(ed);
        dotnsNameEscrow.redeem(tokenId);

        assertEq(dotnsNameEscrow.releasedTokenCount(), 0, "released set drops the redeemed token");
    }

    function test_redeem_then_release_again_starts_fresh_clocks() public {
        uint256 tokenId = _registerAt(FUNDED_LABEL, ed, IPopRules.PopStatus.NoStatus);
        _approveAndRelease(tokenId, ed);

        vm.prank(ed);
        dotnsNameEscrow.redeem(tokenId);

        vm.warp(block.timestamp + 5 days);
        uint256 secondReleaseAt = block.timestamp;
        _approveAndRelease(tokenId, ed);

        IDotnsNameEscrow.ReleasePosition memory position = _positionOf(tokenId);
        assertTrue(position.released, "the name is releasable again after a redeem");
        assertEq(
            position.withdrawAvailableAt,
            secondReleaseAt + ESCROW_COOLDOWN,
            "the second release recomputes the withdraw clock rather than inheriting a stale one"
        );
        assertEq(
            position.redeemableUntil,
            secondReleaseAt + ESCROW_REDEEM_WINDOW,
            "the second release recomputes the redeem clock"
        );
    }

    function test_revert_redeem_after_the_window_closes() public {
        uint256 tokenId = _registerAt(FUNDED_LABEL, ed, IPopRules.PopStatus.NoStatus);
        _approveAndRelease(tokenId, ed);

        vm.warp(_positionOf(tokenId).redeemableUntil);

        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsNameEscrow.NotRedeemable.selector, tokenId));
        dotnsNameEscrow.redeem(tokenId);
    }

    function test_revert_redeem_by_someone_other_than_the_recipient() public {
        uint256 tokenId = _registerAt(FUNDED_LABEL, ed, IPopRules.PopStatus.NoStatus);
        _approveAndRelease(tokenId, ed);

        vm.prank(leonardo);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameEscrow.NotRefundRecipient.selector, leonardo, tokenId)
        );
        dotnsNameEscrow.redeem(tokenId);
    }

    function test_revert_redeem_on_an_unreleased_position() public {
        uint256 tokenId = _registerAt(FUNDED_LABEL, ed, IPopRules.PopStatus.NoStatus);

        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsNameEscrow.NotRedeemable.selector, tokenId));
        dotnsNameEscrow.redeem(tokenId);
    }

    /// @dev The load-bearing exclusion. Withdraw opens at +cooldown while redeem stays open to
    ///      +redeemWindow, so without this guard a holder could pull the deposit early and then
    ///      take the name back, ending up with a NoStatus name that no deposit backs. That would
    ///      break the one-deposit-per-live-name bound the deposit exists to enforce.
    function test_revert_redeem_after_withdrawing_the_deposit() public {
        uint256 tokenId = _registerAt(FUNDED_LABEL, ed, IPopRules.PopStatus.NoStatus);
        _approveAndRelease(tokenId, ed);

        vm.warp(block.timestamp + ESCROW_COOLDOWN + 1);
        vm.prank(ed);
        dotnsNameEscrow.withdraw(tokenId);

        // Still inside the redeem window, so only the `claimed` flag stands between the holder and
        // a name they have already been paid for.
        assertLt(block.timestamp, _positionOf(tokenId).redeemableUntil, "still inside the window");

        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsNameEscrow.NotRedeemable.selector, tokenId));
        dotnsNameEscrow.redeem(tokenId);
    }

    /// @dev The mirror of the case above, and the reason `claimed` is only set when value actually
    ///      moves. A zero-amount position has nothing to withdraw, so `withdraw` pays the holder
    ///      nothing, if it still flagged the position claimed it would silently forfeit their
    ///      right to recover their own name for no consideration whatsoever. `withdraw` is also a
    ///      step a holder has every reason to make before a name can be recycled.
    function test_zero_amount_withdrawal_does_not_forfeit_the_redeem_right() public {
        uint256 tokenId =
            _registerCrossPayer(FREE_LABEL, ed, leonardo, IPopRules.PopStatus.Personhood);
        assertEq(_positionOf(tokenId).amount, 0, "this case needs a zero-amount position");

        _approveAndRelease(tokenId, ed);

        vm.warp(block.timestamp + ESCROW_COOLDOWN + 1);
        uint256 balanceBefore = ed.balance;
        vm.prank(ed);
        dotnsNameEscrow.withdraw(tokenId);

        assertEq(ed.balance, balanceBefore, "there was nothing to pay out");
        assertEq(dotnsNameEscrow.pendingWithdrawal(ed), 0, "and nothing to credit");
        assertFalse(
            _positionOf(tokenId).claimed,
            "a settlement that moved no value must not flag the position claimed"
        );

        // Still inside the window, and still ed's name to recover.
        vm.prank(ed);
        dotnsNameEscrow.redeem(tokenId);

        assertEq(
            dotnsRegistrar.ownerOf(tokenId), ed, "ed recovers the name they were never paid for"
        );
    }

    // reclaim: permissionless once the window elapses

    function test_revert_reclaim_while_inside_the_redeem_window() public {
        uint256 tokenId = _registerAt(FUNDED_LABEL, ed, IPopRules.PopStatus.NoStatus);
        _approveAndRelease(tokenId, ed);

        vm.warp(block.timestamp + ESCROW_COOLDOWN + 1);
        vm.prank(ed);
        dotnsNameEscrow.withdraw(tokenId);

        // Withdrawing is no longer what opens reclaim, so even a settled position stays locked
        // until the window elapses.
        vm.prank(address(dotnsRegistrarController));
        vm.expectRevert(abi.encodeWithSelector(IDotnsNameEscrow.NotReclaimable.selector, tokenId));
        dotnsNameEscrow.reclaim(tokenId, leonardo);
    }

    function test_reclaim_settles_an_unwithdrawn_deposit_to_the_previous_holder() public {
        uint256 tokenId = _registerAt(FUNDED_LABEL, ed, IPopRules.PopStatus.NoStatus);
        _approveAndRelease(tokenId, ed);

        uint256 deposit = _positionOf(tokenId).amount;
        assertGt(deposit, 0, "this case needs a funded position");

        vm.warp(_positionOf(tokenId).redeemableUntil);

        // ed never withdrew. Reclaim must not strand their deposit.
        vm.prank(address(dotnsRegistrarController));
        dotnsNameEscrow.reclaim(tokenId, leonardo);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo, "the name goes to the new registrant");
        assertEq(
            dotnsNameEscrow.pendingWithdrawal(ed),
            deposit,
            "the deposit follows the departing holder onto the pull-payment ledger"
        );
        assertEq(_positionOf(tokenId).recipient, address(0), "position cleared for re-registration");
    }

    /// @dev Acceptance criterion: the credit has no deadline, so a holder who reappears much later
    ///      is still made whole.
    function test_settled_deposit_stays_claimable_long_after_reclaim() public {
        uint256 tokenId = _registerAt(FUNDED_LABEL, ed, IPopRules.PopStatus.NoStatus);
        _approveAndRelease(tokenId, ed);

        uint256 deposit = _positionOf(tokenId).amount;
        vm.warp(_positionOf(tokenId).redeemableUntil);

        vm.prank(address(dotnsRegistrarController));
        dotnsNameEscrow.reclaim(tokenId, leonardo);

        vm.warp(block.timestamp + 365 days);

        uint256 balanceBefore = ed.balance;
        vm.prank(ed);
        uint256 claimed = dotnsNameEscrow.claimWithdrawal();

        assertEq(claimed, deposit, "the full deposit is claimable a year later");
        assertEq(ed.balance - balanceBefore, deposit, "and actually lands with the holder");
    }

    function test_reclaim_after_withdrawal_credits_nothing_twice() public {
        uint256 tokenId = _registerAt(FUNDED_LABEL, ed, IPopRules.PopStatus.NoStatus);
        _approveAndRelease(tokenId, ed);

        uint256 deposit = _positionOf(tokenId).amount;

        vm.warp(block.timestamp + ESCROW_COOLDOWN + 1);
        vm.prank(ed);
        dotnsNameEscrow.withdraw(tokenId);

        assertEq(dotnsNameEscrow.pendingWithdrawal(ed), deposit, "withdraw credited once");

        vm.warp(_positionOf(tokenId).redeemableUntil);
        vm.prank(address(dotnsRegistrarController));
        dotnsNameEscrow.reclaim(tokenId, leonardo);

        assertEq(
            dotnsNameEscrow.pendingWithdrawal(ed),
            deposit,
            "an already-settled position must not be credited a second time on reclaim"
        );
    }

    // the zero-amount case: what the bug actually was

    /// @dev The headline regression test. A cross-payer registration seeds a zero-amount position,
    ///      so its holder has nothing to withdraw and therefore no reason ever to call `withdraw`.
    ///      Under a `released && claimed` reclaim gate that would make the name permanently
    ///      unregisterable.
    function test_zero_amount_release_becomes_reclaimable_without_any_withdrawal() public {
        uint256 tokenId =
            _registerCrossPayer(FREE_LABEL, ed, leonardo, IPopRules.PopStatus.Personhood);

        assertEq(
            _positionOf(tokenId).amount,
            0,
            "a cross-payer registration seeds a zero-amount position"
        );

        _approveAndRelease(tokenId, ed);

        // ed never withdraws: there is nothing to withdraw.
        assertFalse(_positionOf(tokenId).claimed, "nothing was ever withdrawn");
        assertFalse(
            dotnsRegistrar.available(tokenId),
            "the name is not advertised as free while ed can still redeem it"
        );

        vm.warp(_positionOf(tokenId).redeemableUntil);

        assertTrue(
            dotnsRegistrar.available(tokenId),
            "once the window elapses the name reports registrable"
        );

        uint256 escrowBalanceBefore = address(dotnsNameEscrow).balance;

        vm.prank(address(dotnsRegistrarController));
        dotnsNameEscrow.reclaim(tokenId, leonardo);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo, "a third party takes over the name");
        assertEq(
            dotnsNameEscrow.pendingWithdrawal(ed),
            0,
            "a zero-amount position writes no ledger entry"
        );
        assertEq(address(dotnsNameEscrow).balance, escrowBalanceBefore, "and moves no value");
    }

    // governance: updateRedeemWindow

    function test_updateRedeemWindow_sets_the_value_and_emits() public {
        uint256 current = dotnsNameEscrow.redeemWindow();
        uint256 next = 3 days;

        vm.expectEmit(true, true, true, true, address(dotnsNameEscrow));
        emit IDotnsNameEscrow.RedeemWindowUpdated(current, next);
        vm.prank(owner);
        dotnsNameEscrow.updateRedeemWindow(next);

        assertEq(dotnsNameEscrow.redeemWindow(), next, "the new window is stored");
    }

    function test_revert_updateRedeemWindow_on_zero() public {
        uint256 min = dotnsNameEscrow.MIN_REDEEM_WINDOW();

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameEscrow.RedeemWindowTooShort.selector, 0, min)
        );
        dotnsNameEscrow.updateRedeemWindow(0);
    }

    function test_revert_updateRedeemWindow_below_the_floor() public {
        uint256 min = dotnsNameEscrow.MIN_REDEEM_WINDOW();

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameEscrow.RedeemWindowTooShort.selector, min - 1, min)
        );
        dotnsNameEscrow.updateRedeemWindow(min - 1);
    }

    /// @dev Both bounds are inclusive, so the extremes must be settable rather than one-off
    ///      rejected. A floor that rejected its own value would leave the deploy default
    ///      unreachable through the setter.
    function test_updateRedeemWindow_accepts_both_bounds() public {
        uint256 min = dotnsNameEscrow.MIN_REDEEM_WINDOW();
        uint256 max = dotnsNameEscrow.MAX_REDEEM_WINDOW();

        vm.prank(owner);
        dotnsNameEscrow.updateRedeemWindow(min);
        assertEq(dotnsNameEscrow.redeemWindow(), min, "the floor itself is settable");

        vm.prank(owner);
        dotnsNameEscrow.updateRedeemWindow(max);
        assertEq(dotnsNameEscrow.redeemWindow(), max, "the ceiling itself is settable");
    }

    function test_revert_updateRedeemWindow_above_the_ceiling() public {
        uint256 max = dotnsNameEscrow.MAX_REDEEM_WINDOW();

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameEscrow.RedeemWindowTooLong.selector, max + 1, max)
        );
        dotnsNameEscrow.updateRedeemWindow(max + 1);
    }

    function test_revert_updateRedeemWindow_from_a_non_owner() public {
        vm.prank(ed);
        vm.expectRevert();
        dotnsNameEscrow.updateRedeemWindow(3 days);
    }

    /// @dev The window is snapshotted per position at release time, so retuning policy must never
    ///      move the goalposts for a name already in flight.
    function test_updateRedeemWindow_does_not_move_an_in_flight_position() public {
        uint256 tokenId = _registerAt(FUNDED_LABEL, ed, IPopRules.PopStatus.NoStatus);
        _approveAndRelease(tokenId, ed);

        uint64 stamped = _positionOf(tokenId).redeemableUntil;

        // Read the ceiling before pranking: an external call in the argument list would consume
        // the prank and the update would arrive from the test contract instead of the owner.
        uint256 max = dotnsNameEscrow.MAX_REDEEM_WINDOW();

        vm.prank(owner);
        dotnsNameEscrow.updateRedeemWindow(max);

        assertEq(
            _positionOf(tokenId).redeemableUntil,
            stamped,
            "an in-flight position keeps the window it was released under"
        );
    }
}
