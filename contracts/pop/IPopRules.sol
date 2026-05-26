// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title Proof of Personhood Rules for Dotns
/// @notice Proof of personhood interface defining Dotns price calculation, PoP-tier requirements,
///         and base-name reservation rules.
/// @dev Classifies labels into the PoP tier required for registration and exposes reservation
///      metadata. Length <= 5 is reserved for governance; lengths 6-8 require PopFull unless they
///      carry exactly two trailing digits (PopLite, gateway-issued); lengths >= 9 are open to
///      every caller as NoStatus when they carry zero or exactly two trailing digits. Any one-digit
///      suffix, and any suffix longer than two digits, is invalid; internal digits do not affect
///      classification. Reservations are keyed by the digit-stripped stem so `alice` and `alice42`
///      share a slot.
///
///      Pricing is a flat per-name deposit on the NoStatus tier; verified PopLite and PopFull
///      users pay zero.
/// @custom:security-contact admin@parity.io
interface IPopRules {
    /// @notice Proof-of-Personhood eligibility tier.
    /// @dev `NoStatus` is the default for unverified users; `PopLite` and `PopFull` are the two
    ///      personhood tiers; `Reserved` covers both governance-held names and base stems held by
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

    /// @notice Emitted when the spam-deterrent NoStatus starting price is rotated.
    /// @dev Owner-only setter @custom:function updateStartingPrice; the new value is consumed
    ///      by `_priceValidatedName` on the next pricing read.
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
    /// @param controller Address that wrote the reservation; the only address permitted to release
    /// it before expiry.
    struct Reservation {
        address owner;
        uint64 expires;
        address controller;
    }

    /// @notice Classifies a name into a required PoP tier per DotNS naming rules.
    /// @dev Pure; inputs are the label bytes only. Callers use the returned tier to decide which
    ///      pricing and verification branch applies. Non-canonical labels (anything other than a
    ///      single lowercase ASCII DNS label) and labels with exactly one or more than two
    ///      trailing digits both trigger @custom:reverts PopError.
    /// @param name The name label being evaluated.
    /// @return requirement Required tier for registration.
    /// @return message Explanation of the classification result.
    function classifyName(string calldata name)
        external
        pure
        returns (PopStatus requirement, string memory message);

    /// @notice Updates the spam-deterrent starting price for NoStatus pricing.
    /// @dev Owner-only; unauthorised callers trigger @custom:reverts
    ///      OwnableUnauthorizedAccount. `newStartingPrice` must be strictly positive, otherwise
    ///      @custom:reverts PopError. The new value flows into `_priceValidatedName` on the next
    ///      pricing read; no redeploy. Emits @custom:emits StartingPriceUpdated with the prior
    ///      and new values.
    /// @param newStartingPrice New base price in wei.
    function updateStartingPrice(uint256 newStartingPrice) external;

    /// @notice Creates or refreshes a reservation entry for a PopLite-eligible stem.
    /// @dev Commit-reveal reservation path. Only an authorised controller on the registrar may
    ///      call this, otherwise @custom:reverts NotRegistry. The caller passes the
    /// already-stripped stem; the contract enforces stem shape (no trailing digits) and
    /// PopLite-eligibility
    ///      (length in `[6, 8]`), and a non-canonical label or a label outside that shape triggers
    ///      @custom:reverts PopError. Cross-user collision on a live slot triggers @custom:reverts
    ///      PopError so the caller cannot silently overwrite another user's reservation; same-user
    ///      refresh and writes into an empty or expired slot emit @custom:emits BaseNameReserved.
    /// @param stem The base label with no trailing digits.
    /// @param user The address receiving reservation rights.
    function reserveBaseName(string calldata stem, address user) external;

    /// @notice Emitted when a base-name reservation is cleared.
    /// @param baseName The base label whose reservation was released.
    event BaseNameReleased(string indexed baseName);

