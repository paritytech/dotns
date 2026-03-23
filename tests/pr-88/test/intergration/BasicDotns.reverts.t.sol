// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../base/BaseDotns.t.sol";
import {IPopRules} from "../../contracts/pop/IPopRules.sol";
import {IDotnsRegistry} from "../../contracts/registry/IDotnsRegistry.sol";
import {IDotnsContentResolver} from "../../contracts/resolvers/IDotnsContentResolver.sol";
import {IDotnsRegistrarController} from "../../contracts/registrars/IDotnsRegistrarController.sol";

contract BasicDotnsIntegrationReverts is BaseDotns {
    string internal constant NAME_POPFULL = "waytall1";
    string internal constant NAME_POPLITE = "way2tall01";
    string internal constant NAME_NOSTATUS = "kitesurfing01";

    bytes internal constant CID_A =
        hex"e30101701220aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    function test_revert_poplite_cannot_register_nostatus_name() public {
        string memory nameLabel = NAME_NOSTATUS;
        address registrant = ed;

        vm.startPrank(registrant);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopLite);

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, registrant, block.timestamp));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel, owner: registrant, secret: secret, reserved: false
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPopRules.PopError.selector, "Personhood Lite cannot register base names"
            )
        );
        dotnsRegistrarController.register(registration);
        vm.stopPrank();
    }

    function test_revert_poplite_cannot_register_popfull_required() public {
        string memory nameLabel = NAME_POPFULL;
        address registrant = ed;

        vm.startPrank(registrant);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopLite);

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, registrant, block.timestamp));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel, owner: registrant, secret: secret, reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPopRules.PopError.selector, "Requires Full Personhood verification"
            )
        );
        dotnsRegistrarController.register(registration);
        vm.stopPrank();
    }

    function test_revert_non_owner_cannot_create_subdomain_under_someone_elses_name() public {
        address parentOwner = ed;
        address attacker = tiago;

        vm.prank(parentOwner);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);
        _commitAndRegister(NAME_POPFULL, parentOwner, true);

        bytes32 parentNode = _namehash(dotNode, keccak256(bytes(NAME_POPFULL)));

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "blog", parentLabel: NAME_POPFULL, owner: attacker
        });

        vm.startPrank(attacker);
        vm.expectRevert(IDotnsRegistry.NotAuthorised.selector);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);
        vm.stopPrank();
    }

    function test_revert_cannot_create_same_subdomain_twice() public {
        address parentOwner = ed;

        vm.prank(parentOwner);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);
        _commitAndRegister(NAME_POPFULL, parentOwner, true);
        bytes32 parentNode = _namehash(dotNode, keccak256(bytes(NAME_POPFULL)));

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "blog", parentLabel: NAME_POPFULL, owner: parentOwner
        });

        vm.startPrank(parentOwner);
        bytes32 subnode = dotnsRegistry.setSubnodeOwner(subnodeRecord);

        vm.expectRevert(abi.encodeWithSelector(IDotnsRegistry.NodeAlreadyExists.selector, subnode));
        dotnsRegistry.setSubnodeOwner(subnodeRecord);
        vm.stopPrank();
    }

    function test_revert_unapproved_cannot_set_contenthash() public {
        address parentOwner = ed;
        address attacker = tiago;

        vm.prank(parentOwner);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);
        _commitAndRegister(NAME_POPFULL, parentOwner, true);

        bytes32 node = _namehash(dotNode, keccak256(bytes(NAME_POPFULL)));

        vm.startPrank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsContentResolver.NotAuthorised.selector, node, attacker)
        );
        dotnsContentResolver.setContenthash(node, CID_A);
        vm.stopPrank();
    }
}
