// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ILabelStore} from "../store/ILabelStore.sol";
import {IStoreFactory} from "../store/IStoreFactory.sol";

/// @title DotNS Store Utilities Library
/// @notice Canonical helpers for protocol writes into per-user `LabelStore` instances.
/// @dev One auth rule, one write path. Every DotNS consumer (controller, registrar,
///      registry, PoP controller) funnels label writes through `writeLabel` so
///      authorisation and deploy-on-first-use semantics are identical across flows.
/// @custom:security-contact admin@parity.io
library StoreUtils {
    /// @notice Returns the `LabelStore` for `user`, deploying one via the factory if absent.
    /// @dev Deploy-on-demand: a user's store is created on their first protocol write so
    ///      unused accounts never pay the deployment cost. The deploy path is gated by the
    ///      factory, so callers that are not the factory owner and not protocol-registered
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

    /// @notice Writes `label` under `labelhash` for `user`, deploying their `LabelStore` if needed.
    /// @dev Idempotent on locked entries: once a label is locked the call is a no-op rather
    ///      than a revert, so retried protocol flows (e.g. an ERC721 transfer back to a prior
    ///      owner) pass through without failing on the existing lock. Inherits the factory's
    ///      writer authorisation: callers that are not the factory owner and not
    ///      protocol-registered @custom:reverts NotAuthorised when the user has no store yet.
    /// @param factory The store factory.
    /// @param user The label store owner.
    /// @param labelhash The labelhash key.
    /// @param label The label string (typically the full name, e.g. "alice.dot").
    /// @return store The resolved or newly deployed store address.
    function writeLabel(
        IStoreFactory factory,
        address user,
        bytes32 labelhash,
        string memory label
    )
        internal
        returns (address store)
    {
        store = ensureLabelStore(factory, user);
        if (!ILabelStore(store).isLocked(labelhash)) {
            ILabelStore(store).storeLabel(labelhash, label);
        }
    }
}
