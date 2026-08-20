// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IDotnsRoleManager} from "./IDotnsRoleManager.sol";

/// @title Dotns Role Manager
/// @notice Shared owner-administered role layer for DotNS contracts with operational roles.
/// @dev Consuming contracts define their supported role set in @custom:function _isSupportedRole.
///      The owner remains the only account that can grant or revoke roles; role holders receive
///      only the operational permissions each consuming contract explicitly gates with
///      @custom:function _checkRoleOrOwner.
/// @custom:security-contact admin@parity.io
abstract contract DotnsRoleManager is
    AccessControlUpgradeable,
    OwnableUpgradeable,
    IDotnsRoleManager
{
    /// @notice Initialises the OpenZeppelin access-control state for consuming contracts.
    /// @dev Must be called during the consuming contract initialiser.
    function _dotnsRoleManagerInit() internal onlyInitializing {
        __AccessControl_init();
    }

    /// @inheritdoc IDotnsRoleManager
    function setRole(bytes32 role, address account, bool enabled) external override onlyOwner {
        _setRole(role, account, enabled);
    }

    /// @inheritdoc IAccessControl
    function grantRole(
        bytes32 role,
        address account
    )
        public
        override(AccessControlUpgradeable, IAccessControl)
        onlyOwner
    {
        _setRole(role, account, true);
    }

    /// @inheritdoc IAccessControl
    function revokeRole(
        bytes32 role,
        address account
    )
        public
        override(AccessControlUpgradeable, IAccessControl)
        onlyOwner
    {
        _setRole(role, account, false);
    }

    /// @inheritdoc AccessControlUpgradeable
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlUpgradeable)
        returns (bool supported)
    {
        return interfaceId == type(IDotnsRoleManager).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice Reverts unless the caller is the owner or holds `role`.
    /// @dev Consuming contracts use this for operational paths where the owner keeps super-user
    ///      access and role holders receive a narrower permission; any other caller is rejected
    ///      with @custom:reverts NotRoleOrOwner.
    function _checkRoleOrOwner(bytes32 role) internal view {
        address caller = _msgSender();
        require(caller == owner() || hasRole(role, caller), NotRoleOrOwner(caller, role));
    }

    /// @notice Grants or revokes a supported role for `account`.
    /// @dev `role` must be recognised by the consuming contract (otherwise
    ///      @custom:reverts UnsupportedRole) and `account` must be non-zero (otherwise
    ///      @custom:reverts InvalidRoleAccount). Delegates to OpenZeppelin's `_grantRole` or
    ///      `_revokeRole`, which emit @custom:emits IAccessControl.RoleGranted on grant and
    ///      @custom:emits IAccessControl.RoleRevoked on revoke.
    function _setRole(bytes32 role, address account, bool enabled) internal {
        require(_isSupportedRole(role), UnsupportedRole(role));
        require(account != address(0), InvalidRoleAccount(account));

        if (enabled) {
            _grantRole(role, account);
        } else {
            _revokeRole(role, account);
        }
    }

    /// @notice Returns whether `role` is recognised by the consuming contract.
    /// @dev Implemented by each consuming contract so unsupported role identifiers fail closed.
    function _isSupportedRole(bytes32 role) internal view virtual returns (bool supported);
}
