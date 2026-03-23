// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {PopRules, IPopRules} from "../contracts/pop/PopRules.sol";
import {DotnsRegistrar, IDotnsRegistrar} from "../contracts/registrars/DotnsRegistrar.sol";
import {
    DotnsRegistrarController,
    IDotnsRegistrarController
} from "../contracts/registrars/DotnsRegistrarController.sol";
import {DotnsRegistry, IDotnsRegistry} from "../contracts/registry/DotnsRegistry.sol";
import {
    DotnsReverseResolver,
    IDotnsReverseResolver
} from "../contracts/resolvers/DotnsReverseResolver.sol";
import {DotnsContentResolver} from "../contracts/resolvers/DotnsContentResolver.sol";
import {DotnsResolver} from "../contracts/resolvers/DotnsResolver.sol";
import {StoreFactory, IStoreFactory} from "../contracts/store/StoreFactory.sol";
import {
    DotnsProtocolRegistry,
    IDotnsProtocolRegistry
} from "../contracts/registry/DotnsProtocolRegistry.sol";

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
    DotnsProtocolRegistry public protocolRegistry;

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
            "DotnsRegistry.sol:DotnsRegistry",
            abi.encodeCall(
                DotnsRegistry.initialize,
                (
                    IDotnsRegistrar(dotnsRegistrarProxy),
                    IDotnsReverseResolver(dotnsReverseResolverProxy),
                    storeFactory
                )
            )
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

        // DotnsProtocolRegistry
        address protocolRegistryProxy = Upgrades.deployUUPSProxy(
            "DotnsProtocolRegistry.sol:DotnsProtocolRegistry",
            abi.encodeCall(DotnsProtocolRegistry.initialize, ())
        );
        protocolRegistry = DotnsProtocolRegistry(protocolRegistryProxy);
        vm.label(protocolRegistryProxy, "DotnsProtocolRegistry");
        logDeployment("DotnsProtocolRegistry", protocolRegistryProxy);

        // Registrar needs controller in its own mapping (not resolved via protocol registry)
        dotnsRegistrar.addController(IDotnsRegistrarController(dotnsRegistrarControllerProxy));

        // Wire protocol registry keys (single source of truth for all contract resolution)
        // forge-lint: disable-next-line(unsafe-typecast)
        protocolRegistry.set(bytes32("registrar"), dotnsRegistrarProxy);
        // forge-lint: disable-next-line(unsafe-typecast)
        protocolRegistry.set(bytes32("controller"), dotnsRegistrarControllerProxy);
        // forge-lint: disable-next-line(unsafe-typecast)
        protocolRegistry.set(bytes32("registry"), dotnsRegistryProxy);
        // forge-lint: disable-next-line(unsafe-typecast)
        protocolRegistry.set(bytes32("reverseResolver"), dotnsReverseResolverProxy);
        // forge-lint: disable-next-line(unsafe-typecast)
        protocolRegistry.set(bytes32("resolver"), dotnsResolverProxy);
        // forge-lint: disable-next-line(unsafe-typecast)
        protocolRegistry.set(bytes32("contentResolver"), dotnsContentResolverProxy);
        // forge-lint: disable-next-line(unsafe-typecast)
        protocolRegistry.set(bytes32("popRules"), popRulesProxy);
        // forge-lint: disable-next-line(unsafe-typecast)
        protocolRegistry.set(bytes32("storeFactory"), address(storeFactory));
        console.log("Protocol registry keys set");

        // Wire protocol registry to all contracts
        dotnsRegistrar.updateProtocolRegistry(IDotnsProtocolRegistry(address(protocolRegistry)));
        dotnsRegistrarController.updateProtocolRegistry(
            IDotnsProtocolRegistry(address(protocolRegistry))
        );
        dotnsRegistry.updateProtocolRegistry(IDotnsProtocolRegistry(address(protocolRegistry)));
        dotnsReverseResolver.updateProtocolRegistry(
            IDotnsProtocolRegistry(address(protocolRegistry))
        );
        dotnsResolver.updateProtocolRegistry(IDotnsProtocolRegistry(address(protocolRegistry)));
        dotnsContentResolver.updateProtocolRegistry(
            IDotnsProtocolRegistry(address(protocolRegistry))
        );
        popRules.updateProtocolRegistry(IDotnsProtocolRegistry(address(protocolRegistry)));
        console.log("Protocol registry wired to all contracts");

        vm.stopBroadcast();

        // Post-deploy verification
        _verifyDeployment(
            dotnsRegistrarProxy,
            dotnsRegistrarControllerProxy,
            dotnsRegistryProxy,
            dotnsReverseResolverProxy,
            dotnsResolverProxy,
            dotnsContentResolverProxy,
            popRulesProxy,
            OWNER
        );

        saveDeployments(_getDeploymentFolder(), vm.toString(chainId));
    }

    function _verifyDeployment(
        address registrarProxy,
        address controllerProxy,
        address registryProxy,
        address reverseResolverProxy,
        address resolverProxy,
        address contentResolverProxy,
        address popRulesProxy,
        address expectedOwner
    )
        internal
        view
    {
        // Verify ownership
        require(DotnsRegistrar(registrarProxy).owner() == expectedOwner, "Registrar: wrong owner");
        require(
            DotnsRegistrarController(controllerProxy).owner() == expectedOwner,
            "Controller: wrong owner"
        );
        require(DotnsRegistry(registryProxy).owner() == expectedOwner, "Registry: wrong owner");
        require(
            DotnsReverseResolver(reverseResolverProxy).owner() == expectedOwner,
            "ReverseResolver: wrong owner"
        );
        require(DotnsResolver(resolverProxy).owner() == expectedOwner, "Resolver: wrong owner");
        require(
            DotnsContentResolver(contentResolverProxy).owner() == expectedOwner,
            "ContentResolver: wrong owner"
        );
        require(PopRules(popRulesProxy).owner() == expectedOwner, "PopRules: wrong owner");
        require(protocolRegistry.owner() == expectedOwner, "ProtocolRegistry: wrong owner");
        console.log("Ownership verified for all contracts");

        // Verify protocol registry wiring
        // forge-lint: disable-next-line(unsafe-typecast)
        require(protocolRegistry.get(bytes32("registrar")) == registrarProxy, "Key: registrar");
        // forge-lint: disable-next-line(unsafe-typecast)
        require(protocolRegistry.get(bytes32("controller")) == controllerProxy, "Key: controller");
        // forge-lint: disable-next-line(unsafe-typecast)
        require(protocolRegistry.get(bytes32("registry")) == registryProxy, "Key: registry");
        // forge-lint: disable-next-line(unsafe-typecast)
        require(
            protocolRegistry.get(bytes32("reverseResolver")) == reverseResolverProxy,
            "Key: reverseResolver"
        );
        // forge-lint: disable-next-line(unsafe-typecast)
        require(protocolRegistry.get(bytes32("resolver")) == resolverProxy, "Key: resolver");
        // forge-lint: disable-next-line(unsafe-typecast)
        require(
            protocolRegistry.get(bytes32("contentResolver")) == contentResolverProxy,
            "Key: contentResolver"
        );
        // forge-lint: disable-next-line(unsafe-typecast)
        require(protocolRegistry.get(bytes32("popRules")) == popRulesProxy, "Key: popRules");
        // forge-lint: disable-next-line(unsafe-typecast)
        require(
            protocolRegistry.get(bytes32("storeFactory")) == address(storeFactory),
            "Key: storeFactory"
        );
        console.log("Protocol registry keys verified");

        // Verify protocol registry is wired to all contracts
        require(
            address(DotnsRegistrar(registrarProxy).protocolRegistry())
                == address(protocolRegistry),
            "Registrar: not wired"
        );
        require(
            address(DotnsRegistrarController(controllerProxy).protocolRegistry())
                == address(protocolRegistry),
            "Controller: not wired"
        );
        require(
            address(DotnsRegistry(registryProxy).protocolRegistry())
                == address(protocolRegistry),
            "Registry: not wired"
        );
        require(
            address(DotnsReverseResolver(reverseResolverProxy).protocolRegistry())
                == address(protocolRegistry),
            "ReverseResolver: not wired"
        );
        require(
            address(DotnsResolver(resolverProxy).protocolRegistry())
                == address(protocolRegistry),
            "Resolver: not wired"
        );
        require(
            address(DotnsContentResolver(contentResolverProxy).protocolRegistry())
                == address(protocolRegistry),
            "ContentResolver: not wired"
        );
        require(
            address(PopRules(popRulesProxy).protocolRegistry()) == address(protocolRegistry),
            "PopRules: not wired"
        );
        console.log("Protocol registry wiring verified");

        // Verify controller is authorized
        require(
            DotnsRegistrar(registrarProxy).controllers(
                IDotnsRegistrarController(controllerProxy)
            ),
            "Controller not added to registrar"
        );

        // Verify root record exists
        require(DotnsRegistry(registryProxy).recordExists(bytes32(0)), "Root record missing");
        console.log("Root record verified");

        console.log("=== Deployment verification complete ===");
    }

    function _getDeploymentFolder() internal view returns (string memory directory) {
        directory = "localhost";
        if (block.chainid == 420420422) {
            directory = "passethub-testnet";
        } else if (block.chainid == 420420417) {
            directory = "paseo-assethub";
        } else if (block.chainid == 420420420) {
            directory = "paseo-local";
        }
    }
}
