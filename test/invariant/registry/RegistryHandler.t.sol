// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

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
import {IPersonhood} from "../../../contracts/external/personhood/IPersonhood.sol";

/// @title Registry Handler for Invariant Testing
/// @notice Executes bounded random actions on the registry: register base domains,
///         create subnodes, reassign subnodes, set resolvers, and transfer base domains.
contract RegistryHandler is Test {
    /// @notice Node hash of the suite's TLD, injected from the deployed protocol registry.
    /// @dev Keeps the handler rooted at the same TLD the protocol under test uses, without a
    ///      second TLD definition.
    bytes32 private immutable TLD_NODE;

    /// @notice The registrar controller driving registrations.
    DotnsRegistrarController public controller;

    /// @notice The hierarchical registry under test.
    DotnsRegistry public registry;

    /// @notice The base registrar (ERC721) backing each base domain.
    DotnsRegistrar public registrar;

    /// @notice The PoP rules contract used for pricing.
    IPopRules public popRules;

    /// @notice Actor addresses driving handler actions.
    address[] public actors;

    /// @notice Personhood tier assigned to each actor at registration time.
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

    /// @notice Monotonic counter ensuring each generated label is unique.
    uint256 public labelNonce;

    /// @notice Cached controller `minCommitmentAge` to skip a cross-contract read per call.
    uint256 public minCommitmentAge;

    /// @notice Initialises the handler with the contracts under test.
    /// @param _controller The registrar controller.
    /// @param _registry The hierarchical registry.
    /// @param _registrar The base registrar.
    /// @param _popRules The PoP rules contract.
    /// @param _tldNode Node hash of the suite's TLD, from the deployed protocol registry.
    constructor(
        DotnsRegistrarController _controller,
        DotnsRegistry _registry,
        DotnsRegistrar _registrar,
        IPopRules _popRules,
        bytes32 _tldNode
    ) {
        TLD_NODE = _tldNode;
        controller = _controller;
        registry = _registry;
        registrar = _registrar;
        popRules = _popRules;
        minCommitmentAge = _controller.minCommitmentAge();
    }

    /// @notice Registers an actor with the given personhood status and mocks the precompile.
    /// @param actor Address to add to the actor set.
    /// @param status Personhood tier reported for `actor`.
    function addActor(address actor, IPopRules.PopStatus status) external {
        actors.push(actor);
        actorStatus[actor] = status;
        if (status != IPopRules.PopStatus.NoStatus) {
            _mockPersonhoodTier(actor, status);
        }
    }

    /// @notice Mocks the personhood precompile so it reports `tier` for `account`.
    /// @param account Address whose status is being mocked.
    /// @param tier Verification tier to report for `account`.
    function _mockPersonhoodTier(address account, IPopRules.PopStatus tier) internal {
        uint8 statusByte;
        if (tier == IPopRules.PopStatus.PopFull) statusByte = 2;
        else if (tier == IPopRules.PopStatus.PopLite) statusByte = 1;

        bytes32 contextAlias =
            statusByte == 0 ? bytes32(0) : keccak256(abi.encode(account, statusByte));
        vm.mockCall(
            DotnsConstants.PERSONHOOD,
            abi.encodeWithSelector(
                IPersonhood.personhoodStatus.selector, account, DotnsConstants.PERSONHOOD_CONTEXT
            ),
            abi.encode(IPersonhood.PersonhoodInfo({status: statusByte, contextAlias: contextAlias}))
        );
    }

    /// @notice Register a base domain and create a subnode under it.
    /// @param actorSeed Seed selecting the base domain owner.
    /// @param subnodeOwnerSeed Seed selecting the subnode owner.
    function registerAndCreateSubnode(uint256 actorSeed, uint256 subnodeOwnerSeed) external {
        if (actors.length < 2) return;

        address domainOwner = actors[actorSeed % actors.length];
        address subnodeOwner = actors[subnodeOwnerSeed % actors.length];
        string memory label = _generateUniqueLabel();

        _registerBaseDomain(label, domainOwner);
        bytes32 parentNode = _computeNode(label);

        _createSubnode(parentNode, "sub", label, domainOwner, subnodeOwner);
    }

    /// @notice Reassign an existing subnode to a different owner.
    /// @param subnodeSeed Seed selecting which subnode to reassign.
    /// @param newOwnerSeed Seed selecting the new subnode owner.
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
    /// @param labelSeed Seed selecting which registered label to transfer.
    /// @param recipientSeed Seed selecting the recipient.
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

        vm.prank(currentOwner);
        registrar.transferFrom(currentOwner, recipient, tokenId);

        _registeredOwners[index] = recipient;
    }

    /// @notice Returns the recorded subnode hashes.
    function getSubnodeHashes() external view returns (bytes32[] memory) {
        return _subnodeHashes;
    }

    /// @notice Returns the parent node for each recorded subnode (same index).
    function getSubnodeParents() external view returns (bytes32[] memory) {
        return _subnodeParents;
    }

    /// @notice Returns the current owner tracked for each recorded subnode.
    function getSubnodeOwners() external view returns (address[] memory) {
        return _subnodeOwners;
    }

    /// @notice Returns all base domain labels registered via the handler.
    function getRegisteredLabels() external view returns (string[] memory) {
        return _registeredLabels;
    }

    /// @notice Runs the commit-reveal flow and registers a base domain for `domainOwner`.
    /// @param label Label to register.
    /// @param domainOwner Address receiving ownership of the base domain.
    function _registerBaseDomain(string memory label, address domainOwner) internal {
        bytes32 secret =
            keccak256(abi.encodePacked(label, domainOwner, block.timestamp, labelNonce));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label, owner: domainOwner, secret: secret, reserved: true
            });

        bytes32 commitment = controller.makeCommitment(registration);
        vm.prank(domainOwner);
        controller.commit(commitment);
        vm.warp(block.timestamp + minCommitmentAge + 1);

        uint256 price = popRules.priceWithCheck(label, domainOwner).price;
        vm.prank(domainOwner);
        controller.register{value: price}(registration);

        _registeredLabels.push(label);
        _registeredOwners.push(domainOwner);
    }

    /// @notice Creates a subnode under `parentNode` and records it in ghost state.
    /// @param parentNode Namehash of the parent node.
    /// @param subLabel Sub-label being created.
    /// @param parentLabel Label of the parent (required by `setSubnodeOwner`).
    /// @param parentOwner Address authorised to create the subnode.
    /// @param subnodeOwner Address receiving ownership of the new subnode.
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

    /// @notice Computes the namehash for `label` under the suite's TLD.
    /// @param label Label whose node hash is required.
    function _computeNode(string memory label) internal view returns (bytes32) {
        return LabelUtils.namehashUnder(TLD_NODE, LabelUtils.labelhashMemory(label));
    }

    /// @notice Generates a unique label for each registration in the run.
    /// @dev Uses an incrementing nonce to ensure uniqueness across calls.
    function _generateUniqueLabel() internal returns (string memory) {
        string memory label = string(abi.encodePacked("inv", vm.toString(labelNonce)));
        ++labelNonce;
        return label;
    }

    /// @notice Picks an actor other than `exclude` from the actor set.
    /// @param exclude Actor to skip.
    /// @param seed Seed selecting amongst the remaining actors.
    /// @return Address of a different actor, or `address(0)` if none qualifies.
    function _pickDifferent(address exclude, uint256 seed) internal view returns (address) {
        for (uint256 i; i < actors.length; ++i) {
            address candidate = actors[(seed + i) % actors.length];
            if (candidate != exclude) return candidate;
        }
        return address(0);
    }

    /// @notice Allows the handler to receive native funds (e.g. refunds).
    receive() external payable {}
}
