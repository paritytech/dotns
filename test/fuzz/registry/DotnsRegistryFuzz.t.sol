// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsRegistry} from "../../../contracts/registry/IDotnsRegistry.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

/// @title DotnsRegistryFuzzTest
/// @notice Property-based tests for @custom:contract DotnsRegistry subnode ownership and
/// authorisation.
contract DotnsRegistryFuzzTest is BaseDotns {
    function testFuzz_parent_can_reassign_subnode_to_any_owner(address newOwner) public {
        vm.assume(newOwner != address(0));
        vm.assume(newOwner != leonardo);
        vm.assume(storeFactory.getLabelStore(newOwner) == address(0));

        string memory parentLabel = "fuzzparent01";
        bytes32 parentNode = _register(parentLabel, ed, IPopRules.PopStatus.NoStatus);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "sub", parentLabel: parentLabel, owner: leonardo
        });

        vm.prank(ed);
        bytes32 subnode = dotnsRegistry.setSubnodeOwner(subnodeRecord);

        subnodeRecord.owner = newOwner;
        vm.prank(ed);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);

        assertEq(dotnsRegistry.owner(subnode), newOwner);
    }

    function testFuzz_reassignment_resets_resolver_to_default(address resolver) public {
        string memory parentLabel = "fuzzparent02";
        bytes32 parentNode = _register(parentLabel, ed, IPopRules.PopStatus.NoStatus);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "app", parentLabel: parentLabel, owner: leonardo
        });

        vm.prank(ed);
        bytes32 subnode = dotnsRegistry.setSubnodeOwner(subnodeRecord);

        vm.prank(leonardo);
        dotnsRegistry.setResolver(subnode, resolver);

        subnodeRecord.owner = tiago;
        vm.prank(ed);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);

        assertEq(dotnsRegistry.resolver(subnode), address(dotnsReverseResolver));
    }

    function testFuzz_non_parent_non_owner_cannot_reassign(address caller) public {
        vm.assume(caller != ed && caller != address(0));

        string memory parentLabel = "fuzzparent03";
        bytes32 parentNode = _register(parentLabel, ed, IPopRules.PopStatus.NoStatus);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "api", parentLabel: parentLabel, owner: leonardo
        });

        vm.prank(ed);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);

        subnodeRecord.owner = caller;
        vm.prank(caller);
        vm.expectRevert(IDotnsRegistry.NotAuthorised.selector);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);
    }
}
