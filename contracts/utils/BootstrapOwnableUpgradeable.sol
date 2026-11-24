// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SystemUtils} from "./SystemUtils.sol";

/// @title BootstrapOwnableUpgradeable
/// @notice Governance gate for an upgradeable dotNS contract: substrate Root, or the bootstrap
///         owner while one is set.
/// @dev The owner exists only to configure a fresh deployment. Ownership cannot move to another
///      account: the only transition is @custom:function renounceOwnership, after which Root is
///      the only governance. Only Root can renounce: a Root call passes the gate behind a proxy
///      only on a runtime where `callerIsRoot` works there, so the renounce proves that Root can
///      still govern after it. An owner renouncing on a runtime without that would leave no
///      account able to upgrade. `DotnsProtocolRegistry` holds the one bootstrap owner of a
///      deployment. Every other dotNS contract reads it from there through
///      @custom:contract ProtocolOwnedUpgradeable, so one renounce ends the bootstrap everywhere.
///
///      The gate checks Root first and reads `msg.sender` only when the caller is not Root: a
///      Root origin has no account behind it, so reading `msg.sender` in its frame traps. A
///      function behind the gate must not read `msg.sender` either. Root passes only when it
///      called this contract directly (see @custom:function SystemUtils.callerIsRoot), so a
///      contract reached later in a Root transaction cannot pass. The gate reads Root through
///      @custom:function SystemUtils.tryCallerIsRoot, so a deployment script still configures
///      as the owner in a local simulation that has no System precompile.
///
///      Adds no storage. `OwnableUpgradeable` keeps the owner in ERC-7201 namespaced storage, so
///      a contract can switch its base from `OwnableUpgradeable` to this one without moving any
///      slot.
abstract contract BootstrapOwnableUpgradeable is OwnableUpgradeable {
    /// @notice Thrown by @custom:function transferOwnership, which is disabled.
    error OwnershipTransferDisabled();

    /// @notice Thrown by @custom:function renounceOwnership when the caller is not Root.
    error RenounceRequiresRoot();

    /// @notice Restricts a call to Root, or to the owner while one is set.
    modifier onlyRootOrOwner() {
        _checkRootOrOwner();
        _;
    }

    /// @notice Disabled: ownership can only be renounced.
    /// @dev Always @custom:reverts OwnershipTransferDisabled.
    function transferOwnership(address) public pure override {
        revert OwnershipTransferDisabled();
    }

    /// @notice Removes the bootstrap owner, leaving Root as the only governance.
    /// @dev Root only, otherwise @custom:reverts RenounceRequiresRoot. Irreversible: no function
    ///      sets an owner again.
    function renounceOwnership() public virtual override onlyRoot {
        _transferOwnership(address(0));
    }

    /// @notice Restricts a call to a direct Root dispatch.
    modifier onlyRoot() {
        require(SystemUtils.tryCallerIsRoot(), RenounceRequiresRoot());
        _;
    }

    /// @notice Internal check behind @custom:modifier onlyRootOrOwner.
    /// @dev Reverts with OwnableUnauthorizedAccount when the caller is neither Root nor the owner.
    ///      Once the owner is renounced, `owner()` is zero and no account passes.
    function _checkRootOrOwner() internal view {
        if (!SystemUtils.tryCallerIsRoot()) _checkOwner();
    }
}
