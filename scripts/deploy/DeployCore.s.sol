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
import {Multicall3} from "../../contracts/utils/Multicall3.sol";

/// @title DeployCore
/// @notice First stage of the DotNS fresh-deploy pipeline. Bootstraps the
///         CREATE3 factory, deploys the protocol registry through it, records
///         the factory on the registry, then deploys the foundational
///         name-ownership layer: the Store factory and three UUPS proxies
///         (registrar, reverse resolver, forward registry) that all bind to the
///         protocol registry at init, plus the generic Multicall3 helper for
///         client and tooling batching.
/// @dev Runs in its own `forge script` process; the OpenZeppelin validator's
///      per-call memory never crosses the process boundary into later stages.
/// @custom:security-contact admin@parity.io
contract DeployCore is BaseDeployer {
    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(DeploymentNetwork.folder(block.chainid), vm.toString(block.chainid));

        address factory = _bootstrapCreate3Factory(owner);
        address protocolRegistry = _deployProtocolRegistry(owner);
        _registerCreate3Factory(owner, protocolRegistry, factory);

        _deployMulticall3(owner);
        _deployStoreFactory(owner, protocolRegistry);
        _deployRegistrar(owner, protocolRegistry);
        _deployReverseResolver(owner, protocolRegistry);
        _deployRegistry(owner, protocolRegistry);

        saveDeployments();

        console.log("=== DeployCore complete ===");
    }

    function _deployProtocolRegistry(address owner) internal returns (address proxy) {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsProtocolRegistry.sol:DotnsProtocolRegistry",
            abi.encodeCall(DotnsProtocolRegistry.initialize, ()),
            "DotnsProtocolRegistry"
        );
    }

    function _deployStoreFactory(address owner, address protocolRegistry) internal {
        StoreFactory factory = StoreFactory(
            _broadcastDeployCreate3(
                owner,
                "StoreFactory.sol:StoreFactory",
                abi.encode(protocolRegistry, owner),
                "StoreFactory"
            )
        );
        vm.label(address(factory), "StoreFactory");
        vm.label(factory.labelStoreBeacon(), "LabelStoreBeacon");
        vm.label(factory.userStoreBeacon(), "UserStoreBeacon");
        logDeployment("LabelStoreBeacon", factory.labelStoreBeacon());
        logDeployment("UserStoreBeacon", factory.userStoreBeacon());
    }

    function _deployMulticall3(address owner) internal {
        Multicall3 multicall3 = Multicall3(
            _broadcastDeployCreate3(owner, "Multicall3.sol:Multicall3", bytes(""), "Multicall3")
        );
        vm.label(address(multicall3), "Multicall3");
    }

    function _deployRegistrar(
        address owner,
        address protocolRegistry
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsRegistrar.sol:DotnsRegistrar",
            abi.encodeCall(
                DotnsRegistrar.initialize,
                ("Dotns", "Dotns", IDotnsProtocolRegistry(protocolRegistry))
            ),
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
        proxy = _broadcastDeployUups(
            owner,
            "DotnsReverseResolver.sol:DotnsReverseResolver",
            abi.encodeCall(
                DotnsReverseResolver.initialize, (IDotnsProtocolRegistry(protocolRegistry))
            ),
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
        proxy = _broadcastDeployUups(
            owner,
            "DotnsRegistry.sol:DotnsRegistry",
            abi.encodeCall(DotnsRegistry.initialize, (IDotnsProtocolRegistry(protocolRegistry))),
            "DotnsRegistry"
        );
    }
}
