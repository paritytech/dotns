// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IDotnsRegistry} from "../../../contracts/registry/IDotnsRegistry.sol";
import {DotnsRegistry} from "../../../contracts/registry/DotnsRegistry.sol";
import {LabelUtils} from "../../../contracts/utils/LabelUtils.sol";
import {DotnsRegistrar} from "../../../contracts/registrars/DotnsRegistrar.sol";
import {
    IDotnsRegistrarController,
    DotnsRegistrarController
} from "../../../contracts/registrars/DotnsRegistrarController.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";

/// @title Registry Handler for Invariant Testing
/// @notice Executes bounded random actions on the registry: register base domains,
///         create subnodes, reassign subnodes, set resolvers, and transfer base domains.
contract RegistryHandler is Test {
    bytes32 private constant DOT_NODE = DotnsConstants.DOT_NODE;

    DotnsRegistrarController public controller;
    DotnsRegistry public registry;
    DotnsRegistrar public registrar;
    IPopRules public popRules;

    address[] public actors;
    mapping(address actor => IPopRules.PopStatus status) public actorStatus;

    /// @notice Registered base domain labels.
    string[] internal _registeredLabels;
    /// @notice Owners at time of registration (may change via transfer).
    address[] internal _registeredOwners;

    /// @notice Subnode hashes.
    bytes32[] internal _subnodeHashes;
    /// @notice Parent node for each subnode (same index).
    bytes32[] internal _subnodeParents;
    /// @notice Current subnode owner (updated on reassignment).
    address[] internal _subnodeOwners;

    uint256 public labelNonce;
    uint256 public minCommitmentAge;

    constructor(
        DotnsRegistrarController _controller,
        DotnsRegistry _registry,
        DotnsRegistrar _registrar,
        IPopRules _popRules
    ) {
        controller = _controller;
        registry = _registry;
        registrar = _registrar;
        popRules = _popRules;
        minCommitmentAge = _controller.minCommitmentAge();
    }

    function addActor(address actor, IPopRules.PopStatus status) external {
        actors.push(actor);
        actorStatus[actor] = status;
        if (status != IPopRules.PopStatus.NoStatus) {
            vm.prank(actor);
            popRules.setUserPopStatus(status);
        }
    }

    /// @notice Register a base domain and create a subnode under it.
    function registerAndCreateSubnode(uint256 actorSeed, uint256 subnodeOwnerSeed) external {
        if (actors.length < 2) return;

        address domainOwner = actors[actorSeed % actors.length];
        address subnodeOwner = actors[subnodeOwnerSeed % actors.length];
        string memory label = _generateUniqueLabel();

        if (!_registerBaseDomain(label, domainOwner)) return;

        bytes32 parentNode = _computeNode(label);
        _createSubnode(parentNode, "sub", label, domainOwner, subnodeOwner);
    }

    /// @notice Reassign an existing subnode to a different owner.
    function reassignSubnode(uint256 subnodeSeed, uint256 newOwnerSeed) external {
        if (_subnodeHashes.length == 0 || actors.length < 2) return;

        uint256 index = subnodeSeed % _subnodeHashes.length;
        bytes32 parentNode = _subnodeParents[index];

        // Find the parent label from registered labels
        string memory parentLabel;
        for (uint256 i; i < _registeredLabels.length; ++i) {
            if (_computeNode(_registeredLabels[i]) == parentNode) {
                parentLabel = _registeredLabels[i];
                break;
            }
        }
        if (bytes(parentLabel).length == 0) return;

        // Get current parent owner via registrar
        uint256 tokenId = uint256(parentNode);
        address parentOwner;
        try registrar.ownerOf(tokenId) returns (address o) {
            parentOwner = o;
        } catch {
            return;
        }

        address newOwner = actors[newOwnerSeed % actors.length];

        IDotnsRegistry.SubnodeRecord memory record = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: "sub", parentLabel: parentLabel, owner: newOwner
        });

        vm.prank(parentOwner);
        registry.setSubnodeOwner(record);

        _subnodeOwners[index] = newOwner;
    }

    /// @notice Transfer a base domain ERC721 token.
    function transferBaseDomain(uint256 labelSeed, uint256 recipientSeed) external {
        if (_registeredLabels.length == 0 || actors.length < 2) return;

        uint256 index = labelSeed % _registeredLabels.length;
        string memory label = _registeredLabels[index];
        bytes32 node = _computeNode(label);
        uint256 tokenId = uint256(node);

        address currentOwner;
        try registrar.ownerOf(tokenId) returns (address o) {
            currentOwner = o;
        } catch {
            return;
        }

        address recipient = _pickDifferent(currentOwner, recipientSeed);
        if (recipient == address(0)) return;

        // Cross-tier transfers require a fee under the reach-floor model; quote
        // it from the registrar and supply it via the now-payable transferFrom.
        uint256 fee = registrar.quoteTransferFee(tokenId, recipient);

        vm.prank(currentOwner);
        registrar.transferFrom{value: fee}(currentOwner, recipient, tokenId);

        _registeredOwners[index] = recipient;
    }

    function getSubnodeHashes() external view returns (bytes32[] memory) {
        return _subnodeHashes;
    }

    function getSubnodeParents() external view returns (bytes32[] memory) {
        return _subnodeParents;
    }

    function getSubnodeOwners() external view returns (address[] memory) {
        return _subnodeOwners;
    }

    function getRegisteredLabels() external view returns (string[] memory) {
        return _registeredLabels;
    }

    function _registerBaseDomain(
        string memory label,
        address domainOwner
    )
        internal
        returns (bool success)
    {
        bytes32 secret =
            keccak256(abi.encodePacked(label, domainOwner, block.timestamp, labelNonce));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label, owner: domainOwner, secret: secret, reserved: true
            });

        bytes32 commitment = controller.makeCommitment(registration);
        vm.prank(domainOwner);
        try controller.commit(commitment) {}
        catch {
            return false;
        }
        vm.warp(block.timestamp + minCommitmentAge + 1);

        uint256 price = popRules.priceWithCheck(label, domainOwner).price;
        vm.prank(domainOwner);
        try controller.register{value: price}(registration) {
            _registeredLabels.push(label);
            _registeredOwners.push(domainOwner);
            return true;
        } catch {
            return false;
        }
    }

    function _createSubnode(
        bytes32 parentNode,
        string memory subLabel,
        string memory parentLabel,
        address parentOwner,
        address subnodeOwner
    )
        internal
    {
        IDotnsRegistry.SubnodeRecord memory record = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode,
            subLabel: subLabel,
            parentLabel: parentLabel,
            owner: subnodeOwner
        });

        vm.prank(parentOwner);
        bytes32 subnode = registry.setSubnodeOwner(record);

        _subnodeHashes.push(subnode);
        _subnodeParents.push(parentNode);
        _subnodeOwners.push(subnodeOwner);
    }

    function _computeNode(string memory label) internal pure returns (bytes32) {
        return LabelUtils.namehashUnder(DOT_NODE, LabelUtils.labelhashMemory(label));
    }

    function _generateUniqueLabel() internal returns (string memory) {
        // PopRules classifies labels by base-stem length and trailing-digit count.
        // Targets the open NoStatus tier: baselength ≥9 + exactly 2 trailing
        // digits — every actor (including NoStatus tiago) can register without a
        // PoP gate. The "invariant" stem (9 chars) plus a 4-letter rotation
        // index gives ~456k unique prefixes; the 2-digit suffix fans each one
        // out 100x. Easily enough headroom for a full CI invariant campaign
        // (1024 runs × 1000 depth) without label collisions.
        uint256 encoded = labelNonce / 100;
        uint256 suffix = labelNonce % 100;

        bytes memory letters = new bytes(4);
        for (uint256 i; i < 4; ++i) {
            // encoded % 26 is always 0-25, safely fits in uint8
            // forge-lint: disable-next-line(unsafe-typecast)
            letters[i] = bytes1(uint8(0x61) + uint8(encoded % 26));
            encoded /= 26;
        }

        string memory padded =
            suffix < 10 ? string(abi.encodePacked("0", vm.toString(suffix))) : vm.toString(suffix);
        string memory label = string(abi.encodePacked("invariant", letters, padded));
        ++labelNonce;
        return label;
    }

    function _pickDifferent(address exclude, uint256 seed) internal view returns (address) {
        for (uint256 i; i < actors.length; ++i) {
            address candidate = actors[(seed + i) % actors.length];
            if (candidate != exclude) return candidate;
        }
        return address(0);
    }

    receive() external payable {}
}
