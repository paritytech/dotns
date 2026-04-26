// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsRegistry} from "../../../contracts/registry/IDotnsRegistry.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {RegistryHandler} from "./RegistryHandler.t.sol";

contract DotnsRegistryInvariantTest is BaseDotns {
    RegistryHandler public handler;

    function setUp() public override {
        super.setUp();

        handler =
            new RegistryHandler(dotnsRegistrarController, dotnsRegistry, dotnsRegistrar, popRules);

        vm.deal(address(handler), 1000 ether);

        handler.addActor(ed, IPopRules.PopStatus.PopFull);
        handler.addActor(leonardo, IPopRules.PopStatus.PopLite);
        handler.addActor(tiago, IPopRules.PopStatus.NoStatus);

        address alice = _createUser("alice");
        handler.addActor(alice, IPopRules.PopStatus.PopFull);

        targetContract(address(handler));

        excludeContract(address(dotnsRegistrarController));
        excludeContract(address(dotnsRegistry));
        excludeContract(address(dotnsRegistrar));
        excludeContract(address(popRules));
        excludeContract(address(storeFactory));
    }

    /// @notice The parent domain owner must always be able to reassign subnodes.
    function invariant_parent_can_always_reassign_subnodes() public {
        bytes32[] memory subnodes = handler.getSubnodeHashes();
        bytes32[] memory parents = handler.getSubnodeParents();

        for (uint256 i; i < subnodes.length; ++i) {
            bytes32 parentNode = parents[i];

            // Get current parent owner via ERC721
            uint256 tokenId = uint256(parentNode);
            address parentOwner;
            try dotnsRegistrar.ownerOf(tokenId) returns (address o) {
                parentOwner = o;
            } catch {
                continue;
            }

            // Find the parent label
            string[] memory labels = handler.getRegisteredLabels();
            string memory parentLabel;
            for (uint256 j; j < labels.length; ++j) {
                bytes32 node = _namehash(dotNode, keccak256(bytes(labels[j])));
                if (node == parentNode) {
                    parentLabel = labels[j];
                    break;
                }
            }
            if (bytes(parentLabel).length == 0) continue;

            // Parent should be able to reassign
            IDotnsRegistry.SubnodeRecord memory record = IDotnsRegistry.SubnodeRecord({
                parentNode: parentNode,
                subLabel: "sub",
                parentLabel: parentLabel,
                owner: parentOwner
            });

            vm.prank(parentOwner);
            dotnsRegistry.setSubnodeOwner(record);

            assertEq(
                dotnsRegistry.owner(subnodes[i]),
                parentOwner,
                "Parent must be able to reassign subnode"
            );
        }
    }

    /// @notice The direct subnode owner must always be authorized for node operations.
    function invariant_subnode_owner_authorized() public view {
        bytes32[] memory subnodes = handler.getSubnodeHashes();
        address[] memory owners = handler.getSubnodeOwners();

        for (uint256 i; i < subnodes.length; ++i) {
            address currentOwner = dotnsRegistry.owner(subnodes[i]);
            assertEq(currentOwner, owners[i], "Registry owner must match tracked owner");
        }
    }

    /// @notice Subnodes must always exist once created.
    function invariant_subnodes_always_exist() public view {
        bytes32[] memory subnodes = handler.getSubnodeHashes();

        for (uint256 i; i < subnodes.length; ++i) {
            assertTrue(dotnsRegistry.recordExists(subnodes[i]), "Subnode must exist after creation");
        }
    }
}
