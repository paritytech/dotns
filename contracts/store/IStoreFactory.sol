// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IStore} from "./IStore.sol";

/// @title IStoreFactory
/// @notice Interface defining factory functions for deploying and managing user-specific stores.
/// @dev Each address can deploy a single store instance. Subsequent deployment attempts revert.
// TODO: On fresh deploy, adopt OZ Ownable2Step on Store and use the factory as escrow:
//       1. Alice calls store.transferOwnership(factory) -- pending via Ownable2Step.
//       2. Factory accepts ownership and records the offer (Alice => Bob).
//       3. Bob calls factory.acceptTransfer() -- factory transfers store to Bob and updates mapping.
//       4. If Bob never accepts, Alice calls factory.cancelTransfer() -- factory returns store to Alice.
/// @custom:security-contact admin@parity.io
interface IStoreFactory {
    /// @notice Deploys a new store contract for the caller
    /// @dev Creates a store instance owned by msg.sender. Reverts if caller already has a deployed
    /// store. @custom:reverts AlreadyDeployed if msg.sender has previously deployed a store
    function deploy() external returns (IStore);

    /// @notice Transfers the factory lookup mapping from msg.sender to newOwner.
    /// @dev Only moves the factory's internal `_deployedStores` pointer, not the Store's
    ///      Ownable ownership. The Store's Ownable owner must already be `newOwner` before
    ///      this call succeeds.
    // TODO: On fresh deploy, replace with Ownable2Step pattern.
    /// @param newOwner The address to receive the factory mapping.
    function transferOwnership(address newOwner) external;

    /// @notice Retrieves the store contract address deployed by a specific user
    /// @dev Returns the zero address if no store has been deployed by the specified address
    /// @param who The address of the store owner to query
    /// @return The IStore instance deployed by the specified address, or zero address if none
    /// exists
    function getDeployedStore(address who) external view returns (IStore);

    /// @notice Retrieves all deployed stores
    /// @return An array of all IStore instances deployed via this factory
    function getAllDeployedStores() external view returns (IStore[] memory);

    /// @notice Emitted when a store is successfully deployed
    /// @param owner The address that deployed and owns the store
    /// @param store The address of the newly deployed store contract
    event StoreDeployed(address indexed owner, IStore indexed store);

    /// @notice Thrown when attempting to deploy a store for an address that already has one
    /// @param existingStore The address of the store already deployed by the caller
    error AlreadyDeployed(address existingStore);
    /// @notice Thrown when attempting to transfer ownership of the store to the caller
    /// @param store The address of the store which failed to transfer ownership
    error InvalidOwnership(address store);

    /// @notice Thrown when a non owner tries transferring a deployed store
    /// @param caller The address attempting to make the transfer
    error InvalidTransfer(address caller);

    /// @notice Emmitted when a store has been transferred to a new owner
    /// @param oldOwner The address which owned the store
    /// @param newOwner The address which owns the new store
    event OwnershipTransfered(address indexed oldOwner, address indexed newOwner);
}
