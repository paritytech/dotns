// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns, IDotnsRegistrarController} from "../../base/BaseDotns.t.sol";

import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {IStore} from "../../../contracts/store/IStore.sol";
import {Store} from "../../../contracts/store/Store.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract DotnsRegistrarControllerTest is BaseDotns {
    bytes32 private constant DOTNS_REGISTERED_PREFIX =
        hex"646f746e732e72656769737465726564000000000000000000000000000000";

    function test_available_returns_true_for_unregistered_label() public view {
        assertTrue(dotnsRegistrarController.available("alicebob"));
    }

    function test_available_returns_false_after_registration() public {
        _register("longnamehere01", ed, IPopRules.PopStatus.NoStatus);
        assertFalse(dotnsRegistrarController.available("longnamehere01"));
    }

    function test_makecommitment_matches_controller_encoding() public view {
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: "alicebob", owner: ed, secret: keccak256("secret"), reserved: true
            });

        bytes32 gotCommitment = dotnsRegistrarController.makeCommitment(registration);

        bytes32 expectedCommitment = keccak256(
            abi.encodePacked(
                bytes(registration.label),
                bytes32(uint256(uint160(registration.owner))),
                registration.secret,
                registration.reserved
            )
        );

        assertEq(gotCommitment, expectedCommitment);
    }

    function test_commit_sets_timestamp_and_emits() public {
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: "alicebob", owner: ed, secret: keccak256("secret"), reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);

        vm.expectEmit(true, false, false, false);
        emit IDotnsRegistrarController.NameCommitted(commitment);

        vm.prank(ed);
        dotnsRegistrarController.commit(commitment);

        assertEq(dotnsRegistrarController.commitments(commitment), block.timestamp);
    }

    function test_commit_allows_recommit_after_expiry() public {
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: "alicebob", owner: ed, secret: keccak256("secret"), reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);

        vm.prank(ed);
        dotnsRegistrarController.commit(commitment);

        uint256 firstCommitTimestamp = dotnsRegistrarController.commitments(commitment);
        vm.warp(firstCommitTimestamp + dotnsRegistrarController.maxCommitmentAge() + 1);

        vm.prank(ed);
        dotnsRegistrarController.commit(commitment);

        assertEq(dotnsRegistrarController.commitments(commitment), block.timestamp);
    }

    function test_register_registers_popfull_name_and_wires_records() public {
        string memory nameLabel = "alicebob";
        address nameOwner = ed;

        vm.prank(nameOwner);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);

        // PopFull should always have zero price
        uint256 quotedPrice = popRules.priceWithCheck(nameLabel, nameOwner).price;
        assertEq(quotedPrice, 0);

        vm.prank(nameOwner);
        IStore ownerStoreInterface = storeFactory.deploy();

        Store ownerStore = Store(address(ownerStoreInterface));

        vm.prank(nameOwner);
        ownerStore.authorizeDotnsController(address(dotnsRegistrarController));

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, nameOwner, "store"));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel, owner: nameOwner, secret: secret, reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);

        vm.prank(nameOwner);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        IPopRules.PriceWithMeta memory priceMetadata = popRules.priceWithCheck(nameLabel, nameOwner);
        assertEq(priceMetadata.price, 0);

        bytes32 labelHash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelHash);

        vm.expectEmit(true, true, true, true);
        emit IDotnsRegistrarController.NameRegistered(
            nameLabel, labelHash, nameOwner, priceMetadata.price, address(ownerStore)
        );

        vm.prank(nameOwner);
        dotnsRegistrarController.register{value: 0}(registration);

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(labelHash)), nameOwner);
        assertEq(dotnsRegistry.owner(node), nameOwner);
        assertEq(dotnsReverseResolver.nameOf(nameOwner), string.concat(nameLabel, ".dot"));

        bytes32 storeKey = keccak256(abi.encodePacked(DOTNS_REGISTERED_PREFIX, labelHash));
        assertEq(ownerStore.getValueFor(nameOwner, storeKey), string.concat(nameLabel, ".dot"));
        assertTrue(ownerStore.isLocked(nameOwner, storeKey));
    }

    function test_register_refunds_full_value_when_price_is_zero() public {
        vm.txGasPrice(0);

        string memory nameLabel = "alicebob";
        address nameOwner = ed;

        vm.prank(nameOwner);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);

        // PopFull should always have zero price
        uint256 quotedPrice = popRules.priceWithCheck(nameLabel, nameOwner).price;
        assertEq(quotedPrice, 0);

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, nameOwner, "refund"));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel, owner: nameOwner, secret: secret, reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);

        vm.prank(nameOwner);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 requiredPrice = popRules.priceWithCheck(nameLabel, nameOwner).price;
        assertEq(requiredPrice, 0);

        uint256 balanceBefore = nameOwner.balance;

        vm.prank(nameOwner);
        dotnsRegistrarController.register{value: 1}(registration);

        // Entire payment should be refunded when price is 0
        assertEq(nameOwner.balance, balanceBefore);
    }

    function test_register_reserves_base_name_for_poplite_user() public {
        string memory nameLabel = "lights01";
        address nameOwner = ed;

        vm.prank(nameOwner);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopLite);

        // PopLite should always have zero price
        uint256 quotedPrice = popRules.priceWithCheck(nameLabel, nameOwner).price;
        assertEq(quotedPrice, 0);

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, nameOwner, "lite"));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel, owner: nameOwner, secret: secret, reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);

        vm.prank(nameOwner);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 requiredPrice = popRules.priceWithCheck(nameLabel, nameOwner).price;
        assertEq(requiredPrice, 0);

        vm.prank(nameOwner);
        dotnsRegistrarController.register{value: 0}(registration);

        (bool isReserved, address reservationOwner,) = popRules.isBaseNameReserved("lights");
        assertTrue(isReserved);
        assertEq(reservationOwner, nameOwner);
    }

    function test_registerreserved_registers_and_writes_to_existing_store() public {
        string memory nameLabel = "hello";
        address nameOwner = ed;

        vm.prank(nameOwner);
        IStore ownerStoreInterface = storeFactory.deploy();

        Store ownerStore = Store(address(ownerStoreInterface));

        vm.prank(nameOwner);
        ownerStore.authorizeDotnsController(address(dotnsRegistrarController));

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, nameOwner, "reserved"));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel, owner: nameOwner, secret: secret, reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);

        vm.prank(nameOwner);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        bytes32 labelHash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelHash);

        vm.expectEmit(true, true, true, true);
        emit IDotnsRegistrarController.NameRegistered(
            nameLabel, labelHash, nameOwner, 0, address(ownerStore)
        );

        vm.prank(nameOwner);
        dotnsRegistrarController.registerReserved(registration);

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(labelHash)), nameOwner);
        assertEq(dotnsRegistry.owner(node), nameOwner);
        assertEq(dotnsReverseResolver.nameOf(nameOwner), string.concat(nameLabel, ".dot"));

        bytes32 storeKey = keccak256(abi.encodePacked(DOTNS_REGISTERED_PREFIX, labelHash));
        assertEq(ownerStore.getValueFor(nameOwner, storeKey), string.concat(nameLabel, ".dot"));
    }
}
