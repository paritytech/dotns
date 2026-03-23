// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Store} from "../store/Store.sol";
import {IStore} from "../store/IStore.sol";
import {IStoreFactory} from "../store/IStoreFactory.sol";

/// @title DotNS Store Utilities Library
/// @notice Provides Store acquisition and management utilities for any contract that requires a store.
///
/// @dev Store Resolution Strategy:
///      The library implements a two-tier resolution strategy:
///      1. Direct lookup: Store already exists and is mapped to the target owner.
///      2. Fresh deployment: No store exists; deploy, authorize controllers, and transfer ownership.
///
/// @dev Ownership Model:
///      Two distinct ownership concepts exist:
///      - Factory mapping: Tracks which address has which Store for lookup purposes.
///      - Store.owner (Ownable): Controls who can authorize contracts to write to the Store.
///      Both must be transferred to the target owner for correct operation.
///
/// @custom:security-contact admin@parity.io
library StoreUtils {
    /// @notice Key prefix for DotNS-written Store immutable entries ("dotns.registered").
    /// @dev Used by all contracts that read or write registration labels to per-user Stores.
    ///      The value is `bytes32("dotns.registered")` — safe because the string fits in 32 bytes.
    /// casting to 'bytes32' is safe because the string fits in 32 bytes
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant DOTNS_REGISTERED_KEY = bytes32("dotns.registered");

    /// @notice Computes the Store key for a registered label.
    /// @dev Returns `keccak256(abi.encodePacked(DOTNS_REGISTERED_KEY, labelhash))`.
    ///      Uses scratch-space assembly to avoid ABI-encoding overhead.
    /// @param labelhash `keccak256(bytes(label))`.
    /// @return key Store key used for DotNS-written registration entries.
    function storeKey(bytes32 labelhash) internal pure returns (bytes32 key) {
        bytes32 prefix = DOTNS_REGISTERED_KEY;
        assembly {
            let pointer := mload(0x40)
            mstore(pointer, prefix)
            mstore(add(pointer, 0x20), labelhash)
            key := keccak256(pointer, 0x40)
        }
    }

    /// @notice Returns the Store for `owner`, deploying one if needed.
    /// @dev Unifies Store acquisition across registration flows. Handles two cases:
    ///
    ///      Case 1 - Direct Lookup:
    ///      Store already mapped to `owner` in the factory. Returns immediately.
    ///
    ///      Case 2 - Fresh Deployment:
    ///      No store exists for owner. Deploys a new Store under the calling controller,
    ///      authorizes all provided controllers for DotNS writes, transfers Store.owner
    ///      to the target owner, then migrates the factory mapping to owner.
    ///
    /// @dev Deployment Flow:
    ///      1. factory.deploy() creates Store with msg.sender as Ownable owner
    ///      2. authorizeDotnsController() succeeds because msg.sender is owner
    ///      3. store.transferOwnership(owner) transfers Ownable ownership
    ///      4. factory.transferOwnership(owner) transfers factory mapping
    ///      After step 4, msg.sender has no factory mapping and can deploy again.
    ///
    /// @dev Reentrancy Consideration:
    ///      No explicit reentrancy guard is applied. The deployed Store contract
    ///      does not make external calls that could re-enter this function.
    ///      StoreFactory and Store are not upgradeable.
    ///
    /// @param factory The StoreFactory instance used to resolve or deploy Stores.
    /// @param controllers The addresses that should be authorized as DotNS controllers.
    /// @param owner The target Store owner address.
    /// @return store The resolved or newly deployed Store instance.
    function getOrCreateStore(
        IStoreFactory factory,
        address[] memory controllers,
        address owner
    )
        internal
        returns (Store store)
    {
        IStore existing = factory.getDeployedStore(owner);
        if (address(existing) != address(0)) {
            return Store(address(existing));
        }

        store = Store(address(factory.deploy()));

        for (uint256 i; i < controllers.length; i++) {
            store.authorizeDotnsController(controllers[i]);
        }

        store.transferOwnership(owner);
        factory.transferOwnership(owner);
    }

    /// @notice Checks whether a Store exists for the given owner.
    /// @dev Performs a read-only lookup against the factory without any state changes.
    /// @param factory The StoreFactory instance to query.
    /// @param owner The address to check for an existing Store.
    /// @return exists True if a Store is mapped to `owner`, false otherwise.
    function hasStore(IStoreFactory factory, address owner) internal view returns (bool exists) {
        exists = address(factory.getDeployedStore(owner)) != address(0);
    }

    /// @notice Returns the Store address for an owner without deploying.
    /// @dev Returns zero address if no Store exists. Use `hasStore` for boolean checks.
    /// @param factory The StoreFactory instance to query.
    /// @param owner The address to look up.
    /// @return store The Store address, or zero if none exists.
    function getStore(IStoreFactory factory, address owner) internal view returns (address store) {
        store = address(factory.getDeployedStore(owner));
    }
}
