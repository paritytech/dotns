// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.34;

/// @title IPersonhood - Proof of Personhood Precompile
/// @notice Query personhood status of an account.
/// @dev Available at address 0x000000000000000000000000000000000a010000.
///      The precompile reads from the alias-accounts pallet which stores per-context
///      alias mappings backed by ring membership proofs. Ring roots are received from
///      the People chain via XCM pub/sub.
///
/// Example usage:
///   IPersonhood personhood = IPersonhood(0x000000000000000000000000000000000a010000);
///   IPersonhood.PersonhoodInfo memory info = personhood.personhoodStatus(someAddress,
/// bytes32("dotns")); if (info.status == 2) { // full person
///       // ...
///   }
/// @custom:security-contact admin@parity.io
interface IPersonhood {
    /// @notice Personhood information for an account in a given context.
    /// @param status The personhood verification tier.
    /// @param contextAlias Context-specific 32-byte pseudonym derived from ring membership proof.
    ///        Unique per person per context, preventing cross-application linkability.
    ///        Zero when status is None.
    /// @dev status tiers are defined incrementally: 0=None, 1=Lite, 2=Full.
    ///      If we add more types in the future, the existing ones remain unchanged.
    struct PersonhoodInfo {
        uint8 status;
        bytes32 contextAlias;
    }

    /// @notice Returns personhood info for an account within a specific application context.
    /// @param account The address to query.
    /// @param context A 32-byte application identifier. Each application picks a fixed constant
    ///        (e.g. `bytes32("dotns")`). The same person receives a different `contextAlias`
    ///        in each context, preventing cross-application linkability.
    /// @return info The personhood info struct. All fields are zero when the account has no
    ///         personhood.
    function personhoodStatus(
        address account,
        bytes32 context
    )
        external
        view
        returns (PersonhoodInfo memory info);
}
