// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Dot Reverse Resolver Interface
/// @notice Interface for writing and reading reverse name records for addresses.
/// @dev Defines the minimal surface required to associate an address with a human-readable name.
///      Implementations are expected to enforce authorization for writes.
/// @custom:security-contact admin@parity.io
interface IDotnsReverseResolver {
    /// @notice Thrown when a caller is not authorised to modify reverse records.
    error NotRegistrar();

    /// @notice Thrown when an invalid registrar address is provided.
    error InvalidRegistrar();

    /// @notice Emitted when the registrar address is updated.
    /// @param oldRegistrar Previous registrar.
    /// @param newRegistrar New registrar.
    event RegistrarUpdated(address indexed oldRegistrar, address indexed newRegistrar);

    /// @notice Emitted when a name is associated with an address
    /// @param addr The address for which the reverse name is being set.
    /// @param name The human-readable name associated with the address.
    event ReverseNameSet(address indexed addr, string indexed name);

    /// @notice Associates an address with a reverse name record.
    /// @dev This function overwrites any existing reverse record for `addr`.
    /// @param addr The address for which the reverse name is being set.
    /// @param name The human-readable name associated with the address.
    /// @custom:reverts NotRegistrar if the caller is not authorised to write.
    function setReverseName(address addr, string calldata name) external;

    /// @notice Returns the reverse name for an address.
    /// @dev Returns an empty string if no reverse name is set.
    /// @param addr The address to query.
    /// @return name The reverse name associated with `addr`.
    function nameOf(address addr) external view returns (string memory name);

    /// @notice Updates the registrar address authorised to write reverse records.
    /// @dev Implementations should restrict this to an admin/owner.
    /// @param newRegistrar The new registrar address.
    /// @custom:reverts InvalidRegistrar if `newRegistrar` is the zero address.
    function updateRegistrar(address newRegistrar) external;
}
