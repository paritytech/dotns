// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IDotnsRegistry} from "../registry/IDotnsRegistry.sol";
import {IDotnsRegistrar} from "../registrars/IDotnsRegistrar.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {LabelUtils} from "./LabelUtils.sol";
import {DotnsConstants} from "./DotnsConstants.sol";

/// @title DotNS Subnode Utilities Library
/// @notice General-purpose helpers for registering names that live as subnodes of another name,
///         rather than as tokenised second-level registrations.
/// @dev A subname has no token: its ownership lives in the registry record, not in the registrar's
///      ERC-721 ledger. So it is registered through @custom:function IDotnsRegistry.setSubnodeOwner
///      here, rather than through the tokenised mint triad of @custom:contract RegistrationUtils.
/// @custom:security-contact admin@parity.io
library SubnodeUtils {
    /// @notice Inputs describing a single subname registration.
    /// @dev Passed as a struct so call sites name each field rather than thread a positional
    ///      argument list, mirroring @custom:struct RegistrationUtils.RegistrationContext.
    /// @param protocolRegistry Protocol-level address registry used to resolve the registry and
    /// TLD.
    /// @param parentLabel Second-level parent label, e.g. `01`.
    /// @param subLabel Subname label to register, e.g. `alice`.
    /// @param owner Address to record as the subname owner.
    /// @param persist Whether the registry should index the subnode into the owner's `LabelStore`.
    struct SubnameContext {
        IDotnsProtocolRegistry protocolRegistry;
        string parentLabel;
        string subLabel;
        address owner;
        bool persist;
    }

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

    /// @notice Registers `subLabel` beneath the second-level name `parentLabel`, minting the parent
    ///         if it does not exist yet.
    /// @dev Derives the parent node `parentLabel.tld`; when no name is registered there yet it is
    ///      minted through the registrar with the calling contract as owner, so the caller holds
    ///      the parent authority @custom:function IDotnsRegistry.setSubnodeOwner requires. The
    ///      calling contract must therefore be a registrar controller, otherwise the registrar
    ///      @custom:reverts NotController. When a name already exists at the parent it must be
    /// owned by the caller, otherwise @custom:reverts NotAuthorised, so a name someone else holds
    /// is
    ///      never treated as the caller's parent. Ownership of the subname is then recorded through
    ///      @custom:function IDotnsRegistry.setSubnodeOwner. `persist` is forwarded to the
    /// registry: when false the ownership and resolver record is written but the owner's
    /// `LabelStore` is
    ///      not, and the caller writes the label into the store separately.
    /// @dev The parent is owned by the calling contract's address and is soulbound, so it cannot be
    ///      moved. A caller that migrates to a new address rather than upgrading in place strands
    ///      every parent it minted and can no longer register subnames beneath them; the caller
    /// must upgrade in place, or hold parents under an owner whose address is stable across
    ///      migrations.
    /// @dev `parentLabel` is a single label registered directly under the TLD, so the parent node
    /// is derived as `namehash(tldNode, keccak(parentLabel))`; deeper parents are out of scope for
    ///      this helper.
    /// @param context Subname registration inputs. See @custom:struct SubnameContext.
    /// @return subnode Namehash of the registered subname.
    function registerSubname(SubnameContext memory context) internal returns (bytes32 subnode) {
        IDotnsProtocolRegistry protocolRegistry = context.protocolRegistry;

        bytes32 parentNode = LabelUtils.namehashUnder(
            protocolRegistry.tldNode(), LabelUtils.labelhashMemory(context.parentLabel)
        );

        IDotnsRegistrar registrar = IDotnsRegistrar(protocolRegistry.get(DotnsConstants.REGISTRAR));
        IDotnsRegistry registry = IDotnsRegistry(protocolRegistry.get(DotnsConstants.REGISTRY));

        // Mint the parent on first use, owned by the caller, and pass an empty label so no
        // `LabelStore` is written for it. When it already exists it must both belong to the caller
        // and be soulbound, otherwise a name someone else registered, or one transferred to the
        // caller, would be treated as this caller's parent; both are checked locally rather than
        // assumed from an out-of-contract gate. Subsequent subnames under a parent the caller
        // already owns skip straight to the subnode write.
        if (!registrar.exists(uint256(parentNode))) {
            registrar.register(uint256(parentNode), address(this), "");
            registry.setOwner(parentNode, address(this));
        } else {
            require(
                registry.owner(parentNode) == address(this)
                    && registrar.isSoulbound(uint256(parentNode)),
                IDotnsRegistry.NotAuthorised()
            );
        }

        subnode = registry.setSubnodeOwner(
            IDotnsRegistry.SubnodeRecord({
                parentNode: parentNode,
                subLabel: context.subLabel,
                parentLabel: context.parentLabel,
                owner: context.owner,
                persist: context.persist
            })
        );
    }
}
