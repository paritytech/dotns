// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

contract ForceSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @notice Standalone ERC721 used to verify the escrow refuses tokens not minted by the
///         configured registrar.
contract GhostNft is ERC721 {
    constructor() ERC721("Ghost", "GHST") {}

    function mint(address to, uint256 tokenId) external {
        _safeMint(to, tokenId);
    }
}

contract DotnsNameEscrowTest is BaseDotns {
    /// @dev 14-char label so NoStatus price = startingPrice * (15 - 14) = RENT_PRICE.
    string internal constant LABEL = "longerlabela01";

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

    function _approveAndRelease(uint256 tokenId, address caller) internal {
        vm.startPrank(caller);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();
    }

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

        assertEq(pos.amount, RENT_PRICE, "amount should equal RENT_PRICE");
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
            RENT_PRICE,
            "pending withdrawal should be credited"
        );

        vm.prank(ed);
        dotnsNameEscrow.claimWithdrawal();

        assertEq(ed.balance, balanceBefore + RENT_PRICE, "ed should receive RENT_PRICE refund");

        IDotnsNameEscrow.ReleasePosition memory pos = dotnsNameEscrow.getReleasePosition(tokenId);
        assertTrue(pos.claimed, "claimed should be true");

        uint256 reservesAfter = dotnsNameEscrow.reserves(address(0));
        assertEq(reservesAfter, reservesBefore - RENT_PRICE, "reserves should be decremented");
    }

    function test_reclaim_transfers_custody_to_new_owner() public {
        uint256 tokenId = _fullWithdrawFlow(LABEL, ed);

        assertEq(
            dotnsRegistrar.ownerOf(tokenId),
            address(dotnsNameEscrow),
            "escrow holds token before reclaim"
        );

        vm.prank(address(dotnsRegistrarController));
        dotnsNameEscrow.reclaim(tokenId, leonardo);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo, "leonardo owns token after reclaim");

        IDotnsNameEscrow.ReleasePosition memory pos = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(pos.recipient, address(0), "position fully cleared after reclaim");
        assertEq(pos.amount, 0, "position amount zeroed after reclaim");
        assertFalse(pos.released, "released flag cleared after reclaim");
    }

    function test_release_after_transfer_still_refunds_locked_recipient() public {
        uint256 tokenId = _registerNoStatus(LABEL, ed);

        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);

        // Two-party cooperation: the current holder approves the escrow for the
        // safeTransferFrom inside release() and authorises the locked recipient
        // (ed) to call it. position.recipient is locked at deposit time and is
        // not mutated by NFT transfers.
        vm.startPrank(leonardo);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        dotnsRegistrar.setApprovalForAll(ed, true);
        vm.stopPrank();

        vm.prank(ed);
        dotnsNameEscrow.release(tokenId);

        IDotnsNameEscrow.ReleasePosition memory pos = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(pos.recipient, ed, "recipient should remain locked to ed");
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

    /// @notice A foreign ERC721 transferred into escrow must be rejected.
    /// @dev Without this guard a foreign NFT (or a registrar NFT moved outside the release
    ///      flow) would become permanently stuck in escrow with no recovery path.
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

    /// @notice Pop-verified registrations pay no deposit, so release must always revert.
    /// @dev Locks the protocol invariant: only NoStatus names can enter the escrow lifecycle.
    function test_revert_pop_full_name_cannot_release() public {
        string memory popLabel = "popfullname";
        bytes32 node = _register(popLabel, ed, IPopRules.PopStatus.PopFull);
        uint256 tokenId = uint256(node);

        vm.prank(ed);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);

        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameEscrow.DepositNotConfigured.selector, tokenId)
        );
        dotnsNameEscrow.release(tokenId);
    }

    function test_revert_release_not_owner_or_approved() public {
        uint256 tokenId = _registerNoStatus(LABEL, ed);

        vm.prank(tiago);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsNameEscrow.NotTokenOwnerOrApproved.selector, tiago, tokenId
            )
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

        // Released but not claimed/withdrawn — not reclaimable yet.
        vm.prank(address(dotnsRegistrarController));
        vm.expectRevert(abi.encodeWithSelector(IDotnsNameEscrow.NotReclaimable.selector, tokenId));
        dotnsNameEscrow.reclaim(tokenId, leonardo);
    }

    function test_revert_deposit_already_funded() public {
        uint256 tokenId = _registerNoStatus(LABEL, ed);

        vm.deal(address(dotnsRegistrarController), RENT_PRICE);
        vm.prank(address(dotnsRegistrarController));
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameEscrow.PositionAlreadyFunded.selector, tokenId)
        );
        dotnsNameEscrow.deposit{value: RENT_PRICE}(
            IDotnsNameEscrow.DepositParams({
                tokenId: tokenId, asset: address(0), amount: RENT_PRICE, recipient: ed
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

    function test_migrate_native_funds_to_escrow() public {
        vm.deal(address(dotnsRegistrarController), 1 ether);

        uint256 escrowBalanceBefore = address(dotnsNameEscrow).balance;

        vm.prank(owner);
        dotnsRegistrarController.migrateNativeFundsToEscrow(1 ether);

        uint256 escrowBalanceAfter = address(dotnsNameEscrow).balance;
        assertEq(
            escrowBalanceAfter,
            escrowBalanceBefore + 1 ether,
            "escrow balance should increase by migrated amount"
        );
    }

    function test_update_cooldown() public {
        uint256 newCooldown = 14 days;

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit IDotnsNameEscrow.CooldownUpdated(ESCROW_COOLDOWN, newCooldown);
        dotnsNameEscrow.updateCooldown(newCooldown);

        assertEq(dotnsNameEscrow.cooldown(), newCooldown, "cooldown should be updated");
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
            ed.balance, balanceBefore + RENT_PRICE, "withdraw should still transfer correct amount"
        );
    }
}
