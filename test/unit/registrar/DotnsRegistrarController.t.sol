// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns, IDotnsRegistrarController} from "../../base/BaseDotns.t.sol";

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
}
