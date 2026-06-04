// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";

import {PopRules} from "../../contracts/pop/PopRules.sol";
import {DotnsRegistrar} from "../../contracts/registrars/DotnsRegistrar.sol";
import {DotnsRegistrarController} from "../../contracts/registrars/DotnsRegistrarController.sol";
import {DotnsPopController} from "../../contracts/registrars/DotnsPopController.sol";
import {DotnsNameEscrow} from "../../contracts/escrow/DotnsNameEscrow.sol";
import {IDotnsController} from "../../contracts/registrars/IDotnsController.sol";
import {DotnsRegistry} from "../../contracts/registry/DotnsRegistry.sol";
import {DotnsReverseResolver} from "../../contracts/resolvers/DotnsReverseResolver.sol";
import {DotnsContentResolver} from "../../contracts/resolvers/DotnsContentResolver.sol";
import {DotnsResolver} from "../../contracts/resolvers/DotnsResolver.sol";
import {DotnsPopResolver} from "../../contracts/resolvers/DotnsPopResolver.sol";
import {StoreFactory} from "../../contracts/store/StoreFactory.sol";
import {
    DotnsProtocolRegistry,
    IDotnsProtocolRegistry
} from "../../contracts/registry/DotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";

/// @title DotnsDeployer
/// @notice Fresh-deploy script for the full DotNS contract set behind UUPS proxies.
/// @dev Deploys every proxy in its own broadcast scope to cap forge's per-tx
///      memory accounting; every proxy still runs OZ upgrade-safety validation.
///      The protocol registry is deployed first so every downstream proxy can
///      bind to it at init time. Post-deploy wiring populates the protocol
///      registry keys and authorises both controllers on the registrar.
/// @custom:security-contact admin@parity.io
contract DotnsDeployer is BaseDeployer {
    /// @notice Default reservation duration for the freshly-deployed PoP controller.
    /// @dev Mirrors `pallet_resources::UsernameReservationDuration`; the protocol owner
    ///      rotates this post-deploy via `DotnsPopController.setReservationDuration`.
    uint64 public constant DEFAULT_RESERVATION_DURATION = 7 days;

    /// @notice Default refund cooldown for the freshly-deployed name escrow.
    /// @dev Sized to the release-and-withdraw safety window, well below the escrow's
    ///      @custom:constant MAX_COOLDOWN ceiling. The protocol owner rotates this
    ///      post-deploy via @custom:function DotnsNameEscrow.updateCooldown.
    uint256 public constant ESCROW_COOLDOWN = 15 minutes;

    /// @notice Operator address granted `WHITELIST_OPERATOR_ROLE` on the
    ///         registrar controller at fresh-deploy time.
    /// @dev Permits managing the public-controller whitelist via
    ///      `DotnsRegistrarController.whiteListAddress` without upgrade or
    ///      configuration authority. The owner rotates, grants, or revokes the
    ///      role at any time via `DotnsRegistrarController.setRole`.
    string internal constant WHITELIST_OPERATOR_ENV = "WHITELIST_OPERATOR";

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
    DotnsNameEscrow public dotnsNameEscrow;
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
        address nameEscrow;
        address popResolver;
        address popController;
    }

    /// @notice Deploys the full DotNS contract set, wires the protocol registry,
    ///         and writes the resulting manifest under `deployments/`.
    /// @dev Network-specific output folder is chosen from `block.chainid`; see
    ///      {_getDeploymentFolder}. The broadcasting account becomes the owner
    ///      of every proxy. PoP-controller auth is gated on the substrate
    ///      `Root` origin via revive's System precompile, so no on-chain
    ///      gateway address is configured here.
    function run() external {
        uint256 chainId = block.chainid;

        vm.warp(365 days);

        console.log("Current blocktime", block.timestamp);

        initDeployment(_getDeploymentFolder(), vm.toString(chainId));

        address OWNER = msg.sender;
        vm.label(OWNER, "OWNER");
        address whitelistOperator = vm.envAddress(WHITELIST_OPERATOR_ENV);
        vm.label(whitelistOperator, "WHITELIST_OPERATOR");

        // Each `_deploy*` step wraps its own `Upgrades.deployUUPSProxy` call in
        // a dedicated `vm.startBroadcast / vm.stopBroadcast` pair. Running each
        // proxy deployment in its own broadcast scope caps forge's per-tx
        // memory accounting; otherwise the OZ upgrade-safety validator's
        // cumulative FFI output (multi-MB build-info JSON per call) drives the
        // whole `run()` into `MemoryOOG` around the 8th proxy. Full OZ
        // validation still runs on every proxy; no checks are skipped.
        Deployment memory deployment;
        deployment.protocolRegistry = _deployProtocolRegistry(OWNER);
        deployment.storeFactory = _deployStoreFactory(OWNER, deployment.protocolRegistry);
        deployment.registrar = _deployRegistrar(OWNER, deployment.protocolRegistry);
        deployment.reverseResolver = _deployReverseResolver(OWNER, deployment.protocolRegistry);
        deployment.registry = _deployRegistry(OWNER, deployment.protocolRegistry);
        deployment.contentResolver = _deployContentResolver(OWNER, deployment.protocolRegistry);
        deployment.resolver = _deployResolver(OWNER, deployment.protocolRegistry);
        deployment.popRules = _deployPopRules(OWNER, deployment.protocolRegistry);
        deployment.nameEscrow = _deployNameEscrow(OWNER, deployment.protocolRegistry);
        deployment.registrarController =
            _deployRegistrarController(OWNER, deployment.protocolRegistry);
        deployment.popResolver = _deployPopResolver(OWNER, deployment.protocolRegistry);
        deployment.popController = _deployPopController(OWNER, deployment.protocolRegistry);

        _authoriseControllers(OWNER, deployment);
        _wireProtocolRegistryKeys(OWNER, deployment);
        _bootstrapWhitelistOperator(OWNER, deployment, whitelistOperator);

        _verifyDeployment(deployment, OWNER, whitelistOperator);

        saveDeployments();
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

    function _deployStoreFactory(
        address owner,
        address protocolRegistryProxy
    )
        internal
        returns (address proxy)
    {
        storeFactory = StoreFactory(
            _broadcastDeployCreate3(
                owner,
                "StoreFactory.sol:StoreFactory",
                abi.encode(protocolRegistryProxy, owner),
                "StoreFactory"
            )
        );
        proxy = address(storeFactory);
        vm.label(proxy, "StoreFactory");
        vm.label(storeFactory.labelStoreBeacon(), "LabelStoreBeacon");
        vm.label(storeFactory.userStoreBeacon(), "UserStoreBeacon");
        logDeployment("LabelStoreBeacon", storeFactory.labelStoreBeacon());
        logDeployment("UserStoreBeacon", storeFactory.userStoreBeacon());
    }

    function _deployRegistrar(
        address owner,
        address protocolRegistryProxy
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsRegistrar.sol:DotnsRegistrar",
            abi.encodeCall(
                DotnsRegistrar.initialize,
                ("Dotns", "Dotns", IDotnsProtocolRegistry(protocolRegistryProxy))
            ),
            "DotnsRegistrar"
        );
        dotnsRegistrar = DotnsRegistrar(proxy);
    }

    function _deployReverseResolver(
        address owner,
        address protocolRegistryProxy
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsReverseResolver.sol:DotnsReverseResolver",
            abi.encodeCall(
                DotnsReverseResolver.initialize, (IDotnsProtocolRegistry(protocolRegistryProxy))
            ),
            "DotnsReverseResolver"
        );
        dotnsReverseResolver = DotnsReverseResolver(proxy);
    }

    function _deployRegistry(
        address owner,
        address protocolRegistryProxy
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsRegistry.sol:DotnsRegistry",
            abi.encodeCall(
                DotnsRegistry.initialize, (IDotnsProtocolRegistry(protocolRegistryProxy))
            ),
            "DotnsRegistry"
        );
        dotnsRegistry = DotnsRegistry(proxy);
    }

    function _deployContentResolver(
        address owner,
        address protocolRegistryProxy
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsContentResolver.sol:DotnsContentResolver",
            abi.encodeCall(
                DotnsContentResolver.initialize, (IDotnsProtocolRegistry(protocolRegistryProxy))
            ),
            "DotnsContentResolver"
        );
        dotnsContentResolver = DotnsContentResolver(proxy);
    }

    function _deployResolver(
        address owner,
        address protocolRegistryProxy
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsResolver.sol:DotnsResolver",
            abi.encodeCall(
                DotnsResolver.initialize, (IDotnsProtocolRegistry(protocolRegistryProxy))
            ),
            "DotnsResolver"
        );
        dotnsResolver = DotnsResolver(proxy);
    }

    function _deployPopRules(
        address owner,
        address protocolRegistryProxy
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "PopRules.sol:PopRules",
            abi.encodeCall(
                PopRules.initialize,
                (DotnsConstants.RENT_PRICE, IDotnsProtocolRegistry(protocolRegistryProxy))
            ),
            "PopRules"
        );
        popRules = PopRules(proxy);
    }

    function _deployRegistrarController(
        address owner,
        address protocolRegistryProxy
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsRegistrarController.sol:DotnsRegistrarController",
            abi.encodeCall(
                DotnsRegistrarController.initialize,
                (IDotnsProtocolRegistry(protocolRegistryProxy), 6 seconds, 1 days)
            ),
            "DotnsRegistrarController"
        );
        dotnsRegistrarController = DotnsRegistrarController(proxy);
    }

    function _deployNameEscrow(
        address owner,
        address protocolRegistryProxy
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsNameEscrow.sol:DotnsNameEscrow",
            abi.encodeCall(
                DotnsNameEscrow.initialize,
                (IDotnsProtocolRegistry(protocolRegistryProxy), ESCROW_COOLDOWN)
            ),
            "DotnsNameEscrow"
        );
        dotnsNameEscrow = DotnsNameEscrow(payable(proxy));
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
        protocolRegistry.set(DotnsConstants.NAME_ESCROW, deployment.nameEscrow);
        protocolRegistry.set(DotnsConstants.POP_CONTROLLER, deployment.popController);
        protocolRegistry.set(DotnsConstants.POP_RESOLVER, deployment.popResolver);
        vm.stopBroadcast();
        console.log("Protocol registry keys set");
    }

    function _bootstrapWhitelistOperator(
        address owner,
        Deployment memory deployment,
        address whitelistOperator
    )
        internal
    {
        vm.startBroadcast(owner);
        DotnsRegistrarController(deployment.registrarController)
            .setRole(DotnsConstants.WHITELIST_OPERATOR_ROLE, whitelistOperator, true);
        vm.stopBroadcast();
        console.log("Whitelist operator role granted to", whitelistOperator);
    }

    function _verifyDeployment(
        Deployment memory deployment,
        address expectedOwner,
        address whitelistOperator
    )
        internal
        view
    {
        _verifyOwnership(deployment, expectedOwner);
        _verifyRegistryKeys(deployment, expectedOwner);
        _verifyRegistryPointers(deployment);
        _verifyControllerAuthorisation(deployment);
        _verifyWhitelistOperator(deployment, whitelistOperator);

        require(DotnsRegistry(deployment.registry).recordExists(bytes32(0)), "Root record missing");
        console.log("=== Deployment verification complete ===");
    }

    function _verifyWhitelistOperator(
        Deployment memory deployment,
        address whitelistOperator
    )
        internal
        view
    {
        require(
            DotnsRegistrarController(deployment.registrarController)
                .hasRole(DotnsConstants.WHITELIST_OPERATOR_ROLE, whitelistOperator),
            "WhitelistOperator: role not granted"
        );
    }

    function _verifyOwnership(Deployment memory deployment, address expectedOwner) internal view {
        _assertOwner(
            DotnsRegistrar(deployment.registrar).owner(), expectedOwner, "Registrar: wrong owner"
        );
        _assertOwner(
            DotnsRegistrarController(deployment.registrarController).owner(),
            expectedOwner,
            "Controller: wrong owner"
        );
        _assertOwner(
            DotnsRegistry(deployment.registry).owner(), expectedOwner, "Registry: wrong owner"
        );
        _assertOwner(
            DotnsReverseResolver(deployment.reverseResolver).owner(),
            expectedOwner,
            "ReverseResolver: wrong owner"
        );
        _assertOwner(
            DotnsResolver(deployment.resolver).owner(), expectedOwner, "Resolver: wrong owner"
        );
        _assertOwner(
            DotnsContentResolver(deployment.contentResolver).owner(),
            expectedOwner,
            "ContentResolver: wrong owner"
        );
        _assertOwner(PopRules(deployment.popRules).owner(), expectedOwner, "PopRules: wrong owner");
        _assertOwner(
            DotnsNameEscrow(payable(deployment.nameEscrow)).owner(),
            expectedOwner,
            "NameEscrow: wrong owner"
        );
        _assertOwner(
            DotnsPopController(deployment.popController).owner(),
            expectedOwner,
            "PopController: wrong owner"
        );
        _assertOwner(
            DotnsPopResolver(deployment.popResolver).owner(),
            expectedOwner,
            "PopResolver: wrong owner"
        );
        _assertOwner(protocolRegistry.owner(), expectedOwner, "ProtocolRegistry: wrong owner");
    }

    function _assertOwner(address actual, address expected, string memory label) internal pure {
        require(actual == expected, label);
    }

    function _verifyRegistryKeys(
        Deployment memory deployment,
        address expectedOwner
    )
        internal
        view
    {
        _assertKey(DotnsConstants.REGISTRAR, deployment.registrar, "Key: registrar");
        _assertKey(DotnsConstants.CONTROLLER, deployment.registrarController, "Key: controller");
        _assertKey(DotnsConstants.REGISTRY, deployment.registry, "Key: registry");
        _assertKey(
            DotnsConstants.REVERSE_RESOLVER, deployment.reverseResolver, "Key: reverseResolver"
        );
        _assertKey(DotnsConstants.RESOLVER, deployment.resolver, "Key: resolver");
        _assertKey(
            DotnsConstants.CONTENT_RESOLVER, deployment.contentResolver, "Key: contentResolver"
        );
        _assertKey(DotnsConstants.POP_RULES, deployment.popRules, "Key: popRules");
        _assertKey(DotnsConstants.STORE_FACTORY, deployment.storeFactory, "Key: storeFactory");
        _assertKey(DotnsConstants.NAME_ESCROW, deployment.nameEscrow, "Key: nameEscrow");
        _assertKey(DotnsConstants.POP_CONTROLLER, deployment.popController, "Key: popController");
        _assertKey(DotnsConstants.POP_RESOLVER, deployment.popResolver, "Key: popResolver");
    }

    function _assertKey(bytes32 key, address expected, string memory label) internal view {
        require(protocolRegistry.get(key) == expected, label);
    }

    function _verifyRegistryPointers(Deployment memory deployment) internal view {
        address expected = address(protocolRegistry);
        _assertPointer(
            address(DotnsRegistrar(deployment.registrar).protocolRegistry()),
            expected,
            "Registrar: not wired"
        );
        _assertPointer(
            address(DotnsRegistrarController(deployment.registrarController).protocolRegistry()),
            expected,
            "Controller: not wired"
        );
        _assertPointer(
            address(DotnsRegistry(deployment.registry).protocolRegistry()),
            expected,
            "Registry: not wired"
        );
        _assertPointer(
            address(DotnsReverseResolver(deployment.reverseResolver).protocolRegistry()),
            expected,
            "ReverseResolver: not wired"
        );
        _assertPointer(
            address(DotnsResolver(deployment.resolver).protocolRegistry()),
            expected,
            "Resolver: not wired"
        );
        _assertPointer(
            address(DotnsContentResolver(deployment.contentResolver).protocolRegistry()),
            expected,
            "ContentResolver: not wired"
        );
        _assertPointer(
            address(PopRules(deployment.popRules).protocolRegistry()),
            expected,
            "PopRules: not wired"
        );
        _assertPointer(
            address(DotnsNameEscrow(payable(deployment.nameEscrow)).protocolRegistry()),
            expected,
            "NameEscrow: not wired"
        );
        _assertPointer(
            address(DotnsPopController(deployment.popController).protocolRegistry()),
            expected,
            "PopController: not wired"
        );
        _assertPointer(
            address(DotnsPopResolver(deployment.popResolver).protocolRegistry()),
            expected,
            "PopResolver: not wired"
        );
    }

    function _assertPointer(address actual, address expected, string memory label) internal pure {
        require(actual == expected, label);
    }

    function _verifyControllerAuthorisation(Deployment memory deployment) internal view {
        require(
            DotnsRegistrar(deployment.registrar)
                .controllers(IDotnsController(deployment.registrarController)),
            "Controller not added to registrar"
        );
        require(
            DotnsRegistrar(deployment.registrar)
                .controllers(IDotnsController(deployment.popController)),
            "PopController not added to registrar"
        );
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
