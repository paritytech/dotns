// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IDotnsRegistrar} from "../../../contracts/registrars/IDotnsRegistrar.sol";
import {BaseDotns, IDotnsRegistrarController} from "../../base/BaseDotns.t.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract DotnsRegistrarTests is BaseDotns {
    function test_add_controller() public {
        address additionalController = makeAddr("additionalController");

        vm.startPrank(owner);

        vm.expectEmit(true, false, false, false, address(dotnsRegistrar));
        emit IDotnsRegistrar.ControllerAdded(IDotnsRegistrarController(additionalController));
        dotnsRegistrar.addController(IDotnsRegistrarController(additionalController));

        vm.stopPrank();

        assertTrue(dotnsRegistrar.controllers(IDotnsRegistrarController(additionalController)));
    }

    function test_remove_controller() public {
        address temporaryController = makeAddr("temporaryController");

        vm.startPrank(owner);
        dotnsRegistrar.addController(IDotnsRegistrarController(temporaryController));

        vm.expectEmit(true, false, false, false, address(dotnsRegistrar));
        emit IDotnsRegistrar.ControllerRemoved(IDotnsRegistrarController(temporaryController));
        dotnsRegistrar.removeController(IDotnsRegistrarController(temporaryController));
        vm.stopPrank();

        assertFalse(dotnsRegistrar.controllers(IDotnsRegistrarController(temporaryController)));
    }

    function test_register_mints_to_owner() public {
        address nameOwner = ed;
        uint256 tokenId = uint256(keccak256(bytes("alice")));

        vm.expectEmit(true, true, true, true, address(dotnsRegistrar));
        emit IERC721.Transfer(address(0), nameOwner, tokenId);

        vm.expectEmit(true, true, false, true, address(dotnsRegistrar));
        emit IDotnsRegistrar.NameRegistered(tokenId, nameOwner);

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, nameOwner);

        assertEq(dotnsRegistrar.ownerOf(tokenId), nameOwner);
        assertEq(dotnsRegistrar.balanceOf(nameOwner), 1);
    }

    function test_register_multiple_same_owner() public {
        address nameOwner = ed;

        uint256 firstTokenId = uint256(keccak256(bytes("nameOne")));
        uint256 secondTokenId = uint256(keccak256(bytes("nameTwo")));

        vm.startPrank(address(dotnsRegistrarController));
        dotnsRegistrar.register(firstTokenId, nameOwner);
        dotnsRegistrar.register(secondTokenId, nameOwner);
        vm.stopPrank();

        assertEq(dotnsRegistrar.balanceOf(nameOwner), 2);
        assertEq(dotnsRegistrar.ownerOf(firstTokenId), nameOwner);
        assertEq(dotnsRegistrar.ownerOf(secondTokenId), nameOwner);
    }

    function test_register_multiple_owners() public {
        address firstOwner = ed;
        address secondOwner = tiago;

        uint256 firstTokenId = uint256(keccak256(bytes("edName")));
        uint256 secondTokenId = uint256(keccak256(bytes("tiagoName")));

        vm.startPrank(address(dotnsRegistrarController));
        dotnsRegistrar.register(firstTokenId, firstOwner);
        dotnsRegistrar.register(secondTokenId, secondOwner);
        vm.stopPrank();

        assertEq(dotnsRegistrar.balanceOf(firstOwner), 1);
        assertEq(dotnsRegistrar.balanceOf(secondOwner), 1);
        assertEq(dotnsRegistrar.ownerOf(firstTokenId), firstOwner);
        assertEq(dotnsRegistrar.ownerOf(secondTokenId), secondOwner);
    }

    function test_available_before_after_register() public {
        address nameOwner = ed;
        uint256 tokenId = uint256(keccak256(bytes("availabilityCheck")));

        assertTrue(dotnsRegistrar.available(tokenId));

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, nameOwner);

        assertFalse(dotnsRegistrar.available(tokenId));
    }

    function test_register_to_contract_owner() public {
        address nameOwner = address(popRules);
        uint256 tokenId = uint256(keccak256(bytes("contractOwnedName")));

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, nameOwner);

        assertEq(dotnsRegistrar.ownerOf(tokenId), nameOwner);
        assertEq(dotnsRegistrar.balanceOf(nameOwner), 1);
    }

    function test_approvals_work() public {
        address nameOwner = ed;
        address tokenApproval = tiago;
        address operator = leonardo;

        uint256 tokenId = uint256(keccak256(bytes("approvalName")));

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistrar.register(tokenId, nameOwner);

        vm.prank(nameOwner);
        dotnsRegistrar.approve(tokenApproval, tokenId);
        assertEq(dotnsRegistrar.getApproved(tokenId), tokenApproval);

        vm.prank(nameOwner);
        dotnsRegistrar.setApprovalForAll(operator, true);
        assertTrue(dotnsRegistrar.isApprovedForAll(nameOwner, operator));

        assertTrue(dotnsRegistrar.supportsInterface(type(IERC721).interfaceId));
    }
}
