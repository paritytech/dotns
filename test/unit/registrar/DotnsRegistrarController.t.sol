// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns, IDotnsRegistrarController} from "../../base/BaseDotns.t.sol";

import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {ILabelStore} from "../../../contracts/store/ILabelStore.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {IDotnsRoleManager} from "../../../contracts/access/IDotnsRoleManager.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";
import {DotnsRegistrarController} from "../../../contracts/registrars/DotnsRegistrarController.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title DotnsRegistrarControllerTest
/// @notice Unit coverage for the public commit-reveal registrar controller:
///         availability and commitment book-keeping, PoP-aware registration,
///         whitelisting, role management, and transfer-side store wiring.
contract DotnsRegistrarControllerTest is BaseDotns {
    function test_initialize_reverts_when_min_commitment_age_is_zero() public {
        DotnsRegistrarController impl = new DotnsRegistrarController();
        bytes memory initData = abi.encodeCall(
            DotnsRegistrarController.initialize,
            (IDotnsProtocolRegistry(address(protocolRegistry)), 0, 1 days)
        );
        vm.expectRevert(IDotnsRegistrarController.MinCommitmentAgeZero.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_reverts_when_max_not_greater_than_min() public {
        DotnsRegistrarController impl = new DotnsRegistrarController();
        bytes memory initData = abi.encodeCall(
            DotnsRegistrarController.initialize,
            (IDotnsProtocolRegistry(address(protocolRegistry)), 10 seconds, 10 seconds)
        );
        vm.expectRevert(IDotnsRegistrarController.MaxCommitmentAgeTooLow.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_reverts_when_max_above_ceiling() public {
        uint256 ceiling = dotnsRegistrarController.MAX_ALLOWED_COMMITMENT_AGE();
        DotnsRegistrarController impl = new DotnsRegistrarController();
        bytes memory initData = abi.encodeCall(
            DotnsRegistrarController.initialize,
            (IDotnsProtocolRegistry(address(protocolRegistry)), 6 seconds, ceiling + 1)
        );
        vm.expectRevert(IDotnsRegistrarController.MaxCommitmentAgeTooHigh.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_available_state_transitions() public {
        assertTrue(dotnsRegistrarController.available("longnamehere01"));

        _register("longnamehere01", ed, IPopRules.PopStatus.NoStatus);

        assertFalse(dotnsRegistrarController.available("longnamehere01"));
    }

    function test_available_reverts_for_dotted_label() public {
        vm.expectRevert(IDotnsRegistrarController.InvalidLabel.selector);
        dotnsRegistrarController.available("app.parity01");
    }

    function test_available_reverts_for_empty_label() public {
        vm.expectRevert(IDotnsRegistrarController.InvalidLabel.selector);
        dotnsRegistrarController.available("");
    }

    function test_commit_sets_timestamp() public {
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: "alicebob", owner: ed, secret: keccak256("secret"), reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);

        vm.startPrank(ed);
        dotnsRegistrarController.commit(commitment);
        vm.stopPrank();

        assertEq(dotnsRegistrarController.commitments(commitment), block.timestamp);
    }

    function test_commit_allows_recommit_after_expiry() public {
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: "alicebob", owner: ed, secret: keccak256("secret"), reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);

        vm.startPrank(ed);
        dotnsRegistrarController.commit(commitment);

        uint256 firstCommitTimestamp = dotnsRegistrarController.commitments(commitment);
        vm.warp(firstCommitTimestamp + dotnsRegistrarController.maxCommitmentAge() + 1);

        dotnsRegistrarController.commit(commitment);
        vm.stopPrank();

        assertEq(dotnsRegistrarController.commitments(commitment), block.timestamp);
    }

    function test_commit_allows_recommit_at_exact_expiry_boundary() public {
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: "alicebob", owner: ed, secret: keccak256("secret"), reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);

        vm.startPrank(ed);
        dotnsRegistrarController.commit(commitment);

        uint256 firstCommitTimestamp = dotnsRegistrarController.commitments(commitment);
        // Land exactly on the expiry boundary. `_consumeCommitment` treats this as expired
        // (`committedAt + maxCommitmentAge > block.timestamp` is false), so `commit` must
        // also treat it as overwritable; otherwise the slot is permanently dead-zoned for
        // that one timestamp.
        vm.warp(firstCommitTimestamp + dotnsRegistrarController.maxCommitmentAge());

        dotnsRegistrarController.commit(commitment);
        vm.stopPrank();

        assertEq(dotnsRegistrarController.commitments(commitment), block.timestamp);
    }

    function test_register_reverts_at_exact_expiry_boundary() public {
        string memory nameLabel = "alicebobx";
        address nameOwner = ed;
        _grantPopFull(nameOwner);

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel, owner: nameOwner, secret: keccak256("boundary"), reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);

        vm.startPrank(nameOwner);
        dotnsRegistrarController.commit(commitment);
        uint256 committedAt = dotnsRegistrarController.commitments(commitment);
        uint256 maxAge = dotnsRegistrarController.maxCommitmentAge();
        vm.warp(committedAt + maxAge);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrarController.CommitmentTooOld.selector,
                commitment,
                committedAt + maxAge,
                block.timestamp
            )
        );
        dotnsRegistrarController.register{value: 0}(registration);
        vm.stopPrank();
    }

    function test_register_popfull_wires_all_records() public {
        string memory nameLabel = "web2summit";
        address nameOwner = ed;

        _grantPopFull(nameOwner);

        vm.prank(owner);
        storeFactory.deployLabelStoreFor(nameOwner);

        vm.startPrank(nameOwner);

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, nameOwner, "store"));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel, owner: nameOwner, secret: secret, reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        dotnsRegistrarController.register{value: 0}(registration);
        vm.stopPrank();

        bytes32 labelHash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelHash);

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(node)), nameOwner);
        assertEq(dotnsRegistry.owner(node), nameOwner);
        assertEq(dotnsReverseResolver.nameOf(nameOwner), string.concat(nameLabel, ".dot"));

        ILabelStore ownerStore = ILabelStore(storeFactory.getLabelStore(nameOwner));
        assertEq(ownerStore.getLabel(node), string.concat(nameLabel, ".dot"));
        assertTrue(ownerStore.isLocked(node));
    }

    function test_register_poplite_reserves_base_name() public {
        string memory nameLabel = "lights01";
        address nameOwner = ed;

        _grantPopLite(nameOwner);
        vm.startPrank(nameOwner);

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, nameOwner, "lite"));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel, owner: nameOwner, secret: secret, reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        dotnsRegistrarController.register{value: 0}(registration);
        vm.stopPrank();

        (bool isReserved, address reservationOwner,) = popRules.isBaseNameReserved("lights");
        assertTrue(isReserved);
        assertEq(reservationOwner, nameOwner);
    }

    function test_register_does_not_overwrite_third_party_reverse_record() public {
        string memory victimLabel = "victimname01";
        string memory giftedLabel = "hijackname01";

        _register(victimLabel, tiago, IPopRules.PopStatus.NoStatus);
        assertEq(dotnsReverseResolver.nameOf(tiago), "victimname01.dot");

        bytes32 secret = keccak256(abi.encodePacked(giftedLabel, tiago, ed, block.timestamp));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: giftedLabel, owner: tiago, secret: secret, reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);

        vm.prank(ed);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 price = popRules.priceWithCheck(giftedLabel, tiago).price;

        vm.prank(ed);
        dotnsRegistrarController.register{value: price}(registration);

        assertEq(dotnsRegistrar.ownerOf(_tokenIdForLabel(giftedLabel)), tiago);
        assertEq(dotnsReverseResolver.nameOf(tiago), "victimname01.dot");
    }

    function test_registerreserved_writes_to_store() public {
        string memory nameLabel = "hello";
        address nameOwner = ed;

        vm.startPrank(owner);

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, nameOwner, "reserved"));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel, owner: nameOwner, secret: secret, reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        dotnsRegistrarController.registerReserved(registration);
        vm.stopPrank();

        bytes32 labelHash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelHash);

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(node)), nameOwner);
        assertEq(dotnsRegistry.owner(node), nameOwner);

        ILabelStore edStore = ILabelStore(storeFactory.getLabelStore(nameOwner));
        assertEq(edStore.getLabel(node), string.concat(nameLabel, ".dot"));
    }

    function test_registerreserved_revertnon_owner() public {
        string memory nameLabel = "hello";
        address nameOwner = ed;

        vm.startPrank(owner);

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, nameOwner, "reserved"));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel, owner: nameOwner, secret: secret, reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
        vm.stopPrank();

        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrarController.NotWhiteListedOrOwner.selector, ed)
        );
        dotnsRegistrarController.registerReserved(registration);
    }

    function test_whitelistaddress_reverts_without_owner_or_operator() public {
        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRoleManager.NotRoleOrOwner.selector,
                ed,
                DotnsConstants.WHITELIST_OPERATOR_ROLE
            )
        );
        dotnsRegistrarController.whiteListAddress(ed, true);
    }

    function test_owner_can_grant_and_revoke_whitelist_operator() public {
        vm.startPrank(owner);
        dotnsRegistrarController.grantRole(DotnsConstants.WHITELIST_OPERATOR_ROLE, leonardo);
        assertTrue(
            dotnsRegistrarController.hasRole(DotnsConstants.WHITELIST_OPERATOR_ROLE, leonardo)
        );

        dotnsRegistrarController.revokeRole(DotnsConstants.WHITELIST_OPERATOR_ROLE, leonardo);
        vm.stopPrank();

        assertFalse(
            dotnsRegistrarController.hasRole(DotnsConstants.WHITELIST_OPERATOR_ROLE, leonardo)
        );
    }

    function test_whitelist_operator_can_whitelist_address() public {
        _grantWhitelistOperator(leonardo);

        vm.prank(leonardo);
        dotnsRegistrarController.whiteListAddress(ed, true);

        assertTrue(dotnsRegistrarController.isWhiteListed(ed));
    }

    function test_setrole_reverts_for_zero_address() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRoleManager.InvalidRoleAccount.selector, address(0))
        );
        dotnsRegistrarController.setRole(DotnsConstants.WHITELIST_OPERATOR_ROLE, address(0), true);
    }

    function test_setrole_reverts_for_unsupported_role() public {
        bytes32 unsupportedRole = keccak256("DOTNS_UNSUPPORTED_ROLE");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRoleManager.UnsupportedRole.selector, unsupportedRole)
        );
        dotnsRegistrarController.setRole(unsupportedRole, leonardo, true);
    }

    function test_non_owner_cannot_grant_role() public {
        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, ed)
        );
        dotnsRegistrarController.grantRole(DotnsConstants.WHITELIST_OPERATOR_ROLE, leonardo);
    }

    function test_non_owner_cannot_revoke_role() public {
        _grantWhitelistOperator(leonardo);

        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, ed)
        );
        dotnsRegistrarController.revokeRole(DotnsConstants.WHITELIST_OPERATOR_ROLE, leonardo);
    }

    function test_supports_idotnsrolemanager_interface() public view {
        assertTrue(dotnsRegistrarController.supportsInterface(type(IDotnsRoleManager).interfaceId));
    }

    function test_whitelisted_can_register_reserved() public {
        string memory nameLabel = "reserved01";
        address nameOwner = ed;

        vm.prank(owner);
        dotnsRegistrarController.whiteListAddress(ed, true);
        assertTrue(dotnsRegistrarController.isWhiteListed(ed));

        vm.startPrank(ed);

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, nameOwner, "whitelisted"));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel, owner: nameOwner, secret: secret, reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        dotnsRegistrarController.registerReserved(registration);
        vm.stopPrank();

        bytes32 labelHash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelHash);

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(node)), nameOwner);
        assertEq(dotnsRegistry.owner(node), nameOwner);
    }

    function test_removed_from_whitelist_cannot_register_reserved() public {
        string memory nameLabel = "reserved02";
        address nameOwner = ed;

        vm.startPrank(owner);
        dotnsRegistrarController.whiteListAddress(ed, true);
        dotnsRegistrarController.whiteListAddress(ed, false);
        vm.stopPrank();

        assertFalse(dotnsRegistrarController.isWhiteListed(ed));

        vm.startPrank(ed);

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, nameOwner, "removed"));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel, owner: nameOwner, secret: secret, reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrarController.NotWhiteListedOrOwner.selector, ed)
        );
        dotnsRegistrarController.registerReserved(registration);
        vm.stopPrank();
    }

    function test_register_reverts_for_dotted_label() public {
        string memory nameLabel = "app.parity01";
        address nameOwner = ed;

        vm.startPrank(nameOwner);

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, nameOwner, "dotted"));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel, owner: nameOwner, secret: secret, reserved: false
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        vm.expectRevert(IDotnsRegistrarController.InvalidLabel.selector);
        dotnsRegistrarController.register{value: 0}(registration);
        vm.stopPrank();
    }

    function test_transfer_writes_label_and_creates_store() public {
        string memory nameLabel = "alicetransfer01";

        _register(nameLabel, ed, IPopRules.PopStatus.PopFull);

        assertEq(storeFactory.getLabelStore(leonardo), address(0));

        uint256 tokenId = _tokenIdForLabel(nameLabel);

        uint256 fee = dotnsRegistrar.quoteTransferFee(tokenId, leonardo);
        vm.prank(ed);
        dotnsRegistrar.transferFrom{value: fee}(ed, leonardo, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo);

        address leonardoStoreAddr = storeFactory.getLabelStore(leonardo);
        assertTrue(leonardoStoreAddr != address(0));

        ILabelStore leonardoStore = ILabelStore(leonardoStoreAddr);

        assertEq(leonardoStore.getLabel(bytes32(tokenId)), string.concat(nameLabel, ".dot"));
        assertTrue(leonardoStore.isLocked(bytes32(tokenId)));
    }

    function test_transfer_back_skips_locked_entry() public {
        string memory nameLabel = "carolreturn01";

        _register(nameLabel, ed, IPopRules.PopStatus.PopFull);

        uint256 tokenId = _tokenIdForLabel(nameLabel);

        uint256 outboundFee = dotnsRegistrar.quoteTransferFee(tokenId, leonardo);
        vm.prank(ed);
        dotnsRegistrar.transferFrom{value: outboundFee}(ed, leonardo, tokenId);

        uint256 returnFee = dotnsRegistrar.quoteTransferFee(tokenId, ed);
        vm.prank(leonardo);
        dotnsRegistrar.transferFrom{value: returnFee}(leonardo, ed, tokenId);

        ILabelStore edStore = ILabelStore(storeFactory.getLabelStore(ed));
        assertEq(edStore.getLabel(bytes32(tokenId)), string.concat(nameLabel, ".dot"));
        assertTrue(edStore.isLocked(bytes32(tokenId)));

        assertEq(dotnsRegistrar.ownerOf(tokenId), ed);
    }

    function test_transfer_clears_primary_reverse_name_when_current_name_is_moved() public {
        string memory nameLabel = "primarymove01";

        _register(nameLabel, ed, IPopRules.PopStatus.PopFull);

        uint256 tokenId = _tokenIdForLabel(nameLabel);
        assertEq(dotnsReverseResolver.nameOf(ed), "primarymove01.dot");

        uint256 _xferFee = dotnsRegistrar.quoteTransferFee(tokenId, leonardo);
        vm.prank(ed);
        dotnsRegistrar.transferFrom{value: _xferFee}(ed, leonardo, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo);
        assertEq(dotnsReverseResolver.nameOf(ed), "");
    }

    function test_mint_does_not_trigger_store_write() public {
        string memory nameLabel = "daveminting01";

        assertEq(storeFactory.getLabelStore(address(0)), address(0));

        _register(nameLabel, tiago, IPopRules.PopStatus.PopFull);

        ILabelStore tiagoStore = ILabelStore(storeFactory.getLabelStore(tiago));
        uint256 tokenId = _tokenIdForLabel(nameLabel);
        assertEq(tiagoStore.getLabel(bytes32(tokenId)), string.concat(nameLabel, ".dot"));

        assertEq(storeFactory.getLabelStore(address(0)), address(0));
    }

    function test_safe_transfer_writes_to_store() public {
        string memory nameLabel = "safexfer01";

        _register(nameLabel, ed, IPopRules.PopStatus.PopFull);

        uint256 tokenId = _tokenIdForLabel(nameLabel);

        uint256 _xferFee = dotnsRegistrar.quoteTransferFee(tokenId, leonardo);
        vm.prank(ed);
        dotnsRegistrar.safeTransferFrom{value: _xferFee}(ed, leonardo, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo);

        ILabelStore leonardoStore = ILabelStore(storeFactory.getLabelStore(leonardo));
        assertTrue(address(leonardoStore) != address(0));

        assertEq(leonardoStore.getLabel(bytes32(tokenId)), string.concat(nameLabel, ".dot"));
        assertTrue(leonardoStore.isLocked(bytes32(tokenId)));
    }

    function test_revert_cross_payer_sponsoring_unverified_owner() public {
        string memory popfullLabel = "alicedef";
        address payer = ed;
        address ownerAddr = leonardo;

        _grantPopFull(payer);

        bytes32 secret = keccak256(abi.encodePacked(popfullLabel, ownerAddr, block.timestamp));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: popfullLabel, owner: ownerAddr, secret: secret, reserved: true
            });
        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);

        vm.prank(payer);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 priced = popRules.priceWithoutCheck(popfullLabel, ownerAddr).price;
        uint256 friction = popRules.transferFloor(popfullLabel, payer, ownerAddr);
        uint256 charge = priced > friction ? priced : friction;

        vm.deal(payer, charge);
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrarController.OwnerStatusInsufficient.selector,
                popfullLabel,
                IPopRules.PopStatus.NoStatus,
                IPopRules.PopStatus.PopFull
            )
        );
        dotnsRegistrarController.register{value: charge}(registration);
    }

    function test_transfer_via_approved_operator_writes_to_store() public {
        string memory nameLabel = "opxfer01";

        _register(nameLabel, ed, IPopRules.PopStatus.PopFull);

        uint256 tokenId = _tokenIdForLabel(nameLabel);

        vm.prank(ed);
        dotnsRegistrar.setApprovalForAll(tiago, true);

        uint256 xferFee = dotnsRegistrar.quoteTransferFee(tokenId, leonardo);
        vm.deal(tiago, xferFee);
        vm.prank(tiago);
        dotnsRegistrar.transferFrom{value: xferFee}(ed, leonardo, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo);

        ILabelStore leonardoStore = ILabelStore(storeFactory.getLabelStore(leonardo));
        assertTrue(address(leonardoStore) != address(0));

        assertEq(leonardoStore.getLabel(bytes32(tokenId)), string.concat(nameLabel, ".dot"));
        assertTrue(leonardoStore.isLocked(bytes32(tokenId)));
    }

    function test_transfer_skips_store_deploy_when_label_empty() public {
        string memory nameLabel = "nolabel01";
        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelhash);
        uint256 tokenId = uint256(node);

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, ed, "");

        assertEq(storeFactory.getLabelStore(leonardo), address(0));

        uint256 _xferFee = dotnsRegistrar.quoteTransferFee(tokenId, leonardo);
        vm.prank(ed);
        dotnsRegistrar.transferFrom{value: _xferFee}(ed, leonardo, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo);
        // Label-less mints (gateway-cold PoP path) carry no label to mirror, so the registrar
        // skips the eager `LabelStore` deploy on transfer; demand-deploy still kicks in if the
        // recipient later receives a labelled write.
        assertEq(storeFactory.getLabelStore(leonardo), address(0));
    }

    /// @notice A zero-fee NoStatus to NoStatus transfer must still rebind the escrow
    ///         position to the new holder, because the deposit follows the NFT and
    ///         only the current holder can later release it.
    /// @dev Exercises the position-sync path in the registrar: with the transfer floor
    ///      at zero (NoStatus to NoStatus), the registrar still consults the escrow
    ///      whenever a live position points at a recipient other than the destination,
    ///      so the position rebinds. No reserve movement, no refund entry, and no
    ///      transfer-time payout fires.
    function test_transfer_zero_fee_rebinds_position_to_new_holder() public {
        string memory nameLabel = NOSTATUS_LABEL_A;

        _register(nameLabel, ed, IPopRules.PopStatus.NoStatus);
        uint256 tokenId = _tokenIdForLabel(nameLabel);

        IDotnsNameEscrow.ReleasePosition memory before = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(before.amount, RENT_PRICE, "NoStatus mint must seed RENT_PRICE deposit");
        assertEq(before.recipient, ed, "deposit recipient must be original registrant at mint");

        uint256 transferFee = dotnsRegistrar.quoteTransferFee(tokenId, leonardo);
        assertEq(transferFee, 0, "NoStatus to NoStatus transfer floor is zero");

        uint256 priorReserve = dotnsNameEscrow.reserves(address(0));
        uint256 priorPendingRefundsEd = dotnsNameEscrow.pendingRefundCount(ed);
        uint256 priorPendingRefundsLeonardo = dotnsNameEscrow.pendingRefundCount(leonardo);

        vm.prank(ed);
        dotnsRegistrar.transferFrom{value: 0}(ed, leonardo, tokenId);

        IDotnsNameEscrow.ReleasePosition memory after_ = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(after_.amount, RENT_PRICE, "deposit amount must travel with the NFT");
        assertEq(
            after_.recipient, leonardo, "position must rebind to the new holder, not be deleted"
        );
        assertEq(
            dotnsNameEscrow.reserves(address(0)),
            priorReserve,
            "tokenReserved must not move on a same-tier rebind"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(ed),
            priorPendingRefundsEd,
            "no refund entry may be credited to the prior depositor at transfer time"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(leonardo),
            priorPendingRefundsLeonardo,
            "no refund entry may be credited to the new holder at transfer time"
        );
        assertEq(
            dotnsNameEscrow.pendingWithdrawal(ed),
            0,
            "no pull-payment credit fires at transfer time"
        );
    }

    /// @notice A round trip leaves the deposit bound to whichever address currently
    ///         holds the NFT. No refund entries are credited on either leg.
    /// @dev Defensive: confirms a depositor-to-foreign-to-depositor round trip leaves
    ///      the position pointing back at the original registrant after the return leg,
    ///      with reserves untouched and no refund accruals at any step.
    function test_transfer_round_trip_to_original_depositor_rebinds_position_back() public {
        string memory nameLabel = NOSTATUS_LABEL_A;

        _register(nameLabel, ed, IPopRules.PopStatus.NoStatus);
        uint256 tokenId = _tokenIdForLabel(nameLabel);

        uint256 reserveAtMint = dotnsNameEscrow.reserves(address(0));
        uint256 edRefundsAtMint = dotnsNameEscrow.pendingRefundCount(ed);
        uint256 leonardoRefundsAtMint = dotnsNameEscrow.pendingRefundCount(leonardo);

        // Outbound leg ed to leonardo rebinds the position to leonardo.
        vm.prank(ed);
        dotnsRegistrar.transferFrom{value: 0}(ed, leonardo, tokenId);

        IDotnsNameEscrow.ReleasePosition memory between =
            dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(between.amount, RENT_PRICE, "deposit must travel through the first hop");
        assertEq(between.recipient, leonardo, "position recipient rebinds to leonardo on outbound");

        // Return leg leonardo back to ed rebinds the position back to ed.
        vm.prank(leonardo);
        dotnsRegistrar.transferFrom{value: 0}(leonardo, ed, tokenId);

        IDotnsNameEscrow.ReleasePosition memory after_ = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(after_.amount, RENT_PRICE, "deposit must travel through the return hop");
        assertEq(after_.recipient, ed, "position recipient rebinds back to ed on the return leg");

        assertEq(
            dotnsNameEscrow.reserves(address(0)),
            reserveAtMint,
            "reserves remain unchanged across the round trip"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(ed),
            edRefundsAtMint,
            "depositor receives no refund on either leg"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(leonardo),
            leonardoRefundsAtMint,
            "intermediate holder receives no refund on either leg"
        );
    }
}
