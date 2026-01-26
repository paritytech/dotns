// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {PopRules, IPopRules} from "../contracts/pop/PopRules.sol";
import {DotnsRegistrar, IDotnsRegistrar} from "../contracts/registrars/DotnsRegistrar.sol";
import {DotnsRegistrarController, IDotnsRegistrarController} from "../contracts/registrars/DotnsRegistrarController.sol";
import {DotnsRegistry, IDotnsRegistry} from "../contracts/registry/DotnsRegistry.sol";
import {DotnsReverseResolver, IDotnsReverseResolver} from "../contracts/resolvers/DotnsReverseResolver.sol";
import {DotnsContentResolver} from "../contracts/resolvers/DotnsContentResolver.sol";
import {DotnsResolver} from "../contracts/resolvers/DotnsResolver.sol";
import {StoreFactory, IStoreFactory} from "../contracts/store/StoreFactory.sol";

/// @title DotnsDeployer
contract DotnsDeployer is BaseDeployer {
    uint256 public constant rentPrice = 2e15 wei;

    StoreFactory public storeFactory;

    PopRules public popRules;
    DotnsRegistrar public dotnsRegistrar;
    DotnsRegistry public dotnsRegistry;
    DotnsReverseResolver public dotnsReverseResolver;
    DotnsContentResolver public dotnsContentResolver;
    DotnsResolver public dotnsResolver;
    DotnsRegistrarController public dotnsRegistrarController;

    function run() external {
        uint256 chainId = block.chainid;

        vm.warp(365 days);

        console.log("Current blocktime", block.timestamp);

        initDeployment();

        address OWNER = msg.sender;
        vm.startBroadcast(OWNER);
        vm.label(OWNER, "OWNER");

        // StoreFactory
        storeFactory = new StoreFactory();
        vm.label(address(storeFactory), "StoreFactory");
        logDeployment("StoreFactory", address(storeFactory));

        // DotnsRegistrar
        address dotnsRegistrarProxy = Upgrades.deployUUPSProxy(
            "DotnsRegistrar.sol:DotnsRegistrar",
            abi.encodeCall(DotnsRegistrar.initialize, ("Dotns", "Dotns"))
        );
        dotnsRegistrar = DotnsRegistrar(dotnsRegistrarProxy);
        vm.label(dotnsRegistrarProxy, "DotnsRegistrar");
        logDeployment("DotnsRegistrar", dotnsRegistrarProxy);

        // DotnsReverseResolver
        address dotnsReverseResolverProxy = Upgrades.deployUUPSProxy(
            "DotnsReverseResolver.sol:DotnsReverseResolver",
            abi.encodeCall(DotnsReverseResolver.initialize, ())
        );
        dotnsReverseResolver = DotnsReverseResolver(dotnsReverseResolverProxy);
        vm.label(dotnsReverseResolverProxy, "DotnsReverseResolver");
        logDeployment("DotnsReverseResolver", dotnsReverseResolverProxy);

        // DotnsRegistry
        address dotnsRegistryProxy = Upgrades.deployUUPSProxy(
            "DotnsRegistry.sol:DotnsRegistry", abi.encodeCall(DotnsRegistry.initialize, (IDotnsReverseResolver(dotnsReverseResolverProxy)))
        );
        dotnsRegistry = DotnsRegistry(dotnsRegistryProxy);
        vm.label(dotnsRegistryProxy, "DotnsRegistry");
        logDeployment("DotnsRegistry", dotnsRegistryProxy);

        // DotnsContentResolver
        address dotnsContentResolverProxy = Upgrades.deployUUPSProxy(
            "DotnsContentResolver.sol:DotnsContentResolver",
            abi.encodeCall(DotnsContentResolver.initialize, (IDotnsRegistry(dotnsRegistryProxy)))
        );
        dotnsContentResolver = DotnsContentResolver(dotnsContentResolverProxy);
        vm.label(dotnsContentResolverProxy, "DotnsContentResolver");
        logDeployment("DotnsContentResolver", dotnsContentResolverProxy);

        // DotnsResolver
        address dotnsResolverProxy = Upgrades.deployUUPSProxy(
            "DotnsResolver.sol:DotnsResolver",
            abi.encodeCall(DotnsResolver.initialize, (IDotnsRegistry(dotnsRegistryProxy)))
        );
        dotnsResolver = DotnsResolver(dotnsResolverProxy);
        vm.label(dotnsResolverProxy, "DotnsResolver");
        logDeployment("DotnsResolver", dotnsResolverProxy);

        // PopRules
        address popRulesProxy = Upgrades.deployUUPSProxy(
            "PopRules.sol:PopRules", abi.encodeCall(PopRules.initialize, (rentPrice))
        );
        popRules = PopRules(popRulesProxy);
        vm.label(popRulesProxy, "PopRules");
        logDeployment("PopRules", popRulesProxy);

        // DotnsRegistrarController
        address dotnsRegistrarControllerProxy = Upgrades.deployUUPSProxy(
            "DotnsRegistrarController.sol:DotnsRegistrarController",
            abi.encodeCall(
                DotnsRegistrarController.initialize,
                (
                    IDotnsRegistrar(dotnsRegistrarProxy),
                    IDotnsRegistry(dotnsRegistryProxy),
                    IDotnsReverseResolver(dotnsReverseResolverProxy),
                    IPopRules(popRulesProxy),
                    IStoreFactory(address(storeFactory)),
                    6 seconds,
                    1 days
                )
            )
        );
        dotnsRegistrarController = DotnsRegistrarController(dotnsRegistrarControllerProxy);
        vm.label(dotnsRegistrarControllerProxy, "DotnsRegistrarController");
        logDeployment("DotnsRegistrarController", dotnsRegistrarControllerProxy);

        // Wire dependencies
        dotnsReverseResolver.updateRegistrar(dotnsRegistrarControllerProxy);
        popRules.updateEthRegistry(dotnsRegistrarControllerProxy);
        dotnsRegistrar.addController(IDotnsRegistrarController(dotnsRegistrarControllerProxy));
        dotnsRegistry.updateRegistrarController(IDotnsRegistrarController(dotnsRegistrarControllerProxy));

        vm.stopBroadcast();

        saveDeployments(_getDeploymentFolder(), vm.toString(chainId));
    }

    function _getDeploymentFolder() internal view returns (string memory directory) {
        directory = "localhost";
        if (block.chainid == 420420422) {
            directory = "paseo";
        } else if (block.chainid == 420420420) {
            directory = "paseo-local";
        }
    }
}