    /// @notice Writes or refreshes a reservation for a bare base-name stem.
    /// @dev Gateway-driven reservation path used by the PoP controller. Only a controller in the
    ///      registrar's `controllers` set may call this, otherwise @custom:reverts NotRegistry.
    ///      Does not apply the lite-format length window that @custom:function reserveBaseName
    ///      enforces, but does require the input to be canonical and stem-shaped (no trailing
    ///      digits); a non-canonical or non-stem label triggers @custom:reverts PopError. If the
    ///      slot is already live and held by a different user, @custom:reverts PopError so the
    ///      caller's local bookkeeping and PopRules state stay in lockstep; if it is live for the
    ///      same user, expiry is refreshed to `block.timestamp + MAX_RESERVATION_TIME`. Emits
    ///      @custom:emits BaseNameReserved on every successful write.
    /// @param stem The base label with no trailing digits.
    /// @param user The address receiving reservation rights.
    function reserveBaseNameForPop(string calldata stem, address user) external;

    /// @notice Clears a reservation for a base-name stem.
    /// @dev Only a controller in the registrar's `controllers` set may call this, otherwise
    ///      @custom:reverts NotRegistry. Non-canonical or non-stem labels trigger
    ///      @custom:reverts PopError. Live reservations may only be cleared by the same controller
    ///      that wrote them; another authorised controller attempting to clear a live slot triggers
    ///      @custom:reverts PopError. Expired reservations may be cleared by any authorised
    ///      controller as garbage collection. Used by the PoP controller when a reservation is
    ///      claimed, relinquished, or a queue head promotion leaves the slot empty. Emits
    ///      @custom:emits BaseNameReleased once the slot is cleared.
    /// @param stem The base label whose reservation should be cleared (no trailing digits).
    function releaseBaseName(string calldata stem) external;

    /// @notice Clears a reservation when the slot owner matches `expectedOwner`, allowing any
    ///         registrar-authorised controller (not only the stamping one) to release the slot.
    /// @dev Narrower than @custom:function releaseBaseName: callers must prove they know the
    ///      slot owner, so cross-controller release is gated on a positive match rather than on
    ///      caller identity. Intended for the public registrar controller's reclaim path, where
    ///      a prior occupant has handed the name back to escrow and the new registrant needs
    ///      the cross-flow guard cleared regardless of which controller originally stamped it.
    ///      Only a registrar-authorised controller may call this (@custom:reverts NotRegistry).
    ///      Non-canonical or non-stem labels trigger @custom:reverts PopError. A live reservation
    ///      whose owner does not match `expectedOwner` triggers @custom:reverts PopError; expired
    ///      reservations are cleared regardless. Emits @custom:emits BaseNameReleased.
    /// @param stem The base label whose reservation should be cleared (no trailing digits).
    /// @param expectedOwner The address the caller expects to be the current reservation owner.
    function releaseReservationForReclaim(string calldata stem, address expectedOwner) external;

    /// @notice Retrieves reservation information for a base name.
    /// @dev Raw accessor: returns the stored slot regardless of expiry. Use
    ///      @custom:function isBaseNameReserved
    ///      when live-window semantics are needed. Non-canonical labels trigger
    ///      @custom:reverts PopError.
    /// @param baseName The base label without trailing digits.
    /// @return owner The address assigned to the reservation.
    /// @return expires UNIX timestamp when the reservation expires.
    function getBaseNameReservation(string calldata baseName)
        external
        view
        returns (address owner, uint64 expires);

    /// @notice Returns the bare stem of a label, i.e. the label with any trailing ASCII digits
    ///         removed.
    /// @dev Mirrors the normalisation that @custom:function reserveBaseName applies before writing
    ///      a reservation, so callers can look up or release a reservation by passing the full
    ///      label without re-implementing the digit-stripping rule. Non-canonical labels
    ///      trigger @custom:reverts PopError.
    /// @param name Full label (with or without trailing digits).
    /// @return stem The label with trailing digits removed.
    function stripDigits(string calldata name) external pure returns (string memory stem);

