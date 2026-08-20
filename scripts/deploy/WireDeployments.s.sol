// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";

import {DotnsRegistrar} from "../../contracts/registrars/DotnsRegistrar.sol";
import {DotnsRegistrarController} from "../../contracts/registrars/DotnsRegistrarController.sol";
import {DotnsPopController} from "../../contracts/registrars/DotnsPopController.sol";
import {DotnsNameEscrow} from "../../contracts/escrow/DotnsNameEscrow.sol";
import {IDotnsController} from "../../contracts/registrars/IDotnsController.sol";
import {DotnsRegistry} from "../../contracts/registry/DotnsRegistry.sol";
import {DotnsProtocolRegistry} from "../../contracts/registry/DotnsProtocolRegistry.sol";
import {DotnsResolver} from "../../contracts/resolvers/DotnsResolver.sol";
import {DotnsContentResolver} from "../../contracts/resolvers/DotnsContentResolver.sol";
import {DotnsReverseResolver} from "../../contracts/resolvers/DotnsReverseResolver.sol";
import {DotnsPopResolver} from "../../contracts/resolvers/DotnsPopResolver.sol";
import {PopRules} from "../../contracts/pop/PopRules.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";

/// @title WireDeployments
/// @notice Final stage. Runs no proxy deployments; reads every address the
///         earlier stages wrote to the manifest and performs the two wire-up
///         operations the system needs before it can function: authorising
///         both controllers on the registrar, and populating every
///         protocol-registry key. Each consumer proxy already received the
///         protocol registry at init time, so no post-deploy pointer wiring is
///         required here.
/// @dev Also runs a best-effort post-wire verification: owner, protocol
///      registry key, and controller authorisation for each proxy.
/// @custom:security-contact admin@parity.io
contract WireDeployments is BaseDeployer {
    /// @notice Environment variable containing the address that receives
    ///         `WHITELIST_OPERATOR_ROLE` during deployment wire-up.
    string internal constant WHITELIST_OPERATOR_ENV = "WHITELIST_OPERATOR";

    struct Addresses {
        address storeFactory;
        address registrar;
        address reverseResolver;
        address registry;
        address contentResolver;
        address resolver;
        address popRules;
        address registrarController;
        address protocolRegistry;
        address multicall3;
        address nameEscrow;
        address popResolver;
        address popController;
        address rootGatewayDispatcher;
    }

    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");
        address whitelistOperator = vm.envAddress(WHITELIST_OPERATOR_ENV);
        vm.label(whitelistOperator, "WHITELIST_OPERATOR");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        Addresses memory addr = _loadAddresses();

        _authoriseControllers(owner, addr);
        _wireProtocolRegistryKeys(owner, addr);
        _bootstrapWhitelistOperator(owner, addr, whitelistOperator);
        _verifyDeployment(addr, owner, whitelistOperator);

        saveDeployments();

        console.log("=== WireDeployments complete ===");
    }

    function _loadAddresses() internal view returns (Addresses memory addr) {
        addr.storeFactory = _readAddress("StoreFactory");
        addr.registrar = _readAddress("DotnsRegistrar");
        addr.reverseResolver = _readAddress("DotnsReverseResolver");
        addr.registry = _readAddress("DotnsRegistry");
        addr.contentResolver = _readAddress("DotnsContentResolver");
        addr.resolver = _readAddress("DotnsResolver");
        addr.popRules = _readAddress("PopRules");
        addr.registrarController = _readAddress("DotnsRegistrarController");
        addr.protocolRegistry = _readAddress("DotnsProtocolRegistry");
        addr.multicall3 = _readAddress("Multicall3");
        addr.nameEscrow = _readAddress("DotnsNameEscrow");
        addr.popResolver = _readAddress("DotnsPopResolver");
        addr.popController = _readAddress("DotnsPopController");
        addr.rootGatewayDispatcher = _readAddress("RootGatewayDispatcher");
    }

    function _authoriseControllers(address owner, Addresses memory addr) internal {
        DotnsRegistrar registrar = DotnsRegistrar(addr.registrar);
        vm.startBroadcast(owner);
        registrar.addController(IDotnsController(addr.registrarController));
        registrar.addController(IDotnsController(addr.popController));
        vm.stopBroadcast();
    }

    function _wireProtocolRegistryKeys(address owner, Addresses memory addr) internal {
        DotnsProtocolRegistry registry = DotnsProtocolRegistry(addr.protocolRegistry);

        vm.startBroadcast(owner);
        registry.set(DotnsConstants.REGISTRAR, addr.registrar);
        registry.set(DotnsConstants.CONTROLLER, addr.registrarController);
        registry.set(DotnsConstants.REGISTRY, addr.registry);
        registry.set(DotnsConstants.REVERSE_RESOLVER, addr.reverseResolver);
        registry.set(DotnsConstants.RESOLVER, addr.resolver);
        registry.set(DotnsConstants.CONTENT_RESOLVER, addr.contentResolver);
        registry.set(DotnsConstants.POP_RULES, addr.popRules);
        registry.set(DotnsConstants.STORE_FACTORY, addr.storeFactory);
        registry.set(DotnsConstants.NAME_ESCROW, addr.nameEscrow);
        registry.set(DotnsConstants.MULTICALL3, addr.multicall3);
        registry.set(DotnsConstants.POP_CONTROLLER, addr.popController);
        registry.set(DotnsConstants.POP_RESOLVER, addr.popResolver);
        registry.set(DotnsConstants.POP_GATEWAY, addr.rootGatewayDispatcher);
        vm.stopBroadcast();
        console.log("Protocol registry keys set");
    }

    function _bootstrapWhitelistOperator(
        address owner,
        Addresses memory addr,
        address whitelistOperator
    )
        internal
    {
        vm.startBroadcast(owner);
        DotnsRegistrarController(addr.registrarController)
            .setRole(DotnsConstants.WHITELIST_OPERATOR_ROLE, whitelistOperator, true);
        vm.stopBroadcast();
        console.log("Whitelist operator role granted to", whitelistOperator);
    }

    function _verifyDeployment(
        Addresses memory addr,
        address expectedOwner,
        address whitelistOperator
    )
        internal
        view
    {
        require(DotnsRegistrar(addr.registrar).owner() == expectedOwner, "Registrar: wrong owner");
        require(
            DotnsRegistrarController(addr.registrarController).owner() == expectedOwner,
            "Controller: wrong owner"
        );
        require(DotnsRegistry(addr.registry).owner() == expectedOwner, "Registry: wrong owner");
        require(
            DotnsReverseResolver(addr.reverseResolver).owner() == expectedOwner,
            "ReverseResolver: wrong owner"
        );
        require(DotnsResolver(addr.resolver).owner() == expectedOwner, "Resolver: wrong owner");
        require(
            DotnsContentResolver(addr.contentResolver).owner() == expectedOwner,
            "ContentResolver: wrong owner"
        );
        require(PopRules(addr.popRules).owner() == expectedOwner, "PopRules: wrong owner");
        require(
            DotnsNameEscrow(payable(addr.nameEscrow)).owner() == expectedOwner,
            "NameEscrow: wrong owner"
        );
        require(
            DotnsPopController(addr.popController).owner() == expectedOwner,
            "PopController: wrong owner"
        );
        require(
            DotnsPopResolver(addr.popResolver).owner() == expectedOwner, "PopResolver: wrong owner"
        );
        require(
            DotnsProtocolRegistry(addr.protocolRegistry).owner() == expectedOwner,
            "ProtocolRegistry: wrong owner"
        );

        DotnsProtocolRegistry registry = DotnsProtocolRegistry(addr.protocolRegistry);
        require(registry.get(DotnsConstants.REGISTRAR) == addr.registrar, "Key: registrar");
        require(
            registry.get(DotnsConstants.CONTROLLER) == addr.registrarController, "Key: controller"
        );
        require(registry.get(DotnsConstants.REGISTRY) == addr.registry, "Key: registry");
        require(
            registry.get(DotnsConstants.REVERSE_RESOLVER) == addr.reverseResolver,
            "Key: reverseResolver"
        );
        require(registry.get(DotnsConstants.RESOLVER) == addr.resolver, "Key: resolver");
        require(
            registry.get(DotnsConstants.CONTENT_RESOLVER) == addr.contentResolver,
            "Key: contentResolver"
        );
        require(registry.get(DotnsConstants.POP_RULES) == addr.popRules, "Key: popRules");
        require(
            registry.get(DotnsConstants.STORE_FACTORY) == addr.storeFactory, "Key: storeFactory"
        );
        require(registry.get(DotnsConstants.NAME_ESCROW) == addr.nameEscrow, "Key: nameEscrow");
        require(registry.get(DotnsConstants.MULTICALL3) == addr.multicall3, "Key: multicall3");
        require(
            registry.get(DotnsConstants.POP_CONTROLLER) == addr.popController, "Key: popController"
        );
        require(registry.get(DotnsConstants.POP_RESOLVER) == addr.popResolver, "Key: popResolver");
        require(
            registry.get(DotnsConstants.POP_GATEWAY) == addr.rootGatewayDispatcher,
            "Key: popGateway"
        );

        require(
            DotnsRegistrar(addr.registrar).controllers(IDotnsController(addr.registrarController)),
            "Controller: not authorised"
        );
        require(
            DotnsRegistrar(addr.registrar).controllers(IDotnsController(addr.popController)),
            "PopController: not authorised"
        );
        require(
            DotnsRegistrarController(addr.registrarController)
                .hasRole(DotnsConstants.WHITELIST_OPERATOR_ROLE, whitelistOperator),
            "WhitelistOperator: role not granted"
        );

        console.log("=== Deployment verification complete ===");
    }
}
