// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns, IDotnsRegistrarController} from "../../base/BaseDotns.t.sol";

import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {DotnsScarcityPricing} from "../../../contracts/pop/DotnsScarcityPricing.sol";
import {IDotnsPricing} from "../../../contracts/pop/IDotnsPricing.sol";
import {IDotnsCostModelRegistry} from "../../../contracts/pop/IDotnsCostModelRegistry.sol";
import {ILabelStore} from "../../../contracts/store/ILabelStore.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";
import {DotnsRegistrarController} from "../../../contracts/registrars/DotnsRegistrarController.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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
                label: "alicebob",
                owner: ed,
                secret: keccak256("secret"),
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
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
                label: "alicebob",
                owner: ed,
                secret: keccak256("secret"),
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
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
                label: "alicebob",
                owner: ed,
                secret: keccak256("secret"),
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
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
                label: nameLabel,
                owner: nameOwner,
                secret: keccak256("boundary"),
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
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
                label: nameLabel,
                owner: nameOwner,
                secret: secret,
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 registrationPrice = popRules.priceWithCheck(nameLabel, nameOwner).price;
        dotnsRegistrarController.register{value: registrationPrice}(registration);
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

    /// @notice A two-digit second-level name is unreachable, which is what keeps a subname
    ///         from spelling a lite name.
    /// @dev `joseph.42` reads either as one label or as `joseph` beneath `42`, and the second
    ///      reading needs `42` to exist. No production controller entry point can create it:
    ///      this path requires three characters, and both gateway paths are letters only. An
    ///      owner-authorised controller calling the registrar directly is not bound by either,
    ///      so the invariant holds over entry points rather than over the registrar. Pinned
    ///      here because it rests on a length floor that reads as unrelated to lite names.
    ///      `register` is called directly rather than through `_commitAndRegister`, which
    ///      quotes `priceWithCheck` first and would revert on the reserved tier instead. No
    ///      commitment is needed: the label is validated before one is consumed.
    function test_register_rejects_a_two_digit_label() public {
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: "42",
                owner: ed,
                secret: keccak256("two-digit"),
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
            });

        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrarController.LabelTooShort.selector, "42")
        );
        vm.prank(ed);
        dotnsRegistrarController.register(registration);
    }

    /// @notice A public registration reserves no stem.
    /// @dev PopRules' reservation slot belongs to the gateway queue, and `register` writes none
    ///      of its own. Pinned here because a stem the public path reserved silently would
    ///      block the gateway's own registrant for the whole reservation window.
    function test_public_register_reserves_no_base_name() public {
        string memory nameLabel = "lights01";
        address nameOwner = ed;

        _grantPopFull(nameOwner);
        _commitAndRegister(nameLabel, nameOwner, true);

        assertEq(dotnsRegistrar.ownerOf(_tokenIdForLabel(nameLabel)), nameOwner);

        (bool isReserved,,) = popRules.isBaseNameReserved(popRules.stripDigits(nameLabel));
        assertFalse(isReserved, "no stem reserved by a public registration");
    }

    function test_register_does_not_overwrite_third_party_reverse_record() public {
        string memory victimLabel = "victimname01";
        string memory giftedLabel = "hijackname01";

        _register(victimLabel, tiago, IPopRules.PopStatus.NoStatus);
        assertEq(dotnsReverseResolver.nameOf(tiago), "victimname01.dot");

        bytes32 secret = keccak256(abi.encodePacked(giftedLabel, tiago, ed, block.timestamp));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: giftedLabel,
                owner: tiago,
                secret: secret,
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
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

        _grantName(nameLabel, nameOwner);
        vm.startPrank(nameOwner);

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, nameOwner, "reserved"));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel,
                owner: nameOwner,
                secret: secret,
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
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

    function test_registerreserved_reverts_without_a_grant() public {
        string memory nameLabel = "hello";
        address nameOwner = ed;

        vm.startPrank(ed);

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, nameOwner, "reserved"));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel,
                owner: nameOwner,
                secret: secret,
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
        vm.stopPrank();

        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrarController.NameNotGranted.selector, nameLabel, nameOwner
            )
        );
        dotnsRegistrarController.registerReserved(registration);
    }

    /// @dev The controller exposes no role surface at all: reserved registration reads grants
    /// from `DotnsNameWhitelist`, whose own admin surface is Root-only, so there is no role to
    /// hold and nothing to advertise.
    function test_controller_advertises_no_role_interface() public view {
        assertTrue(
            dotnsRegistrarController.supportsInterface(type(IDotnsRegistrarController).interfaceId)
        );
        assertFalse(dotnsRegistrarController.supportsInterface(bytes4(0xdeadbeef)));
    }

    function test_granted_beneficiary_can_register_reserved() public {
        string memory nameLabel = "reserved01";
        address nameOwner = ed;

        _grantName(nameLabel, nameOwner);
        assertTrue(dotnsNameWhitelist.isGrantedTo(nameLabel, nameOwner));

        vm.startPrank(ed);

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, nameOwner, "whitelisted"));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel,
                owner: nameOwner,
                secret: secret,
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
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
        // Single use: the mint spends the grant.
        assertFalse(dotnsNameWhitelist.isGrantedTo(nameLabel, nameOwner));
        // The reserved path never writes the owner's reverse record.
        assertEq(dotnsReverseResolver.nameOf(nameOwner), "");
    }

    function test_registerReserved_bypasses_closed_short_name_gate() public {
        _setShortNames(false);

        // base length 8, closed on the public path
        string memory nameLabel = "reserved";
        address nameOwner = ed;

        _grantName(nameLabel, nameOwner);

        vm.startPrank(ed);
        bytes32 secret = keccak256(abi.encodePacked(nameLabel, nameOwner, "gate-closed"));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel,
                owner: nameOwner,
                secret: secret,
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
            });
        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
        dotnsRegistrarController.registerReserved(registration);
        vm.stopPrank();

        bytes32 node = _namehash(dotNode, keccak256(bytes(nameLabel)));
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(node)), nameOwner);
    }

    function test_revoked_grant_cannot_register_reserved() public {
        string memory nameLabel = "reserved02";
        address nameOwner = ed;

        _grantName(nameLabel, nameOwner);
        _mockOriginIsRoot(true);
        dotnsNameWhitelist.revokeName(nameLabel);
        _mockOriginIsRoot(false);

        assertFalse(dotnsNameWhitelist.isGrantedTo(nameLabel, nameOwner));

        vm.startPrank(ed);

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, nameOwner, "removed"));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel,
                owner: nameOwner,
                secret: secret,
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrarController.NameNotGranted.selector, nameLabel, nameOwner
            )
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
                label: nameLabel,
                owner: nameOwner,
                secret: secret,
                reserved: false,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
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
                label: popfullLabel,
                owner: ownerAddr,
                secret: secret,
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
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
                IPopRules.OwnerStatusInsufficient.selector,
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
        assertEq(before.amount, BASE_DEPOSIT, "NoStatus mint must seed BASE_DEPOSIT deposit");
        assertEq(before.recipient, ed, "deposit recipient must be original registrant at mint");

        uint256 transferFee = dotnsRegistrar.quoteTransferFee(tokenId, leonardo);
        assertEq(transferFee, 0, "NoStatus to NoStatus transfer floor is zero");

        uint256 priorReserve = dotnsNameEscrow.reserves(address(0));
        uint256 priorPendingRefundsEd = dotnsNameEscrow.pendingRefundCount(ed);
        uint256 priorPendingRefundsLeonardo = dotnsNameEscrow.pendingRefundCount(leonardo);

        vm.prank(ed);
        dotnsRegistrar.transferFrom{value: 0}(ed, leonardo, tokenId);

        IDotnsNameEscrow.ReleasePosition memory after_ = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(after_.amount, BASE_DEPOSIT, "deposit amount must travel with the NFT");
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
        assertEq(between.amount, BASE_DEPOSIT, "deposit must travel through the first hop");
        assertEq(between.recipient, leonardo, "position recipient rebinds to leonardo on outbound");

        // Return leg leonardo back to ed rebinds the position back to ed.
        vm.prank(leonardo);
        dotnsRegistrar.transferFrom{value: 0}(leonardo, ed, tokenId);

        IDotnsNameEscrow.ReleasePosition memory after_ = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(after_.amount, BASE_DEPOSIT, "deposit must travel through the return hop");
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

    function _nostatusRegistration(
        string memory label,
        address nameOwner,
        uint256 maxPrice,
        uint256 pricingVersion
    )
        internal
        pure
        returns (IDotnsRegistrarController.Registration memory registration)
    {
        registration = IDotnsRegistrarController.Registration({
            label: label,
            owner: nameOwner,
            secret: keccak256(abi.encodePacked(label, nameOwner)),
            reserved: false,
            maxPrice: maxPrice,
            pricingVersion: pricingVersion
        });
    }

    function test_register_reverts_when_charge_exceeds_maxPrice() public {
        string memory label = "ceilingtest01";
        address nameOwner = ed;
        uint256 price = popRules.price(label);
        IDotnsRegistrarController.Registration memory registration =
            _nostatusRegistration(label, nameOwner, price - 1, popRules.pricingVersion());

        _commitRegistrationAndWaitMinimumAge(registration);

        vm.prank(nameOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrarController.PriceExceedsMax.selector, label, price, price - 1
            )
        );
        dotnsRegistrarController.register{value: price}(registration);
    }

    function test_register_succeeds_when_maxPrice_exactly_met() public {
        string memory label = "exactmaxtest01";
        address nameOwner = ed;
        uint256 price = popRules.price(label);
        IDotnsRegistrarController.Registration memory registration =
            _nostatusRegistration(label, nameOwner, price, popRules.pricingVersion());

        _commitRegistrationAndWaitMinimumAge(registration);

        vm.prank(nameOwner);
        dotnsRegistrarController.register{value: price}(registration);

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(_tokenIdForLabel(label)), nameOwner);
    }

    function test_maxPrice_bound_into_commitment() public {
        string memory label = "maxbindtest01";
        address nameOwner = ed;
        uint256 price = popRules.price(label);
        IDotnsRegistrarController.Registration memory committed =
            _nostatusRegistration(label, nameOwner, type(uint256).max, popRules.pricingVersion());

        _commitRegistrationAndWaitMinimumAge(committed);

        // Reveal with a different ceiling: the commitment hash no longer matches.
        IDotnsRegistrarController.Registration memory tampered = committed;
        tampered.maxPrice = price;
        bytes32 expected = dotnsRegistrarController.makeCommitment(tampered);

        vm.prank(nameOwner);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrarController.CommitmentNotFound.selector, expected)
        );
        dotnsRegistrarController.register{value: price}(tampered);
    }

    function test_pricingVersion_bound_into_commitment() public {
        string memory label = "verbindtest01";
        address nameOwner = ed;
        uint256 price = popRules.price(label);
        IDotnsRegistrarController.Registration memory committed =
            _nostatusRegistration(label, nameOwner, type(uint256).max, popRules.pricingVersion());

        _commitRegistrationAndWaitMinimumAge(committed);

        // Reveal with a different committed version: the commitment hash no longer matches.
        IDotnsRegistrarController.Registration memory tampered = committed;
        tampered.pricingVersion = committed.pricingVersion + 1;
        bytes32 expected = dotnsRegistrarController.makeCommitment(tampered);

        vm.prank(nameOwner);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrarController.CommitmentNotFound.selector, expected)
        );
        dotnsRegistrarController.register{value: price}(tampered);
    }

    function test_reveal_prices_at_committed_version_after_model_swap() public {
        string memory label = "versionlock01";
        address nameOwner = ed;
        uint256 committedVersion = popRules.pricingVersion();
        uint256 committedPrice = popRules.price(label);

        IDotnsRegistrarController.Registration memory registration =
            _nostatusRegistration(label, nameOwner, committedPrice, committedVersion);

        _commitRegistrationAndWaitMinimumAge(registration);

        // Governance registers a pricier model mid-window, moving the current version.
        DotnsScarcityPricing pricierModel = new DotnsScarcityPricing(BASE_DEPOSIT * 2, MIN_PRICE);
        vm.prank(owner);
        costModelRegistry.register(IDotnsPricing(address(pricierModel)));
        assertTrue(popRules.pricingVersion() != committedVersion);

        // The reveal still settles at the committed version's amount and succeeds.
        vm.prank(nameOwner);
        dotnsRegistrarController.register{value: committedPrice}(registration);

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(_tokenIdForLabel(label)), nameOwner);
    }

    function test_reveal_reverts_when_committed_version_not_current() public {
        string memory label = "unknownver01";
        address nameOwner = ed;
        // A caller cannot bind an arbitrary version: commit stamps the version current then, and
        // the reveal rejects a `pricingVersion` that differs from it.
        uint256 stampedVersion = costModelRegistry.currentVersion();
        uint256 wrongVersion = uint256(keccak256("never registered version"));

        IDotnsRegistrarController.Registration memory registration =
            _nostatusRegistration(label, nameOwner, type(uint256).max, wrongVersion);

        _commitRegistrationAndWaitMinimumAge(registration);

        vm.prank(nameOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsCostModelRegistry.PricingVersionMismatch.selector,
                stampedVersion,
                wrongVersion
            )
        );
        dotnsRegistrarController.register{value: BASE_DEPOSIT}(registration);
    }

    function test_reveal_prices_at_committed_version_across_current_moves() public {
        string memory label = "movingcur01";
        address nameOwner = ed;

        // Register a second model and commit under it as the current version.
        DotnsScarcityPricing modelV2 = new DotnsScarcityPricing(BASE_DEPOSIT * 2, MIN_PRICE);
        vm.prank(owner);
        costModelRegistry.register(IDotnsPricing(address(modelV2)));
        uint256 committedVersion = costModelRegistry.currentVersion();
        uint256 committedPrice = popRules.price(label);

        IDotnsRegistrarController.Registration memory registration =
            _nostatusRegistration(label, nameOwner, committedPrice, committedVersion);
        _commitRegistrationAndWaitMinimumAge(registration);

        // Move current forward to a third model, then revert it back to the first registered
        // version, which the harness seeds with the flat launch model.
        DotnsScarcityPricing modelV3 = new DotnsScarcityPricing(BASE_DEPOSIT * 4, MIN_PRICE);
        uint256 firstVersion = flatPricing.version();
        vm.prank(owner);
        costModelRegistry.register(IDotnsPricing(address(modelV3)));
        vm.prank(owner);
        costModelRegistry.setCurrentVersion(firstVersion);

        // The reveal still charges the committed version's amount, no matter how current moved.
        vm.prank(nameOwner);
        dotnsRegistrarController.register{value: committedPrice}(registration);

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(_tokenIdForLabel(label)), nameOwner);
    }

    // Reserved path: Root authority, single use, relayer submission, unconfigured whitelist.

    /// @dev Root is the second accepted authority and needs no grant. It must also leave any live
    /// grant unspent, so governance minting does not silently consume someone else's entitlement.
    function test_root_mints_reserved_without_a_grant_and_leaves_grants_unspent() public {
        string memory nameLabel = "rootmint01";

        // Grant the label Root is about to mint. Root skips consume, so this exact grant must
        // survive; an unrelated label could not detect consumption of the one being minted.
        _grantName(nameLabel, ed);

        _mockOriginIsRoot(true);
        _revealReserved(nameLabel, ed, tiago);
        _mockOriginIsRoot(false);

        assertEq(dotnsRegistrar.ownerOf(_tokenIdForLabel(nameLabel)), ed);
        assertTrue(
            dotnsNameWhitelist.isGrantedTo(nameLabel, ed),
            "a Root mint consumed the grant on the label it minted"
        );
    }

    /// @dev A grant is spent by its mint, so a second registration of the same label is refused by
    /// the grant check, which runs before the availability check. Availability after a re-grant is
    /// covered separately in the lifecycle suite.
    function test_consumed_grant_cannot_mint_again() public {
        string memory nameLabel = "singleuse01";
        _grantName(nameLabel, ed);
        _revealReserved(nameLabel, ed, ed);

        assertFalse(dotnsNameWhitelist.isGrantedTo(nameLabel, ed));

        IDotnsRegistrarController.Registration memory second = _commitReserved(nameLabel, ed, ed);
        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrarController.NameNotGranted.selector, nameLabel, ed)
        );
        dotnsRegistrarController.registerReserved(second);
    }

    /// @dev The gate pairs label with owner. A grant naming one address must not admit a
    /// registration for a different one, even though the label does carry a live grant. Without
    /// this, an implementation that checked only "the label is granted" would pass every other
    /// negative test here, since those all use ungranted labels.
    function test_a_grant_does_not_admit_a_different_owner() public {
        string memory nameLabel = "boundgrant01";
        _grantName(nameLabel, ed);

        IDotnsRegistrarController.Registration memory registration =
            _commitReserved(nameLabel, tiago, tiago);
        vm.prank(tiago);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrarController.NameNotGranted.selector, nameLabel, tiago
            )
        );
        dotnsRegistrarController.registerReserved(registration);

        assertTrue(dotnsNameWhitelist.isGrantedTo(nameLabel, ed), "the grant was disturbed");
    }

    /// @dev The gate reads `registration.owner`, so a relayer may submit for the beneficiary and
    /// the name still mints to the beneficiary rather than the submitter.
    function test_relayer_can_submit_for_the_granted_beneficiary() public {
        string memory nameLabel = "relayed01";
        _grantName(nameLabel, ed);

        _revealReserved(nameLabel, ed, tiago);

        assertEq(dotnsRegistrar.ownerOf(_tokenIdForLabel(nameLabel)), ed);
        assertEq(dotnsReverseResolver.nameOf(ed), "");
    }

    /// @dev With no whitelist on the registry there is no grant authority to consult, so the path
    /// fails closed rather than falling back to some other gate. Checked before the Root branch
    /// can matter, so it holds for a Root dispatch too.
    function test_registerReserved_reverts_when_the_whitelist_is_unconfigured() public {
        string memory nameLabel = "unconfigured01";
        _grantName(nameLabel, ed);

        vm.mockCall(
            address(protocolRegistry),
            abi.encodeWithSelector(
                IDotnsProtocolRegistry.get.selector, DotnsConstants.NAME_WHITELIST
            ),
            abi.encode(address(0))
        );

        IDotnsRegistrarController.Registration memory registration =
            _commitReserved(nameLabel, ed, ed);
        vm.prank(ed);
        vm.expectRevert(IDotnsRegistrarController.WhitelistNotConfigured.selector);
        dotnsRegistrarController.registerReserved(registration);
    }

    /// @dev Root reads no grant and consumes none, so it does not need the whitelist wired. A
    /// governance mint therefore works on a protocol whose registry is only partly configured,
    /// which is what makes Root a usable recovery path rather than one gated on another key's
    /// wiring having completed.
    function test_root_mints_when_the_whitelist_is_unconfigured() public {
        string memory nameLabel = "rootunconfigured01";
        vm.mockCall(
            address(protocolRegistry),
            abi.encodeWithSelector(
                IDotnsProtocolRegistry.get.selector, DotnsConstants.NAME_WHITELIST
            ),
            abi.encode(address(0))
        );

        IDotnsRegistrarController.Registration memory registration =
            _commitReserved(nameLabel, ed, ed);
        _mockOriginIsRoot(true);
        vm.prank(ed);
        dotnsRegistrarController.registerReserved(registration);
        _mockOriginIsRoot(false);

        assertEq(dotnsRegistrar.ownerOf(_tokenIdForLabel(nameLabel)), ed);
    }

    // Regression: the paid path's governance-reserved rejection is unchanged by the grant gate.

    /// @dev A reserved-tier label (base length five or fewer) is refused on the paid path whoever
    /// pays. The cross-payer branch distinguishes a governance-reserved label from a stem held by
    /// another user, so it reverts `GovernanceReserved` rather than `NameReserved`. Reserved-tier
    /// labels reach circulation only through `registerReserved`, and a grant does not change that.
    function test_register_rejects_a_governance_reserved_label_for_a_cross_payer() public {
        string memory nameLabel = "alice";

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel,
                owner: ed,
                secret: keccak256("governance-reserved"),
                reserved: false,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
            });

        vm.startPrank(tiago);
        dotnsRegistrarController.commit(dotnsRegistrarController.makeCommitment(registration));
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
        vm.expectRevert(abi.encodeWithSelector(IPopRules.GovernanceReserved.selector, nameLabel));
        dotnsRegistrarController.register{value: 10 ether}(registration);
        vm.stopPrank();
    }

    /// @dev The direct branch prices through `priceWithCheck`, which rejects the reserved tier in
    /// PopRules before the controller sees it.
    function test_register_rejects_a_governance_reserved_label_for_the_owner() public {
        string memory nameLabel = "alice";

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel,
                owner: ed,
                secret: keccak256("governance-reserved-direct"),
                reserved: false,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
            });

        vm.startPrank(ed);
        dotnsRegistrarController.commit(dotnsRegistrarController.makeCommitment(registration));
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IPopRules.PopError.selector, "Reserved for Governance")
        );
        dotnsRegistrarController.register{value: 10 ether}(registration);
        vm.stopPrank();
    }

    /// @notice Commit-reveal a reserved registration for `nameOwner`, submitted by `submitter`.
    /// @notice Commits a reserved registration and warps past the minimum age, returning it ready
    /// to reveal.
    /// @dev Separate from the reveal so a negative test can place `vm.expectRevert` immediately
    ///      before `registerReserved`. The cheatcode attaches to the next external call, and
    ///      `makeCommitment` is one, so a combined helper would consume the expectation there and
    ///      the test would fail against a call that never reverts.
    function _commitReserved(
        string memory nameLabel,
        address nameOwner,
        address submitter
    )
        private
        returns (IDotnsRegistrarController.Registration memory registration)
    {
        registration = IDotnsRegistrarController.Registration({
            label: nameLabel,
            owner: nameOwner,
            secret: keccak256(abi.encodePacked(nameLabel, nameOwner, submitter)),
            reserved: true,
            maxPrice: type(uint256).max,
            pricingVersion: popRules.pricingVersion()
        });

        vm.startPrank(submitter);
        dotnsRegistrarController.commit(dotnsRegistrarController.makeCommitment(registration));
        vm.stopPrank();
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
    }

    /// @notice Commit-reveal a reserved registration for `nameOwner`, submitted by `submitter`.
    function _revealReserved(
        string memory nameLabel,
        address nameOwner,
        address submitter
    )
        private
    {
        IDotnsRegistrarController.Registration memory registration =
            _commitReserved(nameLabel, nameOwner, submitter);
        vm.prank(submitter);
        dotnsRegistrarController.registerReserved(registration);
    }
}
