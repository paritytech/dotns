// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IStoreFactory} from "./IStoreFactory.sol";
import {IStore} from "./IStore.sol";
import {Store} from "./Store.sol";

/// @title StoreFactory
/// @notice Factory contract for deploying and tracking user-specific store instances
/// @dev Uses CREATE opcode for deployment. Each address can deploy exactly one store.
/// @custom:security-contact admin@parity.io
contract StoreFactory is IStoreFactory {
    /// @notice Maps owner addresses to their deployed store contracts
    /// @dev Zero address indicates no store has been deployed for that address
    mapping(address owner => IStore store) private _deployedStores;

    /// @inheritdoc IStoreFactory
    function deploy() external returns (IStore) {
        IStore existingStore = _deployedStores[msg.sender];
        require(address(existingStore) == address(0), AlreadyDeployed(address(existingStore)));
        Store newStore = new Store();
        _deployedStores[msg.sender] = IStore(address(newStore));
        newStore.transferOwnership(msg.sender);
        require(newStore.owner() == msg.sender, InvalidOwnership(address(newStore)));
        emit StoreDeployed(msg.sender, newStore);
        return newStore;
    }

    /// @inheritdoc IStoreFactory
    function transferOwnership(address newOwner) external {
        IStore store = _deployedStores[msg.sender];
        require(address(store) != address(0), InvalidTransfer(msg.sender));

        if (newOwner != address(0)) {
            require(address(_deployedStores[newOwner]) == address(0), InvalidTransfer(newOwner));
        }

        emit OwnershipTransfered(msg.sender, newOwner);

        _deployedStores[newOwner] = store;
        _deployedStores[msg.sender] = IStore(address(0));
    }

    /// @inheritdoc IStoreFactory
    function getDeployedStore(address who) external view returns (IStore) {
        return _deployedStores[who];
    }
}
