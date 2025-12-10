// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IETHRegistrarController} from "../ethregistrar/IETHRegistrarController.sol";
import {ENS} from "../registry/ENS.sol";
import {IStoreFactory} from "./IStoreFactory.sol";
import {IStore} from "./IStore.sol";
import {IDotnsRegistrar} from "./IDotnsRegistrar.sol";

/// @title IDotnsRegistrar
/// @notice Orchestrates ENS registration and subdomain management with automated storage.
/// @dev Combines ENS operations with user store management to provide atomic registration workflows.
contract DotnsRegistrar is IDotnsRegistrar {
    IETHRegistrarController public immutable registrar;

    ENS public immutable registry;

    IStoreFactory public immutable storeFactory;

    /// @notice Initializes the orchestrator with required contract addresses.
    /// @param registrarAddress The address of the ETHRegistrarController contract.
    /// @param registryAddress The address of the ENS Registry contract.
    /// @param storeFactoryAddress The address of the StoreFactory contract.
    constructor(address registrarAddress, address registryAddress, address storeFactoryAddress) {
        registrar = IETHRegistrarController(registrarAddress);
        registry = ENS(registryAddress);
        storeFactory = IStoreFactory(storeFactoryAddress);
    }

    /// @inheritdoc IDotnsRegistrar
    function registerAndStore(
        IETHRegistrarController.Registration calldata registration,
        address store
    )
        external
        payable
    {
        registrar.register{value: msg.value}(registration);

        bytes32 key = keccak256(abi.encodePacked(msg.sender, registration.label));
        IStore(store).setValueFor(msg.sender, key, registration.label);

        emit NameRegisteredAndStored(msg.sender, registration.label, store);
    }

    /// @inheritdoc IDotnsRegistrar
    function registerSubdomainAndStore(
        string calldata parentName,
        string calldata subdomain,
        address owner,
        address resolver,
        address store
    )
        external
    {
        bytes32 parentNode = keccak256(abi.encodePacked(bytes32(0), keccak256(bytes(parentName))));

        bytes32 label = keccak256(bytes(subdomain));
        registry.setSubnodeRecord(parentNode, label, owner, resolver, 0);

        bytes32 key = keccak256(abi.encodePacked(owner, subdomain));
        IStore(store).setValueFor(msg.sender, key, subdomain);

        emit SubdomainRegisteredAndStored(owner, parentName, subdomain, store);
    }
}
