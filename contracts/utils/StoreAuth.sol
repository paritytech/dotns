// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IDotnsController} from "../registrars/IDotnsController.sol";
import {IDotnsRegistrar} from "../registrars/IDotnsRegistrar.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "./DotnsConstants.sol";

/// @title StoreAuth
/// @notice Decides which protocol components may act on a user's store.
/// @dev Registry membership is not authority. `DotnsProtocolRegistry` is an address book kept so
///      consumers can discover the protocol, and `isRegisteredAddress` answers true for every
///      address under every key, including entries that exist only to be found. Using it as the
///      gate hands store authority to whatever is registered next, and the registry has no
///      delete, so `set` can only repoint a key rather than clear it. A registered call
///      forwarder is the sharpest case: it makes the call anyone asks it to, and the store sees
///      the forwarder as its caller.
/// @dev Authority is instead the registrar, the registry, and whatever the registrar currently
///      accepts as a controller. Controllers are read from
///      @custom:function IDotnsRegistrar.controllers rather than from a registry key so that a
///      controller added through `addController` can write the labels it mints, without a second
///      registration step or a beacon upgrade of every deployed store.
/// @custom:security-contact admin@parity.io
library StoreAuth {
    /// @notice Whether `caller` is a protocol component allowed to act on a user's store.
    /// @dev Ordered by how often each one writes: the registrar on every mint and transfer, a
    ///      controller on a registration or a gateway name, and the registry on a subname.
    /// @param protocolRegistry The canonical DotNS protocol registry.
    /// @param caller The address being checked, normally `msg.sender`.
    /// @return authorised True if `caller` is the registrar, an authorised controller, or the
    ///         registry.
    function isStoreWriter(
        address protocolRegistry,
        address caller
    )
        internal
        view
        returns (bool authorised)
    {
        // An unset key reads as the zero address, so a zero caller would match it on a partially
        // wired deployment. Unreachable through a real call, rejected anyway.
        if (caller == address(0)) return false;

        IDotnsProtocolRegistry registry = IDotnsProtocolRegistry(protocolRegistry);

        address registrar = registry.get(DotnsConstants.REGISTRAR);
        if (caller == registrar) return true;

        // Skipped rather than called on a registry that has no registrar yet: a staticcall to an
        // address with no code returns empty and would revert on decode. A non-zero key pointing
        // at a codeless address still reverts here, which fails closed and is an operator error
        // the deploy verification catches; an extcodesize probe on every write is not worth it.
        if (
            registrar != address(0)
                && IDotnsRegistrar(registrar).controllers(IDotnsController(caller))
        ) {
            return true;
        }

        return caller == registry.get(DotnsConstants.REGISTRY);
    }
}
