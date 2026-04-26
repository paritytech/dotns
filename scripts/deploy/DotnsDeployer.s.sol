// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";

import {PopRules, IPopRules} from "../../contracts/pop/PopRules.sol";
import {DotnsRegistrar, IDotnsRegistrar} from "../../contracts/registrars/DotnsRegistrar.sol";
import {DotnsRegistrarController} from "../../contracts/registrars/DotnsRegistrarController.sol";
import {DotnsPopController} from "../../contracts/registrars/DotnsPopController.sol";
import {IDotnsController} from "../../contracts/registrars/IDotnsController.sol";
import {DotnsRegistry, IDotnsRegistry} from "../../contracts/registry/DotnsRegistry.sol";
import {
    DotnsReverseResolver,
    IDotnsReverseResolver
} from "../../contracts/resolvers/DotnsReverseResolver.sol";
import {DotnsContentResolver} from "../../contracts/resolvers/DotnsContentResolver.sol";
import {DotnsResolver} from "../../contracts/resolvers/DotnsResolver.sol";
import {DotnsPopResolver} from "../../contracts/resolvers/DotnsPopResolver.sol";
import {StoreFactory, IStoreFactory} from "../../contracts/store/StoreFactory.sol";
import {
    DotnsProtocolRegistry,
    IDotnsProtocolRegistry
} from "../../contracts/registry/DotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";

