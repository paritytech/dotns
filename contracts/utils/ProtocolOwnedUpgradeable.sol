// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SystemUtils} from "./SystemUtils.sol";

/// @title ProtocolOwnedUpgradeable
/// @notice Governance gate for an upgradeable dotNS contract whose bootstrap owner is the owner of
///         its `DotnsProtocolRegistry`: substrate Root, or that owner while one is set.
/// @dev @custom:function owner returns the protocol registry's owner, so every contract of a
///      deployment shares one bootstrap owner, and renouncing it on the registry leaves Root as
///      the only governance of all of them in the same transaction. This contract keeps no owner
///      and adds no storage: @custom:function transferOwnership and
///      @custom:function renounceOwnership revert. The protocol registry address must be fixed at
///      initialisation, because whoever controls it controls this gate.
///
///      The gate follows @custom:contract BootstrapOwnableUpgradeable: it checks Root first,
///      through @custom:function SystemUtils.tryCallerIsRoot, and reads `msg.sender` only when the
///      caller is not Root, so a function behind it must not read `msg.sender` either. Root
///      passes only when it called this contract directly.
///
///      A contract that inherited `OwnableUpgradeable` can switch to this base: the old owner sits
///      in ERC-7201 namespaced storage, so no slot moves, and nothing reads it afterwards.
abstract contract ProtocolOwnedUpgradeable {
    /// @notice Thrown when the caller is neither Root nor the bootstrap owner.
    /// @param account The caller.
    error OwnableUnauthorizedAccount(address account);

    /// @notice Thrown by @custom:function transferOwnership, which is disabled.
    error OwnershipTransferDisabled();

    /// @notice Thrown by @custom:function renounceOwnership: the protocol registry holds the
    ///         bootstrap owner.
    error OwnershipHeldByProtocolRegistry();

    /// @notice Restricts a call to Root, or to the bootstrap owner while one is set.
    modifier onlyRootOrOwner() {
        _checkRootOrOwner();
        _;
    }

    /// @notice Returns the bootstrap owner, read from the protocol registry.
    /// @return owner_ The protocol registry's owner, or zero once it is renounced.
    function owner() public view returns (address owner_) {
        return OwnableUpgradeable(_protocolRegistryAddress()).owner();
    }

    /// @notice Disabled: the protocol registry holds the bootstrap owner.
    /// @dev Always @custom:reverts OwnershipTransferDisabled.
    function transferOwnership(address) public pure {
        revert OwnershipTransferDisabled();
    }

    /// @notice Disabled: renounce the bootstrap owner on the protocol registry.
    /// @dev Always @custom:reverts OwnershipHeldByProtocolRegistry.
    function renounceOwnership() public pure {
        revert OwnershipHeldByProtocolRegistry();
    }

    /// @notice Internal check behind @custom:modifier onlyRootOrOwner.
    /// @dev Reverts with OwnableUnauthorizedAccount when the caller is neither Root nor the owner.
    ///      Once the owner is renounced, @custom:function owner is zero and no account passes.
    function _checkRootOrOwner() internal view {
        if (!SystemUtils.tryCallerIsRoot()) {
            require(msg.sender == owner(), OwnableUnauthorizedAccount(msg.sender));
        }
    }

    /// @notice Returns the protocol registry that holds the bootstrap owner.
    /// @return registry Address set at initialisation.
    function _protocolRegistryAddress() internal view virtual returns (address registry);
}
