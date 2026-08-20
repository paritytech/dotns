// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsController} from "../../../contracts/registrars/IDotnsController.sol";
import {IDotnsRegistrar} from "../../../contracts/registrars/IDotnsRegistrar.sol";
import {DotnsRegistrar} from "../../../contracts/registrars/DotnsRegistrar.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";
import {ILabelStore} from "../../../contracts/store/ILabelStore.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title DotnsRegistrarTests
/// @notice Unit coverage for the ERC721 registrar's controller authorisation,
///         availability tracking, registration, transfer fee gate, label readback,
///         upgrade authorisation, and approval surfaces.
contract DotnsRegistrarTests is BaseDotns {
    function test_add_controller() public {
        address additionalController = makeAddr("additionalController");

        vm.startPrank(owner);
        dotnsRegistrar.addController(IDotnsController(additionalController));
        vm.stopPrank();

        assertTrue(dotnsRegistrar.controllers(IDotnsController(additionalController)));
    }

    function test_add_controller_emits_event() public {
        address additionalController = makeAddr("additionalController");

        vm.expectEmit(true, false, false, true, address(dotnsRegistrar));
        emit IDotnsRegistrar.ControllerAdded(IDotnsController(additionalController));

        vm.prank(owner);
        dotnsRegistrar.addController(IDotnsController(additionalController));
    }

    function test_remove_controller() public {
        address temporaryController = makeAddr("temporaryController");

        vm.startPrank(owner);
        dotnsRegistrar.addController(IDotnsController(temporaryController));
        dotnsRegistrar.removeController(IDotnsController(temporaryController));
        vm.stopPrank();

        assertFalse(dotnsRegistrar.controllers(IDotnsController(temporaryController)));
    }

    function test_remove_controller_emits_event() public {
        address temporaryController = makeAddr("temporaryController");
        vm.prank(owner);
        dotnsRegistrar.addController(IDotnsController(temporaryController));

        vm.expectEmit(true, false, false, true, address(dotnsRegistrar));
        emit IDotnsRegistrar.ControllerRemoved(IDotnsController(temporaryController));

        vm.prank(owner);
        dotnsRegistrar.removeController(IDotnsController(temporaryController));
    }

    function test_add_controller_reverts_for_non_owner() public {
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, ed)
        );
        vm.prank(ed);
        dotnsRegistrar.addController(IDotnsController(address(this)));
    }

    function test_remove_controller_reverts_for_non_owner() public {
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, ed)
        );
        vm.prank(ed);
        dotnsRegistrar.removeController(IDotnsController(address(dotnsRegistrarController)));
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

    function test_register_emits_name_registered() public {
        string memory label = "emitcheck";
        uint256 tokenId = _tokenIdForLabel(label);

        vm.expectEmit(true, true, false, true, address(dotnsRegistrar));
        emit IDotnsRegistrar.NameRegistered(tokenId, ed);

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, ed, label);
    }

    function test_register_reverts_for_non_controller() public {
        string memory label = "intruder";
        uint256 tokenId = _tokenIdForLabel(label);

        vm.expectRevert(abi.encodeWithSelector(IDotnsRegistrar.NotController.selector, ed));
        vm.prank(ed);
        dotnsRegistrar.register(tokenId, ed, label);
    }

    function test_register_reverts_when_name_not_available() public {
        string memory label = "duplicate";
        uint256 tokenId = _tokenIdForLabel(label);

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, ed, label);

        vm.expectRevert(abi.encodeWithSelector(IDotnsRegistrar.NameNotAvailable.selector, tokenId));
        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, leonardo, label);
    }

    function test_register_writes_label_into_owner_label_store() public {
        string memory label = "labelwrite";
        uint256 tokenId = _tokenIdForLabel(label);

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, ed, label);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0), "label store must be deployed on register");
        assertEq(ILabelStore(store).getLabel(bytes32(tokenId)), string.concat(label, ".dot"));
    }

    function test_register_with_empty_label_skips_store_write() public {
        // Mirrors the gateway path that registers a token without a label string; no
        // LabelStore deploy fires, and a later transfer can still complete.
        string memory label = "labelless";
        uint256 tokenId = _tokenIdForLabel(label);

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, ed, "");

        assertEq(storeFactory.getLabelStore(ed), address(0), "no store must be deployed");
        assertEq(dotnsRegistrar.ownerOf(tokenId), ed);
        // Avoid `unused variable` warnings under stricter solc settings.
        label;
    }

    function test_available_before_after_register() public {
        address nameOwner = ed;
        string memory label = "availabilitycheck";
        uint256 tokenId = _tokenIdForLabel(label);

        assertTrue(dotnsRegistrar.available(tokenId));

        vm.startPrank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, nameOwner, label);
        vm.stopPrank();

        assertFalse(dotnsRegistrar.available(tokenId));
    }

    function test_available_is_false_while_released_token_is_inside_redeem_window() public {
        // Drive a registration through the public controller so a deposit position seeds,
        // approve the escrow, release the token, then assert the name is NOT advertised as free
        // while its previous holder can still redeem it.
        string memory label = "availreclaim01";
        _register(label, ed, IPopRules.PopStatus.NoStatus);
        uint256 tokenId = _tokenIdForLabel(label);

        vm.startPrank(ed);
        dotnsRegistrar.setApprovalForAll(address(dotnsNameEscrow), true);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();

        assertEq(dotnsRegistrar.ownerOf(tokenId), address(dotnsNameEscrow));
        assertFalse(
            dotnsRegistrar.available(tokenId),
            "a released token inside its redeem window must not report available"
        );

        // Still false one second before the boundary: the window is inclusive of its final second.
        IDotnsNameEscrow.ReleasePosition memory position =
            dotnsNameEscrow.getReleasePosition(tokenId);
        vm.warp(position.redeemableUntil - 1);
        assertFalse(
            dotnsRegistrar.available(tokenId),
            "availability must not open before redeemableUntil is reached"
        );
    }

    function test_available_when_redeem_window_elapsed_returns_true() public {
        string memory label = "availreclaim02";
        _register(label, ed, IPopRules.PopStatus.NoStatus);
        uint256 tokenId = _tokenIdForLabel(label);

        vm.startPrank(ed);
        dotnsRegistrar.setApprovalForAll(address(dotnsNameEscrow), true);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();

        IDotnsNameEscrow.ReleasePosition memory position =
            dotnsNameEscrow.getReleasePosition(tokenId);

        // Exactly at the boundary the name is registrable, matching reclaim's `>=` gate so the
        // two views can never disagree about whether a registration would succeed.
        vm.warp(position.redeemableUntil);

        assertEq(dotnsRegistrar.ownerOf(tokenId), address(dotnsNameEscrow));
        assertTrue(
            dotnsRegistrar.available(tokenId),
            "escrow-held tokens must be available once the redeem window has elapsed"
        );
    }

    function test_exists_reports_minted_state() public {
        string memory label = "existscheck01";
        uint256 tokenId = _tokenIdForLabel(label);

        assertFalse(dotnsRegistrar.exists(tokenId));

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, ed, label);

        assertTrue(dotnsRegistrar.exists(tokenId));
    }

    function test_label_of_returns_empty_for_nonexistent_token() public view {
        uint256 ghostTokenId = _tokenIdForLabel("never-minted");
        assertEq(dotnsRegistrar.labelOf(ghostTokenId), "");
    }

    function test_label_of_returns_stripped_label() public {
        string memory label = "labelofcheck";
        uint256 tokenId = _tokenIdForLabel(label);

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, ed, label);

        assertEq(dotnsRegistrar.labelOf(tokenId), label);
    }

    function test_label_of_returns_empty_when_owner_has_no_label_store() public {
        // Register with an empty label so no LabelStore is provisioned. `labelOf` reads
        // from the holder's store and must fall through to the empty-string sentinel
        // rather than reverting on the missing store.
        string memory label = "ghostlabel01";
        uint256 tokenId = _tokenIdForLabel(label);

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, ed, "");

        assertEq(dotnsRegistrar.labelOf(tokenId), "");
        label;
    }

    function test_quote_transfer_fee_reverts_for_zero_recipient() public {
        string memory label = "quotezero01";
        _register(label, ed, IPopRules.PopStatus.NoStatus);
        uint256 tokenId = _tokenIdForLabel(label);

        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0))
        );
        dotnsRegistrar.quoteTransferFee(tokenId, address(0));
    }

    function test_quote_transfer_fee_reverts_when_escrow_unconfigured() public {
        string memory label = "quoteneedsescrow01";
        _register(label, ed, IPopRules.PopStatus.NoStatus);
        uint256 tokenId = _tokenIdForLabel(label);

        // Mask the escrow key so the registrar resolves it to address(0); the protocol
        // registry itself rejects zero writes, so go through `vm.mockCall` instead of
        // mutating storage.
        vm.mockCall(
            address(protocolRegistry),
            abi.encodeWithSelector(IDotnsProtocolRegistry.get.selector, DotnsConstants.NAME_ESCROW),
            abi.encode(address(0))
        );

        vm.expectRevert(IDotnsRegistrar.EscrowNotConfigured.selector);
        dotnsRegistrar.quoteTransferFee(tokenId, leonardo);
    }

    function test_quote_transfer_fee_zero_for_self_transfer() public {
        string memory label = "selfquote01";
        _register(label, ed, IPopRules.PopStatus.NoStatus);
        uint256 tokenId = _tokenIdForLabel(label);

        assertEq(dotnsRegistrar.quoteTransferFee(tokenId, ed), 0);
    }

    function test_quote_transfer_fee_zero_for_escrow_recipient() public {
        string memory label = "escrowquote01";
        _register(label, ed, IPopRules.PopStatus.NoStatus);
        uint256 tokenId = _tokenIdForLabel(label);

        assertEq(dotnsRegistrar.quoteTransferFee(tokenId, address(dotnsNameEscrow)), 0);
    }

    function test_quote_transfer_fee_zero_when_no_label_recorded() public {
        // Direct-controller registration with an empty label leaves no entry in the holder's
        // LabelStore; the quoter has nothing to derive a tier-price from and must return zero.
        string memory label = "noquotelabel01";
        uint256 tokenId = _tokenIdForLabel(label);

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, ed, "");

        assertEq(dotnsRegistrar.quoteTransferFee(tokenId, leonardo), 0);
        label;
    }

    function test_transfer_reverts_when_fee_required_but_no_value_attached() public {
        string memory label = "feerequired01";
        // Grant Full to ed so the mint succeeds, but leave leonardo at NoStatus so the
        // transfer floor charges a non-zero downgrade fee.
        _register(label, ed, IPopRules.PopStatus.PopFull);
        uint256 tokenId = _tokenIdForLabel(label);

        uint256 fee = dotnsRegistrar.quoteTransferFee(tokenId, leonardo);
        assertGt(fee, 0, "test setup must produce a non-zero transfer floor");

        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrar.TransferFeeRequired.selector, tokenId, leonardo, fee
            )
        );
        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);
    }

    function test_self_transfer_skips_fee_charge() public {
        // A `from == to` move must not touch the escrow at all: no fee, no position sync.
        string memory label = "selftransfer01";
        _register(label, ed, IPopRules.PopStatus.NoStatus);
        uint256 tokenId = _tokenIdForLabel(label);

        IDotnsNameEscrow.ReleasePosition memory before = dotnsNameEscrow.getReleasePosition(tokenId);

        vm.prank(ed);
        dotnsRegistrar.transferFrom{value: 0}(ed, ed, tokenId);

        IDotnsNameEscrow.ReleasePosition memory afterPos =
            dotnsNameEscrow.getReleasePosition(tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), ed);
        assertEq(afterPos.recipient, before.recipient);
        assertEq(afterPos.amount, before.amount);
    }

    function test_version_string() public view {
        assertEq(dotnsRegistrar.version(), "1.0.0");
    }

    function test_initialize_cannot_be_called_twice() public {
        vm.expectRevert(); // OZ InvalidInitialization
        dotnsRegistrar.initialize(
            "Dotns", "Dotns", IDotnsProtocolRegistry(address(protocolRegistry))
        );
    }

    function test_upgrade_rejects_non_owner() public {
        DotnsRegistrar newImpl = new DotnsRegistrar();

        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, ed)
        );
        vm.prank(ed);
        dotnsRegistrar.upgradeToAndCall(address(newImpl), bytes(""));
    }

    function test_supports_ierc721_interface() public view {
        assertTrue(dotnsRegistrar.supportsInterface(type(IERC721).interfaceId));
    }

    function test_approvals_work() public {
        address nameOwner = ed;
        address tokenApproval = tiago;
        address operator = leonardo;

        string memory label = "approvalname";
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
}