/// @title DotnsDeployer
/// @notice Fresh-deploy script for the full DotNS contract set behind UUPS proxies.
/// @dev Deploys every proxy in its own broadcast scope to cap forge's per-tx
///      memory accounting; every proxy still runs OZ upgrade-safety validation.
///      Wires the protocol-registry keys and pointer references after the last
///      deploy, and authorises both controllers on the registrar.
/// TODO: Before mainnet we need to modify this
/// @custom:security-contact admin@parity.io
contract DotnsDeployer is BaseDeployer {
    uint256 public constant RENT_PRICE = 2e15 wei;

    /// @notice Default reservation duration for the freshly-deployed PoP controller.
    /// @dev Mirrors `pallet_resources::UsernameReservationDuration`; the protocol owner
    ///      rotates this post-deploy via `DotnsPopController.setReservationDuration`.
    uint64 public constant DEFAULT_RESERVATION_DURATION = 7 days;

    StoreFactory public storeFactory;

    PopRules public popRules;
    DotnsRegistrar public dotnsRegistrar;
    DotnsRegistry public dotnsRegistry;
    DotnsReverseResolver public dotnsReverseResolver;
    DotnsContentResolver public dotnsContentResolver;
    DotnsResolver public dotnsResolver;
    DotnsPopResolver public dotnsPopResolver;
    DotnsRegistrarController public dotnsRegistrarController;
    DotnsPopController public dotnsPopController;
    DotnsProtocolRegistry public protocolRegistry;

    /// @notice Per-proxy handle returned from the deploy pipeline, kept as a
    ///         struct so the ten downstream addresses can be passed around as
    ///         one named value rather than ten positional parameters.
    struct Deployment {
        address storeFactory;
        address registrar;
        address reverseResolver;
        address registry;
        address contentResolver;
        address resolver;
        address popRules;
        address registrarController;
        address protocolRegistry;
        address popResolver;
        address popController;
    }

    /// @notice Deploys the full DotNS contract set, wires the protocol registry,
    ///         and writes the resulting manifest under `deployments/`.
    /// @dev Network-specific output folder is chosen from `block.chainid`; see
    ///      {_getDeploymentFolder}. The broadcasting account becomes the owner
    ///      of every proxy and the default `POP_GATEWAY` until governance rotates it.
    function run() external {
        uint256 chainId = block.chainid;

        vm.warp(365 days);

        console.log("Current blocktime", block.timestamp);

        initDeployment(_getDeploymentFolder(), vm.toString(chainId));

        address OWNER = msg.sender;
        vm.label(OWNER, "OWNER");

        // Each `_deploy*` step wraps its own `Upgrades.deployUUPSProxy` call in
        // a dedicated `vm.startBroadcast / vm.stopBroadcast` pair. Running each
        // proxy deployment in its own broadcast scope caps forge's per-tx
        // memory accounting; otherwise the OZ upgrade-safety validator's
        // cumulative FFI output (multi-MB build-info JSON per call) drives the
        // whole `run()` into `MemoryOOG` around the 8th proxy. Full OZ
        // validation still runs on every proxy; no checks are skipped.
        Deployment memory deployment;
        deployment.storeFactory = _deployStoreFactory(OWNER);
        deployment.registrar = _deployRegistrar(OWNER);
        deployment.reverseResolver = _deployReverseResolver(OWNER);
        deployment.registry = _deployRegistry(
            OWNER, deployment.registrar, deployment.reverseResolver, deployment.storeFactory
        );
        deployment.contentResolver = _deployContentResolver(OWNER, deployment.registry);
        deployment.resolver = _deployResolver(OWNER, deployment.registry);
        deployment.popRules = _deployPopRules(OWNER);
        deployment.registrarController = _deployRegistrarController(OWNER, deployment);
        deployment.protocolRegistry = _deployProtocolRegistry(OWNER);
        deployment.popResolver = _deployPopResolver(OWNER, deployment.protocolRegistry);
        deployment.popController = _deployPopController(OWNER, deployment.protocolRegistry);

        _authoriseControllers(OWNER, deployment);
        _wireProtocolRegistryKeys(OWNER, deployment);
        _wireProtocolRegistryPointers(OWNER);

        _verifyDeployment(
            deployment.registrar,
            deployment.registrarController,
            deployment.registry,
            deployment.reverseResolver,
            deployment.resolver,
            deployment.contentResolver,
            deployment.popRules,
            deployment.popController,
            deployment.popResolver,
            OWNER
        );

        saveDeployments();
    }

    function _deployStoreFactory(address owner) internal returns (address proxy) {
        vm.startBroadcast(owner);
        storeFactory = new StoreFactory();
        vm.stopBroadcast();
        proxy = address(storeFactory);
        vm.label(proxy, "StoreFactory");
        logDeployment("StoreFactory", proxy);
    }

    function _deployRegistrar(address owner) internal returns (address proxy) {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsRegistrar.sol:DotnsRegistrar",
            abi.encodeCall(DotnsRegistrar.initialize, ("Dotns", "Dotns")),
            "DotnsRegistrar"
        );
        dotnsRegistrar = DotnsRegistrar(proxy);
    }

    function _deployReverseResolver(address owner) internal returns (address proxy) {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsReverseResolver.sol:DotnsReverseResolver",
            abi.encodeCall(DotnsReverseResolver.initialize, ()),
            "DotnsReverseResolver"
        );
        dotnsReverseResolver = DotnsReverseResolver(proxy);
    }

    function _deployRegistry(
        address owner,
        address registrar,
        address reverseResolver,
        address factory
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
                    IStoreFactory(factory)
                )
            ),
            "DotnsRegistry"
        );
        dotnsRegistry = DotnsRegistry(proxy);
    }

    function _deployContentResolver(
        address owner,
        address registry
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsContentResolver.sol:DotnsContentResolver",
            abi.encodeCall(DotnsContentResolver.initialize, (IDotnsRegistry(registry))),
            "DotnsContentResolver"
        );
        dotnsContentResolver = DotnsContentResolver(proxy);
    }

    function _deployResolver(address owner, address registry) internal returns (address proxy) {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsResolver.sol:DotnsResolver",
            abi.encodeCall(DotnsResolver.initialize, (IDotnsRegistry(registry))),
            "DotnsResolver"
        );
        dotnsResolver = DotnsResolver(proxy);
    }

    function _deployPopRules(address owner) internal returns (address proxy) {
        proxy = _broadcastDeployUups(
            owner,
            "PopRules.sol:PopRules",
            abi.encodeCall(PopRules.initialize, (RENT_PRICE)),
            "PopRules"
        );
        popRules = PopRules(proxy);
    }

    function _deployRegistrarController(
        address owner,
        Deployment memory deployment
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsRegistrarController.sol:DotnsRegistrarController",
            abi.encodeCall(
                DotnsRegistrarController.initialize,
                (
                    IDotnsRegistrar(deployment.registrar),
                    IDotnsRegistry(deployment.registry),
                    IDotnsReverseResolver(deployment.reverseResolver),
                    IPopRules(deployment.popRules),
                    IStoreFactory(deployment.storeFactory),
                    6 seconds,
                    1 days
                )
            ),
            "DotnsRegistrarController"
        );
        dotnsRegistrarController = DotnsRegistrarController(proxy);
    }

    function _deployProtocolRegistry(address owner) internal returns (address proxy) {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsProtocolRegistry.sol:DotnsProtocolRegistry",
            abi.encodeCall(DotnsProtocolRegistry.initialize, ()),
            "DotnsProtocolRegistry"
        );
        protocolRegistry = DotnsProtocolRegistry(proxy);
    }

    function _deployPopResolver(
        address owner,
        address protocolRegistryProxy
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsPopResolver.sol:DotnsPopResolver",
            abi.encodeCall(
                DotnsPopResolver.initialize, (IDotnsProtocolRegistry(protocolRegistryProxy))
            ),
            "DotnsPopResolver"
        );
        dotnsPopResolver = DotnsPopResolver(proxy);
    }

    function _deployPopController(
        address owner,
        address protocolRegistryProxy
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsPopController.sol:DotnsPopController",
            abi.encodeCall(
                DotnsPopController.initialize,
                (IDotnsProtocolRegistry(protocolRegistryProxy), DEFAULT_RESERVATION_DURATION)
            ),
            "DotnsPopController"
        );
        dotnsPopController = DotnsPopController(proxy);
    }

    function _authoriseControllers(address owner, Deployment memory deployment) internal {
        vm.startBroadcast(owner);
        dotnsRegistrar.addController(IDotnsController(deployment.registrarController));
        dotnsRegistrar.addController(IDotnsController(deployment.popController));
        vm.stopBroadcast();
    }

    function _wireProtocolRegistryKeys(address owner, Deployment memory deployment) internal {
        vm.startBroadcast(owner);
        protocolRegistry.set(DotnsConstants.REGISTRAR, deployment.registrar);
        protocolRegistry.set(DotnsConstants.CONTROLLER, deployment.registrarController);
        protocolRegistry.set(DotnsConstants.REGISTRY, deployment.registry);
        protocolRegistry.set(DotnsConstants.REVERSE_RESOLVER, deployment.reverseResolver);
        protocolRegistry.set(DotnsConstants.RESOLVER, deployment.resolver);
        protocolRegistry.set(DotnsConstants.CONTENT_RESOLVER, deployment.contentResolver);
        protocolRegistry.set(DotnsConstants.POP_RULES, deployment.popRules);
        protocolRegistry.set(DotnsConstants.STORE_FACTORY, deployment.storeFactory);
        protocolRegistry.set(DotnsConstants.POP_CONTROLLER, deployment.popController);
        protocolRegistry.set(DotnsConstants.POP_RESOLVER, deployment.popResolver);
        // `popGateway` defaults to the deploying owner for local deploys. Governance
        // rotates it post-deploy via `protocolRegistry.set(DotnsConstants.POP_GATEWAY, ...)`.
        protocolRegistry.set(DotnsConstants.POP_GATEWAY, owner);
        vm.stopBroadcast();
        console.log("Protocol registry keys set");
    }

    function _wireProtocolRegistryPointers(address owner) internal {
        IDotnsProtocolRegistry registry = IDotnsProtocolRegistry(address(protocolRegistry));
        vm.startBroadcast(owner);
        dotnsRegistrar.updateProtocolRegistry(registry);
        dotnsRegistrarController.updateProtocolRegistry(registry);
        dotnsRegistry.updateProtocolRegistry(registry);
        dotnsReverseResolver.updateProtocolRegistry(registry);
        dotnsResolver.updateProtocolRegistry(registry);
        dotnsContentResolver.updateProtocolRegistry(registry);
        popRules.updateProtocolRegistry(registry);
        vm.stopBroadcast();
        console.log("Protocol registry wired to all contracts");
    }

    function _verifyDeployment(
        address registrarProxy,
        address controllerProxy,
        address registryProxy,
        address reverseResolverProxy,
        address resolverProxy,
        address contentResolverProxy,
        address popRulesProxy,
        address popControllerProxy,
        address popResolverProxy,
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
        require(
            DotnsPopController(popControllerProxy).owner() == expectedOwner,
            "PopController: wrong owner"
        );
        require(
            DotnsPopResolver(popResolverProxy).owner() == expectedOwner, "PopResolver: wrong owner"
        );
        require(protocolRegistry.owner() == expectedOwner, "ProtocolRegistry: wrong owner");
        console.log("Ownership verified for all contracts");

        // Verify protocol registry wiring
        require(protocolRegistry.get(DotnsConstants.REGISTRAR) == registrarProxy, "Key: registrar");
        require(
            protocolRegistry.get(DotnsConstants.CONTROLLER) == controllerProxy, "Key: controller"
        );
        require(protocolRegistry.get(DotnsConstants.REGISTRY) == registryProxy, "Key: registry");
        require(
            protocolRegistry.get(DotnsConstants.REVERSE_RESOLVER) == reverseResolverProxy,
            "Key: reverseResolver"
        );
        require(protocolRegistry.get(DotnsConstants.RESOLVER) == resolverProxy, "Key: resolver");
        require(
            protocolRegistry.get(DotnsConstants.CONTENT_RESOLVER) == contentResolverProxy,
            "Key: contentResolver"
        );
        require(protocolRegistry.get(DotnsConstants.POP_RULES) == popRulesProxy, "Key: popRules");
        require(
            protocolRegistry.get(DotnsConstants.STORE_FACTORY) == address(storeFactory),
            "Key: storeFactory"
        );
        require(
            protocolRegistry.get(DotnsConstants.POP_CONTROLLER) == popControllerProxy,
            "Key: popController"
        );
        require(
            protocolRegistry.get(DotnsConstants.POP_RESOLVER) == popResolverProxy,
            "Key: popResolver"
        );
        require(
            protocolRegistry.get(DotnsConstants.POP_GATEWAY) == expectedOwner, "Key: popGateway"
        );
        console.log("Protocol registry keys verified");

        // Verify protocol registry is wired to all contracts
        require(
            address(DotnsRegistrar(registrarProxy).protocolRegistry()) == address(protocolRegistry),
            "Registrar: not wired"
        );
        require(
            address(DotnsRegistrarController(controllerProxy).protocolRegistry())
                == address(protocolRegistry),
            "Controller: not wired"
        );
        require(
            address(DotnsRegistry(registryProxy).protocolRegistry()) == address(protocolRegistry),
            "Registry: not wired"
        );
        require(
            address(DotnsReverseResolver(reverseResolverProxy).protocolRegistry())
                == address(protocolRegistry),
            "ReverseResolver: not wired"
        );
        require(
            address(DotnsResolver(resolverProxy).protocolRegistry()) == address(protocolRegistry),
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

        // Verify both controllers are authorised on the registrar's multi-controller mapping.
        require(
            DotnsRegistrar(registrarProxy).controllers(IDotnsController(controllerProxy)),
            "Controller not added to registrar"
        );
        require(
            DotnsRegistrar(registrarProxy).controllers(IDotnsController(popControllerProxy)),
            "PopController not added to registrar"
        );

        // Verify PoP contracts are wired to the protocol registry.
        require(
            address(DotnsPopController(popControllerProxy).protocolRegistry())
                == address(protocolRegistry),
            "PopController: not wired"
        );
        require(
            address(DotnsPopResolver(popResolverProxy).protocolRegistry())
                == address(protocolRegistry),
            "PopResolver: not wired"
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
