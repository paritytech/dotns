// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IDotnsController} from "./IDotnsController.sol";
import {IPopRules} from "../pop/IPopRules.sol";

/// @title Dotns Registrar Controller
/// @notice Interface for registering .dot labels using a commit reveal scheme.
/// @dev Defines allocation only; forward resolution, reverse lookup, pricing mechanics, PoP
/// validation, and store writing are handled by external contracts. Users commit a hash of
/// registration parameters and, after a minimum delay, reveal the same parameters to register.
/// Implementations write the successfully registered name into the user's Store to create an
/// immutable on-chain record that doubles as a quick lookup for all names registered.
/// @custom:security-contact admin@parity.io
interface IDotnsRegistrarController is IDotnsController {
    /// @notice Parameters used to generate and reveal a commitment.
    /// @dev All fields must match exactly between commitment and reveal.
    /// @param label Label being registered (e.g. "alice").
    /// @param owner Beneficiary the registered name is minted to.
    /// @param secret Caller-chosen entropy that hides the registration intent in the commit
    /// hash; revealed verbatim at registration time.
    /// @param reserved True when the registration flows through the whitelisted reserved
    /// pipeline (`registerReserved`); false for the standard public flow (`register`).
    struct Registration {
        string label;
        address owner;
        bytes32 secret;
        bool reserved;
    }

    /// @notice Emitted when a commitment is submitted.
    event NameCommitted(bytes32 indexed commitment);

    /// @notice Emitted when a name is successfully registered.
    /// @param baseCost The price returned by the oracle for this registration.
    /// @param store The Store instance used to persist an immutable registration record.
    event NameRegistered(
        string indexed label,
        bytes32 indexed labelhash,
        address indexed owner,
        uint256 baseCost,
        address store
    );

    /// @notice Emitted when an address is added to or removed from the whitelist.
    event WhiteListed(address indexed who, bool indexed whiteListStatus);

    /// @notice Emitted when overpayment is refunded to the payer at registration entry.
    event OverpaymentRefunded(address indexed payer, uint256 amount);

    /// @notice Thrown when the caller is not whitelisted or the owner.
    error NotWhiteListedOrOwner(address caller);

    /// @notice Thrown when an unexpired commitment already exists.
    error UnexpiredCommitmentExists(bytes32 commitment);

    /// @notice Thrown when revealing a commitment that does not exist.
    error CommitmentNotFound(bytes32 commitment);

    /// @notice Thrown when a commitment is revealed before the minimum age.
    error CommitmentTooNew(bytes32 commitment, uint256 minTime, uint256 currentTime);

    /// @notice Thrown when a commitment has expired.
    error CommitmentTooOld(bytes32 commitment, uint256 maxTime, uint256 currentTime);

    /// @notice Thrown when attempting to register an unavailable name.
    error NameNotAvailable(string label);

    /// @notice Thrown when a label is below the minimum-length policy.
    /// @dev Distinct from @custom:reverts NameNotAvailable so off-chain consumers can tell a
    /// too-short label apart from a name that is already minted.
    /// @param label Caller-supplied label that failed the minimum-length policy.
    error LabelTooShort(string label);

    /// @notice Thrown when attempting to register a name whose base stem is held as a live
    /// reservation by another user.
    error NameReserved(string label);

    /// @notice Thrown when attempting to register a label that classifies as
    /// governance-reserved at the protocol level.
    /// @dev Distinct from @custom:reverts NameReserved so off-chain consumers can tell
    /// "wait for the holder to relinquish" apart from "this label is permanently held by
    /// governance".
    /// @param label Caller-supplied label that the rules engine classifies as governance-reserved.
    error GovernanceReserved(string label);

    /// @notice Thrown on the cross-payer path when the owner's recorded PoP tier does not
    /// meet the label's required tier. The direct path's @custom:contract IPopRules
    /// `priceWithCheck` covers this same condition via its own revert.
    /// @param label Label whose tier requirement was unmet.
    /// @param userStatus Owner's recorded tier.
    /// @param required Required tier for the label.
    error OwnerStatusInsufficient(
        string label, IPopRules.PopStatus userStatus, IPopRules.PopStatus required
    );

    /// @notice Thrown when a label is not a canonical lowercase ASCII DNS label.
    error InvalidLabel();

    /// @notice Thrown when supplied payment is insufficient.
    error InsufficientValue();

    /// @notice Thrown when escrow is not configured in the protocol registry.
    error EscrowNotConfigured();

    /// @notice Thrown when min commitment age is zero, which would allow same-block
    /// commit-reveal and defeat the front-running guard.
    error MinCommitmentAgeZero();

    /// @notice Thrown when max commitment age is invalid (must be > minCommitmentAge).
    error MaxCommitmentAgeTooLow();

    /// @notice Thrown when max commitment age is invalid (exceeds implementation limit).
    error MaxCommitmentAgeTooHigh();

