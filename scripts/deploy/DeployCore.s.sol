// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";
import {DeploymentNetwork} from "./DeploymentNetwork.sol";

import {StoreFactory} from "../../contracts/store/StoreFactory.sol";
import {DotnsRegistrar, IDotnsRegistrar} from "../../contracts/registrars/DotnsRegistrar.sol";
import {
    DotnsReverseResolver,
    IDotnsReverseResolver
} from "../../contracts/resolvers/DotnsReverseResolver.sol";
import {DotnsRegistry} from "../../contracts/registry/DotnsRegistry.sol";

/// @title DeployCore
/// @notice First stage of the DotNS fresh-deploy pipeline. Deploys the
///         foundational name-ownership layer: the Store factory (plain
///         contract) and three UUPS proxies (registrar, reverse resolver,
///         forward registry). Records every address on the deployment manifest
///         so downstream stages can resolve them without redeploying.
/// @dev Runs in its own `forge script` process; the OpenZeppelin validator's
///      per-call memory never crosses the process boundary into later stages.
/// @custom:security-contact admin@parity.io
contract DeployCore is BaseDeployer {
    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(DeploymentNetwork.folder(block.chainid), vm.toString(block.chainid));

        _deployStoreFactory(owner);
        address registrar = _deployRegistrar(owner);
        address reverseResolver = _deployReverseResolver(owner);
        _deployRegistry(owner, registrar, reverseResolver, _readAddress("StoreFactory"));

        saveDeployments();

        console.log("=== DeployCore complete ===");
    }

    function _deployStoreFactory(address owner) internal {
        vm.startBroadcast(owner);
        StoreFactory factory = new StoreFactory();
        vm.stopBroadcast();
        vm.label(address(factory), "StoreFactory");
        logDeployment("StoreFactory", address(factory));
    }

    function _deployRegistrar(address owner) internal returns (address proxy) {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsRegistrar.sol:DotnsRegistrar",
            abi.encodeCall(DotnsRegistrar.initialize, ("Dotns", "Dotns")),
            "DotnsRegistrar"
        );
    }

    function _deployReverseResolver(address owner) internal returns (address proxy) {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsReverseResolver.sol:DotnsReverseResolver",
            abi.encodeCall(DotnsReverseResolver.initialize, ()),
            "DotnsReverseResolver"
        );
    }

    function _deployRegistry(
        address owner,
        address registrar,
        address reverseResolver,
        address storeFactory
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsRegistry.sol:DotnsRegistry",
            abi.encodeCall(
                DotnsRegistry.initialize,
                (
                    IDotnsRegistrar(registrar),
                    IDotnsReverseResolver(reverseResolver),
                    StoreFactory(storeFactory)
                )
            ),
            "DotnsRegistry"
        );
    }
}
