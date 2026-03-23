// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns, IDotnsRegistrarController} from "../../base/BaseDotns.t.sol";
import {IDotnsRegistrar} from "../../../contracts/registrars/IDotnsRegistrar.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";

import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {IStore, Store} from "../../../contracts/store/Store.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract DotnsRegistrarControllerTest is BaseDotns {
    bytes32 private constant DOTNS_REGISTERED_PREFIX =
        hex"646f746e732e72656769737465726564000000000000000000000000000000";

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

    function test_register_popfull_wires_all_records() public {
        string memory nameLabel = "web2summit";
        address nameOwner = ed;

        vm.startPrank(nameOwner);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);

        IStore ownerStoreInterface = storeFactory.deploy();
        Store ownerStore = Store(address(ownerStoreInterface));
        ownerStore.authorizeDotnsController(address(dotnsRegistrarController));

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

        bytes32 storeKey = keccak256(abi.encodePacked(DOTNS_REGISTERED_PREFIX, labelHash));
        assertEq(ownerStore.getValueFor(nameOwner, storeKey), string.concat(nameLabel, ".dot"));
        assertTrue(ownerStore.isLocked(nameOwner, storeKey));
    }

    function test_register_poplite_reserves_base_name() public {
        string memory nameLabel = "lights01";
        address nameOwner = ed;

        vm.startPrank(nameOwner);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopLite);

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

        Store edStore = Store(address(storeFactory.getDeployedStore(nameOwner)));
        bytes32 storeKey = keccak256(abi.encodePacked(DOTNS_REGISTERED_PREFIX, labelHash));
        assertEq(edStore.getValueFor(nameOwner, storeKey), string.concat(nameLabel, ".dot"));
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

    function test_whitelistaddress_reverts_non_owner() public {
        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, ed)
        );
        dotnsRegistrarController.whiteListAddress(ed, true);
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

    function test_registration_reverts_unauthorized_store() public {
        vm.startPrank(ed);
        storeFactory.deploy();
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);

        string memory label = "myname";
        bytes32 secret = keccak256(abi.encodePacked(label, ed, block.timestamp));

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label, owner: ed, secret: secret, reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 price = popRules.priceWithCheck(label, ed).price;

        vm.expectRevert(
            abi.encodeWithSelector(IStore.NotAuthorised.selector, address(dotnsRegistrarController))
        );
        dotnsRegistrarController.register{value: price}(registration);
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

        assertEq(address(storeFactory.getDeployedStore(leonardo)), address(0));

        uint256 tokenId = _tokenIdForLabel(nameLabel);

        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo);

        address leonardoStoreAddr = address(storeFactory.getDeployedStore(leonardo));
        assertTrue(leonardoStoreAddr != address(0));

        Store leonardoStore = Store(leonardoStoreAddr);
        assertEq(leonardoStore.owner(), leonardo);

        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 storeKey = _storeKey(labelhash);

        assertEq(leonardoStore.getValueFor(leonardo, storeKey), string.concat(nameLabel, ".dot"));
        assertTrue(leonardoStore.isLocked(leonardo, storeKey));
    }

    function test_transfer_back_skips_locked_entry() public {
        string memory nameLabel = "carolreturn01";

        _register(nameLabel, ed, IPopRules.PopStatus.PopFull);

        uint256 tokenId = _tokenIdForLabel(nameLabel);

        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);

        vm.prank(leonardo);
        dotnsRegistrar.transferFrom(leonardo, ed, tokenId);

        Store edStore = Store(address(storeFactory.getDeployedStore(ed)));
        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 storeKey = _storeKey(labelhash);
        assertEq(edStore.getValueFor(ed, storeKey), string.concat(nameLabel, ".dot"));
        assertTrue(edStore.isLocked(ed, storeKey));

        assertEq(dotnsRegistrar.ownerOf(tokenId), ed);
    }

    function test_transfer_clears_primary_reverse_name_when_current_name_is_moved() public {
        string memory nameLabel = "primarymove01";

        _register(nameLabel, ed, IPopRules.PopStatus.PopFull);

        uint256 tokenId = _tokenIdForLabel(nameLabel);
        assertEq(dotnsReverseResolver.nameOf(ed), "primarymove01.dot");

        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo);
        assertEq(dotnsReverseResolver.nameOf(ed), "");
    }

    function test_mint_does_not_trigger_store_write() public {
        string memory nameLabel = "daveminting01";

        assertEq(address(storeFactory.getDeployedStore(address(0))), address(0));

        _register(nameLabel, tiago, IPopRules.PopStatus.PopFull);

        Store tiagoStore = Store(address(storeFactory.getDeployedStore(tiago)));
        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 storeKey = _storeKey(labelhash);
        assertEq(tiagoStore.getValueFor(tiago, storeKey), string.concat(nameLabel, ".dot"));

        assertEq(address(storeFactory.getDeployedStore(address(0))), address(0));
    }

    function test_transfer_succeeds_without_protocol_registry() public {
        string memory nameLabel = "noregistry01";

        _register(nameLabel, ed, IPopRules.PopStatus.PopFull);

        uint256 tokenId = _tokenIdForLabel(nameLabel);

        vm.prank(owner);
        dotnsRegistrar.updateProtocolRegistry(IDotnsProtocolRegistry(address(0)));

        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo);
        assertEq(address(storeFactory.getDeployedStore(leonardo)), address(0));
    }

    function test_transfer_succeeds_when_sender_has_no_store() public {
        string memory nameLabel = "nostore01";
        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelhash);
        uint256 tokenId = uint256(node);

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, ed, nameLabel);

        // Sender has no Store — transfer should still succeed
        assertEq(address(storeFactory.getDeployedStore(ed)), address(0));

        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo);

        // Recipient gets a Store with the label written (label comes from _labels, not sender Store)
        assertTrue(address(storeFactory.getDeployedStore(leonardo)) != address(0));
        bytes32 storeKey = _storeKey(labelhash);
        Store leonardoStore = Store(address(storeFactory.getDeployedStore(leonardo)));
        assertEq(leonardoStore.getValueFor(leonardo, storeKey), "nostore01.dot");
    }

    function test_safe_transfer_writes_to_store() public {
        string memory nameLabel = "safexfer01";

        _register(nameLabel, ed, IPopRules.PopStatus.PopFull);

        uint256 tokenId = _tokenIdForLabel(nameLabel);

        vm.prank(ed);
        dotnsRegistrar.safeTransferFrom(ed, leonardo, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo);

        Store leonardoStore = Store(address(storeFactory.getDeployedStore(leonardo)));
        assertTrue(address(leonardoStore) != address(0));

        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 storeKey = _storeKey(labelhash);
        assertEq(leonardoStore.getValueFor(leonardo, storeKey), string.concat(nameLabel, ".dot"));
        assertTrue(leonardoStore.isLocked(leonardo, storeKey));
    }

    function test_transfer_via_approved_operator_writes_to_store() public {
        string memory nameLabel = "opxfer01";

        _register(nameLabel, ed, IPopRules.PopStatus.PopFull);

        uint256 tokenId = _tokenIdForLabel(nameLabel);

        vm.prank(ed);
        dotnsRegistrar.setApprovalForAll(tiago, true);

        vm.prank(tiago);
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo);

        Store leonardoStore = Store(address(storeFactory.getDeployedStore(leonardo)));
        assertTrue(address(leonardoStore) != address(0));

        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 storeKey = _storeKey(labelhash);
        assertEq(leonardoStore.getValueFor(leonardo, storeKey), string.concat(nameLabel, ".dot"));
        assertTrue(leonardoStore.isLocked(leonardo, storeKey));
    }

    function test_syncLabel_sets_label_for_owner() public {
        string memory nameLabel = "synclabel01";
        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = keccak256(abi.encodePacked(dotNode, labelhash));
        uint256 tokenId = uint256(node);

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, ed, "");

        vm.prank(ed);
        dotnsRegistrar.syncLabel(tokenId, nameLabel);

        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);

        Store leonardoStore = Store(address(storeFactory.getDeployedStore(leonardo)));
        assertTrue(address(leonardoStore) != address(0));

        bytes32 storeKey = _storeKey(labelhash);
        assertEq(leonardoStore.getValueFor(leonardo, storeKey), string.concat(nameLabel, ".dot"));
    }

    function test_syncLabel_reverts_for_non_owner() public {
        string memory nameLabel = "synclabel02";
        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = keccak256(abi.encodePacked(dotNode, labelhash));
        uint256 tokenId = uint256(node);

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, ed, "");

        vm.prank(leonardo);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrar.NotTokenOwner.selector, leonardo, tokenId)
        );
        dotnsRegistrar.syncLabel(tokenId, nameLabel);
    }

    function test_syncLabel_reverts_wrong_label() public {
        string memory nameLabel = "synclabel03";
        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = keccak256(abi.encodePacked(dotNode, labelhash));
        uint256 tokenId = uint256(node);

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, ed, "");

        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsRegistrar.LabelMismatch.selector, tokenId));
        dotnsRegistrar.syncLabel(tokenId, "wronglabel");
    }

    function test_syncLabel_reverts_already_set() public {
        string memory nameLabel = "synclabel04";
        _register(nameLabel, ed, IPopRules.PopStatus.PopFull);
        uint256 tokenId = _tokenIdForLabel(nameLabel);

        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsRegistrar.LabelAlreadySet.selector, tokenId));
        dotnsRegistrar.syncLabel(tokenId, nameLabel);
    }

    function test_syncLabel_reverts_for_dotted_label() public {
        string memory nameLabel = "nested.label";
        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = keccak256(abi.encodePacked(dotNode, labelhash));
        uint256 tokenId = uint256(node);

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, ed, "");

        vm.prank(ed);
        vm.expectRevert(IDotnsRegistrar.InvalidLabel.selector);
        dotnsRegistrar.syncLabel(tokenId, nameLabel);
    }

    function test_syncLabel_reverts_for_uppercase_label() public {
        string memory nameLabel = "Synclabel05";
        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = keccak256(abi.encodePacked(dotNode, labelhash));
        uint256 tokenId = uint256(node);

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, ed, "");

        vm.prank(ed);
        vm.expectRevert(IDotnsRegistrar.InvalidLabel.selector);
        dotnsRegistrar.syncLabel(tokenId, nameLabel);
    }

    function test_transfer_deploys_store_without_label() public {
        string memory nameLabel = "nolabel01";
        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = keccak256(abi.encodePacked(dotNode, labelhash));
        uint256 tokenId = uint256(node);

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, ed, "");

        assertEq(address(storeFactory.getDeployedStore(leonardo)), address(0));

        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo);
        assertTrue(address(storeFactory.getDeployedStore(leonardo)) != address(0));

        bytes32 storeKey = _storeKey(labelhash);
        Store leonardoStore = Store(address(storeFactory.getDeployedStore(leonardo)));
        assertEq(leonardoStore.getValueFor(leonardo, storeKey), "");
    }
}
