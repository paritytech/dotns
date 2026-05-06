// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";

/// @title Proof of Personhood Rules for Dotns
/// @notice Proof of personhood interface defining Dotns price calculation, PoP-tier requirements,
/// and base-name reservation rules @dev Provides the classification logic for Dotns labels,
/// enforces suffix constraints, and exposes reservation metadata.
///      Names are evaluated according to the following rules:
///      • Length ≤ 5: Reserved
///      • Length 6–8 without trailing digits: PopFull required
///      • Length 6–8 with 2 trailing digits: PopLite required
///      • Length ≥ 9 without trailing digits: PopFull required
///      • Length ≥ 9 with 2 trailing digits: NoStatus (open)
///      Trailing digits beyond 2 are invalid. Internal digits do not affect classification.
///      Reservation rules apply to a label stripped of trailing digits.
///      Its also important to note that for Pop Full there are no restrictions to name
/// registrations any Character combination is valid, the same is valid for Light and No status
/// users with the exception of
///      Requiring 2 suffix digits appended to the username being registered
/// @dev The pricing applied is mainly for POP No status users as measure to prevent spam
/// @custom:security-contact admin@parity.io
interface IPopRules {
    /// @notice Proof-of-Personhood eligibility tier.
    /// @dev Defines verification requirements for a given name classification.
    ///      `NoStatus` is the default for unverified users; `PopLite` and
    ///      `PopFull` correspond to the two personhood tiers; `Reserved` is
    ///      used both for governance-held names and for base stems held by
    ///      another user through the reservation table.
    enum PopStatus {
        NoStatus,
        PopLite,
        PopFull,
        Reserved
    }

    /// @notice Emitted when a base name receives a reservation.
    /// @param baseName The digit-stripped label receiving the reservation.
    /// @param owner Address obtaining the reservation right.
    /// @param expires UNIX timestamp when the reservation expires.
    event BaseNameReserved(string indexed baseName, address indexed owner, uint64 expires);

    /// @notice Emitted when a user's PoP status is updated.
    /// @dev Temporary until a precompile exposes PoP status directly from the pallet.
    /// @param user Address of the user.
    /// @param status New PoP tier assigned.
    event UserPopStatusSet(address indexed user, PopStatus status);

    /// @notice Emitted when the spam-deterrent starting price is changed by the owner.
    /// @dev `startingPrice` is the wei-denominated base used by `_priceValidatedName`
    ///      to compute the NoStatus length curve. A change takes effect on the next
    ///      `priceWithCheck` / `priceWithoutCheck` call — no redeploy.
    /// @param oldPrice Previous wei value.
    /// @param newPrice New wei value.
    event StartingPriceUpdated(uint256 oldPrice, uint256 newPrice);

    /// @notice Thrown when a name violates PoP-tier or reservation requirements.
    /// @param reason Human-readable explanation of the failure condition.
    error PopError(string reason);

    /// @notice Thrown when a caller is not an authorised controller on the registrar.
    error NotRegistry();

    /// @notice Bundle returned from metadata-aware pricing queries.
    /// @param price Registration cost; typically non-zero only for NoStatus users.
    /// @param status Required PoP tier for this name.
    /// @param userStatus Current PoP status recorded for the querying user.
    /// @param message Human-readable classification description.
    struct PriceWithMeta {
        uint256 price;
        PopStatus status;
        PopStatus userStatus;
        string message;
    }

    /// @notice Reservation metadata for a base name (digits removed).
    /// @param owner Address holding exclusive claim rights during the reservation window.
    /// @param expires UNIX timestamp when the reservation expires.
    /// @param controller Address that wrote the reservation; the only address
    ///        permitted to release it before expiry.
    struct Reservation {
        address owner;
        uint64 expires;
        address controller;
    }

    /// @notice Classifies a name into a required PoP tier per DotNS naming rules.
    /// @dev Pure; inputs are the label bytes only. Callers use the returned
    ///      tier to decide which pricing and verification branch applies.
    /// @param name The name label being evaluated.
    /// @return requirement Required tier for registration.
    /// @return message Explanation of the classification result.
    function classifyName(string calldata name)
        external
        pure
        returns (PopStatus requirement, string memory message);

    /// @notice Creates a reservation entry for the digit-stripped version of a name.
    /// @dev Commit-reveal reservation path. Callable only by an authorised
    ///      controller on the registrar. Applies the lite-eligibility
    ///      classification check; no-ops when the slot is already live.
    /// @param baseName The base label with trailing digits removed.
    /// @param user The address receiving reservation rights.
    function reserveBaseName(string calldata baseName, address user) external;

    /// @notice Emitted when a base-name reservation is cleared.
    /// @param baseName The base label whose reservation was released.
    event BaseNameReleased(string indexed baseName);

    /// @notice Writes or refreshes a reservation for a bare base-name stem.
    /// @dev Gateway-driven reservation path used by the PoP controller. Callable
    ///      by any controller in the registrar's `controllers` set. Does not
    ///      apply the lite-format classification that `reserveBaseName`
    ///      enforces; the caller is expected to supply the bare stem directly.
    ///      Reverts if the slot is already held by another user and still live
    ///      so the caller's local bookkeeping and PopRules state stay in
    ///      lockstep.
    /// @param baseName The base label to reserve (no trailing digits).
    /// @param user The address receiving reservation rights.
    function reserveBaseNameForPop(string calldata baseName, address user) external;

