// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {IDotnsRegistry} from "../registry/IDotnsRegistry.sol";
import {IDotnsRegistrar} from "../registrars/IDotnsRegistrar.sol";
import {LabelUtils} from "./LabelUtils.sol";
import {StringUtils} from "./StringUtils.sol";

/// @title dotNS Subnode Utilities Library
/// @notice General-purpose helpers for registering names that live as subnodes of another name,
///         rather than as tokenised second-level registrations.
/// @dev A subname has no token: its ownership lives in the registry record, not in the registrar's
///      ERC-721 ledger. So it is registered through @custom:function IDotnsRegistry.setSubnodeOwner
///      beneath a parent prepared by @custom:function ensureParent, rather than through the
///      tokenised mint triad of @custom:contract RegistrationUtils.
/// @custom:security-contact admin@parity.io
library SubnodeUtils {
    /// @notice Derives the subnode `subLabel.parentLabel.tld`.
    /// @dev The single source of truth for how a two-level name maps to a node: walk `parentLabel`
    ///      under `tldNode`, then `subLabel` under that. Consumers that need the node without
    ///      writing it (readers, validators) call this so they agree with the write path.
    /// @param tldNode The TLD node.
    /// @param parentLabel Second-level parent label, e.g. `01`.
    /// @param subLabel Subname label, e.g. `alice`.
    /// @return subnode Namehash of `subLabel` under `parentLabel.tld`.
    function subnodeOf(
        bytes32 tldNode,
        string memory parentLabel,
        string memory subLabel
    )
        internal
        pure
        returns (bytes32 subnode)
    {
        bytes32 parentNode =
            LabelUtils.namehashUnder(tldNode, LabelUtils.labelhashMemory(parentLabel));
        subnode = LabelUtils.namehashUnder(parentNode, LabelUtils.labelhashMemory(subLabel));
    }

    /// @notice Derives the subnode for a device name `<stem>.<suffix>`, splitting it on the
    /// separator first.
    /// @dev The single place a device name is turned into a node, shared by the write path and
    ///      every reader of a device name so the issuer and its readers agree on where a device
    ///      name lives. Callers gate on @custom:function StringUtils.isDeviceLabelMemory
    ///      beforehand, so the label is known to carry the separator this splits on.
    /// @param tldNode The TLD node.
    /// @param deviceLabel Device name, e.g. `alice.01`.
    /// @return subnode Namehash of the stem beneath its numeric container beneath the TLD.
    function deviceSubnodeOf(
        bytes32 tldNode,
        string memory deviceLabel
    )
        internal
        pure
        returns (bytes32 subnode)
    {
        (string memory stem, string memory suffix) = StringUtils.splitDeviceLabel(deviceLabel);
        subnode = subnodeOf(tldNode, suffix, stem);
    }

    /// @notice Makes the calling contract the owner of the second-level name `parentNode`, minting
    ///         it if no name is registered there yet, so the caller can register subnames beneath
    ///         it.
    /// @dev When no name exists at `parentNode`, it is minted through the registrar with the
    ///      calling contract as owner and an empty label, so no `LabelStore` is written for it.
    ///      The calling contract must therefore be a registrar controller, otherwise the registrar
    ///      @custom:reverts NotController. When a name already exists there it must be owned by
    ///      the caller, otherwise @custom:reverts NotAuthorised, so a name someone else holds is
    ///      never treated as the caller's parent. The caller then records each subname through
    ///      @custom:function IDotnsRegistry.setSubnodeOwner, which requires that parent authority.
    /// @dev The parent is owned by the calling contract's address. A caller that migrates to a new
    ///      address, rather than upgrading in place, strands every parent it minted and can no
    ///      longer register subnames beneath them.
    /// @param registrar The base registrar.
    /// @param registry The forward registry.
    /// @param parentNode Node of a single label registered directly under the TLD.
    function ensureParent(
        IDotnsRegistrar registrar,
        IDotnsRegistry registry,
        bytes32 parentNode
    )
        internal
    {
        if (!registrar.exists(uint256(parentNode))) {
            registrar.register(uint256(parentNode), address(this), "");
            registry.setOwner(parentNode, address(this));
        } else {
            require(registry.owner(parentNode) == address(this), IDotnsRegistry.NotAuthorised());
        }
    }
}
