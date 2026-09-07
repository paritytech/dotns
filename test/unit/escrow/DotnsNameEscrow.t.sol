// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {BaseDotns, IDotnsRegistrarController} from "../../base/BaseDotns.t.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

/// @title ForceSender
/// @notice Self-destructing helper that force-credits its constructor balance to `target`,
///         bypassing the receive/fallback guards on the recipient.
contract ForceSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @title GhostNft
/// @notice Standalone ERC721 used to verify the escrow refuses tokens not minted by the
///         configured registrar.
contract GhostNft is ERC721 {
    constructor() ERC721("Ghost", "GHST") {}

    /// @notice Mint `tokenId` to `to` for use in foreign-NFT rejection tests.
    function mint(address to, uint256 tokenId) external {
        _safeMint(to, tokenId);
    }
}

/// @title DotnsNameEscrowTest
/// @notice Unit tests covering the deposit, release, withdrawal and reclaim lifecycle on
///         @custom:contract DotnsNameEscrow, plus the pull-payment and solvency guarantees.
contract DotnsNameEscrowTest is BaseDotns {
    /// @notice Default label used across most tests.
    /// @dev Nine-character stem that classifies as NoStatus; the flat deposit equals
    ///      BASE_DEPOSIT.
    string internal constant LABEL = "labelnine01";

    /// @notice Register `label` for `nameOwner` under the NoStatus PoP tier and return its tokenId.
    function _registerNoStatus(
        string memory label,
        address nameOwner
    )
        internal
        returns (uint256 tokenId)
    {
        _register(label, nameOwner, IPopRules.PopStatus.NoStatus);
        tokenId = _tokenIdForLabel(label);
    }

    /// @notice Approve the escrow for `tokenId` and call `release` as `caller`.
    function _approveAndRelease(uint256 tokenId, address caller) internal {
        vm.startPrank(caller);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();
    }

    /// @notice Drive the full register -> release -> wait-cooldown -> withdraw flow.
    /// @dev Leaves the position withdrawn but not yet claimed via `claimWithdrawal`.
    function _fullWithdrawFlow(
        string memory label,
        address nameOwner
    )
        internal
        returns (uint256 tokenId)
    {
        tokenId = _registerNoStatus(label, nameOwner);
        _approveAndRelease(tokenId, nameOwner);
        vm.warp(block.timestamp + ESCROW_COOLDOWN + 1);
        vm.prank(nameOwner);
        dotnsNameEscrow.withdraw(tokenId);
    }

    function test_deposit_records_position() public {
        uint256 tokenId = _registerNoStatus(LABEL, ed);

        IDotnsNameEscrow.ReleasePosition memory pos = dotnsNameEscrow.getReleasePosition(tokenId);

        assertEq(pos.amount, BASE_DEPOSIT, "amount should equal BASE_DEPOSIT");
        assertEq(pos.asset, address(0), "asset should be native (address(0))");
        assertFalse(pos.released, "released should be false");
        assertFalse(pos.claimed, "claimed should be false");
    }

    function test_release_transfers_token_to_escrow() public {
        uint256 tokenId = _registerNoStatus(LABEL, ed);
        _approveAndRelease(tokenId, ed);

        assertEq(
            dotnsRegistrar.ownerOf(tokenId), address(dotnsNameEscrow), "escrow should own the token"
        );

        IDotnsNameEscrow.ReleasePosition memory pos = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(pos.recipient, ed, "recipient should be snapshotted as ed");
        assertTrue(pos.released, "released should be true");
        assertGt(pos.withdrawAvailableAt, 0, "withdrawAvailableAt should be set");
    }

    function test_withdraw_sends_refund_after_cooldown() public {
        uint256 tokenId = _registerNoStatus(LABEL, ed);
        _approveAndRelease(tokenId, ed);

        uint256 reservesBefore = dotnsNameEscrow.reserves(address(0));
        uint256 balanceBefore = ed.balance;

        vm.warp(block.timestamp + ESCROW_COOLDOWN + 1);
        vm.prank(ed);
        dotnsNameEscrow.withdraw(tokenId);

        // Pull-payment: withdraw credits the pending balance; the recipient must
        // call claimWithdrawal to actually receive the funds.
        assertEq(
            dotnsNameEscrow.pendingWithdrawal(ed),
            BASE_DEPOSIT,
            "pending withdrawal should be credited"
        );

        vm.prank(ed);
        dotnsNameEscrow.claimWithdrawal();

        assertEq(ed.balance, balanceBefore + BASE_DEPOSIT, "ed should receive BASE_DEPOSIT refund");

        IDotnsNameEscrow.ReleasePosition memory pos = dotnsNameEscrow.getReleasePosition(tokenId);
        assertTrue(pos.claimed, "claimed should be true");

        uint256 reservesAfter = dotnsNameEscrow.reserves(address(0));
        assertEq(reservesAfter, reservesBefore - BASE_DEPOSIT, "reserves should be decremented");
    }

    function test_reclaim_transfers_custody_to_new_owner() public {
        uint256 tokenId = _fullWithdrawFlow(LABEL, ed);

        assertEq(
            dotnsRegistrar.ownerOf(tokenId),
            address(dotnsNameEscrow),
            "escrow holds token before reclaim"
        );

        // Withdrawing no longer opens reclaim on its own: the redeem window has to elapse, because
        // that window is the previous holder's exclusive claim on the name.
        vm.warp(block.timestamp + ESCROW_REDEEM_WINDOW + 1);

        vm.prank(address(dotnsRegistrarController));
        dotnsNameEscrow.reclaim(tokenId, leonardo);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo, "leonardo owns token after reclaim");

        IDotnsNameEscrow.ReleasePosition memory pos = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(pos.recipient, address(0), "position fully cleared after reclaim");
        assertEq(pos.amount, 0, "position amount zeroed after reclaim");
        assertFalse(pos.released, "released flag cleared after reclaim");
    }

    function test_revert_deposit_not_controller() public {
        uint256 tokenId = _tokenIdForLabel(LABEL);

        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsNameEscrow.NotController.selector, ed));
        dotnsNameEscrow.deposit(
            IDotnsNameEscrow.DepositParams({
                tokenId: tokenId, asset: address(0), amount: 1 ether, recipient: ed
            })
        );
    }

    function test_revert_ghost_nft_transfer_into_escrow() public {
        GhostNft ghost = new GhostNft();
        uint256 ghostId = 42;
        ghost.mint(ed, ghostId);

        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameEscrow.NotAcceptedTransfer.selector, address(ghost))
        );
        ghost.safeTransferFrom(ed, address(dotnsNameEscrow), ghostId);

        assertEq(ghost.ownerOf(ghostId), ed, "ghost NFT must remain with the original owner");
    }

    function test_self_registration_seeds_funded_position() public {
        string memory popLabel = "selfregis";
        bytes32 node = _register(popLabel, ed, IPopRules.PopStatus.PopFull);
        uint256 tokenId = uint256(node);

        vm.prank(ed);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);

        vm.prank(ed);
        dotnsNameEscrow.release(tokenId);

        IDotnsNameEscrow.ReleasePosition memory position =
            dotnsNameEscrow.getReleasePosition(tokenId);
        assertTrue(position.released, "self-registered name must be releasable");
        assertEq(position.amount, BASE_DEPOSIT, "self-registration locks a refundable deposit");
        assertEq(position.recipient, ed, "position is bound to the registrant");
    }

    function test_revert_release_not_holder() public {
        uint256 tokenId = _registerNoStatus(LABEL, ed);

        vm.prank(tiago);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameEscrow.NotRefundRecipient.selector, tiago, tokenId)
        );
        dotnsNameEscrow.release(tokenId);
    }

    function test_revert_withdraw_not_recipient() public {
        uint256 tokenId = _registerNoStatus(LABEL, ed);
        _approveAndRelease(tokenId, ed);

        vm.warp(block.timestamp + ESCROW_COOLDOWN + 1);

        vm.prank(tiago);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameEscrow.NotRefundRecipient.selector, tiago, tokenId)
        );
        dotnsNameEscrow.withdraw(tokenId);
    }

    function test_revert_reclaim_not_controller() public {
        uint256 tokenId = _fullWithdrawFlow(LABEL, ed);

        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsNameEscrow.NotController.selector, ed));
        dotnsNameEscrow.reclaim(tokenId, leonardo);
    }

    function test_revert_double_release() public {
        uint256 tokenId = _registerNoStatus(LABEL, ed);
        _approveAndRelease(tokenId, ed);

        vm.prank(address(dotnsNameEscrow));
        vm.expectRevert(abi.encodeWithSelector(IDotnsNameEscrow.AlreadyReleased.selector, tokenId));
        dotnsNameEscrow.release(tokenId);
    }

    function test_revert_withdraw_before_cooldown() public {
        uint256 tokenId = _registerNoStatus(LABEL, ed);
        _approveAndRelease(tokenId, ed);

        IDotnsNameEscrow.ReleasePosition memory pos = dotnsNameEscrow.getReleasePosition(tokenId);

        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsNameEscrow.WithdrawalTooEarly.selector,
                tokenId,
                pos.withdrawAvailableAt,
                block.timestamp
            )
        );
        dotnsNameEscrow.withdraw(tokenId);
    }

    function test_revert_reclaim_before_withdraw() public {
        uint256 tokenId = _registerNoStatus(LABEL, ed);
        _approveAndRelease(tokenId, ed);

        // Released but not claimed/withdrawn; not reclaimable yet.
        vm.prank(address(dotnsRegistrarController));
        vm.expectRevert(abi.encodeWithSelector(IDotnsNameEscrow.NotReclaimable.selector, tokenId));
        dotnsNameEscrow.reclaim(tokenId, leonardo);
    }

    function test_revert_deposit_already_funded() public {
        uint256 tokenId = _registerNoStatus(LABEL, ed);

        vm.deal(address(dotnsRegistrarController), BASE_DEPOSIT);
        vm.prank(address(dotnsRegistrarController));
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameEscrow.PositionAlreadyFunded.selector, tokenId)
        );
        dotnsNameEscrow.deposit{value: BASE_DEPOSIT}(
            IDotnsNameEscrow.DepositParams({
                tokenId: tokenId, asset: address(0), amount: BASE_DEPOSIT, recipient: ed
            })
        );
    }

    function test_revert_release_escrow_not_approved() public {
        uint256 tokenId = _registerNoStatus(LABEL, ed);

        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameEscrow.EscrowNotApproved.selector, tokenId)
        );
        dotnsNameEscrow.release(tokenId);
    }

    function test_released_tokens_pagination() public {
        string[3] memory labels = ["longernameaa01", "longernameab02", "longernameac03"];
        uint256[3] memory tokenIds;

        for (uint256 i = 0; i < 3; i++) {
            tokenIds[i] = _registerNoStatus(labels[i], ed);
            _approveAndRelease(tokenIds[i], ed);
        }

        assertEq(dotnsNameEscrow.releasedTokenCount(), 3, "releasedTokenCount should be 3");

        uint256[] memory page1 = dotnsNameEscrow.releasedTokens(0, 2);
        assertEq(page1.length, 2, "first page should have 2 entries");

        uint256[] memory page2 = dotnsNameEscrow.releasedTokens(2, 2);
        assertEq(page2.length, 1, "second page should have 1 entry");

        uint256[] memory empty = dotnsNameEscrow.releasedTokens(10, 2);
        assertEq(empty.length, 0, "out-of-bounds start should return empty array");
    }

    function test_update_cooldown() public {
        uint256 newCooldown = 30 minutes;

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit IDotnsNameEscrow.CooldownUpdated(ESCROW_COOLDOWN, newCooldown);
        dotnsNameEscrow.updateCooldown(newCooldown);

        assertEq(dotnsNameEscrow.cooldown(), newCooldown, "cooldown should be updated");
    }

    function test_same_tier_NoStatus_transfer_rebinds_position_to_new_holder() public {
        uint256 tokenId = _registerNoStatus(LABEL, ed);

        IDotnsNameEscrow.ReleasePosition memory before = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(before.recipient, ed);
        assertEq(before.amount, BASE_DEPOSIT);

        uint256 quotedFee = dotnsRegistrar.quoteTransferFee(tokenId, leonardo);
        assertEq(quotedFee, 0, "same-tier NoStatus transfer should be free");

        uint256 reservesBefore = dotnsNameEscrow.reserves(address(0));
        uint256 edRefundsBefore = dotnsNameEscrow.pendingRefundCount(ed);
        uint256 leonardoRefundsBefore = dotnsNameEscrow.pendingRefundCount(leonardo);

        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);

        // Deposits follow the NFT: the position is rebound to the new holder rather than refunded
        // to the original payer, so transferring a funded NoStatus name forfeits the locked
        // deposit. The recycle that drove the old refund-and-delete model is closed off: the only
        // path back to D is for the current holder to release into escrow.
        IDotnsNameEscrow.ReleasePosition memory afterTransfer =
            dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(
            afterTransfer.recipient,
            leonardo,
            "position must rebind to the new holder when the NFT leaves the depositor"
        );
        assertEq(afterTransfer.amount, BASE_DEPOSIT, "deposit must travel with the name");

        assertEq(
            dotnsNameEscrow.reserves(address(0)),
            reservesBefore,
            "reserves must not move on a same-tier rebind"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(ed),
            edRefundsBefore,
            "no refund may be credited to the prior depositor at transfer time"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(leonardo),
            leonardoRefundsBefore,
            "no refund may be credited to the new holder at transfer time"
        );
    }

    function test_funded_position_rebinds_to_new_holder_on_transfer() public {
        string memory label = BASE_LABEL_A;

        _grantPopFull(ed);
        _grantPopFull(leonardo);
        _register(label, ed, IPopRules.PopStatus.PopFull);
        uint256 tokenId = _tokenIdForLabel(label);

        IDotnsNameEscrow.ReleasePosition memory before = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(before.recipient, ed, "funded position starts with registrant");
        assertEq(before.amount, BASE_DEPOSIT, "self-registration locks a refundable deposit");

        uint256 quotedFee = dotnsRegistrar.quoteTransferFee(tokenId, leonardo);
        assertEq(quotedFee, 0, "same-tier transfer costs nothing");

        uint256 edRefundsBefore = dotnsNameEscrow.pendingRefundCount(ed);
        uint256 leonardoRefundsBefore = dotnsNameEscrow.pendingRefundCount(leonardo);

        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);

        IDotnsNameEscrow.ReleasePosition memory afterTransfer =
            dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(afterTransfer.recipient, leonardo, "position must follow the current holder");
        assertEq(afterTransfer.amount, BASE_DEPOSIT, "deposit travels with the name on rebind");
        assertEq(dotnsNameEscrow.pendingRefundCount(ed), edRefundsBefore, "no refund on rebind");
        assertEq(
            dotnsNameEscrow.pendingRefundCount(leonardo),
            leonardoRefundsBefore,
            "recipient gets no refund entry"
        );

        vm.startPrank(leonardo);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();

        IDotnsNameEscrow.ReleasePosition memory afterRelease =
            dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(
            dotnsRegistrar.ownerOf(tokenId), address(dotnsNameEscrow), "escrow owns released NFT"
        );
        assertTrue(afterRelease.released, "new holder can release the transferred name");
        assertEq(afterRelease.recipient, leonardo, "release recipient is the current holder");
    }

    function test_downgrade_transfer_pays_name_price() public {
        string memory label = "lights01";

        _grantPopFull(ed);
        _grantPopLite(leonardo);

        _commitAndRegister(label, ed, false);

        uint256 tokenId = _tokenIdForLabel(label);
        uint256 ownPrice = popRules.price(label);
        uint256 quotedFee = dotnsRegistrar.quoteTransferFee(tokenId, leonardo);

        assertEq(quotedFee, ownPrice, "downgrade re-prices at the name's own length");

        uint256 priorProtocolFees = dotnsNameEscrow.protocolFees();

        vm.deal(ed, quotedFee);
        vm.prank(ed);
        dotnsRegistrar.transferFrom{value: quotedFee}(ed, leonardo, tokenId);

        assertEq(
            dotnsNameEscrow.protocolFees() - priorProtocolFees,
            ownPrice,
            "downgrade fee settles to protocol fees"
        );
    }

    function test_transfer_charges_friction_and_rebinds_position() public {
        // Downward cross-tier transfer of a funded NoStatus name: the friction fee settles to
        // protocol fees and the deposit travels with the NFT. There is no transfer-time refund:
        // `position.recipient` rebinds to the new holder, the locked deposit follows, and only
        // the new holder can later release into escrow. Promoting `ed` to PopFull before the
        // transfer forces `PopRules.transferFloor` to return the base fee D while the position
        // still carries the original `BASE_DEPOSIT` deposit, so both legs of `chargeTransferFee`
        // run in one call.
        uint256 tokenId = _registerNoStatus(LABEL, ed);

        _grantPopFull(ed);

        uint256 startingPrice = popRules.price(LABEL);
        uint256 quotedFee = dotnsRegistrar.quoteTransferFee(tokenId, leonardo);
        assertEq(quotedFee, startingPrice, "PopFull holder downgrading to NoStatus pays D");

        uint256 reservesBefore = dotnsNameEscrow.reserves(address(0));
        uint256 protocolFeesBefore = dotnsNameEscrow.protocolFees();
        uint256 edRefundsBefore = dotnsNameEscrow.pendingRefundCount(ed);
        uint256 leonardoRefundsBefore = dotnsNameEscrow.pendingRefundCount(leonardo);

        vm.deal(ed, quotedFee);
        vm.prank(ed);
        dotnsRegistrar.transferFrom{value: quotedFee}(ed, leonardo, tokenId);

        IDotnsNameEscrow.ReleasePosition memory pos = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(pos.recipient, leonardo, "position must rebind to the new holder");
        assertEq(pos.amount, BASE_DEPOSIT, "deposit amount untouched on rebind");

        assertEq(
            dotnsNameEscrow.reserves(address(0)),
            reservesBefore,
            "reserves must not move when the deposit follows the NFT"
        );
        assertEq(
            dotnsNameEscrow.protocolFees() - protocolFeesBefore,
            startingPrice,
            "friction fee settles to protocol fees independently of the deposit"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(ed),
            edRefundsBefore,
            "no refund credited to the prior depositor"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(leonardo),
            leonardoRefundsBefore,
            "no refund credited to the new holder at transfer time"
        );
    }

    function test_transfer_no_rebind_when_to_equals_position_recipient() public {
        // Defensive: if `chargeTransferFee` is ever invoked with `to == position.recipient`
        // (only reachable through a future code path or a direct registrar-pranked call), the
        // rebind branch must not fire. The position stays funded with the same recipient, no
        // refund entry is credited, and the fee leg behaves exactly as for any other payable
        // transfer. Drives the call from the registrar's address so the `onlyRegistrar` guard
        // passes without trying to perform an NFT move.
        uint256 tokenId = _registerNoStatus(LABEL, ed);

        IDotnsNameEscrow.ReleasePosition memory before = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(before.recipient, ed, "precondition: position bound to ed");
        assertEq(before.amount, BASE_DEPOSIT, "precondition: deposit at BASE_DEPOSIT");

        uint256 reservesBefore = dotnsNameEscrow.reserves(address(0));
        uint256 protocolFeesBefore = dotnsNameEscrow.protocolFees();
        uint256 refundCountBefore = dotnsNameEscrow.pendingRefundCount(ed);

        uint256 fee = popRules.price(LABEL);
        vm.deal(address(dotnsRegistrar), fee);
        vm.prank(address(dotnsRegistrar));
        dotnsNameEscrow.chargeTransferFee{value: fee}(
            IDotnsNameEscrow.ChargeTransferFeeParams({
                tokenId: tokenId, transferFee: fee, payer: leonardo, to: ed
            })
        );

        IDotnsNameEscrow.ReleasePosition memory pos = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(pos.recipient, ed, "position recipient untouched when to == recipient");
        assertEq(pos.amount, BASE_DEPOSIT, "deposit amount untouched when to == recipient");

        assertEq(
            dotnsNameEscrow.reserves(address(0)),
            reservesBefore,
            "reserves unchanged when no refund fires"
        );
        assertEq(
            dotnsNameEscrow.protocolFees() - protocolFeesBefore,
            fee,
            "fee leg still settles to protocol fees"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(ed),
            refundCountBefore,
            "no refund entry credited to the depositor"
        );
    }

    function test_release_and_withdraw_subject_to_cooldown_after_transfer() public {
        // Deposits follow the NFT: a NoStatus name transferred to a new holder carries its
        // locked D with it. The only path back to the deposit is for the current holder to
        // release into escrow and withdraw after the configured cooldown. This is the lock
        // that prevents a register-transfer-reclaim loop from being run inside a single block.
        uint256 tokenId = _registerNoStatus(LABEL, ed);

        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);

        IDotnsNameEscrow.ReleasePosition memory pos = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(pos.recipient, leonardo, "position recipient must follow the NFT");
        assertEq(pos.amount, BASE_DEPOSIT, "deposit amount untouched on rebind");
        assertEq(
            dotnsNameEscrow.pendingRefundCount(ed),
            0,
            "no refund entry may be credited at transfer time"
        );

        vm.startPrank(leonardo);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();

        IDotnsNameEscrow.ReleasePosition memory released =
            dotnsNameEscrow.getReleasePosition(tokenId);
        assertTrue(released.released, "current holder may release into escrow");
        uint64 availableAt = released.withdrawAvailableAt;

        // Withdraw before cooldown is locked.
        vm.prank(leonardo);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsNameEscrow.WithdrawalTooEarly.selector, tokenId, availableAt, block.timestamp
            )
        );
        dotnsNameEscrow.withdraw(tokenId);

        // Still locked one second before cooldown.
        vm.warp(uint256(availableAt) - 1);
        vm.prank(leonardo);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsNameEscrow.WithdrawalTooEarly.selector, tokenId, availableAt, block.timestamp
            )
        );
        dotnsNameEscrow.withdraw(tokenId);

        // Unlocks exactly at `availableAt`: withdraw credits the pull-payment ledger.
        vm.warp(uint256(availableAt));
        vm.prank(leonardo);
        dotnsNameEscrow.withdraw(tokenId);

        assertEq(
            dotnsNameEscrow.pendingWithdrawal(leonardo),
            BASE_DEPOSIT,
            "deposit lands on the new holder's pull-payment ledger"
        );

        uint256 balanceBefore = leonardo.balance;
        vm.prank(leonardo);
        uint256 claimed = dotnsNameEscrow.claimWithdrawal();

        assertEq(claimed, BASE_DEPOSIT, "claim returns the full deposit");
        assertEq(
            leonardo.balance - balanceBefore, BASE_DEPOSIT, "current holder receives the refund"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(ed),
            0,
            "original depositor never accrues a refund entry"
        );
    }

    function test_funded_position_follows_NFT_through_multiple_transfers() public {
        // Deposits travel with the NFT. The first hop ed -> leonardo rebinds the position to
        // leonardo; the second hop leonardo -> tiago rebinds it again to tiago. The locked
        // deposit and the per-asset reserves stay put across the chain of transfers, no
        // friction or refund accounting fires for same-tier moves, and only the final holder
        // can release into escrow.
        uint256 tokenId = _registerNoStatus(LABEL, ed);

        uint256 reservesAtStart = dotnsNameEscrow.reserves(address(0));
        uint256 protocolFeesAtStart = dotnsNameEscrow.protocolFees();
        uint256 edRefundsAtStart = dotnsNameEscrow.pendingRefundCount(ed);
        uint256 leonardoRefundsAtStart = dotnsNameEscrow.pendingRefundCount(leonardo);
        uint256 tiagoRefundsAtStart = dotnsNameEscrow.pendingRefundCount(tiago);
        uint256 escrowBalanceAtStart = address(dotnsNameEscrow).balance;

        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);

        IDotnsNameEscrow.ReleasePosition memory midPos = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(midPos.recipient, leonardo, "position rebinds to leonardo on the first hop");
        assertEq(midPos.amount, BASE_DEPOSIT, "deposit amount untouched on the first hop");

        // Same-tier free transfer; quote must agree this is a zero-fee move that still rebinds.
        uint256 quotedFee = dotnsRegistrar.quoteTransferFee(tokenId, tiago);
        assertEq(quotedFee, 0, "follow-up same-tier transfer must be free");

        vm.prank(leonardo);
        dotnsRegistrar.transferFrom(leonardo, tiago, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), tiago, "tiago receives the NFT on the second hop");

        IDotnsNameEscrow.ReleasePosition memory tailPos =
            dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(tailPos.recipient, tiago, "position rebinds again to tiago on the second hop");
        assertEq(tailPos.amount, BASE_DEPOSIT, "deposit amount untouched on the second hop");

        assertEq(
            dotnsNameEscrow.reserves(address(0)),
            reservesAtStart,
            "reserves must stay put while the deposit follows the NFT"
        );
        assertEq(
            dotnsNameEscrow.protocolFees(),
            protocolFeesAtStart,
            "same-tier hops must not credit protocol fees"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(ed),
            edRefundsAtStart,
            "original depositor's refund ledger never accrues"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(leonardo),
            leonardoRefundsAtStart,
            "intermediate holder accrues no refund"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(tiago),
            tiagoRefundsAtStart,
            "final holder accrues no refund at transfer time"
        );
        assertEq(
            address(dotnsNameEscrow).balance,
            escrowBalanceAtStart,
            "escrow native balance unchanged across same-tier hops"
        );
    }

    /// @notice Builds, commits and registers `label` for `nameOwner` paid by `payer`, returning
    ///         the resulting tokenId.
    /// @dev Centralises the cross-payer commit-register dance so the cross-payer charge tests
    ///      stay focused on accounting assertions. The caller is responsible for setting any
    ///      personhood tiers on `payer` and `nameOwner` before invoking this helper.
    function _crossPayerRegister(
        string memory label,
        address payer,
        address nameOwner,
        uint256 attachedValue
    )
        internal
        returns (uint256 tokenId)
    {
        bytes32 secret = keccak256(abi.encodePacked(label, nameOwner, block.timestamp, payer));
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

        vm.prank(payer);
        dotnsRegistrarController.register{value: attachedValue}(registration);

        tokenId = _tokenIdForLabel(label);
    }

    /// @notice Verified payer sponsoring a NoStatus owner on a NoStatus-tier label pays
    ///         exactly D under the max-not-sum rule.
    /// @dev `priced.price` equals D because the owner is NoStatus, and `transferFloor` returns
    ///      D because the payer's PopFull tier downgrades into the owner's NoStatus tier. The
    ///      controller charges `max(priced.price, friction) = D` and routes the entire charge
    ///      into protocol fees; the owner-side refundable position is seeded with zero
    ///      amount, so reserves must not move.
    function test_cross_payer_verified_sponsors_nostatus_pays_only_D() public {
        string memory label = "crosspayr01";

        _grantPopFull(leonardo);
        // ed left at default NoStatus tier.

        uint256 priorProtocolFees = dotnsNameEscrow.protocolFees();
        uint256 priorReserves = dotnsNameEscrow.reserves(address(0));
        uint256 priorBalance = leonardo.balance;

        uint256 tokenId = _crossPayerRegister(label, leonardo, ed, BASE_DEPOSIT);

        // Protocol fees must grow by exactly D and reserves must stay flat: the entire charge
        // routes to the friction reserve on the cross-payer path under the max rule.
        assertEq(
            dotnsNameEscrow.protocolFees() - priorProtocolFees,
            BASE_DEPOSIT,
            "protocol fees must grow by exactly D on cross-payer NoStatus sponsorship"
        );
        assertEq(
            dotnsNameEscrow.reserves(address(0)),
            priorReserves,
            "reserves must not move when the cross-payer charge routes entirely to protocol fees"
        );
        assertEq(
            priorBalance - leonardo.balance,
            BASE_DEPOSIT,
            "payer must be debited exactly D, never above"
        );

        // The owner-side position is seeded with zero amount so the release lifecycle stays
        // reachable; the recipient sentinel binds to the registrant.
        IDotnsNameEscrow.ReleasePosition memory pos = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(pos.recipient, ed, "position recipient must be the registrant");
        assertEq(pos.amount, 0, "no refundable deposit seeded for cross-payer registration");
    }

    /// @notice A cross-payer sponsoring a verified owner pays the name's own curve price into
    ///         protocol fees; personhood buys the owner access, not a free ride for the sponsor.
    /// @dev `priced.price` is the curve price for the owner and `transferFloor` is at most that
    ///      same price, so the controller charges the owner-side price and `_settleEscrow` routes
    ///      it through `depositProtocolFee`, seeding a zero-amount refundable position.
    function test_cross_payer_pays_the_curve_into_fees() public {
        string memory label = BASE_LABEL_A;

        _grantPopFull(leonardo);
        _grantPopFull(ed);

        uint256 ownPrice = popRules.price(label);
        uint256 priorProtocolFees = dotnsNameEscrow.protocolFees();
        uint256 priorReserves = dotnsNameEscrow.reserves(address(0));
        uint256 priorBalance = leonardo.balance;

        uint256 tokenId = _crossPayerRegister(label, leonardo, ed, ownPrice);

        assertEq(
            dotnsNameEscrow.protocolFees() - priorProtocolFees,
            ownPrice,
            "cross-payer charge settles to protocol fees"
        );
        assertEq(
            dotnsNameEscrow.reserves(address(0)),
            priorReserves,
            "reserves must not move on the cross-payer path"
        );
        assertEq(
            priorBalance - leonardo.balance, ownPrice, "payer is debited the cross-payer charge"
        );

        IDotnsNameEscrow.ReleasePosition memory pos = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(pos.recipient, ed, "position recipient must be the registrant");
        assertEq(pos.amount, 0, "cross-payer registration seeds no refundable deposit");
    }

    /// @notice A cross-payer whose tier downgrades into the owner's is still charged only the
    ///         name's own price, never the owner price plus the downgrade friction.
    /// @dev The owner-side price is the curve price and the downgrade friction can at most equal
    ///      it, so `max(ownerPrice, friction)` collapses to the owner price. The whole charge
    ///      routes to protocol fees with no refundable deposit.
    function test_cross_payer_downgrade_charges_only_owner_price() public {
        // LITE_LABEL_A carries the gateway's separator, which the public path this test drives
        // rejects, so the label here is a flat one in the same tier.
        string memory label = "michael01";

        _grantPopFull(leonardo);
        _grantPopLite(ed);

        uint256 ownPrice = popRules.price(label);
        uint256 priorProtocolFees = dotnsNameEscrow.protocolFees();
        uint256 priorReserves = dotnsNameEscrow.reserves(address(0));
        uint256 priorBalance = leonardo.balance;

        uint256 tokenId = _crossPayerRegister(label, leonardo, ed, ownPrice);

        assertEq(
            dotnsNameEscrow.protocolFees() - priorProtocolFees,
            ownPrice,
            "downgrade never exceeds the name's own price"
        );
        assertEq(
            dotnsNameEscrow.reserves(address(0)),
            priorReserves,
            "reserves stay flat on the cross-payer path"
        );
        assertEq(
            priorBalance - leonardo.balance,
            ownPrice,
            "payer is debited the owner-side price, not the sum"
        );

        IDotnsNameEscrow.ReleasePosition memory pos = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(pos.recipient, ed, "position recipient must be the registrant");
        assertEq(pos.amount, 0, "no refundable deposit seeded for cross-payer registration");
    }

    function test_solvency_after_force_sent_funds() public {
        uint256 tokenId = _registerNoStatus(LABEL, ed);
        _approveAndRelease(tokenId, ed);

        uint256 reservesBefore = dotnsNameEscrow.reserves(address(0));

        new ForceSender{value: 1 ether}(payable(address(dotnsNameEscrow)));

        assertGt(
            address(dotnsNameEscrow).balance,
            reservesBefore,
            "balance should exceed reserves after force-send"
        );

        vm.warp(block.timestamp + ESCROW_COOLDOWN + 1);
        uint256 balanceBefore = ed.balance;

        vm.prank(ed);
        dotnsNameEscrow.withdraw(tokenId);

        // Pull-payment: settle the pending balance via claimWithdrawal before
        // asserting that the correct amount has reached the recipient.
        vm.prank(ed);
        dotnsNameEscrow.claimWithdrawal();

        assertEq(
            ed.balance,
            balanceBefore + BASE_DEPOSIT,
            "withdraw should still transfer correct amount"
        );
    }
}