    /// @notice Clears a reservation for a base-name stem.
    /// @dev Callable by any controller in the registrar's `controllers` set. Used
    ///      by the PoP controller when a reservation is claimed, relinquished, or
    ///      a queue head promotion leaves the slot empty.
    /// @param baseName The base label whose reservation should be cleared.
    function releaseBaseName(string calldata baseName) external;

    /// @notice Retrieves reservation information for a base name.
    /// @dev Raw accessor: returns the stored slot regardless of expiry. Use
    ///      {isBaseNameReserved} when live-window semantics are needed.
    /// @param baseName The base label without trailing digits.
    /// @return owner The address assigned to the reservation.
    /// @return expires UNIX timestamp when the reservation expires.
    function getBaseNameReservation(string calldata baseName)
        external
        view
        returns (address owner, uint64 expires);

    /// @notice Indicates whether a base name is currently reserved.
    /// @dev Applies the live-window predicate to the stored slot so an
    ///      expired reservation reads as free.
    /// @param baseName The base label without trailing digits.
    /// @return reservedStatus True if a live reservation is active.
    /// @return owner The reservation holder (zero when not reserved).
    /// @return expires UNIX timestamp when the reservation expires.
    function isBaseNameReserved(string calldata baseName)
        external
        view
        returns (bool reservedStatus, address owner, uint64 expires);

    /// @notice Calculates price with PoP classification and reservation enforcement.
    /// @dev Reverting pricing path used by the commit-reveal controller.
    ///      Rejects governance-reserved names and base-name registrations held
    ///      by another user. The price applied is a spam deterrent and is
    ///      significant only for NoStatus users; verified users pay zero.
    /// @param name Domain label.
    /// @param userAddress Registering user for the given label.
    /// @return metadata Price with PoP requirements and classification.
    function priceWithCheck(
        string calldata name,
        address userAddress
    )
        external
        view
        returns (PriceWithMeta memory metadata);

    /// @notice Calculates price with PoP classification and reservation metadata,
    ///         without reverting on conflicts.
    /// @dev Non-reverting counterpart to `priceWithCheck`: surfaces the same
    ///      fields, but reports a `Reserved` status through `metadata` instead
    ///      of reverting when the base stem is held by another user. Used by
    ///      front-ends that need to present a price and eligibility preview
    ///      without forcing a transaction attempt. Governance-reserved names
    ///      are not rejected here either; the caller decides what to do.
    /// @param name Domain label.
    /// @param userAddress Registering user for the given label.
    /// @return metadata Price with PoP requirements and classification.
    function priceWithoutCheck(
        string calldata name,
        address userAddress
    )
        external
        view
        returns (PriceWithMeta memory metadata);

    /// @notice Friction fee owed when `account` reaches into a label tier above its verification
    /// level. @dev Returns a length-scaled reach price when the account does not satisfy the
    /// label's
    ///      required verification tier; zero otherwise. The personhood gate on direct registration
    ///      enforces this same comparison as a revert; this view exposes it as a charge for paths
    ///      that bypass the gate (cross-payer registration, transfer to an under-qualified
    /// recipient). @param name Domain label being acted on.
    /// @param account Account whose verification reach is being measured.
    /// @return fee Length-scaled reach price when `account` is below the label's required tier;
    /// zero otherwise.
    function reachFee(string calldata name, address account) external view returns (uint256 fee);

    /// @notice Returns whether `name` is a base name under PoP rules.
    /// @dev A base name has no trailing digits; lite-person labels always
    ///      have at least two trailing digits, so the two spaces are disjoint.
    /// @param name The label to check.
    /// @return isBase True when the label has no trailing digits.
    function isBaseName(string calldata name) external pure returns (bool isBase);

    /// @notice Sets the Proof-of-Personhood (PoP) tier for the caller's profile.
    /// @dev Once set, this PoP status applies to every registration by the
    ///      caller and replaces per-name PoP assignments. Temporary until a
    ///      precompile exposes PoP status directly from the pallet.
    /// @param status The PoP tier to assign to the user (NoStatus, PopLite, or PopFull).
    function setUserPopStatus(PopStatus status) external;

    /// @notice Updates the spam-deterrent starting price for NoStatus pricing.
    /// @dev Owner-only. The new value flows into `_priceValidatedName` on the next
    ///      pricing read; no redeploy. Emits {StartingPriceUpdated}.
    /// @param newStartingPrice New base price in wei.
    function updateStartingPrice(uint256 newStartingPrice) external;

    /// @notice Calculates registration cost for a label.
    /// @dev Pure length-based pricing; ignores PoP status and reservation state.
    /// @param name Domain label to price.
    /// @return cost Registration cost in wei.
    function price(string calldata name) external view returns (uint256 cost);

    /// @notice Emitted when the protocol registry is updated.
    /// @param newRegistry The address of the new protocol registry.
    event ProtocolRegistryUpdated(IDotnsProtocolRegistry indexed newRegistry);

    /// @notice Updates the protocol registry address.
    /// @dev Callable only by the contract owner.
    /// @param registry The address of the new protocol registry.
    // TODO: On fresh deploy (not upgrade), remove this function. Set protocolRegistry in initialize instead.
    function updateProtocolRegistry(IDotnsProtocolRegistry registry) external;
}