    /// @notice Returns whether a label is available for registration.
    /// @dev Validates the canonical DNS-label shape (otherwise @custom:reverts InvalidLabel)
    /// and rejects labels below the minimum-length policy with
    /// @custom:reverts LabelTooShort before checking ERC721 availability on the registrar.
    function available(string calldata label) external view returns (bool isAvailable);

    /// @notice Computes the commitment hash for a registration.
    /// @dev Uses `abi.encode` so the variable-width `label` is length-prefixed and the boundary
    /// between `label` and the fixed-width `owner`, `secret`, and `reserved` fields is
    /// unambiguous, binding the commitment to the exact tuple.
    function makeCommitment(Registration calldata registration)
        external
        pure
        returns (bytes32 commitment);

    /// @notice Submits a commitment for a future registration.
    /// @dev Idempotent over expiry: re-committing an unexpired hash reverts with
    /// @custom:reverts UnexpiredCommitmentExists (front-running guard); a hash whose stored
    /// timestamp has passed `maxCommitmentAge` overwrites the slot so storage cannot be
    /// permanently griefed. The expiry boundary is inclusive on the commit side
    /// (`committedAt + maxCommitmentAge <= block.timestamp` overwrites) and exclusive on the
    /// reveal side (`register` rejects at the same instant with @custom:reverts
    /// CommitmentTooOld), so the slot is overwritable from exactly the timestamp at which
    /// reveal begins rejecting it. Emits @custom:emits NameCommitted on success.
    function commit(bytes32 commitment) external;

    /// @notice Registers a name after the commitment delay.
    /// @dev Validates the label shape (otherwise @custom:reverts InvalidLabel), rejects labels
    /// below the minimum length policy (@custom:reverts LabelTooShort), and ERC721 availability
    /// (otherwise @custom:reverts NameNotAvailable), then consumes the prior commitment, which
    /// fails with @custom:reverts CommitmentNotFound when no commitment exists for the supplied
    /// registration, @custom:reverts CommitmentTooNew before `minCommitmentAge`, and
    /// @custom:reverts CommitmentTooOld past `maxCommitmentAge`, and finally resolves the
    /// configured escrow address from the protocol registry (otherwise
    /// @custom:reverts EscrowNotConfigured). Splits on direct vs cross-payer at
    /// `msg.sender == registration.owner`. The direct path runs `priceWithCheck` (personhood
    /// + reservation gate) and routes the charge to a refundable escrow deposit owned by
    /// `registration.owner`. The cross-payer path skips the personhood revert in
    /// `priceWithCheck` but applies it directly via @custom:reverts OwnerStatusInsufficient
    /// when the owner's recorded tier does not meet the label's required tier, and still
    /// rejects governance-reserved labels with @custom:reverts GovernanceReserved and live
    /// cross-user stem reservations with @custom:reverts NameReserved. The total
    /// charge on the cross-payer path is the greater of the owner-side registration price and
    /// the owner-tier `transferFloor` friction (never their sum); friction is computed against
    /// the owner's tier so a verified payer cannot pay around an unverified owner. The entire
    /// charge routes to the escrow insurance fund while seeding a zero-amount deposit slot so
    /// the release lifecycle stays reachable. The caller must supply at least the charge
    /// (otherwise @custom:reverts InsufficientValue); any overpayment is pushed back to
    /// `msg.sender` inline and, on failure, credited to the escrow's pull-payment ledger so
    /// contract receivers cannot block registration. Emits @custom:emits OverpaymentRefunded
    /// on the inline branch, the escrow's own @custom:emits OverpaymentRefunded on the pull
    /// fallback, and @custom:emits NameRegistered on success.
    function register(Registration calldata registration) external payable;

    /// @notice Registers a name after the commitment delay.
    /// @dev Whitelisted issuance path used to seed reserved labels at zero base cost: skips the
    /// PoP price check and the escrow deposit, but reuses the same commit-reveal pipeline so
    /// the same anti-front-running guarantees apply. Restricted to whitelisted callers and the
    /// owner (otherwise @custom:reverts NotWhiteListedOrOwner). Validates the label shape
    /// (otherwise @custom:reverts InvalidLabel) and ERC721 availability (otherwise
    /// @custom:reverts NameNotAvailable), then consumes the prior commitment, which fails with
    /// @custom:reverts CommitmentNotFound, @custom:reverts CommitmentTooNew, or
    /// @custom:reverts CommitmentTooOld under the same conditions as @custom:function register.
    /// Emits
    /// @custom:emits NameRegistered on success.
    function registerReserved(Registration calldata registration) external;

    /// @notice Checks if the given address is whitelisted to call `registerReserved`.
    function isWhiteListed(address who) external view returns (bool isWhiteListed);

    /// @notice Adds or removes an address from the whitelist for `registerReserved`.
    /// @dev Callable by the owner or an account holding `DotnsConstants.WHITELIST_OPERATOR_ROLE`;
    /// any other caller reverts with @custom:reverts IDotnsRoleManager.NotRoleOrOwner. Emits
    /// @custom:emits WhiteListed on success.
    function whiteListAddress(address who, bool whiteListStatus) external;
}
