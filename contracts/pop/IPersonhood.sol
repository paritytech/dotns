// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IPersonhood - Proof of Personhood Status Precompile
/// @notice Queries the on-chain personhood status of an account via the Individuality runtime precompile.
/// @dev The precompile is deployed at a fixed address in the pallet-revive address space.
///      Status values returned by `personhoodStatus`:
///        0 = None     — Account has no registered personhood
///        1 = Lite     — Proof of personhood lite (device-attested uniqueness)
///        2 = Full     — Full proof of personhood (active cryptographic authorization)
///        3 = Demoted  — Full personhood with expired authorization
///
///      Precompile address: 0x0000000000000000000000000000000A010000
/// @custom:security-contact admin@parity.io
interface IPersonhood {
    /// @notice Returns the personhood status of the given account.
    /// @param account The address to query.
    /// @return status The personhood tier as a uint8 (0–3).
    function personhoodStatus(address account) external view returns (uint8 status);
}
