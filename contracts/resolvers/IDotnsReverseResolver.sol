// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title Dotns Reverse Resolver
/// @notice Interface for writing and reading reverse name records for addresses.
/// @dev Reverse records bind to an EOA rather than a registry node. Two write paths exist:
///      a registrar-only setter used by the controller during reserved registration, and a
///      self-service claim path callable by the current name owner. Reads are fail-closed:
///      if the stored record no longer maps to a name owned by the address, @custom:function nameOf
///      returns the empty string.
/// @custom:security-contact admin@parity.io
interface IDotnsReverseResolver {
    /// @notice Thrown when a caller is not authorised to modify reverse records.
    /// @param caller The address attempting the modification.
    error NotRegistrarController(address caller);

    /// @notice Thrown when a caller attempts to claim a reverse record for a name they do not own.
    /// @param caller The address attempting the claim.
    /// @param node The claimed name's node: a token id for a tokenised name, and the
    ///        stem-under-container subnode for a lite name.
    error NotNameOwner(address caller, uint256 node);

    /// @notice Emitted when a name is associated with an address.
    /// @param addr The address for which the reverse name is being set.
    /// @param name The human-readable name associated with the address.
    event ReverseNameSet(address indexed addr, string indexed name);

    /// @notice Associates an address with a reverse name record.
    /// @dev Callable only by the configured registrar or its controller, otherwise
    ///      @custom:reverts NotRegistrarController. Overwrites any existing reverse record for
    ///      `addr` and emits @custom:emits ReverseNameSet on every successful write.
    /// @param addr The address for which the reverse name is being set.
    /// @param name The human-readable name associated with the address.
    function setReverseName(address addr, string calldata name) external;

    /// @notice Self-service claim: associates `msg.sender` with `<label>` under the network TLD.
    /// @dev The caller must currently own `label`, read through the registry, which delegates a
    ///      tokenised name to the registrar and holds a lite subname directly, otherwise
    ///      @custom:reverts NotNameOwner. Overwrites any existing record for the caller
    ///      and emits @custom:emits ReverseNameSet on every successful write. Transferring the
    ///      name away does not eagerly clear the record; @custom:function nameOf fails closed at
    ///      read time when the stored record no longer matches current ownership.
    /// @param label The label (without the TLD suffix) the caller is claiming a reverse record for.
    function claimReverseRecord(string calldata label) external;

    /// @notice Returns the reverse name for an address, fail-closed against current ownership.
    /// @dev Returns the empty string when no record is set, when the record is malformed, or
    ///      when the address no longer owns the name pointed to by the stored record.
    /// @param addr The address to query.
    /// @return name The reverse name associated with `addr`, or the empty string.
    function nameOf(address addr) external view returns (string memory name);
}
