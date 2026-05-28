// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";
import {DeploymentNetwork} from "./DeploymentNetwork.sol";

import {StoreFactory} from "../../contracts/store/StoreFactory.sol";
import {DotnsRegistrar} from "../../contracts/registrars/DotnsRegistrar.sol";
import {DotnsReverseResolver} from "../../contracts/resolvers/DotnsReverseResolver.sol";
import {DotnsRegistry} from "../../contracts/registry/DotnsRegistry.sol";
import {DotnsProtocolRegistry} from "../../contracts/registry/DotnsProtocolRegistry.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";

/// @title DeployCore
/// @notice First stage of the DotNS fresh-deploy pipeline. Deploys the
///         protocol registry first, then the foundational name-ownership
///         layer: the Store factory and three UUPS proxies (registrar,
///         reverse resolver, forward registry) that all bind to the protocol
///         registry at init, plus the generic Multicall3 helper for client
///         and tooling batching.
/// @dev Runs in its own `forge script` process; the OpenZeppelin validator's
///      per-call memory never crosses the process boundary into later stages.
///      Every contract is routed through the singleton CREATE2 factory so
///      addresses match across chains.
/// @custom:security-contact admin@parity.io
contract DeployCore is BaseDeployer {
    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(DeploymentNetwork.folder(block.chainid), vm.toString(block.chainid));
        initFactory();

        address protocolRegistry = _deployProtocolRegistry(owner);
        _deployMulticall3(owner);
        _deployStoreFactory(owner, protocolRegistry);
        _deployRegistrar(owner, protocolRegistry);
        _deployReverseResolver(owner, protocolRegistry);
        _deployRegistry(owner, protocolRegistry);

        saveDeployments();

        console.log("=== DeployCore complete ===");
    }

    function _deployProtocolRegistry(address owner) internal returns (address proxy) {
        proxy = _deployUupsCreate2(
            owner,
            "DotnsProtocolRegistry.sol:DotnsProtocolRegistry",
            abi.encodeCall(DotnsProtocolRegistry.initialize, (owner)),
            "protocolRegistry",
            1,
            "DotnsProtocolRegistry"
        );
    }

    function _deployStoreFactory(address owner, address protocolRegistry) internal {
        address factoryAddr = _deployContractCreate2(
            owner,
            "StoreFactory.sol:StoreFactory",
            abi.encode(protocolRegistry),
            "storeFactory",
            1,
            "StoreFactory"
        );
        // StoreFactory deploys its two beacons in its constructor (plain
        // CREATE under the factory's own nonce), so the beacon addresses are
        // deterministic too once the factory's address is fixed.
        StoreFactory factory = StoreFactory(factoryAddr);
        vm.label(factory.labelStoreBeacon(), "LabelStoreBeacon");
        vm.label(factory.userStoreBeacon(), "UserStoreBeacon");
        logDeployment("LabelStoreBeacon", factory.labelStoreBeacon());
        logDeployment("UserStoreBeacon", factory.userStoreBeacon());
    }

    function _deployMulticall3(address owner) internal {
        _deployContractCreate2(
            owner, "Multicall3.sol:Multicall3", "", "multicall3", 2, "Multicall3"
        );
    }

    function _deployRegistrar(
        address owner,
        address protocolRegistry
    )
        internal
        returns (address proxy)
    {
        proxy = _deployUupsCreate2(
            owner,
            "DotnsRegistrar.sol:DotnsRegistrar",
            abi.encodeCall(
                DotnsRegistrar.initialize,
                ("Dotns", "Dotns", IDotnsProtocolRegistry(protocolRegistry), owner)
            ),
            "registrar",
            1,
            "DotnsRegistrar"
        );
    }

    function _deployReverseResolver(
        address owner,
        address protocolRegistry
    )
        internal
        returns (address proxy)
    {
        proxy = _deployUupsCreate2(
            owner,
            "DotnsReverseResolver.sol:DotnsReverseResolver",
            abi.encodeCall(
                DotnsReverseResolver.initialize, (IDotnsProtocolRegistry(protocolRegistry), owner)
            ),
            "reverseResolver",
            1,
            "DotnsReverseResolver"
        );
    }

    function _deployRegistry(
        address owner,
        address protocolRegistry
    )
        internal
        returns (address proxy)
    {
        proxy = _deployUupsCreate2(
            owner,
            "DotnsRegistry.sol:DotnsRegistry",
            abi.encodeCall(
                DotnsRegistry.initialize, (IDotnsProtocolRegistry(protocolRegistry), owner)
            ),
            "registry",
            1,
            "DotnsRegistry"
        );
    }
}
