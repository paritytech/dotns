// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsRegistry} from "../../../contracts/registry/IDotnsRegistry.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {RegistryHandler} from "./RegistryHandler.t.sol";

/// @title Dotns Registry Invariant Suite
/// @notice Asserts authorisation, persistence, and parent-reassignment properties of the
///         hierarchical registry across randomised registration, subnode creation, and
///         transfer flows.
contract DotnsRegistryInvariantTest is BaseDotns {
    /// @notice Handler driving randomised actions against the registry.
    RegistryHandler public handler;

    /// @notice Deploys the registry handler, funds it, registers a mixed-tier actor set
    ///         (including a freshly created `alice`), and targets the handler exclusively.
    function setUp() public override {
        super.setUp();

        handler = new RegistryHandler(
            dotnsRegistrarController,
            dotnsRegistry,
            dotnsRegistrar,
            popRules,
            protocolRegistry.tldNode()
        );

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

        _seedCoverage();
    }

    /// @notice Drives subnode creation until both a created subnode and a rejected dotted
    ///         sub-label exist.
    /// @dev The assertions in @custom:function afterInvariant would otherwise depend on the
    ///      fuzzer happening to generate a separator, which is a coin flip per run. Sub-labels
    ///      come from a seed, so this walks seeds and stops at the first that satisfies both;
    ///      seeding from `setUp` puts them in the snapshot every run starts from. The walk is
    ///      bounded so a change to the alphabet fails the run loudly rather than hanging.
    function _seedCoverage() internal {
        for (uint256 seed; seed < 64; ++seed) {
            if (handler.dottedSubLabelAttempts() > 0 && handler.subnodeCount() > 0) break;
            handler.registerAndCreateSubnode(seed, seed, seed);
        }
    }

    /// @notice Fails the run if the campaign never created a subnode or never offered a dotted
    ///         sub-label.
    /// @dev Every assertion in this suite iterates the handler's subnode list, so an empty list
    ///      passes them all without testing anything, and a base registration the protocol
    ///      stopped accepting would empty it silently. The second check covers the other
    ///      direction: the separator assertion only means something once a dotted sub-label has
    ///      actually been put in front of the registry.
    function afterInvariant() public view {
        assertGt(handler.subnodeCount(), 0, "campaign created no subnode");
        assertGt(handler.dottedSubLabelAttempts(), 0, "campaign offered no dotted sub-label");
        assertEq(
            handler.dottedSubLabelRejections(),
            handler.dottedSubLabelAttempts(),
            "a dotted sub-label was accepted"
        );
    }

    /// @notice No subname the registry accepted carries a separator, and none lands on the node
    ///         the same text would take as one whole label.
    /// @dev The design rests on the two readings of a dotted text staying apart: `joseph` under
    ///      `42` is a subname, `joseph.42` is one person. The handler draws sub-labels from an
    ///      alphabet that includes the separator, so this asserts over what the registry
    ///      actually admitted rather than over an assumption that a dotted sub-label is
    ///      impossible to submit.
    function invariant_subnames_never_produce_a_dotted_node() public view {
        bytes32[] memory subnodes = handler.getSubnodeHashes();
        for (uint256 i; i < subnodes.length; ++i) {
            string memory subLabel = handler.subnodeLabelAt(i);
            assertFalse(_carriesSeparator(subLabel), "registry accepted a dotted sub-label");

            string memory flattened = string.concat(subLabel, ".", handler.subnodeParentLabelAt(i));
            assertTrue(subnodes[i] != _nodeOf(flattened), "subnode collided with a whole label");
        }
    }

    /// @notice Whether `value` carries the label separator.
    function _carriesSeparator(string memory value) internal pure returns (bool carries) {
        bytes memory raw = bytes(value);
        for (uint256 i = 0; i < raw.length; ++i) {
            if (raw[i] == bytes1(0x2e)) return true;
        }
        return false;
    }

    /// @notice The parent domain owner must always be able to reassign any of its subnodes
    ///         to itself, regardless of intervening transfers or reassignments.
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
                subLabel: handler.subnodeLabelAt(i),
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

    /// @notice The registry's recorded subnode owner must equal the handler's tracked owner
    ///         for every subnode created during the run.
    function invariant_subnode_owner_authorized() public view {
        bytes32[] memory subnodes = handler.getSubnodeHashes();
        address[] memory owners = handler.getSubnodeOwners();

        for (uint256 i; i < subnodes.length; ++i) {
            address currentOwner = dotnsRegistry.owner(subnodes[i]);
            assertEq(currentOwner, owners[i], "Registry owner must match tracked owner");
        }
    }

    /// @notice Once a subnode has been created it must always report `recordExists() == true`.
    function invariant_subnodes_always_exist() public view {
        bytes32[] memory subnodes = handler.getSubnodeHashes();

        for (uint256 i; i < subnodes.length; ++i) {
            assertTrue(dotnsRegistry.recordExists(subnodes[i]), "Subnode must exist after creation");
        }
    }
}
