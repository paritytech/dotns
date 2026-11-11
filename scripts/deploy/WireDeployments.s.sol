// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";

import {DotnsRegistrar} from "../../contracts/registrars/DotnsRegistrar.sol";
import {DotnsRegistrarController} from "../../contracts/registrars/DotnsRegistrarController.sol";
import {DotnsPopController} from "../../contracts/registrars/DotnsPopController.sol";
import {DotnsNameEscrow} from "../../contracts/escrow/DotnsNameEscrow.sol";
import {DotnsNameWhitelist} from "../../contracts/whitelist/DotnsNameWhitelist.sol";
import {IDotnsController} from "../../contracts/registrars/IDotnsController.sol";
import {DotnsRegistry} from "../../contracts/registry/DotnsRegistry.sol";
import {DotnsProtocolRegistry} from "../../contracts/registry/DotnsProtocolRegistry.sol";
import {DotnsResolver} from "../../contracts/resolvers/DotnsResolver.sol";
import {DotnsContentResolver} from "../../contracts/resolvers/DotnsContentResolver.sol";
import {DotnsReverseResolver} from "../../contracts/resolvers/DotnsReverseResolver.sol";
import {DotnsPopResolver} from "../../contracts/resolvers/DotnsPopResolver.sol";
import {PopRules} from "../../contracts/pop/PopRules.sol";
import {StoreFactory} from "../../contracts/store/StoreFactory.sol";
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
    struct Addresses {
        address create3Factory;
        address storeFactory;
        address registrar;
        address reverseResolver;
        address registry;
        address contentResolver;
        address resolver;
        address popRules;
        address costModelRegistry;
        address registrarController;
        address protocolRegistry;
        address nameEscrow;
        address nameWhitelist;
        address popResolver;
        address popController;
        address popLens;
    }

    /// @notice One registry key with the deployed contract it resolves to, paired with a
    ///         human-readable label for verification failures.
    struct RegistryEntry {
        bytes32 key;
        address target;
        string label;
    }

    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        // Read before anything is broadcast, so a run that would end unable to declare its
        // release aborts here instead of after the wiring.
        string memory releaseTag = vm.envString("DOTNS_RELEASE_TAG");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        Addresses memory addr = _loadAddresses();

        _authoriseControllers(owner, addr);
        _wireProtocolRegistryKeys(owner, addr);
        _declareCodeIdentity(owner, addr);
        _verifyDeployment(addr, owner);
        // Declared last, once the wiring and every code-identity declaration verified: a run
        // that dies earlier leaves the previous version standing rather than over-claiming.
        _declareProtocolVersion(owner, addr, releaseTag);

        saveDeployments();

        console.log("=== WireDeployments complete ===");
    }

    function _loadAddresses() internal view returns (Addresses memory addr) {
        addr.create3Factory = _readAddress("Create3Factory");
        addr.storeFactory = _readAddress("StoreFactory");
        addr.registrar = _readAddress("DotnsRegistrar");
        addr.reverseResolver = _readAddress("DotnsReverseResolver");
        addr.registry = _readAddress("DotnsRegistry");
        addr.contentResolver = _readAddress("DotnsContentResolver");
        addr.resolver = _readAddress("DotnsResolver");
        addr.popRules = _readAddress("PopRules");
        addr.costModelRegistry = _readAddress("DotnsCostModelRegistry");
        addr.registrarController = _readAddress("DotnsRegistrarController");
        addr.protocolRegistry = _readAddress("DotnsProtocolRegistry");
        addr.nameEscrow = _readAddress("DotnsNameEscrow");
        addr.nameWhitelist = _readAddress("DotnsNameWhitelist");
        addr.popResolver = _readAddress("DotnsPopResolver");
        addr.popController = _readAddress("DotnsPopController");
        addr.popLens = _readAddress("DotnsPopLens");
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
        // The registry registers itself so its own implementation has a declared codehash to
        // drift from; consumers still bootstrap from the manifest address, not this key.
        registry.set(DotnsConstants.PROTOCOL_REGISTRY, addr.protocolRegistry);
        registry.set(DotnsConstants.REGISTRAR, addr.registrar);
        registry.set(DotnsConstants.CONTROLLER, addr.registrarController);
        registry.set(DotnsConstants.REGISTRY, addr.registry);
        registry.set(DotnsConstants.REVERSE_RESOLVER, addr.reverseResolver);
        registry.set(DotnsConstants.RESOLVER, addr.resolver);
        registry.set(DotnsConstants.CONTENT_RESOLVER, addr.contentResolver);
        // Point at the cost-model registry before PopRules so no pricing read resolves an unset
        // key.
        registry.set(DotnsConstants.COST_MODEL, addr.costModelRegistry);
        registry.set(DotnsConstants.POP_RULES, addr.popRules);
        registry.set(DotnsConstants.STORE_FACTORY, addr.storeFactory);
        registry.set(DotnsConstants.NAME_ESCROW, addr.nameEscrow);
        registry.set(DotnsConstants.NAME_WHITELIST, addr.nameWhitelist);
        // Multicall3 is deliberately not registered. It is a generic call forwarder, not a
        // protocol component, and registry membership is a trust signal other contracts read.
        // Consumers take its address from the deployment manifest instead.
        registry.set(DotnsConstants.POP_CONTROLLER, addr.popController);
        registry.set(DotnsConstants.POP_RESOLVER, addr.popResolver);
        registry.set(DotnsConstants.POP_LENS, addr.popLens);
        vm.stopBroadcast();
        console.log("Protocol registry keys set");
    }

    /// @notice Every registered key with its target, in the order
    ///         @custom:function _wireProtocolRegistryKeys sets them.
    /// @dev Single source for @custom:function _declareCodeIdentity and the declaration leg of
    ///      @custom:function _verifyDeployment, so the declared set and the verified set cannot
    ///      drift apart.
    function _registryEntries(Addresses memory addr)
        internal
        pure
        returns (RegistryEntry[] memory entries)
    {
        entries = new RegistryEntry[](16);
        entries[0] = RegistryEntry(
            DotnsConstants.PROTOCOL_REGISTRY, addr.protocolRegistry, "protocolRegistry"
        );
        // Registered by DeployCore when the factory is created or adopted, so it is part of
        // the declared set even though this stage never sets the key itself.
        entries[15] =
            RegistryEntry(DotnsConstants.CREATE3_FACTORY, addr.create3Factory, "create3Factory");
        entries[1] = RegistryEntry(DotnsConstants.REGISTRAR, addr.registrar, "registrar");
        entries[2] =
            RegistryEntry(DotnsConstants.CONTROLLER, addr.registrarController, "controller");
        entries[3] = RegistryEntry(DotnsConstants.REGISTRY, addr.registry, "registry");
        entries[4] =
            RegistryEntry(DotnsConstants.REVERSE_RESOLVER, addr.reverseResolver, "reverseResolver");
        entries[5] = RegistryEntry(DotnsConstants.RESOLVER, addr.resolver, "resolver");
        entries[6] =
            RegistryEntry(DotnsConstants.CONTENT_RESOLVER, addr.contentResolver, "contentResolver");
        entries[7] = RegistryEntry(DotnsConstants.COST_MODEL, addr.costModelRegistry, "costModel");
        entries[8] = RegistryEntry(DotnsConstants.POP_RULES, addr.popRules, "popRules");
        entries[9] = RegistryEntry(DotnsConstants.STORE_FACTORY, addr.storeFactory, "storeFactory");
        entries[10] = RegistryEntry(DotnsConstants.NAME_ESCROW, addr.nameEscrow, "nameEscrow");
        entries[11] =
            RegistryEntry(DotnsConstants.NAME_WHITELIST, addr.nameWhitelist, "nameWhitelist");
        entries[12] =
            RegistryEntry(DotnsConstants.POP_CONTROLLER, addr.popController, "popController");
        entries[13] = RegistryEntry(DotnsConstants.POP_RESOLVER, addr.popResolver, "popResolver");
        entries[14] = RegistryEntry(DotnsConstants.POP_LENS, addr.popLens, "popLens");
    }

    /// @notice Codehash of the code that executes for `target`: the implementation behind the
    ///         ERC1967 slot when `target` is a proxy, the contract's own code otherwise.
    /// @dev The proxy/plain split is read from the slot rather than kept as a list here, so a
    ///      key changing shape in a later release cannot silently declare the wrong hash.
    function _executingCodehash(address target) internal view returns (bytes32 codehash) {
        address implementation =
            address(uint160(uint256(vm.load(target, ERC1967_IMPLEMENTATION_SLOT))));
        return implementation == address(0) ? target.codehash : implementation.codehash;
    }

    /// @notice Declares, for every registered key, the codehash of the code that executes for
    ///         it, read back from the chain state this pipeline just created.
    /// @dev Declared equals actual by construction, so any later divergence between
    ///      `expectedCodehash(key)` and the code behind `get(key)` means the code changed after
    ///      this run, which is exactly what the declaration exists to expose.
    function _declareCodeIdentity(address owner, Addresses memory addr) internal {
        DotnsProtocolRegistry registry = DotnsProtocolRegistry(addr.protocolRegistry);
        RegistryEntry[] memory entries = _registryEntries(addr);

        vm.startBroadcast(owner);
        for (uint256 i = 0; i < entries.length; ++i) {
            registry.setExpectedCodehash(entries[i].key, _executingCodehash(entries[i].target));
        }
        vm.stopBroadcast();
        console.log("Code identity declared for every registry key");
    }

    /// @notice Declares the release this network runs and confirms the readback.
    function _declareProtocolVersion(
        address owner,
        Addresses memory addr,
        string memory tag
    )
        internal
    {
        DotnsProtocolRegistry registry = DotnsProtocolRegistry(addr.protocolRegistry);

        vm.startBroadcast(owner);
        registry.setProtocolVersion(tag);
        vm.stopBroadcast();

        require(
            keccak256(bytes(registry.protocolVersion())) == keccak256(bytes(tag)),
            "ProtocolVersion: readback does not match DOTNS_RELEASE_TAG"
        );
        console.log("Protocol version declared:", tag);
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
            "NameEscrow: wrong owner"
        );
        require(
            DotnsNameWhitelist(addr.nameWhitelist).owner() == expectedOwner,
            "NameWhitelist: wrong owner"
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
        require(
            StoreFactory(addr.storeFactory).owner() == expectedOwner, "StoreFactory: wrong owner"
        );

        DotnsProtocolRegistry registry = DotnsProtocolRegistry(addr.protocolRegistry);
        require(
            registry.get(DotnsConstants.PROTOCOL_REGISTRY) == addr.protocolRegistry,
            "Key: protocolRegistry"
        );
        require(
            registry.get(DotnsConstants.CREATE3_FACTORY) == addr.create3Factory,
            "Key: create3Factory"
        );
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
        require(registry.get(DotnsConstants.COST_MODEL) == addr.costModelRegistry, "Key: costModel");
        require(
            registry.get(DotnsConstants.STORE_FACTORY) == addr.storeFactory, "Key: storeFactory"
        );
        require(registry.get(DotnsConstants.NAME_ESCROW) == addr.nameEscrow, "Key: nameEscrow");
        require(
            registry.get(DotnsConstants.NAME_WHITELIST) == addr.nameWhitelist, "Key: nameWhitelist"
        );
        require(
            registry.get(DotnsConstants.POP_CONTROLLER) == addr.popController, "Key: popController"
        );
        require(registry.get(DotnsConstants.POP_RESOLVER) == addr.popResolver, "Key: popResolver");
        require(registry.get(DotnsConstants.POP_LENS) == addr.popLens, "Key: popLens");

        require(
            DotnsRegistrar(addr.registrar).controllers(IDotnsController(addr.registrarController)),
            "Controller: not authorised"
        );
        require(
            DotnsRegistrar(addr.registrar).controllers(IDotnsController(addr.popController)),
            "PopController: not authorised"
        );

        _verifyStoreImplementations(addr.storeFactory, addr.protocolRegistry);

        // Every declared codehash must match the code actually executing for its key, and no
        // key may be left undeclared, so the network never ships half-claimed.
        RegistryEntry[] memory entries = _registryEntries(addr);
        for (uint256 i = 0; i < entries.length; ++i) {
            bytes32 declared = registry.expectedCodehash(entries[i].key);
            require(
                declared != bytes32(0), string.concat("Codehash undeclared: ", entries[i].label)
            );
            require(
                declared == _executingCodehash(entries[i].target),
                string.concat("Codehash mismatch: ", entries[i].label)
            );
        }

        console.log("=== Deployment verification complete ===");
    }
}