    /// @notice Indicates whether a base name is currently reserved.
    /// @dev Applies the live-window predicate to the stored slot so an expired reservation reads
    ///      as free. Non-canonical labels trigger @custom:reverts PopError.
    /// @param baseName The base label without trailing digits.
    /// @return reservedStatus True if a live reservation is active.
    /// @return owner The reservation holder (zero when not reserved).
    /// @return expires UNIX timestamp when the reservation expires.
    function isBaseNameReserved(string calldata baseName)
        external
        view
        returns (bool reservedStatus, address owner, uint64 expires);

    /// @notice Calculates price with PoP classification and reservation enforcement.
    /// @dev Reverting pricing path used by the commit-reveal controller. Price is a spam
    ///      deterrent and is significant only for NoStatus users; verified users pay zero.
    ///      Non-canonical labels, a base stem held live by another user, a governance-reserved
    ///      label, or a `userAddress` whose personhood tier does not meet the label's required
    ///      tier each trigger @custom:reverts PopError.
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

    /// @notice Calculates price with PoP classification and reservation metadata, without
    /// reverting on conflicts.
    /// @dev Non-reverting counterpart to `priceWithCheck`: surfaces the same fields, but reports
    ///      a `Reserved` status through `metadata` instead of reverting when the base stem is
    ///      held by another user. Used by front-ends that need to present a price and eligibility
    ///      preview without forcing a transaction attempt. Governance-reserved names are not
    ///      rejected here either; the caller decides what to do. Non-canonical labels still
    ///      trigger @custom:reverts PopError because the input is malformed rather than just
    ///      contested.
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
    /// level.
    /// @dev Non-zero only when `account` cannot meet the label's required PoP tier; the value is
    ///      the flat NoStatus deposit. Acts as cross-payer friction at registration time. Use
    ///      @custom:function transferFloor for transfer-time friction, which folds in the
    ///      sender-tier-downgrade component as well. Non-canonical labels and labels with exactly
    ///      one or more than two trailing digits trigger @custom:reverts PopError.
    /// @param name Domain label being acted on.
    /// @param account Account whose verification reach is being measured.
    function reachFee(string calldata name, address account) external view returns (uint256 fee);

    /// @notice Transfer-time friction floor: the greater of the recipient-reach component and
    ///         the sender-tier-downgrade component.
    /// @dev Returns the flat NoStatus deposit when either (i) the recipient does not meet the
    ///      label's required tier, or (ii) the recipient's personhood tier is strictly below the
    ///      sender's. Returns zero when neither condition holds. The two components overlap on
    ///      pure tier mismatches, so the function takes their maximum rather than their sum to
    ///      avoid double-charging. Consumed by @custom:function DotnsRegistrar.quoteTransferFee.
    ///      Non-canonical labels and labels with exactly one or more than two trailing digits
    ///      trigger @custom:reverts PopError.
    /// @param name Domain label being transferred.
    /// @param from Current holder of the name.
    /// @param to Incoming holder of the name.
    function transferFloor(
        string calldata name,
        address from,
        address to
    )
        external
        view
        returns (uint256 floor);

    /// @notice Returns whether `name` is a base name under PoP rules.
    /// @dev A base name has no trailing digits; lite-person labels always have exactly two
    ///      trailing digits, so the two spaces are disjoint. Non-canonical labels trigger
    ///      @custom:reverts PopError.
    /// @param name The label to check.
    /// @return isBase True when the label has no trailing digits.
    function isBaseName(string calldata name) external pure returns (bool isBase);

    /// @notice Calculates registration cost for a label.
    /// @dev Returns zero for any label shorter than 9 characters; lengths >= 9 pay the flat
    ///      `startingPrice` deposit. Ignores the caller's personhood status and reservation
    ///      state. Non-canonical labels trigger @custom:reverts PopError.
    /// @param name Domain label to price.
    /// @return cost Registration cost in wei.
    function price(string calldata name) external view returns (uint256 cost);
}
