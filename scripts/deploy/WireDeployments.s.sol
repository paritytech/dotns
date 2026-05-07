// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";
import {DeploymentNetwork} from "./DeploymentNetwork.sol";

import {DotnsRegistrar} from "../../contracts/registrars/DotnsRegistrar.sol";
import {DotnsRegistrarController} from "../../contracts/registrars/DotnsRegistrarController.sol";
import {DotnsPopController} from "../../contracts/registrars/DotnsPopController.sol";
import {DotnsNameEscrow} from "../../contracts/escrow/DotnsNameEscrow.sol";
import {IDotnsController} from "../../contracts/registrars/IDotnsController.sol";
import {DotnsRegistry} from "../../contracts/registry/DotnsRegistry.sol";
import {DotnsProtocolRegistry} from "../../contracts/registry/DotnsProtocolRegistry.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsResolver} from "../../contracts/resolvers/DotnsResolver.sol";
import {DotnsContentResolver} from "../../contracts/resolvers/DotnsContentResolver.sol";
import {DotnsReverseResolver} from "../../contracts/resolvers/DotnsReverseResolver.sol";
import {DotnsPopResolver} from "../../contracts/resolvers/DotnsPopResolver.sol";
import {PopRules} from "../../contracts/pop/PopRules.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";

/// @title WireDeployments
/// @notice Final stage. Runs no proxy deployments; reads every address the
///         earlier stages wrote to the manifest and performs the two
///         wire-up operations the system needs before it can function:
///         authorising both controllers on the registrar, and populating
///         every protocol-registry key plus `updateProtocolRegistry` on every
///         consumer.
/// @dev Also runs a best-effort post-wire verification: owner, protocol
///      registry key, and controller authorisation for each proxy.
/// @custom:security-contact admin@parity.io
contract WireDeployments is BaseDeployer {
    error NameEscrowWrongOwner();
    error NameEscrowKeyMismatch();
    error NameEscrowProtocolRegistryMismatch();

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
        address nameEscrow;
        address popResolver;
        address popController;
    }

    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(DeploymentNetwork.folder(block.chainid), vm.toString(block.chainid));

        Addresses memory addr = _loadAddresses();

        _authoriseControllers(owner, addr);
        _wireProtocolRegistryKeys(owner, addr);
        _wireProtocolRegistryPointers(owner, addr);
        _verifyDeployment(addr, owner);

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
        addr.nameEscrow = _readAddress("DotnsNameEscrow");
        addr.popResolver = _readAddress("DotnsPopResolver");
        addr.popController = _readAddress("DotnsPopController");
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
        registry.set(DotnsConstants.POP_CONTROLLER, addr.popController);
        registry.set(DotnsConstants.POP_RESOLVER, addr.popResolver);
        vm.stopBroadcast();
        console.log("Protocol registry keys set");
    }

    function _wireProtocolRegistryPointers(address owner, Addresses memory addr) internal {
        IDotnsProtocolRegistry registry = IDotnsProtocolRegistry(addr.protocolRegistry);
        vm.startBroadcast(owner);
        DotnsRegistrar(addr.registrar).updateProtocolRegistry(registry);
        DotnsRegistrarController(addr.registrarController).updateProtocolRegistry(registry);
        DotnsRegistry(addr.registry).updateProtocolRegistry(registry);
        DotnsReverseResolver(addr.reverseResolver).updateProtocolRegistry(registry);
        DotnsResolver(addr.resolver).updateProtocolRegistry(registry);
        DotnsContentResolver(addr.contentResolver).updateProtocolRegistry(registry);
        PopRules(addr.popRules).updateProtocolRegistry(registry);
        vm.stopBroadcast();
        console.log("Protocol registry wired to all contracts");
    }

    function _verifyDeployment(Addresses memory addr, address expectedOwner) internal view {
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
            NameEscrowWrongOwner()
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
        require(
            registry.get(DotnsConstants.NAME_ESCROW) == addr.nameEscrow, NameEscrowKeyMismatch()
        );
        require(
            registry.get(DotnsConstants.POP_CONTROLLER) == addr.popController, "Key: popController"
        );
        require(
            address(DotnsNameEscrow(payable(addr.nameEscrow)).protocolRegistry())
                == addr.protocolRegistry,
            NameEscrowProtocolRegistryMismatch()
        );
        require(registry.get(DotnsConstants.POP_RESOLVER) == addr.popResolver, "Key: popResolver");

        require(
            DotnsRegistrar(addr.registrar).controllers(IDotnsController(addr.registrarController)),
            "Controller: not authorised"
        );
        require(
            DotnsRegistrar(addr.registrar).controllers(IDotnsController(addr.popController)),
            "PopController: not authorised"
        );

        console.log("=== Deployment verification complete ===");
    }
}
