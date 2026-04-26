// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsRegistry} from "../../../contracts/registry/IDotnsRegistry.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {Store} from "../../../contracts/store/Store.sol";

contract DotnsRegistryTests is BaseDotns {
    function test_root_record_is_initialized_and_owned_by_owner() public view {
        bytes32 rootNode = bytes32(0);

        assertEq(dotnsRegistry.owner(rootNode), owner);
        assertTrue(dotnsRegistry.recordExists(rootNode));
        assertEq(dotnsRegistry.resolver(rootNode), address(0));
    }

    function test_owner_updates_protocol_registry_emits_event_and_persists() public {
        IDotnsProtocolRegistry newRegistry = IDotnsProtocolRegistry(makeAddr("newRegistry"));

        vm.expectEmit(true, false, false, false, address(dotnsRegistry));
        emit IDotnsRegistry.ProtocolRegistryUpdated(newRegistry);

        vm.prank(owner);
        dotnsRegistry.updateProtocolRegistry(newRegistry);

        assertEq(address(dotnsRegistry.protocolRegistry()), address(newRegistry));
    }

    function test_registrar_controller_sets_owner_emits_event_and_sets_resolver() public {
        bytes32 node = keccak256("node_b");
        address resolverAddress = address(dotnsReverseResolver);

        vm.startPrank(address(dotnsRegistrarController));
        dotnsRegistrar.register(uint256(node), ed, "node_b_label");

        vm.expectEmit(true, false, false, true, address(dotnsRegistry));
        emit IDotnsRegistry.NodeTransferred(node, ed);

        dotnsRegistry.setOwner(node, ed, resolverAddress);
        vm.stopPrank();

        assertEq(dotnsRegistry.owner(node), ed);
        assertTrue(dotnsRegistry.recordExists(node));
        assertEq(dotnsRegistry.resolver(node), resolverAddress);
    }

    function test_node_owner_creates_subnode_emits_event_and_returns_expected_subnode() public {
        string memory parentLabel = "parentnode01";
        bytes32 parentNode = _register(parentLabel, owner, IPopRules.PopStatus.NoStatus);

        string memory subLabel = "alice";
        bytes32 subLabelHash = keccak256(bytes(subLabel));
        bytes32 expectedSubnode = _namehash(parentNode, subLabelHash);

        _ensureStoreFor(ed);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: subLabel, parentLabel: parentLabel, owner: ed
        });

        vm.expectEmit(true, true, false, true, address(dotnsRegistry));
        emit IDotnsRegistry.NewOwner(parentNode, subLabelHash, ed);

        vm.startPrank(owner);
        bytes32 returnedSubnode = dotnsRegistry.setSubnodeOwner(subnodeRecord);
        vm.stopPrank();

        assertEq(returnedSubnode, expectedSubnode);
        assertEq(dotnsRegistry.owner(returnedSubnode), ed);
        assertTrue(dotnsRegistry.recordExists(returnedSubnode));
        assertEq(dotnsRegistry.resolver(returnedSubnode), address(dotnsReverseResolver));
    }

    function test_node_owner_sets_resolver_emits_event_and_persists() public {
        string memory parentLabel = "parentnode03";
        bytes32 parentNode = _register(parentLabel, owner, IPopRules.PopStatus.NoStatus);

        string memory subLabel = "carol";
        bytes32 subLabelHash = keccak256(bytes(subLabel));
        bytes32 node = _namehash(parentNode, subLabelHash);
        address newResolver = makeAddr("resolver");

        _ensureStoreFor(ed);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: subLabel, parentLabel: parentLabel, owner: ed
        });

        vm.startPrank(owner);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);
        vm.stopPrank();

        vm.expectEmit(true, false, false, true, address(dotnsRegistry));
        emit IDotnsRegistry.NewResolver(node, newResolver);

        vm.startPrank(ed);
        dotnsRegistry.setResolver(node, newResolver);
        vm.stopPrank();

        assertEq(dotnsRegistry.resolver(node), newResolver);
    }

    function test_node_owner_can_clear_resolver_to_zero() public {
        string memory parentLabel = "parentnode04";
        bytes32 parentNode = _register(parentLabel, owner, IPopRules.PopStatus.NoStatus);

        string memory subLabel = "dave";
        bytes32 subLabelHash = keccak256(bytes(subLabel));
        bytes32 node = _namehash(parentNode, subLabelHash);
        address newResolver = makeAddr("resolver");

        _ensureStoreFor(ed);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: subLabel, parentLabel: parentLabel, owner: ed
        });

        vm.startPrank(owner);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);
        vm.stopPrank();

        vm.startPrank(ed);
        dotnsRegistry.setResolver(node, newResolver);
        assertEq(dotnsRegistry.resolver(node), newResolver);

        dotnsRegistry.setResolver(node, address(0));
        vm.stopPrank();

        assertEq(dotnsRegistry.resolver(node), address(0));
    }

    function test_node_owner_creates_nested_subnode_with_canonical_parent_path() public {
        string memory parentLabel = "parentnode06";
        bytes32 parentNode = _register(parentLabel, owner, IPopRules.PopStatus.NoStatus);

        IDotnsRegistry.SubnodeRecord memory childRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "child", parentLabel: parentLabel, owner: ed
        });

        vm.prank(owner);
        bytes32 childNode = dotnsRegistry.setSubnodeOwner(childRecord);

        string memory nestedParentLabel = string.concat("child.", parentLabel);
        IDotnsRegistry.SubnodeRecord memory leafRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: childNode, subLabel: "leaf", parentLabel: nestedParentLabel, owner: tiago
        });

        vm.prank(ed);
        bytes32 leafNode = dotnsRegistry.setSubnodeOwner(leafRecord);

        assertEq(dotnsRegistry.owner(leafNode), tiago);
        assertTrue(dotnsRegistry.recordExists(leafNode));
        assertEq(dotnsRegistry.resolver(leafNode), address(dotnsReverseResolver));

        Store tiagoStore = Store(address(storeFactory.getDeployedStore(tiago)));
        assertEq(tiagoStore.getValueFor(tiago, _storeKey(leafNode)), "leaf.child.parentnode06.dot");
    }

    function test_subnode_owner_creates_nested_subnode_under_owned_parent() public {
        string memory parentLabel = "parentnode05";
        bytes32 parentNode = _register(parentLabel, ed, IPopRules.PopStatus.NoStatus);

        string memory childLabel = "child";
        bytes32 childLabelHash = keccak256(bytes(childLabel));
        bytes32 expectedChildNode = _namehash(parentNode, childLabelHash);

        _ensureStoreFor(tiago);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: childLabel, parentLabel: parentLabel, owner: tiago
        });

        vm.startPrank(ed);
        bytes32 returnedChildNode = dotnsRegistry.setSubnodeOwner(subnodeRecord);
        vm.stopPrank();

        assertEq(returnedChildNode, expectedChildNode);
        assertEq(dotnsRegistry.owner(expectedChildNode), tiago);
        assertTrue(dotnsRegistry.recordExists(expectedChildNode));
        assertEq(dotnsRegistry.resolver(expectedChildNode), address(dotnsReverseResolver));
    }

    function test_revert_subnode_owner_with_parent_label_mismatch() public {
        string memory parentLabel = "actualparent01";
        bytes32 parentNode = _register(parentLabel, ed, IPopRules.PopStatus.PopFull);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "docs", parentLabel: "parity", owner: leonardo
        });

        vm.prank(ed);
        vm.expectRevert(IDotnsRegistry.ParentLabelMismatch.selector);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);
    }

    function test_revert_subnode_owner_with_dotted_sublabel() public {
        string memory parentLabel = "parentnode07";
        bytes32 parentNode = _register(parentLabel, owner, IPopRules.PopStatus.NoStatus);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "docs.api", parentLabel: parentLabel, owner: ed
        });

        vm.prank(owner);
        vm.expectRevert(IDotnsRegistry.InvalidLabel.selector);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);
    }

    function test_revert_subnode_owner_with_empty_sublabel() public {
        string memory parentLabel = "parentnode08";
        bytes32 parentNode = _register(parentLabel, owner, IPopRules.PopStatus.NoStatus);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "", parentLabel: parentLabel, owner: ed
        });

        vm.prank(owner);
        vm.expectRevert(IDotnsRegistry.InvalidLabel.selector);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);
    }

    function test_revert_subnode_owner_with_uppercase_sublabel() public {
        string memory parentLabel = "parentnode09";
        bytes32 parentNode = _register(parentLabel, owner, IPopRules.PopStatus.NoStatus);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "Docs", parentLabel: parentLabel, owner: ed
        });

        vm.prank(owner);
        vm.expectRevert(IDotnsRegistry.InvalidLabel.selector);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);
    }

    function test_revert_subnode_owner_with_uppercase_parent_label() public {
        string memory parentLabel = "parentnode10";
        bytes32 parentNode = _register(parentLabel, owner, IPopRules.PopStatus.NoStatus);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "docs", parentLabel: "Parentnode10", owner: ed
        });

        vm.prank(owner);
        vm.expectRevert(IDotnsRegistry.ParentLabelMismatch.selector);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);
    }

    function test_parent_reassigns_existing_subnode_owner() public {
        string memory parentLabel = "parentnode11";
        bytes32 parentNode = _register(parentLabel, ed, IPopRules.PopStatus.NoStatus);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "blog", parentLabel: parentLabel, owner: leonardo
        });

        vm.prank(ed);
        bytes32 subnode = dotnsRegistry.setSubnodeOwner(subnodeRecord);
        assertEq(dotnsRegistry.owner(subnode), leonardo);

        // Parent reassigns to tiago
        subnodeRecord.owner = tiago;
        vm.prank(ed);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);

        assertEq(dotnsRegistry.owner(subnode), tiago);
    }

    function test_parent_reassigns_subnode_to_self_then_sets_resolver() public {
        string memory parentLabel = "parentnode12";
        bytes32 parentNode = _register(parentLabel, ed, IPopRules.PopStatus.NoStatus);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "app", parentLabel: parentLabel, owner: leonardo
        });

        vm.prank(ed);
        bytes32 subnode = dotnsRegistry.setSubnodeOwner(subnodeRecord);

        // Parent reassigns to self
        subnodeRecord.owner = ed;
        vm.prank(ed);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);
        assertEq(dotnsRegistry.owner(subnode), ed);

        // Now parent can setResolver
        address newResolver = makeAddr("newResolver");
        vm.prank(ed);
        dotnsRegistry.setResolver(subnode, newResolver);
        assertEq(dotnsRegistry.resolver(subnode), newResolver);
    }

    function test_reassignment_preserves_resolver() public {
        string memory parentLabel = "parentnode13";
        bytes32 parentNode = _register(parentLabel, ed, IPopRules.PopStatus.NoStatus);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "docs", parentLabel: parentLabel, owner: leonardo
        });

        vm.prank(ed);
        bytes32 subnode = dotnsRegistry.setSubnodeOwner(subnodeRecord);

        // Subnode owner sets a custom resolver
        address customResolver = makeAddr("customResolver");
        vm.prank(leonardo);
        dotnsRegistry.setResolver(subnode, customResolver);
        assertEq(dotnsRegistry.resolver(subnode), customResolver);

        // Parent reassigns owner -- resolver should be preserved
        subnodeRecord.owner = tiago;
        vm.prank(ed);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);

        assertEq(dotnsRegistry.owner(subnode), tiago);
        assertEq(dotnsRegistry.resolver(subnode), customResolver);
    }

    function test_revert_non_parent_cannot_reassign_subnode() public {
        string memory parentLabel = "parentnode14";
        bytes32 parentNode = _register(parentLabel, ed, IPopRules.PopStatus.NoStatus);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "api", parentLabel: parentLabel, owner: leonardo
        });

        vm.prank(ed);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);

        // Tiago (not the parent owner) tries to reassign
        subnodeRecord.owner = tiago;
        vm.prank(tiago);
        vm.expectRevert(IDotnsRegistry.NotAuthorised.selector);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);
    }

    function test_reassignment_emits_new_owner_event() public {
        string memory parentLabel = "parentnode15";
        bytes32 parentNode = _register(parentLabel, ed, IPopRules.PopStatus.NoStatus);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "mail", parentLabel: parentLabel, owner: leonardo
        });

        vm.prank(ed);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);

        // Reassign and check event
        bytes32 subLabelHash = keccak256(bytes("mail"));
        subnodeRecord.owner = tiago;

        vm.expectEmit(true, true, false, true, address(dotnsRegistry));
        emit IDotnsRegistry.NewOwner(parentNode, subLabelHash, tiago);

        vm.prank(ed);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);
    }

    function test_new_parent_can_reassign_after_erc721_transfer() public {
        string memory parentLabel = "parentnode16";
        bytes32 parentNode = _register(parentLabel, ed, IPopRules.PopStatus.NoStatus);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "web", parentLabel: parentLabel, owner: leonardo
        });

        vm.prank(ed);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);

        // Transfer base domain from ed to tiago
        uint256 tokenId = _tokenIdForLabel(parentLabel);
        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, tiago, tokenId);

        // New parent (tiago) can reassign the subnode
        subnodeRecord.owner = tiago;
        vm.prank(tiago);
        bytes32 subnode = dotnsRegistry.setSubnodeOwner(subnodeRecord);

        assertEq(dotnsRegistry.owner(subnode), tiago);
    }

    function test_same_sublabel_under_different_parents_owned_by_same_address() public {
        string memory parentLabelA = "alphaomega";
        string memory parentLabelB = "bravobro";
        bytes32 parentNodeA = _register(parentLabelA, owner, IPopRules.PopStatus.PopFull);
        bytes32 parentNodeB = _register(parentLabelB, owner, IPopRules.PopStatus.PopFull);

        _ensureStoreFor(ed);

        string memory subLabel = "app";

        IDotnsRegistry.SubnodeRecord memory recordA = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNodeA, subLabel: subLabel, parentLabel: parentLabelA, owner: ed
        });

        IDotnsRegistry.SubnodeRecord memory recordB = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNodeB, subLabel: subLabel, parentLabel: parentLabelB, owner: ed
        });

        vm.startPrank(owner);
        bytes32 subnodeA = dotnsRegistry.setSubnodeOwner(recordA);
        bytes32 subnodeB = dotnsRegistry.setSubnodeOwner(recordB);
        assertTrue(subnodeA != subnodeB);
        assertTrue(dotnsRegistry.recordExists(subnodeA));
        assertTrue(dotnsRegistry.recordExists(subnodeB));
        vm.stopPrank();
    }

    function test_parent_can_set_resolver_on_subnode_via_setSubnodeResolver() public {
        string memory parentLabel = "parentnode17";
        bytes32 parentNode = _register(parentLabel, ed, IPopRules.PopStatus.NoStatus);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "api", parentLabel: parentLabel, owner: leonardo
        });

        vm.prank(ed);
        bytes32 subnode = dotnsRegistry.setSubnodeOwner(subnodeRecord);

        // Parent sets resolver on subnode they don't directly own
        address newResolver = makeAddr("parentChosenResolver");
        IDotnsRegistry.SubnodeResolverRecord memory resolverRecord =
            IDotnsRegistry.SubnodeResolverRecord({
                parentNode: parentNode,
                subLabel: "api",
                parentLabel: parentLabel,
                resolver: newResolver
            });

        vm.prank(ed);
        dotnsRegistry.setSubnodeResolver(resolverRecord);
        assertEq(dotnsRegistry.resolver(subnode), newResolver);
    }

    function test_non_parent_cannot_call_setSubnodeResolver() public {
        string memory parentLabel = "parentnode18";
        bytes32 parentNode = _register(parentLabel, ed, IPopRules.PopStatus.NoStatus);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "web", parentLabel: parentLabel, owner: leonardo
        });

        vm.prank(ed);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);

        IDotnsRegistry.SubnodeResolverRecord memory resolverRecord =
            IDotnsRegistry.SubnodeResolverRecord({
                parentNode: parentNode,
                subLabel: "web",
                parentLabel: parentLabel,
                resolver: makeAddr("malicious")
            });

        // Non-parent (tiago) cannot set resolver
        vm.prank(tiago);
        vm.expectRevert(IDotnsRegistry.NotAuthorised.selector);
        dotnsRegistry.setSubnodeResolver(resolverRecord);
    }

    function test_subnode_owner_can_still_set_resolver_directly() public {
        string memory parentLabel = "parentnode19";
        bytes32 parentNode = _register(parentLabel, ed, IPopRules.PopStatus.NoStatus);

        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "mail", parentLabel: parentLabel, owner: leonardo
        });

        vm.prank(ed);
        bytes32 subnode = dotnsRegistry.setSubnodeOwner(subnodeRecord);

        // Subnode owner uses existing setResolver directly
        address newResolver = makeAddr("subnodeOwnerResolver");
        vm.prank(leonardo);
        dotnsRegistry.setResolver(subnode, newResolver);
        assertEq(dotnsRegistry.resolver(subnode), newResolver);
    }

    function test_setSubnodeResolver_reverts_on_nonexistent_subnode() public {
        string memory parentLabel = "parentnode20";
        bytes32 parentNode = _register(parentLabel, ed, IPopRules.PopStatus.NoStatus);

        // Subnode "ghost" was never created
        IDotnsRegistry.SubnodeResolverRecord memory resolverRecord =
            IDotnsRegistry.SubnodeResolverRecord({
                parentNode: parentNode,
                subLabel: "ghost",
                parentLabel: parentLabel,
                resolver: makeAddr("someResolver")
            });

        vm.prank(ed);
        vm.expectRevert(IDotnsRegistry.NotAuthorised.selector);
        dotnsRegistry.setSubnodeResolver(resolverRecord);
    }
}
