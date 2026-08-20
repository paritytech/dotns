// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../base/BaseDotns.t.sol";
import {IPopRules} from "../../contracts/pop/IPopRules.sol";
import {IDotnsRegistry} from "../../contracts/registry/IDotnsRegistry.sol";
import {IDotnsContentResolver} from "../../contracts/resolvers/IDotnsContentResolver.sol";
import {IDotnsRegistrarController} from "../../contracts/registrars/IDotnsRegistrarController.sol";

/// @title BasicDotnsIntegrationReverts
/// @notice Integration coverage for revert paths protecting registration, subnames,
///         and resolver writes.
contract BasicDotnsIntegrationReverts is BaseDotns {
    /// @notice PopFull-classified label fixture exercised by the revert cases.
    string internal constant NAME_POPFULL = "waytalls";

    /// @notice Sample CIDv1 content hash used as a record value.
    bytes internal constant CID_A =
        hex"e30101701220aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    function test_revert_poplite_cannot_register_popfull_required() public {
        string memory nameLabel = NAME_POPFULL;
        address registrant = ed;

        _grantPopLite(registrant);
        vm.startPrank(registrant);

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

        _grantPopFull(parentOwner);
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

    function test_parent_can_reassign_existing_subdomain() public {
        address parentOwner = ed;

        _grantPopFull(parentOwner);
        _commitAndRegister(NAME_POPFULL, parentOwner, true);
        bytes32 parentNode = _namehash(dotNode, keccak256(bytes(NAME_POPFULL)));

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "blog", parentLabel: NAME_POPFULL, owner: parentOwner
        });

        vm.startPrank(parentOwner);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);

        // Parent can reassign existing subnode to a new owner
        subnodeRecord.owner = leonardo;
        dotnsRegistry.setSubnodeOwner(subnodeRecord);
        vm.stopPrank();

        bytes32 subnode = _namehash(parentNode, keccak256(bytes("blog")));
        assertEq(dotnsRegistry.owner(subnode), leonardo);
    }

    function test_revert_unapproved_cannot_set_contenthash() public {
        address parentOwner = ed;
        address attacker = tiago;

        _grantPopFull(parentOwner);
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
