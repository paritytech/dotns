// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IETHRegistrarController} from "../ethregistrar/IETHRegistrarController.sol";

/// @title IDotnsRegistrar
/// @notice Interface for orchestrating ENS registration and subdomain management with automated storage.
/// @dev Combines ENS registration, subdomain creation, and user store operations in atomic transactions.
///      Requires users to deploy their store via StoreFactory before using these functions.
interface IDotnsRegistrar {
    /// @notice Emitted when an ENS name is registered and stored successfully.
    /// @param user The address that registered the name.
    /// @param subdomain The subdomain that was registered and stored.
    /// @param store The address of the user store where the subdomain was recorded.
    event NameRegisteredAndStored(address indexed user, string subdomain, address indexed store);

    /// @notice Emitted when a subdomain is created and stored successfully.
    /// @param owner The address that owns the subdomain.
    /// @param parentName The parent domain under which the subdomain was created.
    /// @param subdomain The subdomain that was created and stored.
    /// @param store The address of the user store where the subdomain was recorded.
    event SubdomainRegisteredAndStored(
        address indexed owner, string parentName, string subdomain, address indexed store
    );

    /// @notice Register a new ENS name and automatically record it in the specified user store.
    /// @dev Performs two atomic operations: registers the name via ETHRegistrarController and
    ///      records the registration in the user's store. The entire transaction reverts if any step fails.
    ///      The store must be deployed via StoreFactory and must have authorized this registrar contract.
    /// @param registration The registration parameters required by ETHRegistrarController.
    /// @param store The address of the user's deployed store contract where the subdomain will be recorded.
    /// @custom:reverts If registration fails, store is not deployed, store has not authorized this contract,
    ///                 or storage operation fails.
    function registerAndStore(
        IETHRegistrarController.Registration calldata registration,
        address store
    )
        external
        payable;

    /// @notice Create a subdomain under an existing domain and record it in the specified user store.
    /// @dev Performs two atomic operations: creates the subnode in ENS registry and records the subdomain
    ///      in the owner's store. The entire transaction reverts if any step fails.
    ///      The store must be deployed via StoreFactory and must have authorized this registrar contract.
    /// @param parentName The parent domain name under which to create the subdomain.
    /// @param subdomain The subdomain label to create.
    /// @param owner The address that will own the subdomain.
    /// @param resolver The resolver address to set for the subdomain.
    /// @param store The address of the owner's deployed store contract where the subdomain will be recorded.
    /// @custom:reverts If subnode creation fails, store is not deployed, store has not authorized this contract,
    ///                 or storage operation fails.
    function registerSubdomainAndStore(
        string calldata parentName,
        string calldata subdomain,
        address owner,
        address resolver,
        address store
    )
        external;
}
