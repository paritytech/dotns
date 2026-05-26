// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IDotnsController} from "./IDotnsController.sol";

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

    /// @notice Thrown when attempting to register a name whose base stem is reserved by another
    /// user.
    error NameReserved(string label);

    /// @notice Thrown when a label is not a canonical lowercase ASCII DNS label.
    error InvalidLabel();

    /// @notice Thrown when supplied payment is insufficient.
    error InsufficientValue();

    /// @notice Thrown when refund fails.
    error RefundFailed();

    /// @notice Thrown when escrow is not configured in the protocol registry.
    error EscrowNotConfigured();

    /// @notice Thrown when max commitment age is invalid (must be > minCommitmentAge).
    error MaxCommitmentAgeTooLow();

    /// @notice Thrown when max commitment age is invalid (exceeds implementation limit).
    error MaxCommitmentAgeTooHigh();

    /// @notice Thrown when an invalid Store instance is encountered.
    error InvalidStore();

    /// @notice Thrown when the caller is not the registry.
    error NotRegistry();

    /// @notice Returns whether a label is available for registration.
    /// @dev Validates the canonical DNS-label shape (otherwise @custom:reverts InvalidLabel)
    /// and rejects labels shorter than the minimum length with
    /// @custom:reverts NameNotAvailable before checking ERC721 availability on the registrar.
    function available(string calldata label) external view returns (bool isAvailable);

    /// @notice Computes the commitment hash for a registration.
    function makeCommitment(Registration calldata registration)
        external
        pure
        returns (bytes32 commitment);

    /// @notice Submits a commitment for a future registration.
    /// @dev Idempotent over expiry: re-committing an unexpired hash reverts with
    /// @custom:reverts UnexpiredCommitmentExists (front-running guard); re-committing a hash
    /// whose stored timestamp has passed `maxCommitmentAge` overwrites the slot so storage
    /// cannot be permanently griefed. Emits @custom:emits NameCommitted on success.
    function commit(bytes32 commitment) external;

    /// @notice Registers a name after the commitment delay.
    /// @dev Validates the label shape (otherwise @custom:reverts InvalidLabel) and ERC721
    /// availability (otherwise @custom:reverts NameNotAvailable), then resolves the configured
    /// escrow address from the protocol registry (otherwise @custom:reverts EscrowNotConfigured)
    /// and consumes the prior commitment, which fails with @custom:reverts CommitmentNotFound
    /// when no commitment exists for the supplied registration, @custom:reverts CommitmentTooNew
    /// before `minCommitmentAge`, and @custom:reverts CommitmentTooOld past `maxCommitmentAge`.
    /// Splits on direct vs cross-payer at `msg.sender == registration.owner`. The direct path
    /// runs `priceWithCheck` (personhood + reservation gate) and routes the fee to a refundable
    /// escrow deposit owned by `registration.owner`. The cross-payer path skips personhood
    /// (a third party may sponsor a verified owner), still enforces base-name reservations
    /// (otherwise @custom:reverts NameReserved), applies the flat NoStatus `reachFee` friction
    /// when the sender's own tier is below the label's required tier, and routes funds to the
    /// insurance branch when the payer's tier price differs from the owner's (genuine
    /// cross-tier sponsorship) versus the refundable branch when the tier prices match
    /// (same-tier-different-address). The caller must supply at least the priced amount plus
    /// any friction (otherwise @custom:reverts InsufficientValue), and any overpayment is
    /// returned to `msg.sender` with @custom:emits OverpaymentRefunded; a failed refund call
    /// reverts with @custom:reverts RefundFailed. Emits @custom:emits NameRegistered on success.
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
