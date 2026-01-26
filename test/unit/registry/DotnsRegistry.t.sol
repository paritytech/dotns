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

        vm.expectEmit(true, true, false, false, address(dotnsRegistry));
        emit IDotnsRegistry.RegistrarControllerUpdated(
            oldRegistrarController, newRegistrarController
        );

        vm.prank(owner);
        dotnsRegistry.updateRegistrarController(newRegistrarController);

        assertEq(address(dotnsRegistry.registrarController()), address(newRegistrarController));
    }

    function test_owner_can_rotate_registrar_controller_multiple_times() public {
        address firstRegistrarController = makeAddr("first_registrar_controller");
        address secondRegistrarController = makeAddr("second_registrar_controller");

        if (firstRegistrarController == secondRegistrarController) {
            secondRegistrarController = makeAddr("second_registrar_controller_alt");
        }

        vm.prank(owner);
        dotnsRegistry.updateRegistrarController(IDotnsRegistrarController(firstRegistrarController));
        assertEq(address(dotnsRegistry.registrarController()), firstRegistrarController);

        vm.prank(owner);
        dotnsRegistry.updateRegistrarController(
            IDotnsRegistrarController(secondRegistrarController)
        );
        assertEq(address(dotnsRegistry.registrarController()), secondRegistrarController);
    }

    function test_registrar_controller_sets_owner_emits_event_and_sets_resolver() public {
        bytes32 node = keccak256("node_b");
        address resolverAddress = address(dotnsReverseResolver);

        vm.prank(owner);
        dotnsRegistry.updateRegistrarController(dotnsRegistrarController);

        vm.expectEmit(true, false, false, true, address(dotnsRegistry));
        emit IDotnsRegistry.NodeTransferred(node, ed);

        vm.prank(address(dotnsRegistrarController));
        dotnsRegistry.setOwner(node, ed, resolverAddress);

        assertEq(dotnsRegistry.owner(node), ed);
        assertTrue(dotnsRegistry.recordExists(node));
        assertEq(dotnsRegistry.resolver(node), resolverAddress);
    }

    function test_registrar_controller_sets_owner_for_multiple_nodes() public {
        bytes32 firstNode = keccak256("first_node");
        bytes32 secondNode = keccak256("second_node");
        address resolverAddress = address(dotnsReverseResolver);

        vm.prank(owner);
        dotnsRegistry.updateRegistrarController(dotnsRegistrarController);

        vm.startPrank(address(dotnsRegistrarController));
        dotnsRegistry.setOwner(firstNode, ed, resolverAddress);
        dotnsRegistry.setOwner(secondNode, tiago, resolverAddress);
        vm.stopPrank();

        assertEq(dotnsRegistry.owner(firstNode), ed);
        assertEq(dotnsRegistry.owner(secondNode), tiago);

        assertTrue(dotnsRegistry.recordExists(firstNode));
        assertTrue(dotnsRegistry.recordExists(secondNode));

        assertEq(dotnsRegistry.resolver(firstNode), resolverAddress);
        assertEq(dotnsRegistry.resolver(secondNode), resolverAddress);
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

        vm.prank(owner);
        bytes32 returnedSubnode = dotnsRegistry.setSubnodeOwner(subnodeRecord);

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

        vm.prank(owner);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);

        vm.expectEmit(true, false, false, true, address(dotnsRegistry));
        emit IDotnsRegistry.NewResolver(node, newResolver);

        vm.prank(ed);
        dotnsRegistry.setResolver(node, newResolver);

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

        vm.prank(owner);
        dotnsRegistry.setSubnodeOwner(subnodeRecord);

        vm.prank(ed);
        dotnsRegistry.setResolver(node, newResolver);
        assertEq(dotnsRegistry.resolver(node), newResolver);

        vm.prank(ed);
        dotnsRegistry.setResolver(node, address(0));
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

        vm.prank(ed);
        bytes32 returnedChildNode = dotnsRegistry.setSubnodeOwner(subnodeRecord);

        assertEq(returnedChildNode, expectedChildNode);
        assertEq(dotnsRegistry.owner(expectedChildNode), tiago);
        assertTrue(dotnsRegistry.recordExists(expectedChildNode));
        assertEq(dotnsRegistry.resolver(expectedChildNode), address(dotnsReverseResolver));
    }
}
