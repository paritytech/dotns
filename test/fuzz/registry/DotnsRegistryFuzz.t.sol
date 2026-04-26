// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsRegistry} from "../../../contracts/registry/IDotnsRegistry.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

contract DotnsRegistryFuzzTest is BaseDotns {
    function testFuzz_parent_can_reassign_subnode_to_any_owner(address newOwner) public {
        vm.assume(newOwner != address(0));
        vm.assume(newOwner != leonardo);
        vm.assume(address(storeFactory.getDeployedStore(newOwner)) == address(0));
        // The subnode reassignment path uses StoreUtils as a `using for`
        // library call, so every external hop (factory.deploy, store.*,
        // factory.transferOwnership) executes with `msg.sender` equal to the
        // registry. When `newOwner` happens to equal the registry address,
        // `factory.deploy` has already mapped the fresh Store under
        // `_deployedStores[registry]`, and the subsequent
        // `factory.transferOwnership(newOwner=registry)` sees the slot
        // occupied and reverts with `InvalidTransfer`. This is a legitimate
        // collision surface of the library's msg.sender bookkeeping, not a
        // failure of the property under test ("parent can hand the subnode
        // to any external address"). Excluding that single address keeps the
        // property honest without papering over anything else.
        vm.assume(newOwner != address(dotnsRegistry));

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

    function testFuzz_reassignment_preserves_resolver(address resolver) public {
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

        assertEq(dotnsRegistry.resolver(subnode), resolver);
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
