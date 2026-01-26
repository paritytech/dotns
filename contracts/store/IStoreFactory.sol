// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IStore} from "./IStore.sol";

/// @title IStoreFactory
/// @notice Interface defining factory functions for deploying and managing user-specific stores
/// @dev Each address can deploy a single store instance. Subsequent deployment attempts revert.
/// @custom:security-contact admin@parity.io
interface IStoreFactory {
    /// @notice Deploys a new store contract for the caller
    /// @dev Creates a store instance owned by msg.sender. Reverts if caller already has a deployed store.
    /// @custom:reverts AlreadyDeployed if msg.sender has previously deployed a store
    function deploy() external returns (IStore);

    /// @notice Transfers ownership of a store
    /// @dev The ownership refers to the address which owned the original deployment
    ///      The ownership reffered to here is the mapping not the actual store ownership
    ///          The Factory is an easy way of query all stores deployed so it could happen that
    ///          The actual ownership of the store hasnt changed hands and its advised
    ///          That the owner transfers the store ownership to the owner passed in here
    /// @param newOwner The new owner
    /// @custom:reverts NotOwner if msg.sender is not the owner of the original contract
    function transferOwnership(address newOwner) external;

    /// @notice Retrieves the store contract address deployed by a specific user
    /// @dev Returns the zero address if no store has been deployed by the specified address
    /// @param who The address of the store owner to query
    /// @return The IStore instance deployed by the specified address, or zero address if none exists
    function getDeployedStore(address who) external view returns (IStore);

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
