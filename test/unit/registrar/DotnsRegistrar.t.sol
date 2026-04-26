// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsController} from "../../../contracts/registrars/IDotnsController.sol";
import {IDotnsRegistrar} from "../../../contracts/registrars/IDotnsRegistrar.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract NonERC721Receiver {}

contract DotnsRegistrarTests is BaseDotns {
    function test_add_controller() public {
        address additionalController = makeAddr("additionalController");

        vm.startPrank(owner);
        dotnsRegistrar.addController(IDotnsController(additionalController));
        vm.stopPrank();

        assertTrue(dotnsRegistrar.controllers(IDotnsController(additionalController)));
    }

    function test_remove_controller() public {
        address temporaryController = makeAddr("temporaryController");

        vm.startPrank(owner);
        dotnsRegistrar.addController(IDotnsController(temporaryController));
        dotnsRegistrar.removeController(IDotnsController(temporaryController));
        vm.stopPrank();

        assertFalse(dotnsRegistrar.controllers(IDotnsController(temporaryController)));
    }

    function test_register_mints_to_owner() public {
        address nameOwner = ed;
        string memory label = "alice";
        uint256 tokenId = _tokenIdForLabel(label);

        vm.startPrank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, nameOwner, label);
        vm.stopPrank();

        assertEq(dotnsRegistrar.ownerOf(tokenId), nameOwner);
        assertEq(dotnsRegistrar.balanceOf(nameOwner), 1);
    }

    function test_available_before_after_register() public {
        address nameOwner = ed;
        string memory label = "availabilityCheck";
        uint256 tokenId = _tokenIdForLabel(label);

        assertTrue(dotnsRegistrar.available(tokenId));

        vm.startPrank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, nameOwner, label);
        vm.stopPrank();

        assertFalse(dotnsRegistrar.available(tokenId));
    }

    function test_available_false_after_direct_transfer_to_escrow() public {
        string memory label = NOSTATUS_LABEL_A;
        uint256 tokenId = _tokenIdForLabel(label);

        _commitAndRegister(label, ed, false);

        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, address(dotnsNameEscrow), tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), address(dotnsNameEscrow));
        assertFalse(dotnsRegistrar.available(tokenId));
    }

    function test_available_true_after_release_and_withdraw() public {
        string memory label = NOSTATUS_LABEL_B;
        uint256 tokenId = _tokenIdForLabel(label);

        _commitAndRegister(label, ed, false);

        vm.startPrank(ed);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();

        assertFalse(dotnsRegistrar.available(tokenId));

        vm.warp(block.timestamp + ESCROW_COOLDOWN + 1);

        vm.prank(ed);
        dotnsNameEscrow.withdraw(tokenId);

        assertTrue(dotnsRegistrar.available(tokenId));
    }

    function test_approvals_work() public {
        address nameOwner = ed;
        address tokenApproval = tiago;
        address operator = leonardo;

        string memory label = "approvalName";
        uint256 tokenId = _tokenIdForLabel(label);

        vm.startPrank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, nameOwner, label);
        vm.stopPrank();

        vm.startPrank(nameOwner);
        dotnsRegistrar.approve(tokenApproval, tokenId);
        assertEq(dotnsRegistrar.getApproved(tokenId), tokenApproval);

        dotnsRegistrar.setApprovalForAll(operator, true);
        vm.stopPrank();

        assertTrue(dotnsRegistrar.isApprovedForAll(nameOwner, operator));
        assertTrue(dotnsRegistrar.supportsInterface(type(IERC721).interfaceId));
    }

    function test_quoteTransferFee_returns_delta_for_cross_tier_transfer() public {
        string memory label = "crossfeeab";
        uint256 tokenId = _tokenIdForLabel(label);

        _grantPopFull(ed);
        _commitAndRegister(label, ed, false);

        uint256 fee = popRules.priceWithoutCheck(label, tiago).price;
        assertGt(fee, 0, "recipient should owe a noStatus-tier price");
        assertEq(dotnsRegistrar.quoteTransferFee(tokenId, tiago), fee);
    }

    function test_transferFrom_reverts_with_transferFeeRequired_when_delta_is_owed() public {
        string memory label = "crossfeeac";
        uint256 tokenId = _tokenIdForLabel(label);

        _grantPopFull(ed);
        _commitAndRegister(label, ed, false);

        uint256 fee = dotnsRegistrar.quoteTransferFee(tokenId, tiago);

        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrar.TransferFeeRequired.selector, tokenId, tiago, fee
            )
        );
        dotnsRegistrar.transferFrom(ed, tiago, tokenId);
    }

    function test_transferFrom_accepts_value_for_cross_tier_move() public {
        string memory label = "crossfeead";
        uint256 tokenId = _tokenIdForLabel(label);

        _grantPopFull(ed);
        _commitAndRegister(label, ed, false);

        uint256 fee = dotnsRegistrar.quoteTransferFee(tokenId, tiago);
        uint256 insuranceBefore = dotnsNameEscrow.insuranceFund();

        vm.prank(ed);
        dotnsRegistrar.transferFrom{value: fee}(ed, tiago, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), tiago);
        assertEq(dotnsNameEscrow.insuranceFund(), insuranceBefore + fee);
    }

    function test_transferFrom_refunds_surplus_when_move_is_already_covered() public {
        string memory label = NOSTATUS_LABEL_A;
        uint256 tokenId = _tokenIdForLabel(label);

        _commitAndRegister(label, ed, false);
        assertEq(
            dotnsRegistrar.quoteTransferFee(tokenId, tiago), 0, "same-tier move should be free"
        );

        uint256 overpayment = 1 wei;
        uint256 registrarBalanceBefore = address(dotnsRegistrar).balance;
        uint256 senderBalanceBefore = ed.balance;
        uint256 insuranceBefore = dotnsNameEscrow.insuranceFund();

        vm.prank(ed);
        dotnsRegistrar.transferFrom{value: overpayment}(ed, tiago, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), tiago);
        assertEq(address(dotnsRegistrar).balance, registrarBalanceBefore, "value must not stick");
        assertEq(ed.balance, senderBalanceBefore, "surplus should be fully refunded");
        assertEq(dotnsNameEscrow.insuranceFund(), insuranceBefore, "insurance must stay unchanged");
    }

    function test_transferFrom_reverts_for_zero_address_receiver() public {
        string memory label = NOSTATUS_LABEL_B;
        uint256 tokenId = _tokenIdForLabel(label);

        _commitAndRegister(label, ed, false);

        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0))
        );
        dotnsRegistrar.transferFrom(ed, address(0), tokenId);
    }

    function test_safeTransferFrom_reverts_for_non_receiver_contract() public {
        string memory label = NOSTATUS_LABEL_A;
        uint256 tokenId = _tokenIdForLabel(label);
        NonERC721Receiver receiver = new NonERC721Receiver();

        _commitAndRegister(label, ed, false);

        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(receiver))
        );
        dotnsRegistrar.safeTransferFrom(ed, address(receiver), tokenId);
    }

    function test_quoteTransferFee_reach_floor_for_lite_recipient_of_base_name() public {
        // A PopFull-funded base name has runningMax = 0 because verified registrants
        // pay nothing. A PopLite recipient is "covered" in price terms (priceForTo = 0)
        // but reaches above their tier (label is PopFull). The reach fee charges the
        // length-scaled NoStatus rate so PopFull stays the only friction-free recipient.
        string memory label = "alicelongname";
        uint256 tokenId = _tokenIdForLabel(label);

        _grantPopFull(ed);
        _commitAndRegister(label, ed, false);

        _grantPopLite(tiago);

        assertEq(dotnsNameEscrow.runningMax(tokenId), 0, "popfull registration funds nothing");

        uint256 expected = popRules.reachFee(label, tiago);
        assertGt(expected, 0, "lite recipient must owe reach fee on a base name");
        assertEq(dotnsRegistrar.quoteTransferFee(tokenId, tiago), expected);
    }

    function test_transferFrom_charges_reach_floor_to_insurance_and_bumps_runningMax() public {
        // Pure reach-fee charge: priceForTo (zero) is at or below runningMax (zero), so
        // the delta path returns zero and the reach path drives the fee. The escrow
        // records the payment by bumping runningMax to the floor amount, mirroring the
        // rule in `deposit` and `depositInsurance` so the same invariant holds across
        // every escrow payment path: runningMax tracks the largest amount ever paid
        // through escrow for this token.
        string memory label = "alicelongname";
        uint256 tokenId = _tokenIdForLabel(label);

        _grantPopFull(ed);
        _commitAndRegister(label, ed, false);
        _grantPopLite(tiago);

        uint256 fee = dotnsRegistrar.quoteTransferFee(tokenId, tiago);
        uint256 insuranceBefore = dotnsNameEscrow.insuranceFund();

        vm.prank(ed);
        dotnsRegistrar.transferFrom{value: fee}(ed, tiago, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), tiago, "ownership flips");
        assertEq(dotnsNameEscrow.insuranceFund(), insuranceBefore + fee, "fee credits insurance");
        assertEq(dotnsNameEscrow.runningMax(tokenId), fee, "runningMax tracks highest payment");
    }

    function test_transferFrom_to_full_recipient_skips_reach_floor() public {
        // PopFull recipient meets reach for any label tier, so the reach fee is zero
        // and a no-value transfer passes through.
        string memory label = "alicelongname";
        uint256 tokenId = _tokenIdForLabel(label);

        _grantPopFull(ed);
        _commitAndRegister(label, ed, false);
        _grantPopFull(tiago);

        assertEq(dotnsRegistrar.quoteTransferFee(tokenId, tiago), 0, "full-to-full is free");

        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, tiago, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), tiago);
    }
}
