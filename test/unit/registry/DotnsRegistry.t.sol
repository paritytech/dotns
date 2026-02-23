// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns, IDotnsRegistrarController} from "../../base/BaseDotns.t.sol";
import {IDotnsRegistry} from "../../../contracts/registry/IDotnsRegistry.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

contract DotnsRegistryTests is BaseDotns {
    function test_root_record_is_initialized_and_owned_by_owner() public view {
        bytes32 rootNode = bytes32(0);

        assertEq(dotnsRegistry.owner(rootNode), owner);
        assertTrue(dotnsRegistry.recordExists(rootNode));
        assertEq(dotnsRegistry.resolver(rootNode), address(0));
    }

    function test_owner_updates_registrar_controller_emits_event_and_persists() public {
        IDotnsRegistrarController oldRegistrarController = dotnsRegistry.registrarController();

        IDotnsRegistrarController newRegistrarController =
            IDotnsRegistrarController(makeAddr("new_registrar_controller"));
        if (address(newRegistrarController) == address(oldRegistrarController)) {
            newRegistrarController =
                IDotnsRegistrarController(makeAddr("new_registrar_controller_alt"));
        }

        vm.startPrank(owner);

        vm.expectEmit(true, true, false, false, address(dotnsRegistry));
        emit IDotnsRegistry.RegistrarControllerUpdated(
            oldRegistrarController, newRegistrarController
        );

        dotnsRegistry.updateRegistrarController(newRegistrarController);

        vm.stopPrank();

        assertEq(address(dotnsRegistry.registrarController()), address(newRegistrarController));
    }

    function test_registrar_controller_sets_owner_emits_event_and_sets_resolver() public {
        bytes32 node = keccak256("node_b");
        address resolverAddress = address(dotnsReverseResolver);

        vm.startPrank(owner);
        dotnsRegistry.updateRegistrarController(dotnsRegistrarController);
        vm.stopPrank();

        vm.startPrank(address(dotnsRegistrarController));
        dotnsRegistrar.register(uint256(node), ed);

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
        bytes32 expectedSubnode = keccak256(abi.encodePacked(parentNode, subLabelHash));

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
        bytes32 node = keccak256(abi.encodePacked(parentNode, subLabelHash));
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
        bytes32 node = keccak256(abi.encodePacked(parentNode, subLabelHash));
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

    function test_subnode_owner_creates_nested_subnode_under_owned_parent() public {
        string memory parentLabel = "parentnode05";
        bytes32 parentNode = _register(parentLabel, ed, IPopRules.PopStatus.NoStatus);

        string memory childLabel = "child";
        bytes32 childLabelHash = keccak256(bytes(childLabel));
        bytes32 expectedChildNode = keccak256(abi.encodePacked(parentNode, childLabelHash));

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
        dotnsRegistry.setSubnodeOwner(recordA);
        dotnsRegistry.setSubnodeOwner(recordB);
        vm.stopPrank();
    }
}
