// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {
    DotnsRegistrarController,
    IDotnsRegistrarController
} from "../../../contracts/registrars/DotnsRegistrarController.sol";
import {DotnsRegistrar} from "../../../contracts/registrars/DotnsRegistrar.sol";
import {DotnsNameEscrow, IDotnsNameEscrow} from "../../../contracts/escrow/DotnsNameEscrow.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

/// @title Escrow Handler
/// @notice Handler contract that executes bounded random actions against the escrow.
/// @dev Maintains ghost state to track deposits, releases, withdrawals, cross-tier
///      registrations, fee-charging transfers, and pull-payment claims for invariant checks.
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

    /// @notice Recipient locked at deposit-time per tokenId (mirrors `_positions[id].recipient`).
    /// @dev Distinct from `depositRecipients`, which only fills at release time. This snapshots
    ///      the address that paid the deposit so the recipient-locked invariant can verify the
    ///      escrow position never mutates the lock between deposit and reclaim.
    mapping(uint256 tokenId => address recipient) public lockedRecipient;

    /// @notice Last observed runningMax per tokenId (refreshed after deposit and payable transferFrom).
    /// @dev Used by the runningMax-monotonicity invariant to confirm the on-chain runningMax
    ///      only ever climbs between mint and reclaim, then resets to zero on reclaim.
    mapping(uint256 tokenId => uint256 max) public lastObservedRunningMax;

    /// @notice Label used to register each tokenId — required for re-registration after finalise.
    mapping(uint256 tokenId => string label) public labelByTokenId;

    /// @notice Cumulative native amount credited into the insurance fund by handler-driven flows.
    /// @dev Increments via cross-tier register (`depositInsurance`) and payable `transferFrom`
    ///      (`chargeTransferFee`). Counterpart to `ghost_insurancePaidOut`.
    uint256 public ghost_insurancePaidIn;

    /// @notice Cumulative native amount drawn out of the insurance fund.
    /// @dev Updated by parsing `InsuranceDraw` events emitted from `withdraw()`. The
    ///      conservation invariant asserts `ghost_insurancePaidIn - ghost_insurancePaidOut
    ///      == escrow.insuranceFund()`.
    uint256 public ghost_insurancePaidOut;

    /// @notice Cumulative native amount credited to recipients via `withdraw()`.
    uint256 public ghost_pendingCredits;

    /// @notice Cumulative native amount drained by recipients via `claimWithdrawal()`.
    uint256 public ghost_pendingPulls;

    /// @notice List of actor addresses used for testing.
    address[] public actors;

    /// @notice Counter for generating unique labels.
    uint256 public labelNonce;

    /// @notice Initialises the handler with protocol contracts.
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
    ///      Tracks the tokenId and deposit amount in ghost state. Only valid for the
    ///      direct (`msg.sender == owner`) NoStatus path; cross-tier behaviour is
    ///      exercised by `registerCrossTier`.
    /// @param actorSeed Seed for selecting an actor.
    function commitRegisterAndDeposit(uint256 actorSeed) external {
        if (actors.length == 0) return;

        address actor = actors[actorSeed % actors.length];
        string memory label = _generateUniqueLabel();

        vm.prank(actor);
        popRules.setUserPopStatus(IPopRules.PopStatus.NoStatus);

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

        if (price == 0) return;

        // Compute tokenId
        bytes32 labelhash = keccak256(bytes(label));
        bytes32 node = keccak256(abi.encodePacked(DOT_NODE, labelhash));
        uint256 tokenId = uint256(node);

        // Update ghost state
        _depositedTokenIds.push(tokenId);
        depositAmounts[tokenId] = price;
        labelByTokenId[tokenId] = label;
        lockedRecipient[tokenId] = actor;
        if (price > lastObservedRunningMax[tokenId]) {
            lastObservedRunningMax[tokenId] = price;
        }
    }

    /// @notice Performs a cross-tier registration where payer != owner.
    /// @dev Bounds inputs with `bound()` to keep handler runs within meaningful state.
    ///      Picks a payer and an owner from the actor set (different where possible),
    ///      randomly aligns or splits their PoP statuses, and dispatches the controller
    ///      `register()` call from the payer. Routes to the deposit, depositInsurance,
    ///      or skip branch depending on the resulting tier prices. Revert-safe: if the
    ///      computed price is zero on both sides (PoPLite/PoPFull no-cost path) the call
    ///      still completes but ghost state is only updated where state actually changed.
    /// @param ownerSeed Seed selecting the registrant.
    /// @param payerSeed Seed selecting the payer.
    /// @param statusSeed Seed selecting the random tier-elevation policy.
    function registerCrossTier(uint256 ownerSeed, uint256 payerSeed, uint256 statusSeed) external {
        if (actors.length < 2) return;

        address payer = actors[ownerSeed % actors.length];
        address ownerAddr = _pickDifferentActor(payer, payerSeed);
        if (ownerAddr == address(0)) return;

        // Tier-status assignment: 0 = both NoStatus, 1 = elevate payer to PopFull,
        // 2 = elevate owner to PopLite, 3 = elevate both (no fee differential).
        uint256 mode = bound(statusSeed, 0, 3);
        if (mode == 0) {
            vm.prank(payer);
            popRules.setUserPopStatus(IPopRules.PopStatus.NoStatus);
            vm.prank(ownerAddr);
            popRules.setUserPopStatus(IPopRules.PopStatus.NoStatus);
        } else if (mode == 1) {
            vm.prank(payer);
            popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);
            vm.prank(ownerAddr);
            popRules.setUserPopStatus(IPopRules.PopStatus.NoStatus);
        } else if (mode == 2) {
            vm.prank(payer);
            popRules.setUserPopStatus(IPopRules.PopStatus.NoStatus);
            vm.prank(ownerAddr);
            popRules.setUserPopStatus(IPopRules.PopStatus.PopLite);
        } else if (mode == 3) {
            vm.prank(payer);
            popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);
            vm.prank(ownerAddr);
            popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);
        }

        string memory label = _generateUniqueLabel();
        bytes32 secret = keccak256(abi.encodePacked(label, ownerAddr, block.timestamp, labelNonce));

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label, owner: ownerAddr, secret: secret, reserved: true
            });

        bytes32 commitment = controller.makeCommitment(registration);

        vm.prank(payer);
        controller.commit(commitment);

        uint256 minAge = controller.minCommitmentAge();
        vm.warp(block.timestamp + minAge + 1);

        // Cross-tier path uses priceWithoutCheck for the owner.
        uint256 ownerPrice = popRules.priceWithoutCheck(label, ownerAddr).price;
        uint256 payerPrice = popRules.priceWithoutCheck(label, payer).price;

        // Skip when there is nothing to register: zero owner price with no fee differential
        // skips the deposit branches entirely and `register()` still mints. Tracking it via
        // ghost state would falsely inflate reserves.
        if (ownerPrice == 0) return;

        // The escrow records the call value as a cross-tier insurance deposit if the
        // payer and owner price tiers differ; otherwise the value backs a refundable
        // deposit position with the owner as the locked refund recipient.
        uint256 priorInsurance = escrow.insuranceFund();
        bytes32 labelhash = keccak256(bytes(label));
        bytes32 node = keccak256(abi.encodePacked(DOT_NODE, labelhash));
        uint256 tokenId = uint256(node);

        vm.recordLogs();
        vm.prank(payer);
        try controller.register{value: ownerPrice}(registration) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 newInsurance = escrow.insuranceFund();

            _depositedTokenIds.push(tokenId);
            labelByTokenId[tokenId] = label;
            depositAmounts[tokenId] = ownerPrice;

            if (newInsurance > priorInsurance) {
                // Cross-tier (different prices): funds went into the insurance fund and there
                // is no refundable position. We must not double-count `ownerPrice` as both
                // reserves (deposit) and insurance — leave depositAmounts at zero in that case.
                depositAmounts[tokenId] = 0;
                ghost_insurancePaidIn += (newInsurance - priorInsurance);
                lockedRecipient[tokenId] = address(0);
            } else if (payerPrice == ownerPrice) {
                // Same-tier-different-address: refundable deposit with owner as recipient.
                lockedRecipient[tokenId] = ownerAddr;
            }

            // Track InsuranceDraw outflows surfaced by this transaction (defensive — the
            // register path itself does not draw insurance, but recordLogs is already on).
            _accountInsuranceDraws(logs);

            uint256 currentMax = escrow.runningMax(tokenId);
            if (currentMax > lastObservedRunningMax[tokenId]) {
                lastObservedRunningMax[tokenId] = currentMax;
            }
        } catch {
            return;
        }
    }

    /// @notice Releases a deposited token into escrow.
    /// @dev Picks from _depositedTokenIds (if any), approves escrow, releases.
    ///      Moves the token to _releasedTokenIds and snapshots the recipient.
    /// @param tokenSeed Seed for selecting which deposited token to release.
    function releaseToken(uint256 tokenSeed) external {
        if (_depositedTokenIds.length == 0) return;

        uint256 index = tokenSeed % _depositedTokenIds.length;
        uint256 tokenId = _depositedTokenIds[index];

        // Only release if the deposit has a non-zero amount (NoStatus names with a refundable position)
        if (depositAmounts[tokenId] == 0) {
            _removeDeposited(index);
            return;
        }

        address tokenOwner = registrar.ownerOf(tokenId);

        IDotnsNameEscrow.ReleasePosition memory positionBefore = escrow.getReleasePosition(tokenId);
        address recipient = positionBefore.recipient;
        if (recipient == address(0)) {
            _removeDeposited(index);
            return;
        }

        // If custody has moved away from the locked recipient, the current holder
        // authorises that recipient to initiate the cooperative release path.
        vm.prank(tokenOwner);
        registrar.approve(address(escrow), tokenId);

        if (recipient != tokenOwner) {
            vm.prank(tokenOwner);
            registrar.setApprovalForAll(recipient, true);
        }

        // Release the token into escrow
        vm.prank(recipient);
        escrow.release(tokenId);

        // Update ghost state
        depositRecipients[tokenId] = recipient;
        _releasedTokenIds.push(tokenId);
        _removeDeposited(index);
    }

    /// @notice Withdraws refund for a released token after cooldown.
    /// @dev Picks from _releasedTokenIds, warps past cooldown, withdraws.
    ///      Moves the token to _withdrawnTokenIds. Records pending credits and any
    ///      `InsuranceDraw` event amounts via `vm.recordLogs`.
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

        uint256 owed = position.amount;

        vm.recordLogs();
        vm.prank(recipient);
        escrow.withdraw(tokenId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Update ghost state after the inner call so a revert leaves accounting intact.
        _withdrawnTokenIds.push(tokenId);
        _removeReleased(index);
        ghost_pendingCredits += owed;
        _accountInsuranceDraws(logs);
    }

    /// @notice Pulls the caller's accumulated pending refund balance.
    /// @dev Walks the actor list, picks one with a non-zero pending balance, and calls
    ///      `claimWithdrawal()` from that actor. Revert-safe: returns early when there is
    ///      no pending balance to claim. Records the claimed amount into `ghost_pendingPulls`
    ///      after the inner call succeeds.
    /// @param actorSeed Seed selecting the actor.
    function claim(uint256 actorSeed) external {
        if (actors.length == 0) return;

        uint256 length = actors.length;
        for (uint256 i; i < length; ++i) {
            address candidate = actors[(actorSeed + i) % length];
            uint256 pending = escrow.pendingWithdrawal(candidate);
            if (pending == 0) continue;

            vm.prank(candidate);
            try escrow.claimWithdrawal() returns (uint256 amount) {
                ghost_pendingPulls += amount;
            } catch {
                // Pending balance may have been drained externally; nothing to update.
            }
            return;
        }
    }

    /// @notice Sets a random PoP status for an actor mid-run.
    /// @dev Bound: 0 = NoStatus, 1 = PopLite, 2 = PopFull. Allows the fuzzer to flip
    ///      tiers between handler calls so subsequent registrations and transfers exercise
    ///      every routing branch.
    /// @param actorSeed Seed selecting the actor whose status flips.
    /// @param statusSeed Seed selecting the new status.
    function setRandomPopStatus(uint256 actorSeed, uint256 statusSeed) external {
        if (actors.length == 0) return;

        address actor = actors[actorSeed % actors.length];
        uint256 status = bound(statusSeed, 0, 2);

        vm.prank(actor);
        popRules.setUserPopStatus(IPopRules.PopStatus(status));
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
        try controller.register{value: price}(registration) {
            _removeWithdrawn(index);
            _depositedTokenIds.push(tokenId);
            depositAmounts[tokenId] = price;
            depositRecipients[tokenId] = address(0);
            labelByTokenId[tokenId] = label;
            // Reclaim resets runningMax on-chain; mirror that into ghost state.
            lastObservedRunningMax[tokenId] = price;
            lockedRecipient[tokenId] = price == 0 ? address(0) : actor;
        } catch {
            return;
        }
    }

    /// @notice Transfers a deposited token to a different actor without paying a cross-tier fee.
    /// @dev Plain transferFrom path — no fee branch is hit because escrow custody is not
    ///      involved and tier prices may match. Used to seed the recipient-locked invariant
    ///      (the locked recipient must NOT change despite NFT custody moving).
    /// @param tokenSeed Seed for selecting which deposited token to transfer.
    /// @param actorSeed Seed for selecting the recipient.
    function transferDeposited(uint256 tokenSeed, uint256 actorSeed) external {
        if (_depositedTokenIds.length == 0 || actors.length < 2) return;

        uint256 index = tokenSeed % _depositedTokenIds.length;
        uint256 tokenId = _depositedTokenIds[index];

        // Zero-value transfer path: skip whenever the registrar's quote returns a
        // non-zero fee. The quote folds in both the price-delta path and the
        // reach-floor path, so the handler stays in sync with whatever fee
        // branches the contract grows over time.
        string memory label = labelByTokenId[tokenId];
        // Read once for documentation continuity; the actual gating check uses the quote.
        label;
        address currentOwner = registrar.ownerOf(tokenId);
        address recipient = _pickDifferentActor(currentOwner, actorSeed);
        if (recipient == address(0)) return;

        if (registrar.quoteTransferFee(tokenId, recipient) != 0) return;

        vm.prank(currentOwner);
        try registrar.transferFrom(currentOwner, recipient, tokenId) {}
        catch {
            return;
        }
    }

    /// @notice Transfers a deposited token using payable `transferFrom`, exercising the
    ///         cross-tier fee path through `chargeTransferFee`.
    /// @dev Bounds inputs and computes the recipient-tier delta against `runningMax` so
    ///      the call is funded with exactly the required charge. Revert-safe: returns
    ///      early when the recipient's price is zero (no fee path needed) or the inner
    ///      call reverts.
    /// @param tokenIdSeed Seed for selecting which deposited token to transfer.
    /// @param fromSeed Unused — current owner is derived on-chain. Retained for fuzzer entropy.
    /// @param toSeed Seed for selecting the recipient.
    function transferPayable(uint256 tokenIdSeed, uint256 fromSeed, uint256 toSeed) external {
        // `fromSeed` injects fuzzer entropy without overriding the registrar's required
        // ownership check. Read it once so the parameter is not unused.
        fromSeed;

        if (_depositedTokenIds.length == 0 || actors.length < 2) return;

        uint256 index = tokenIdSeed % _depositedTokenIds.length;
        uint256 tokenId = _depositedTokenIds[index];
        string memory label = labelByTokenId[tokenId];
        if (bytes(label).length == 0) return;

        address currentOwner = registrar.ownerOf(tokenId);
        address to = _pickDifferentActor(currentOwner, toSeed);
        if (to == address(0)) return;

        uint256 priceForTo = popRules.priceWithoutCheck(label, to).price;
        if (priceForTo == 0) return;

        // Use the registrar's own quote so the value attached matches whatever the
        // contract actually requires. This includes the reach-floor branch: when
        // the recipient's verification level is below the label's required tier,
        // the registrar charges the length-scaled NoStatus rate even though the
        // price-delta path returns zero. Using `quoteTransferFee` makes the handler
        // drift-resistant against future fee additions.
        uint256 requiredFee = registrar.quoteTransferFee(tokenId, to);
        if (requiredFee == 0) return;

        uint256 priorInsurance = escrow.insuranceFund();

        vm.recordLogs();
        vm.prank(currentOwner);
        try registrar.transferFrom{value: requiredFee}(currentOwner, to, tokenId) {
            Vm.Log[] memory logs = vm.getRecordedLogs();

            // Read the on-chain insurance delta rather than predicting it. The contract
            // credits `max(priceForTo - prior, reachFloor)` to insurance; mirroring that
            // formula in the handler would re-create the very drift this guard is meant
            // to prevent.
            uint256 newInsurance = escrow.insuranceFund();
            if (newInsurance > priorInsurance) {
                ghost_insurancePaidIn += (newInsurance - priorInsurance);
            }
            uint256 newMax = escrow.runningMax(tokenId);
            if (newMax > lastObservedRunningMax[tokenId]) {
                lastObservedRunningMax[tokenId] = newMax;
            }
            _accountInsuranceDraws(logs);
        } catch {
            return;
        }
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

    /// @notice Returns the registered actor set.
    /// @return list Array of actor addresses.
    function getActors() external view returns (address[] memory list) {
        list = actors;
    }

    /// @notice Returns the sum of pending pull-payment balances across all actors.
    /// @dev Used by the full-solvency invariant to assert escrow native balance covers
    ///      `reserves + insuranceFund + outstanding-pending-balances`.
    /// @return total Aggregate pending balance owed to the actor set.
    function totalPendingWithdrawals() external view returns (uint256 total) {
        uint256 length = actors.length;
        for (uint256 i; i < length; ++i) {
            total += escrow.pendingWithdrawal(actors[i]);
        }
    }

    /// @notice Generates a unique label of 10+ characters for registration.
    /// @dev Uses incrementing nonce to ensure uniqueness across calls.
    /// @return label A unique label string with minimum 10 characters.
    function _generateUniqueLabel() internal returns (string memory label) {
        label = string(abi.encodePacked("escrowname", vm.toString(labelNonce), "x12"));
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

    /// @notice Scans recorded logs for `InsuranceDraw` events and accumulates the amount
    ///         drawn into `ghost_insurancePaidOut`.
    /// @dev Single canonical accounting helper used by every handler call that may trigger a draw
    ///      (currently `withdraw()`). Other inner calls forward an empty log array, which
    ///      is a no-op.
    /// @param logs Recorded logs from the most recent inner call.
    function _accountInsuranceDraws(Vm.Log[] memory logs) internal {
        // keccak256("InsuranceDraw(uint256,uint256)")
        bytes32 sig = keccak256("InsuranceDraw(uint256,uint256)");
        uint256 length = logs.length;
        for (uint256 i; i < length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(escrow)) continue;
            if (entry.topics.length == 0 || entry.topics[0] != sig) continue;
            uint256 amount = abi.decode(entry.data, (uint256));
            ghost_insurancePaidOut += amount;
        }
    }

    /// @notice Allows the handler to receive ETH refunds.
    receive() external payable {}
}
