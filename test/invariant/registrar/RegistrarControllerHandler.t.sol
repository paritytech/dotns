// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {
    IDotnsRegistrarController,
    DotnsRegistrarController
} from "../../../contracts/registrars/DotnsRegistrarController.sol";
import {IDotnsRegistry} from "../../../contracts/registry/IDotnsRegistry.sol";
import {IDotnsReverseResolver} from "../../../contracts/resolvers/IDotnsReverseResolver.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {IStoreFactory} from "../../../contracts/store/IStoreFactory.sol";
import {DotnsRegistrar} from "../../../contracts/registrars/DotnsRegistrar.sol";
import {IPersonhood} from "../../../contracts/pop/IPersonhood.sol";

/// @title Registrar Controller Handler
/// @notice Handler contract that executes bounded random actions against the controller.
/// @dev Maintains ghost state to track registrations, commitments, and actors for invariant checks.
contract RegistrarControllerHandler is Test {
    /// @notice The registrar controller under test.
    IDotnsRegistrarController public controller;

    /// @notice The forward registry.
    IDotnsRegistry public registry;

    /// @notice The base registrar (ERC721).
    DotnsRegistrar public registrar;

    /// @notice The reverse resolver.
    IDotnsReverseResolver public reverseResolver;

    /// @notice The PoP rules contract.
    IPopRules public popRules;

    /// @notice The store factory.
    IStoreFactory public storeFactory;

    /// @notice List of actor addresses used for testing.
    address[] public actors;

    /// @notice Mapping of actor address to their PoP status.
    mapping(address actor => IPopRules.PopStatus status) public actorStatus;

    /// @notice Labels that have been successfully registered.
    string[] internal _registeredLabels;

    /// @notice Owners corresponding to registered labels (same index).
    address[] internal _registeredOwners;

    /// @notice Labels registered with reserved=true.
    string[] internal _reservedLabels;

    /// @notice Owners of reserved registrations (same index as _reservedLabels).
    address[] internal _reservedOwners;

    /// @notice Commitments that have been consumed by successful registrations.
    bytes32[] internal _consumedCommitments;

    /// @notice Commitments that are currently active (pending reveal).
    bytes32[] internal _activeCommitments;

    /// @notice Mapping to track which labels have been registered.
    mapping(bytes32 labelhash => bool registered) public labelRegistered;

    /// @notice Counter for generating unique labels.
    uint256 public labelNonce;

    /// @notice Total count of successful registrations.
    uint256 public registrationCount;

    /// @notice Minimum commitment age from the controller.
    uint256 public minCommitmentAge;

    /// @notice Maximum commitment age from the controller.
    uint256 public maxCommitmentAge;

    /// @notice Initializes the handler with protocol contracts.
    /// @param _controller The registrar controller.
    /// @param _registry The forward registry.
    /// @param _registrar The base registrar.
    /// @param _reverseResolver The reverse resolver.
    /// @param _popRules The PoP rules contract.
    /// @param _storeFactory The store factory.
    constructor(
        DotnsRegistrarController _controller,
        IDotnsRegistry _registry,
        DotnsRegistrar _registrar,
        IDotnsReverseResolver _reverseResolver,
        IPopRules _popRules,
        IStoreFactory _storeFactory
    ) {
        controller = _controller;
        registry = _registry;
        registrar = _registrar;
        reverseResolver = _reverseResolver;
        popRules = _popRules;
        storeFactory = _storeFactory;

        minCommitmentAge = _controller.minCommitmentAge();
        maxCommitmentAge = _controller.maxCommitmentAge();
    }

    /// @notice Precompile address for the on-chain Personhood status oracle.
    address internal constant PERSONHOOD_PRECOMPILE = 0x000000000000000000000000000000000a010000;

    /// @notice Adds an actor with a specific PoP status.
    /// @param actor The actor address.
    /// @param status The PoP status to assign.
    function addActor(address actor, IPopRules.PopStatus status) external {
        actors.push(actor);
        actorStatus[actor] = status;

        if (status != IPopRules.PopStatus.NoStatus) {
            uint8 raw;
            if (status == IPopRules.PopStatus.PopFull) raw = 2;
            else if (status == IPopRules.PopStatus.PopLite) raw = 1;
            vm.mockCall(
                PERSONHOOD_PRECOMPILE,
                abi.encodeCall(IPersonhood.personhoodStatus, (actor)),
                abi.encode(raw)
            );
        }
    }

    /// @notice Performs a complete commit-reveal registration flow.
    /// @dev Generates a unique label, commits, warps time, and registers.
    /// @param actorSeed Seed for selecting an actor.
    /// @param reservedSeed Seed for determining if name should be reserved.
    function commitAndRegister(uint256 actorSeed, uint256 reservedSeed) external {
        if (actors.length == 0) return;

        address actor = actors[actorSeed % actors.length];
        bool reserved = reservedSeed % 2 == 0;
        string memory label = _generateUniqueLabel();

        bytes32 secret = keccak256(abi.encodePacked(label, actor, block.timestamp, labelNonce));

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label, owner: actor, secret: secret, reserved: reserved
            });

        bytes32 commitment = controller.makeCommitment(registration);

        // Commit
        vm.prank(actor);
        controller.commit(commitment);
        _activeCommitments.push(commitment);

        // Warp past minimum commitment age
        vm.warp(block.timestamp + minCommitmentAge + 1);

        // Get price and register
        uint256 price = popRules.priceWithCheck(label, actor).price;

        vm.prank(actor);
        controller.register{value: price}(registration);

        // Update ghost state
        _registeredLabels.push(label);
        _registeredOwners.push(actor);
        _consumedCommitments.push(commitment);
        _removeActiveCommitment(commitment);
        labelRegistered[keccak256(bytes(label))] = true;
        ++registrationCount;

        if (reserved) {
            _reservedLabels.push(label);
            _reservedOwners.push(actor);
        }
    }

    /// @notice Performs a commit-only action without registration.
    /// @dev Creates a pending commitment that may or may not be revealed.
    /// @param actorSeed Seed for selecting an actor.
    function commitOnly(uint256 actorSeed) external {
        if (actors.length == 0) return;

        address actor = actors[actorSeed % actors.length];
        string memory label = _generateUniqueLabel();

        bytes32 secret = keccak256(abi.encodePacked(label, actor, block.timestamp, labelNonce));

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label, owner: actor, secret: secret, reserved: true
            });

        bytes32 commitment = controller.makeCommitment(registration);

        vm.prank(actor);
        controller.commit(commitment);
        _activeCommitments.push(commitment);
    }

    /// @notice Performs a registration with overpayment to test refunds.
    /// @dev Sends more ETH than required and verifies refund mechanics.
    /// @param actorSeed Seed for selecting an actor.
    /// @param overpaymentSeed Seed for overpayment amount.
    function registerWithOverpayment(uint256 actorSeed, uint256 overpaymentSeed) external {
        if (actors.length == 0) return;

        address actor = actors[actorSeed % actors.length];
        string memory label = _generateUniqueLabel();
        uint256 overpayment = (overpaymentSeed % 10) * 1e15;

        bytes32 secret = keccak256(abi.encodePacked(label, actor, block.timestamp, labelNonce));

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label, owner: actor, secret: secret, reserved: true
            });

        bytes32 commitment = controller.makeCommitment(registration);

        vm.prank(actor);
        controller.commit(commitment);

        vm.warp(block.timestamp + minCommitmentAge + 1);

        uint256 price = popRules.priceWithCheck(label, actor).price;
        uint256 balanceBefore = actor.balance;

        vm.prank(actor);
        controller.register{value: price + overpayment}(registration);

        // Verify refund occurred
        if (overpayment > 0 && price == 0) {
            assertEq(actor.balance, balanceBefore, "Full overpayment must be refunded");
        }

        _registeredLabels.push(label);
        _registeredOwners.push(actor);
        _consumedCommitments.push(commitment);
        labelRegistered[keccak256(bytes(label))] = true;
        ++registrationCount;

        _reservedLabels.push(label);
        _reservedOwners.push(actor);
    }

    /// @notice Advances block timestamp to simulate time passage.
    /// @dev Bounded to prevent excessive time warps.
    /// @param timeDelta Time to advance in seconds.
    function advanceTime(uint256 timeDelta) external {
        uint256 boundedDelta = timeDelta % (maxCommitmentAge * 2);
        vm.warp(block.timestamp + boundedDelta);
    }

    /// @notice Returns all successfully registered labels.
    /// @return labels Array of registered label strings.
    function getRegisteredLabels() external view returns (string[] memory labels) {
        labels = _registeredLabels;
    }

    /// @notice Returns owners corresponding to registered labels.
    /// @return owners Array of owner addresses.
    function getRegisteredOwners() external view returns (address[] memory owners) {
        owners = _registeredOwners;
    }

    /// @notice Returns labels registered with reserved=true.
    /// @return labels Array of reserved label strings.
    function getReservedLabels() external view returns (string[] memory labels) {
        labels = _reservedLabels;
    }

    /// @notice Returns owners of reserved registrations.
    /// @return owners Array of reserved owner addresses.
    function getReservedOwners() external view returns (address[] memory owners) {
        owners = _reservedOwners;
    }

    /// @notice Returns commitments consumed by successful registrations.
    /// @return commitments Array of consumed commitment hashes.
    function getConsumedCommitments() external view returns (bytes32[] memory commitments) {
        commitments = _consumedCommitments;
    }

    /// @notice Returns currently active (pending) commitments.
    /// @return commitments Array of active commitment hashes.
    function getActiveCommitments() external view returns (bytes32[] memory commitments) {
        commitments = _activeCommitments;
    }

    /// @notice Returns the total count of successful registrations.
    /// @return count Number of registrations.
    function getRegistrationCount() external view returns (uint256 count) {
        count = registrationCount;
    }

    /// @notice Generates a unique label for registration.
    /// @dev Uses incrementing nonce to ensure uniqueness across calls.
    /// @return label A unique label string with minimum 3 characters.
    function _generateUniqueLabel() internal returns (string memory label) {
        label = string(abi.encodePacked("name", vm.toString(labelNonce)));
        ++labelNonce;
    }

    /// @notice Removes a commitment from the active commitments array.
    /// @param commitment The commitment hash to remove.
    function _removeActiveCommitment(bytes32 commitment) internal {
        uint256 length = _activeCommitments.length;
        for (uint256 i; i < length; ++i) {
            if (_activeCommitments[i] == commitment) {
                _activeCommitments[i] = _activeCommitments[length - 1];
                _activeCommitments.pop();
                break;
            }
        }
    }

    /// @notice Allows the handler to receive ETH refunds.
    receive() external payable {}
}
