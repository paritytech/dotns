// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {
    DotnsRegistrarController,
    IDotnsRegistrarController
} from "../../../contracts/registrars/DotnsRegistrarController.sol";
import {DotnsRegistrar} from "../../../contracts/registrars/DotnsRegistrar.sol";
import {DotnsNameEscrow, IDotnsNameEscrow} from "../../../contracts/escrow/DotnsNameEscrow.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

/// @title Escrow Handler
/// @notice Handler contract that executes bounded random actions against the escrow.
/// @dev Maintains ghost state to track deposits, releases, and withdrawals
///      for invariant checks.
contract EscrowHandler is Test {
    /// @notice Namehash of the .dot TLD.
    bytes32 private constant DOT_NODE =
        0x3fce7d1364a893e213bc4212792b517ffc88f5b13b86c8ef9c8d390c3a1370ce;

    /// @notice Escrow cooldown period (7 days).
    uint256 private constant ESCROW_COOLDOWN = 7 days;

    /// @notice The registrar controller under test.
    DotnsRegistrarController public controller;

    /// @notice The base registrar (ERC721).
    DotnsRegistrar public registrar;

    /// @notice The name escrow under test.
    DotnsNameEscrow public escrow;

    /// @notice The PoP rules contract.
    IPopRules public popRules;

    /// @notice Tokens with active deposits (not yet released).
    uint256[] internal _depositedTokenIds;

    /// @notice Tokens that have been released into escrow (not yet withdrawn).
    uint256[] internal _releasedTokenIds;

    /// @notice Tokens that have been withdrawn (ready for reclaim via re-registration).
    uint256[] internal _withdrawnTokenIds;

    /// @notice Amount deposited per tokenId.
    mapping(uint256 tokenId => uint256 amount) public depositAmounts;

    /// @notice Snapshotted recipient per tokenId (set at release time).
    mapping(uint256 tokenId => address recipient) public depositRecipients;

    /// @notice Label used to register each tokenId — required for re-registration after finalise.
    mapping(uint256 tokenId => string label) public labelByTokenId;

    /// @notice List of actor addresses used for testing.
    address[] public actors;

    /// @notice Counter for generating unique labels.
    uint256 public labelNonce;

    /// @notice Initializes the handler with protocol contracts.
    /// @param _controller The registrar controller.
    /// @param _registrar The base registrar.
    /// @param _escrow The name escrow.
    /// @param _popRules The PoP rules contract.
    constructor(
        DotnsRegistrarController _controller,
        DotnsRegistrar _registrar,
        DotnsNameEscrow _escrow,
        IPopRules _popRules
    ) {
        controller = _controller;
        registrar = _registrar;
        escrow = _escrow;
        popRules = _popRules;
    }

    /// @notice Adds an actor address.
    /// @param actor The actor address to add.
    function addActor(address actor) external {
        actors.push(actor);
    }

    /// @notice Performs a complete commit-reveal registration, depositing into escrow.
    /// @dev Generates a unique 10+ char label, commits, warps time, and registers.
    ///      Tracks the tokenId and deposit amount in ghost state.
    /// @param actorSeed Seed for selecting an actor.
    function commitRegisterAndDeposit(uint256 actorSeed) external {
        if (actors.length == 0) return;

        address actor = actors[actorSeed % actors.length];
        string memory label = _generateUniqueLabel();

        bytes32 secret = keccak256(abi.encodePacked(label, actor, block.timestamp, labelNonce));

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label, owner: actor, secret: secret, reserved: true
            });

        bytes32 commitment = controller.makeCommitment(registration);

        // Commit
        vm.prank(actor);
        controller.commit(commitment);

        // Warp past minimum commitment age
        uint256 minAge = controller.minCommitmentAge();
        vm.warp(block.timestamp + minAge + 1);

        // Get price and register
        uint256 price = popRules.priceWithCheck(label, actor).price;

        vm.prank(actor);
        controller.register{value: price}(registration);

        // Compute tokenId
        bytes32 labelhash = keccak256(bytes(label));
        bytes32 node = keccak256(abi.encodePacked(DOT_NODE, labelhash));
        uint256 tokenId = uint256(node);

        // Update ghost state
        _depositedTokenIds.push(tokenId);
        depositAmounts[tokenId] = price;
        labelByTokenId[tokenId] = label;
    }

    /// @notice Releases a deposited token into escrow.
    /// @dev Picks from _depositedTokenIds (if any), approves escrow, releases.
    ///      Moves the token to _releasedTokenIds and snapshots the recipient.
    /// @param tokenSeed Seed for selecting which deposited token to release.
    function releaseToken(uint256 tokenSeed) external {
        if (_depositedTokenIds.length == 0) return;

        uint256 index = tokenSeed % _depositedTokenIds.length;
        uint256 tokenId = _depositedTokenIds[index];

        // Only release if the deposit has a non-zero amount (NoStatus names)
        if (depositAmounts[tokenId] == 0) {
            _removeDeposited(index);
            return;
        }

        address tokenOwner = registrar.ownerOf(tokenId);

        // Approve escrow to transfer the token
        vm.prank(tokenOwner);
        registrar.approve(address(escrow), tokenId);

        // Release the token into escrow
        vm.prank(tokenOwner);
        escrow.release(tokenId);

        // Update ghost state
        depositRecipients[tokenId] = tokenOwner;
        _releasedTokenIds.push(tokenId);
        _removeDeposited(index);
    }

    /// @notice Withdraws refund for a released token after cooldown.
    /// @dev Picks from _releasedTokenIds, warps past cooldown, withdraws.
    ///      Moves the token to _withdrawnTokenIds.
    /// @param tokenSeed Seed for selecting which released token to withdraw.
    function withdrawRefund(uint256 tokenSeed) external {
        if (_releasedTokenIds.length == 0) return;

        uint256 index = tokenSeed % _releasedTokenIds.length;
        uint256 tokenId = _releasedTokenIds[index];

        address recipient = depositRecipients[tokenId];

        // Warp past cooldown to ensure withdrawal succeeds
        IDotnsNameEscrow.ReleasePosition memory position = escrow.getReleasePosition(tokenId);
        if (block.timestamp < position.withdrawAvailableAt) {
            vm.warp(position.withdrawAvailableAt);
        }

        // Withdraw
        vm.prank(recipient);
        escrow.withdraw(tokenId);

        // Update ghost state
        _withdrawnTokenIds.push(tokenId);
        _removeReleased(index);
    }

    /// @notice Re-registers a withdrawn (reclaim-ready) name with a (possibly different) actor.
    /// @dev Exercises the full-cycle custody reuse path: register → release → withdraw → reclaim.
    ///      The controller's `register()` routes through `escrow.reclaim()` automatically when
    ///      the token is in escrow custody — no separate finalise step exists.
    /// @param tokenSeed Seed for selecting which withdrawn token to reclaim.
    /// @param actorSeed Seed for selecting the new registrant.
    function reRegisterReclaimed(uint256 tokenSeed, uint256 actorSeed) external {
        if (_withdrawnTokenIds.length == 0 || actors.length == 0) return;

        uint256 index = tokenSeed % _withdrawnTokenIds.length;
        uint256 tokenId = _withdrawnTokenIds[index];
        string memory label = labelByTokenId[tokenId];
        address actor = actors[actorSeed % actors.length];

        bytes32 secret = keccak256(abi.encodePacked(label, actor, block.timestamp, labelNonce));

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label, owner: actor, secret: secret, reserved: true
            });

        bytes32 commitment = controller.makeCommitment(registration);

        vm.prank(actor);
        controller.commit(commitment);

        uint256 minAge = controller.minCommitmentAge();
        vm.warp(block.timestamp + minAge + 1);

        uint256 price = popRules.priceWithCheck(label, actor).price;

        vm.prank(actor);
        controller.register{value: price}(registration);

        _removeWithdrawn(index);
        _depositedTokenIds.push(tokenId);
        depositAmounts[tokenId] = price;
        depositRecipients[tokenId] = address(0);
        labelByTokenId[tokenId] = label;
    }

    /// @notice Transfers a deposited token to a different actor.
    /// @dev Only deposited (pre-release) tokens are transferable; released tokens belong to
    ///      escrow and finalised ones are burned. Ghost state is unaffected because refund
    ///      rights are resolved at release time via `registrar.ownerOf`.
    /// @param tokenSeed Seed for selecting which deposited token to transfer.
    /// @param actorSeed Seed for selecting the recipient.
    function transferDeposited(uint256 tokenSeed, uint256 actorSeed) external {
        if (_depositedTokenIds.length == 0 || actors.length < 2) return;

        uint256 index = tokenSeed % _depositedTokenIds.length;
        uint256 tokenId = _depositedTokenIds[index];
        address currentOwner = registrar.ownerOf(tokenId);
        address recipient = _pickDifferentActor(currentOwner, actorSeed);
        if (recipient == address(0)) return;

        vm.prank(currentOwner);
        registrar.transferFrom(currentOwner, recipient, tokenId);
    }

    /// @notice Advances block timestamp to simulate time passage.
    /// @dev Bounded to prevent excessive time warps.
    /// @param delta Time to advance in seconds.
    function advanceTime(uint256 delta) external {
        uint256 boundedDelta = bound(delta, 0, 30 days);
        vm.warp(block.timestamp + boundedDelta);
    }

    /// @notice Returns all tokens with active deposits.
    /// @return tokenIds Array of deposited token identifiers.
    function getDepositedTokenIds() external view returns (uint256[] memory tokenIds) {
        tokenIds = _depositedTokenIds;
    }

    /// @notice Returns all tokens that have been released into escrow.
    /// @return tokenIds Array of released token identifiers.
    function getReleasedTokenIds() external view returns (uint256[] memory tokenIds) {
        tokenIds = _releasedTokenIds;
    }

    /// @notice Returns all tokens that have been withdrawn.
    /// @return tokenIds Array of withdrawn token identifiers.
    function getWithdrawnTokenIds() external view returns (uint256[] memory tokenIds) {
        tokenIds = _withdrawnTokenIds;
    }

    /// @notice Generates a unique label of 10+ characters for registration.
    /// @dev Uses incrementing nonce to ensure uniqueness across calls.
    /// @return label A unique label string with minimum 10 characters.
    function _generateUniqueLabel() internal returns (string memory label) {
        label = string(abi.encodePacked("escrowname", vm.toString(labelNonce)));
        ++labelNonce;
    }

    /// @notice Removes an element from _depositedTokenIds by index (swap-and-pop).
    /// @param index Index to remove.
    function _removeDeposited(uint256 index) internal {
        uint256 lastIndex = _depositedTokenIds.length - 1;
        if (index != lastIndex) {
            _depositedTokenIds[index] = _depositedTokenIds[lastIndex];
        }
        _depositedTokenIds.pop();
    }

    /// @notice Removes an element from _releasedTokenIds by index (swap-and-pop).
    /// @param index Index to remove.
    function _removeReleased(uint256 index) internal {
        uint256 lastIndex = _releasedTokenIds.length - 1;
        if (index != lastIndex) {
            _releasedTokenIds[index] = _releasedTokenIds[lastIndex];
        }
        _releasedTokenIds.pop();
    }

    /// @notice Removes an element from _withdrawnTokenIds by index (swap-and-pop).
    /// @param index Index to remove.
    function _removeWithdrawn(uint256 index) internal {
        uint256 lastIndex = _withdrawnTokenIds.length - 1;
        if (index != lastIndex) {
            _withdrawnTokenIds[index] = _withdrawnTokenIds[lastIndex];
        }
        _withdrawnTokenIds.pop();
    }

    /// @notice Picks an actor different from `exclude`.
    /// @param exclude Address to exclude from selection.
    /// @param seed Seed for selecting among remaining actors.
    /// @return actor A different actor, or address(0) if none found.
    function _pickDifferentActor(
        address exclude,
        uint256 seed
    )
        internal
        view
        returns (address actor)
    {
        uint256 length = actors.length;
        for (uint256 i; i < length; ++i) {
            address candidate = actors[(seed + i) % length];
            if (candidate != exclude) return candidate;
        }
        return address(0);
    }

    /// @notice Allows the handler to receive ETH refunds.
    receive() external payable {}
}
