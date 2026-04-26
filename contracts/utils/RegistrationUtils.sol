// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IDotnsRegistrar} from "../registrars/IDotnsRegistrar.sol";
import {IDotnsRegistry} from "../registry/IDotnsRegistry.sol";
import {IDotnsReverseResolver} from "../resolvers/IDotnsReverseResolver.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {IStoreFactory} from "../store/IStoreFactory.sol";
import {Store} from "../store/Store.sol";
import {StoreUtils} from "./StoreUtils.sol";
import {DotnsConstants} from "./DotnsConstants.sol";

/// @title DotNS Registration Utilities Library
/// @notice Single canonical implementation of the "mint + forward-registry + store-write"
///         triad used by every DotNS registration flow.
/// @dev Exists so that every controller (public commit-reveal, PoP gateway, future
///      privileged flows) calls the same sequence. Without this library each controller
///      re-implements the sequence, and the implementations drift.
///
/// @dev Scope:
///      This library is deliberately minimal. It only performs the steps that every
///      registration flow needs regardless of policy:
///        1. Mint the ERC721 name token on the base registrar.
///        2. Write the forward registry entry (node => owner + default resolver).
///        3. Ensure a Store exists for the owner and write the registration entry.
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
    ///      Store-authorisation step rather than five separate locals. Never returned
    ///      to callers; kept in memory for the lifetime of one `registerAndStore`.
    struct Siblings {
        IDotnsRegistrar registrar;
        IDotnsRegistry registry;
        IDotnsReverseResolver reverseResolver;
        IStoreFactory storeFactory;
    }

    /// @notice Returns the canonical set of addresses authorised on every
    ///         DotNS-owned Store.
    /// @dev Single source of truth for the Store-authorisation allowlist. Every path
    ///      that creates or touches a Store (controller registration, registry
    ///      subnode write, registrar transfer sync) must resolve the set through
    ///      this helper so authorised-caller drift between flows is impossible. The
    ///      set includes: the forward registry, the base registrar, the
    ///      commit-reveal controller, and the PoP controller if configured.
    ///      Zero-address slots are filtered so unset protocol-registry keys do not
    ///      leak into `Store.authorizeDotnsController`.
    /// @param protocolRegistry The protocol-level address registry.
    /// @return controllers Canonical address list suitable for
    ///         {StoreUtils-getOrCreateStore} / {StoreUtils-writeToStore}.
    function storeControllers(IDotnsProtocolRegistry protocolRegistry)
        internal
        view
        returns (address[] memory controllers)
    {
        address registry = protocolRegistry.get(DotnsConstants.REGISTRY);
        address registrar = protocolRegistry.get(DotnsConstants.REGISTRAR);
        address controller = protocolRegistry.get(DotnsConstants.CONTROLLER);
        address popController = protocolRegistry.get(DotnsConstants.POP_CONTROLLER);

        uint256 count;
        if (registry != address(0)) count++;
        if (registrar != address(0)) count++;
        if (controller != address(0)) count++;
        if (popController != address(0)) count++;

        controllers = new address[](count);
        uint256 i;
        if (registry != address(0)) {
            controllers[i++] = registry;
        }
        if (registrar != address(0)) {
            controllers[i++] = registrar;
        }
        if (controller != address(0)) {
            controllers[i++] = controller;
        }
        if (popController != address(0)) {
            controllers[i++] = popController;
        }
    }

    /// @notice Performs the canonical mint + forward-registry + store-write sequence.
    /// @dev Callable by any authorised controller. Emits no events; each controller
    ///      emits its own flow-level event after this returns, so behavioural drift
    ///      between flows stays contained at the emission layer rather than at the
    ///      underlying state-transition layer.
    ///
    ///      The three-element `controllers` array passed to `writeToStore` matches the
    ///      set authorised on every DotNS-owned Store: the calling controller, the
    ///      forward registry (for subnode writes), and the base registrar (for transfer
    ///      writes). Keeping this set uniform across flows is what lets every Store be
    ///      authored by any of the three without per-flow Store-permission drift.
    /// @param context Registration inputs. See {RegistrationContext}.
    /// @return store The resolved or newly deployed Store for `context.user`.
    function registerAndStore(RegistrationContext memory context) internal returns (Store store) {
        Siblings memory siblings = _resolveSiblings(context.protocolRegistry);

        siblings.registrar.register(uint256(context.node), context.user, context.label);
        siblings.registry.setOwner(context.node, context.user, address(siblings.reverseResolver));

        address[] memory controllers = storeControllers(context.protocolRegistry);

        string memory fullName = string.concat(context.label, DotnsConstants.TLD);
        store = siblings.storeFactory
            .writeToStore(controllers, context.user, context.labelhash, fullName);
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
            reverseResolver: IDotnsReverseResolver(
                protocolRegistry.get(DotnsConstants.REVERSE_RESOLVER)
            ),
            storeFactory: IStoreFactory(protocolRegistry.get(DotnsConstants.STORE_FACTORY))
        });
    }
}
