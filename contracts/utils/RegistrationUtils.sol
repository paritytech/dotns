// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IDotnsRegistrar} from "../registrars/IDotnsRegistrar.sol";
import {IDotnsRegistry} from "../registry/IDotnsRegistry.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {IStoreFactory} from "../store/IStoreFactory.sol";
import {StoreUtils} from "./StoreUtils.sol";
import {DotnsConstants} from "./DotnsConstants.sol";

/// @title DotNS Registration Utilities Library
/// @notice Single canonical implementation of the "mint + forward-registry + store-write"
///         triad used by every DotNS registration flow.
/// @dev Exists so that every controller (public commit-reveal, PoP gateway, future
///      privileged flows) calls the same sequence. Without this library each controller
///      re-implements the sequence, and the implementations drift.
/// @dev Scope: this library is deliberately minimal. It only performs the steps
///      that every registration flow needs regardless of policy:
///        1. Mint the ERC721 name token on the base registrar.
///        2. Write the forward registry entry (node => owner + default resolver).
///        3. Resolve the per-user `LabelStore` (deploying on demand) so the caller
///           can pass it back. The registrar writes the labels-only store entry
///           internally.
///      Flow-specific concerns (pricing, reverse-record setting, chat-key persistence,
///      reservation queue mutation) stay inside the calling controller.
/// @custom:security-contact admin@parity.io
library RegistrationUtils {
    using StoreUtils for IStoreFactory;

    /// @notice Inputs describing a single name registration.
    /// @dev Passed as a struct so callers do not have to thread a growing positional
    ///      argument list, and so future additions (e.g. a subname parent node) can
    ///      be made additively without breaking call sites.
    /// @param protocolRegistry The protocol-level address registry for sibling lookups.
    /// @param user Address receiving the name.
    /// @param label Human-readable label (without the TLD).
    /// @param labelhash `keccak256(bytes(label))`.
    /// @param node `namehash(DOT_NODE, labelhash)`.
    struct RegistrationContext {
        IDotnsProtocolRegistry protocolRegistry;
        address user;
        string label;
        bytes32 labelhash;
        bytes32 node;
    }

    /// @notice Resolved sibling contracts for a registration call.
    /// @dev Held as a struct internally so the helper can pass a single value to the
    ///      downstream steps rather than three separate locals. Never returned to
    ///      callers; kept in memory for the lifetime of one `registerAndStore`.
    struct Siblings {
        IDotnsRegistrar registrar;
        IDotnsRegistry registry;
        IStoreFactory storeFactory;
    }

    /// @notice Performs the canonical mint + forward-registry + store-write sequence.
    /// @dev Callable by any authorised controller. Emits no events; each controller
    ///      emits its own flow-level event after this returns, so behavioural drift
    ///      between flows stays contained at the emission layer rather than at the
    ///      underlying state-transition layer. Store authorisation is handled by the
    ///      protocol registry (`isRegisteredAddress`) on every write, so no per-store
    ///      allowlist bookkeeping is needed here.
    /// @dev The registrar writes the `LabelStore` entry directly inside `register`
    ///      so this helper deliberately does not call `StoreUtils.writeLabel`.
    ///      Doing it twice would deploy or touch the store on every flow and
    ///      could conflict with the registrar's locked-entry semantics.
    /// @param context Registration inputs. See @custom:struct RegistrationContext.
    /// @return labelStore The resolved or newly deployed `LabelStore` address for `context.user`.
    function registerAndStore(RegistrationContext memory context)
        internal
        returns (address labelStore)
    {
        Siblings memory siblings = _resolveSiblings(context.protocolRegistry);

        siblings.registrar.register(uint256(context.node), context.user, context.label);
        siblings.registry.setOwner(context.node, context.user);

        labelStore = siblings.storeFactory.getLabelStore(context.user);
    }

    /// @notice Resolves sibling contracts via the protocol registry.
    /// @dev Exists so that resolution is one round-trip through a single helper and
    ///      not duplicated inline at every call site. If protocol-registry key
    ///      conventions change, the change lands here.
    function _resolveSiblings(IDotnsProtocolRegistry protocolRegistry)
        private
        view
        returns (Siblings memory siblings)
    {
        siblings = Siblings({
            registrar: IDotnsRegistrar(protocolRegistry.get(DotnsConstants.REGISTRAR)),
            registry: IDotnsRegistry(protocolRegistry.get(DotnsConstants.REGISTRY)),
            storeFactory: IStoreFactory(protocolRegistry.get(DotnsConstants.STORE_FACTORY))
        });
    }
}
