// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IPopRules
/// @notice Proof of personhood interface defining DotNS price calculation, PoP-tier requirements, and base-name reservation rules
/// @dev Provides the classification logic for DotNS labels, enforces suffix constraints, and exposes reservation metadata.
///      Names are evaluated according to the following rules:
///      • Length ≤ 5: Reserved
///      • Length 6–8 without trailing digits: PopFull required
///      • Length 6–8 with 2 trailing digits: PopLite required
///      • Length ≥ 9 without trailing digits: PopFull required
///      • Length ≥ 9 with 2 trailing digits: NoStatus (open)
///      Trailing digits beyond 2 are invalid. Internal digits do not affect classification.
///      Reservation rules apply to a label stripped of trailing digits.
///      Its also important to note that for Pop Full there are no restrictions to name registrations any
///      Character combination is valid, the same is valid for Light and No status users with the exception of
///      Requiring 2 suffix digits appended to the username being registered
/// @dev The pricing applied is mainly for POP No status users as measure to prevent spam
/// @custom:security-contact admin@parity.io
interface IPopRules {
    /// @notice Proof-of-Personhood eligibility tier
    /// @dev Defines verification requirements for a given name classification
    enum PopStatus {
        NoStatus,
        PopLite,
        PopFull,
        Reserved
    }

    /// @notice Emitted when a base name receives a reservation
    /// @param baseName The digit-stripped label receiving reservation
    /// @param owner Address obtaining the reservation right
    /// @param expires Timestamp when the reservation expires
    event BaseNameReserved(string indexed baseName, address indexed owner, uint64 expires);

    /// @notice Emitted when the registry is updated
    /// @param oldReg Currently set registry address
    /// @param newReg New address to set
    event RegistryUpdated(address indexed oldReg, address indexed newReg);

    /// @notice Emitted when a user's PoP status is updated
    /// @dev This is temporary until we have a Precompile for accessing PoP status
    /// @param user Address of the user
    /// @param status New PoP tier assigned
    event UserPopStatusSet(address indexed user, PopStatus status);

    /// @notice Thrown when a name violates PoP-tier or reservation requirements
    /// @param reason Human-readable explanation of the failure condition
    error PopError(string reason);

    /// @notice Used to throw generic errors
    /// @param reason Human-readable explanation of the failure condition
    error GenericError(string reason);

    /// @notice Used when functions only allow the registry to make calls
    error NotRegistry();

    /// @notice Bundle returned from metadata-aware pricing queries
    /// @param price The cost the name will cost usually for POP No status
    /// @param status Required PoP tier for this name
    /// @param userStatus Currently set user POP status
    /// @param message Human-readable classification description
    struct PriceWithMeta {
        uint256 price;
        PopStatus status;
        PopStatus userStatus;
        string message;
    }

    /// @notice Reservation metadata for a base name (digits removed)
    /// @param owner Address holding exclusive claim rights during the reservation window
    /// @param expires UNIX timestamp when the reservation expires
    struct Reservation {
        address owner;
        uint64 expires;
    }

    /// @notice Classifies a name into a required PoP tier according to DotNS naming rules
    /// @param name The name label being evaluated
    /// @return requirement Required tier for registration
    /// @return message Explanation of classification result
    function classifyName(string calldata name)
        external
        pure
        returns (PopStatus requirement, string memory message);

    /// @notice Creates a reservation entry for the digit-stripped version of a name
    /// @param baseName The base label with trailing digits removed
    /// @param user The address receiving reservation rights
    /// @dev Can only be called by the registry
    function reserveBaseName(string calldata baseName, address user) external;

    /// @notice Retrieves reservation information for a base name
    /// @param baseName The base label without trailing digits
    /// @return owner The address assigned to the reservation
    /// @return expires UNIX timestamp when the reservation expires
    function getBaseNameReservation(string calldata baseName)
        external
        view
        returns (address owner, uint64 expires);

    /// @notice Indicates whether a base name is currently reserved
    /// @param baseName The base label without trailing digits
    /// @return reservedStatus True if a reservation is active
    /// @return owner The reservation holder
    /// @return expires The reservation expiry timestamp
    function isBaseNameReserved(string calldata baseName)
        external
        view
        returns (bool reservedStatus, address owner, uint64 expires);

    /// @notice Calculates price with PoP and reservation validation
    /// @param name Domain label
    /// @param userAddress Registering user for the given label
    ///@dev We currently revert on names considered as reserved for Governance
    ///     The price we apply here is merely for spam protection and is insignificant
    ///     It mainly applies to no status users
    /// @return metadata Price with PoP requirements
    function priceWithCheck(
        string calldata name,
        address userAddress
    )
        external
        view
        returns (PriceWithMeta memory metadata);

    /// @notice Calculates price with PoP and reservation validation
    /// @param name Domain label
    /// @param userAddress Registering user for the given label
    ///@dev We currently dont revert on names considered as reserved for Governance
    ///     The price we apply here is merely for spam protection and is insignificant
    ///     It mainly applies to no status users
    /// @dev This function is the same as @custom:function priceWithCheck
    /// @return metadata Price with PoP requirements
    function priceWithoutCheck(
        string calldata name,
        address userAddress
    )
        external
        view
        returns (PriceWithMeta memory metadata);

    /// @notice Used to determine if a given name is a base name
    ///        Base name means has no trailing digits based on POP rules
    /// @param name The name to check
    /// @return isBase stating if the name is base or not
    function isBaseName(string calldata name) external pure returns (bool isBase);

    /// @notice allows the Owner to update the dot/eth registry
    /// @param ethReg the address of the new registry
    function updateEthRegistry(address ethReg) external;

    /// @notice Sets the Proof-of-Personhood (PoP) tier for the caller's profile
    /// @param status The PoP tier to assign to the user (NoStatus, PopLite, or PopFull)
    /// @dev Once set, this PoP status applies to all registrations by this user
    ///      This replaces per-name PoP assignments
    /// @dev This is temporary until we have a Precompile for accessing PoP status
    function setUserPopStatus(PopStatus status) external;

    /// @notice Calculates registration cost
    /// @param name Domain label to price
    /// @return cost for registering the name
    function price(string calldata name) external view returns (uint256 cost);
}
