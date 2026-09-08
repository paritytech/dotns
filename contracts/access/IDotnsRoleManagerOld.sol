// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title DotNS Role Manager
/// @notice Shared owner-administered role API for DotNS contracts with operational roles.
/// @dev Role identifiers are declared in `DotnsConstants`. Ownership remains the source of
///      super-user authority: the owner grants and revokes supported roles, while role holders
///      receive only the operational permissions each consuming contract recognises.
/// @custom:security-contact admin@parity.io
interface IDotnsRoleManagerOld is IAccessControl {
    /// @notice Thrown when a caller is neither the contract owner nor a holder of `role`.
    error NotRoleOrOwner(address caller, bytes32 role);

    /// @notice Thrown when role management is attempted for a role the contract does not use.
    error UnsupportedRole(bytes32 role);

    /// @notice Thrown when role management is attempted for the zero address.
    error InvalidRoleAccount(address account);

    /// @notice Grants or revokes an operational role.
    /// @dev Only the owner can manage roles (otherwise @custom:reverts OwnableUnauthorizedAccount);
    ///      `role` must be one of the roles recognised by the consuming contract (otherwise
    ///      @custom:reverts UnsupportedRole); `account` must not be the zero address (otherwise
    ///      @custom:reverts InvalidRoleAccount). Emits @custom:emits IAccessControl.RoleGranted on
    ///      grant and @custom:emits IAccessControl.RoleRevoked on revoke.
    /// @param role Role identifier declared in `DotnsConstants`.
    /// @param account Account whose role membership is updated.
    /// @param enabled Whether the role should be granted or revoked.
    function setRole(bytes32 role, address account, bool enabled) external;
}
