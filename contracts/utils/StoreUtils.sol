// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ILabelStore} from "../store/ILabelStore.sol";
import {IStoreFactory} from "../store/IStoreFactory.sol";

/// @title DotNS Store Utilities Library
/// @notice Canonical helpers for protocol writes into per-user `LabelStore` instances.
/// @dev One auth rule, one write path. Every DotNS consumer (controller, registrar,
///      registry, PoP controller) funnels label writes through `writeNewLabel` so
///      authorisation, deploy-on-first-use and conflict handling are identical across flows.
/// @custom:security-contact admin@parity.io
library StoreUtils {
    /// @notice Thrown when a name being registered already has a different label entry.
    /// @param store The label store holding the conflicting entry.
    /// @param labelhash The key that is already occupied.
    /// @param existing The label already stored under `labelhash`.
    error LabelEntryConflict(address store, bytes32 labelhash, string existing);

    /// @notice Returns the `LabelStore` for `user`, deploying one via the factory if absent.
    /// @dev Deploy-on-demand: a user's store is created on their first protocol write so
    ///      unused accounts never pay the deployment cost. The deploy path is gated by the
    ///      factory, so callers that are not the factory owner and not a store writer
    ///      @custom:reverts NotAuthorised when a deployment is required.
    /// @param factory The store factory.
    /// @param user The user whose label store is being resolved.
    /// @return store The resolved or newly deployed store address.
    function ensureLabelStore(IStoreFactory factory, address user)
        internal
        returns (address store)
    {
        store = factory.getLabelStore(user);
        if (store == address(0)) {
            store = factory.deployLabelStoreFor(user);
        }
    }

    /// @notice Writes `label` for a name being registered, rejecting a conflicting entry.
    /// @dev An existing entry is tolerated only when it already holds `label`. An entry saying
    ///      something else was put there by someone else and must not be silently honoured:
    ///      `storeLabel` is single-write with no delete, so accepting it would leave the name
    ///      permanently mislabelled and untransferable. Matching entries stay a no-op, which keeps
    ///      re-registration by a previous holder, and a transfer back to one, working.
    /// @param factory The store factory.
    /// @param user The label store owner.
    /// @param labelhash The labelhash key.
    /// @param label The label string (typically the full name, e.g. "alice.dot").
    /// @return store The resolved or newly deployed store address.
    function writeNewLabel(
        IStoreFactory factory,
        address user,
        bytes32 labelhash,
        string memory label
    )
        internal
        returns (address store)
    {
        store = ensureLabelStore(factory, user);
        if (ILabelStore(store).isLocked(labelhash)) {
            string memory existing = ILabelStore(store).getLabel(labelhash);
            require(
                keccak256(bytes(existing)) == keccak256(bytes(label)),
                LabelEntryConflict(store, labelhash, existing)
            );
            return store;
        }
        ILabelStore(store).storeLabel(labelhash, label);
    }
}
