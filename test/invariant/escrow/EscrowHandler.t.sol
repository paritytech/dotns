// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test, Vm} from "forge-std/Test.sol";
import {
    DotnsRegistrarController,
    IDotnsRegistrarController
} from "../../../contracts/registrars/DotnsRegistrarController.sol";
import {DotnsRegistrar} from "../../../contracts/registrars/DotnsRegistrar.sol";
import {DotnsNameEscrow, IDotnsNameEscrow} from "../../../contracts/escrow/DotnsNameEscrow.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {IPersonhood} from "../../../contracts/external/personhood/IPersonhood.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";

/// @title Escrow Handler
/// @notice Handler contract that executes bounded random actions against the escrow.
/// @dev Maintains ghost state to track deposits, releases, withdrawals, cross-tier
///      registrations, fee-charging transfers, and pull-payment claims for invariant checks.
contract EscrowHandler is Test {
    /// @notice Namehash of the .dot TLD.
    bytes32 private constant DOT_NODE =
        0x3fce7d1364a893e213bc4212792b517ffc88f5b13b86c8ef9c8d390c3a1370ce;

    /// @notice Escrow cooldown period used by handler-driven flows; mirrors the
    ///         test base and the deploy script so warps to clear the cooldown stay
    ///         consistent with the escrow's enforced upper bound.
    uint256 private constant ESCROW_COOLDOWN = 15 minutes;

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

    /// @notice Label used to register each tokenId; required for re-registration after finalise.
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

        _mockPersonhoodTier(actor, IPopRules.PopStatus.NoStatus);

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
            _mockPersonhoodTier(payer, IPopRules.PopStatus.NoStatus);
            _mockPersonhoodTier(ownerAddr, IPopRules.PopStatus.NoStatus);
        } else if (mode == 1) {
            _mockPersonhoodTier(payer, IPopRules.PopStatus.PopFull);
            _mockPersonhoodTier(ownerAddr, IPopRules.PopStatus.NoStatus);
        } else if (mode == 2) {
            _mockPersonhoodTier(payer, IPopRules.PopStatus.NoStatus);
            _mockPersonhoodTier(ownerAddr, IPopRules.PopStatus.PopLite);
        } else if (mode == 3) {
            _mockPersonhoodTier(payer, IPopRules.PopStatus.PopFull);
            _mockPersonhoodTier(ownerAddr, IPopRules.PopStatus.PopFull);
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
        // `payerPrice` is read for documentation continuity even though the A1
        // max-not-sum charge no longer adds it on top of `ownerPrice`. Bind into
        // a local so the read is observable in traces and a future branch
        // expansion can reuse it without re-reading from the oracle.
        uint256 payerPrice = popRules.priceWithoutCheck(label, payer).price;
        payerPrice;

        // Under the A1 max-not-sum rule the controller charges
        // `max(priced.price, friction)` on the cross-payer path and routes the
        // whole charge into the insurance fund via `depositInsurance`. The
        // refundable deposit position is seeded at zero amount, so the only
        // mutation invariant tracking has to mirror here is the insurance leg.
        uint256 priorInsurance = escrow.insuranceFund();
        bytes32 labelhash = keccak256(bytes(label));
        bytes32 node = keccak256(abi.encodePacked(DOT_NODE, labelhash));
        uint256 tokenId = uint256(node);

        // The handler picks the registrar's required value live so it stays in
        // sync with whatever the A1 formula returns for the current tier mix.
        // `priceWithoutCheck` gives the owner-side price and `transferFloor`
        // returns the payer-to-owner friction; the max collapses both into the
        // single charge the controller demands.
        uint256 frictionForCharge = popRules.transferFloor(label, payer, ownerAddr);
        uint256 charge = ownerPrice > frictionForCharge ? ownerPrice : frictionForCharge;

        // Skip when no value moves: a zero charge produces a free zero-amount
        // position with no insurance or reserves delta, so adding it to the
        // ghost-state token set adds noise without exercising any new branch.
        if (charge == 0) return;

        vm.recordLogs();
        vm.prank(payer);
        try controller.register{value: charge}(registration) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 newInsurance = escrow.insuranceFund();

            _depositedTokenIds.push(tokenId);
            labelByTokenId[tokenId] = label;
            // Cross-payer registrations seed a zero-amount refundable position;
            // ghost-state mirrors that by leaving `depositAmounts` at zero.
            depositAmounts[tokenId] = 0;

            if (newInsurance > priorInsurance) {
                ghost_insurancePaidIn += (newInsurance - priorInsurance);
            }

            // Track InsuranceDraw outflows surfaced by this transaction (defensive; the
            // register path itself does not draw insurance, but recordLogs is already on).
            _accountInsuranceDraws(logs);
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

        // Zero-amount positions are released too. They used to be skipped here, which meant the
        // fuzzer never explored the exact state the reclaim deadlock lived in: a released position
        // with nothing to withdraw, and therefore no reason for its holder ever to call `withdraw`.
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

    /// @notice Redeems a released token back to its previous holder inside the redeem window.
    /// @dev Picks from `_releasedTokenIds` and only acts while the position is still redeemable
    ///      (released, unwithdrawn, inside the window). Moves the token back to
    ///      `_depositedTokenIds` because a redeem restores the pre-release state exactly: the
    ///      deposit is still locked and the name is releasable again. No value moves, so no ghost
    ///      accounting changes.
    /// @param tokenSeed Seed for selecting which released token to redeem.
    function redeemReleased(uint256 tokenSeed) external {
        if (_releasedTokenIds.length == 0) return;

        uint256 index = tokenSeed % _releasedTokenIds.length;
        uint256 tokenId = _releasedTokenIds[index];

        IDotnsNameEscrow.ReleasePosition memory position = escrow.getReleasePosition(tokenId);
        if (!position.released || position.claimed) return;
        if (block.timestamp >= position.redeemableUntil) return;

        vm.prank(position.recipient);
        escrow.redeem(tokenId);

        _depositedTokenIds.push(tokenId);
        _removeReleased(index);
    }

    /// @notice Re-registers a released token whose window elapsed, without any prior withdrawal.
    /// @dev The path the old `released && claimed` gate made unreachable, and the reason this
    ///      action exists separately from `reRegisterReclaimed`: that one draws from
    ///      `_withdrawnTokenIds`, so nothing ever exercised reclaim against an unwithdrawn
    ///      position. Reclaim settles any outstanding deposit onto the previous recipient's
    ///      pull-payment balance, so the credit is mirrored into `ghost_pendingCredits`.
    /// @param tokenSeed Seed for selecting which released token to re-register.
    /// @param actorSeed Seed selecting the new registrant.
    function reRegisterReleased(uint256 tokenSeed, uint256 actorSeed) external {
        if (_releasedTokenIds.length == 0 || actors.length == 0) return;

        uint256 index = tokenSeed % _releasedTokenIds.length;
        uint256 tokenId = _releasedTokenIds[index];
        string memory label = labelByTokenId[tokenId];
        address actor = actors[actorSeed % actors.length];

        IDotnsNameEscrow.ReleasePosition memory position = escrow.getReleasePosition(tokenId);
        if (!position.released) return;
        if (block.timestamp < position.redeemableUntil) {
            vm.warp(position.redeemableUntil);
        }

        // Outstanding value on the position is what reclaim will settle. A position already
        // withdrawn carries a zero amount, so this is naturally zero for those.
        uint256 outstanding = position.amount;

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

        vm.recordLogs();
        vm.prank(actor);
        try controller.register{value: price}(registration) {
            Vm.Log[] memory logs = vm.getRecordedLogs();

            _removeReleased(index);
            _depositedTokenIds.push(tokenId);
            depositAmounts[tokenId] = price;
            depositRecipients[tokenId] = address(0);
            labelByTokenId[tokenId] = label;

            ghost_pendingCredits += outstanding;
            _accountInsuranceDraws(logs);
        } catch {
            return;
        }
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

        _mockPersonhoodTier(actor, IPopRules.PopStatus(status));
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

    /// @notice Re-registers a withdrawn (reclaim-ready) name with a (possibly different) actor.
    /// @dev Exercises the full-cycle custody reuse path: register → release → withdraw →
    /// reclaim.
    ///      The controller's `register()` routes through `escrow.reclaim()` automatically when
    ///      the token is in escrow custody; no separate finalise step exists.
    /// @param tokenSeed Seed for selecting which withdrawn token to reclaim.
    /// @param actorSeed Seed for selecting the new registrant.
    function reRegisterReclaimed(uint256 tokenSeed, uint256 actorSeed) external {
        if (_withdrawnTokenIds.length == 0 || actors.length == 0) return;

        uint256 index = tokenSeed % _withdrawnTokenIds.length;
        uint256 tokenId = _withdrawnTokenIds[index];
        string memory label = labelByTokenId[tokenId];
        address actor = actors[actorSeed % actors.length];

        // Reclaim is gated on the redeem window, not on the withdrawal. Without this warp every
        // attempt would revert NotReclaimable and be swallowed by the try/catch below, so the
        // action would look like it was running while covering nothing.
        IDotnsNameEscrow.ReleasePosition memory position = escrow.getReleasePosition(tokenId);
        if (block.timestamp < position.redeemableUntil) {
            vm.warp(position.redeemableUntil);
        }

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
        } catch {
            return;
        }
    }

    /// @notice Transfers a deposited token to a different actor without paying a cross-tier fee.
    /// @dev Plain transferFrom path; no fee branch is hit because escrow custody is not
    ///      involved and tier prices may match. Used to exercise the position-rebind path that
    ///      moves `position.recipient` to the new holder on every NFT transfer.
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
        try registrar.transferFrom(currentOwner, recipient, tokenId) {
            // Sync the amount as a safety net against future downgrade paths that
            // might shrink it. Under the deposit-follows-name design the position
            // rebinds to the new holder on every transfer; the locked amount itself
            // travels with the NFT, so on a zero-fee same-tier hop we expect both
            // the amount and the per-asset reserves to stay put.
            IDotnsNameEscrow.ReleasePosition memory pos = escrow.getReleasePosition(tokenId);
            depositAmounts[tokenId] = pos.amount;
        } catch {
            return;
        }
    }

    /// @notice Transfers a deposited token using payable `transferFrom`, exercising the
    ///         cross-tier fee path through `chargeTransferFee`.
    /// @dev Funds the call with whatever the registrar's `quoteTransferFee` returns, so the
    ///      handler stays drift-resistant against future fee additions. Revert-safe: returns
    ///      early when the recipient's price is zero (no fee path needed) or the inner call
    ///      reverts.
    /// @param tokenIdSeed Seed for selecting which deposited token to transfer.
    /// @param fromSeed Unused (current owner is derived on-chain). Retained for fuzzer entropy.
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

        // Use the registrar's own quote so the value attached matches whatever the
        // contract actually requires. This includes the reach-floor branch: when
        // the recipient's verification level is below the label's required tier,
        // the registrar charges the flat NoStatus deposit even though the
        // price-delta path returns zero. Using `quoteTransferFee` makes the handler
        // drift-resistant against future fee additions.
        uint256 requiredFee = registrar.quoteTransferFee(tokenId, to);
        if (requiredFee == 0) return;

        uint256 priorInsurance = escrow.insuranceFund();

        vm.recordLogs();
        vm.prank(currentOwner);
        try registrar.transferFrom{value: requiredFee}(currentOwner, to, tokenId) {
            Vm.Log[] memory logs = vm.getRecordedLogs();

            // Read the on-chain insurance delta rather than predicting it. The
            // chargeTransferFee path credits the reach floor to insurance; when
            // the NFT is leaving its prior position recipient the position is
            // rebound to the new holder rather than refunded, so reserves stay
            // put and only insurance moves. Mirroring the formula in the handler
            // would re-create the drift this guard is meant to prevent.
            uint256 newInsurance = escrow.insuranceFund();
            if (newInsurance > priorInsurance) {
                ghost_insurancePaidIn += (newInsurance - priorInsurance);
            }
            _accountInsuranceDraws(logs);

            // Sync the amount as a safety net against future downgrade paths.
            // Under the deposit-follows-name design the leaving-recipient branch
            // rebinds the position to the new holder rather than refunding, so
            // the locked amount and per-asset reserves stay put while the
            // recipient pointer moves.
            IDotnsNameEscrow.ReleasePosition memory pos = escrow.getReleasePosition(tokenId);
            depositAmounts[tokenId] = pos.amount;
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

    /// @notice Returns the sum of outstanding time-locked refund entries across all actors.
    /// @dev Used by the full-solvency invariant to capture overpayment refunds that
    ///      @custom:function chargeTransferFee credits via @custom:function _creditRefund when the
    ///      attached value exceeds the reach floor. Under the deposit-follows-name model the
    ///      deposit itself never lands on this ledger; only payer overpayments do. Iterates each
    ///      actor's entry list and sums each entry's amount.
    /// @return total Aggregate refund-ledger liability owed to the actor set.
    function totalPendingRefundEntries() external view returns (uint256 total) {
        uint256 length = actors.length;
        for (uint256 i; i < length; ++i) {
            address actor = actors[i];
            uint256 count = escrow.pendingRefundCount(actor);
            if (count == 0) continue;
            (, IDotnsNameEscrow.RefundEntry[] memory entries) =
                escrow.pendingRefunds(actor, 0, count);
            for (uint256 j; j < entries.length; ++j) {
                total += entries[j].amount;
            }
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
