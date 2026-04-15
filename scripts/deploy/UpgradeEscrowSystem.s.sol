// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

import {DotnsProtocolRegistry} from "../../contracts/registry/DotnsProtocolRegistry.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsRegistry} from "../../contracts/registry/DotnsRegistry.sol";
import {DotnsNameEscrow} from "../../contracts/escrow/DotnsNameEscrow.sol";
import {DotnsRegistrar} from "../../contracts/registrars/DotnsRegistrar.sol";
import {DotnsRegistrarController} from "../../contracts/registrars/DotnsRegistrarController.sol";

/// @title UpgradeEscrowSystem
/// @notice Single orchestration script that applies the full escrow-system upgrade in order.
/// @dev Sequence (load-bearing):
///      1. Upgrade protocol registry — exposes `NAME_ESCROW` key.
///      2. Deploy escrow (fresh)     — needs protocol registry to exist.
///      3. Write NAME_ESCROW slot    — wires escrow into protocol registry.
///      4. Upgrade forward registry  — relaxes `setOwner` to allow reclaim-time overwrite.
///      5. Upgrade registrar         — `available()` reflects escrow custody for reclaim.
///      6. Upgrade controller        — `register()` routes through escrow reclaim on custody.
///
///      The fork test invokes `upgradeAll` directly, so production and test share one code path.
contract UpgradeEscrowSystem is BaseDeployer {
    /// @notice Deployed Paseo AssetHub proxy addresses.
    address public constant PROTOCOL_REGISTRY_PROXY = 0xF8531342444fAC0A75719130eECcf45314584EFe;
    address public constant REGISTRY_PROXY = 0x4Da0d37aBe96C06ab19963F31ca2DC0412057a6f;
    address public constant REGISTRAR_PROXY = 0x329aAA5b6bEa94E750b2dacBa74Bf41291E6c2BD;
    address public constant CONTROLLER_PROXY = 0xd09e0F1c1E6CE8Cf40df929ef4FC778629573651;

    /// @notice Default cooldown for fresh escrow deployments.
    uint256 public constant DEFAULT_COOLDOWN = 7 days;

    /// @notice Expected versions after upgrade. Single source of truth for post-upgrade checks.
    string public constant PROTOCOL_REGISTRY_VERSION = "1.1.0";
    string public constant REGISTRY_VERSION = "1.5.0";
    string public constant REGISTRAR_VERSION = "1.5.0";
    string public constant CONTROLLER_VERSION = "1.6.0";
    string public constant ESCROW_VERSION = "1.0.0";

    /// @notice Fully-qualified artifact names — used for OZ reference-contract validation.
    string internal constant _PROTOCOL_REGISTRY_NEW =
        "DotnsProtocolRegistry.sol:DotnsProtocolRegistry";
    string internal constant _PROTOCOL_REGISTRY_OLD =
        "DotnsProtocolRegistryOld.sol:DotnsProtocolRegistryOld";
    string internal constant _REGISTRY_NEW = "DotnsRegistry.sol:DotnsRegistry";
    string internal constant _REGISTRY_OLD = "DotnsRegistryOld.sol:DotnsRegistryOld";
    string internal constant _REGISTRAR_NEW = "DotnsRegistrar.sol:DotnsRegistrar";
    string internal constant _REGISTRAR_OLD = "DotnsRegistrarOld.sol:DotnsRegistrarOld";
    string internal constant _CONTROLLER_NEW =
        "DotnsRegistrarController.sol:DotnsRegistrarController";
    string internal constant _CONTROLLER_OLD =
        "DotnsRegistrarControllerOld.sol:DotnsRegistrarControllerOld";
    string internal constant _ESCROW_NEW = "DotnsNameEscrow.sol:DotnsNameEscrow";

    /// @notice Standard run entrypoint — executed live against the configured chain.
    function run() external {
        console.log("=== Escrow System Upgrade ===");
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(msg.sender);
        address escrowProxy = upgradeAll(msg.sender);
        vm.stopBroadcast();

        verifyUpgrade(escrowProxy);
    }

    /// @notice Single-owner overload.
    /// @param caller Owner of all three proxies and authorised registry writer.
    /// @return escrowProxy Address of the freshly deployed escrow proxy.
    function upgradeAll(address caller) public returns (address escrowProxy) {
        escrowProxy = upgradeAll(caller, caller, caller);
    }

    /// @notice Per-proxy-owner overload for when admin addresses differ.
    /// @param registryOwner Owner of the protocol registry proxy; writes NAME_ESCROW.
    /// @param registrarOwner Owner of the registrar proxy.
    /// @param controllerOwner Owner of the controller proxy.
    /// @return escrowProxy Address of the freshly deployed escrow proxy.
    function upgradeAll(
        address registryOwner,
        address registrarOwner,
        address controllerOwner
    )
        public
        returns (address escrowProxy)
    {
        _upgrade(
            PROTOCOL_REGISTRY_PROXY, _PROTOCOL_REGISTRY_NEW, _PROTOCOL_REGISTRY_OLD, registryOwner
        );

        escrowProxy = Upgrades.deployUUPSProxy(
            _ESCROW_NEW,
            abi.encodeCall(
                DotnsNameEscrow.initialize,
                (IDotnsProtocolRegistry(PROTOCOL_REGISTRY_PROXY), DEFAULT_COOLDOWN)
            )
        );

        DotnsProtocolRegistry protocolRegistry = DotnsProtocolRegistry(PROTOCOL_REGISTRY_PROXY);
        vm.startPrank(registryOwner);
        protocolRegistry.set(protocolRegistry.NAME_ESCROW(), escrowProxy);
        vm.stopPrank();

        _upgrade(REGISTRY_PROXY, _REGISTRY_NEW, _REGISTRY_OLD, registryOwner);
        _upgrade(REGISTRAR_PROXY, _REGISTRAR_NEW, _REGISTRAR_OLD, registrarOwner);
        _upgrade(CONTROLLER_PROXY, _CONTROLLER_NEW, _CONTROLLER_OLD, controllerOwner);
    }

    /// @notice Post-upgrade verification checks.
    /// @param escrowProxy Address of the escrow proxy returned by `upgradeAll`.
    function verifyUpgrade(address escrowProxy) public view {
        DotnsProtocolRegistry protocolRegistry = DotnsProtocolRegistry(PROTOCOL_REGISTRY_PROXY);
        DotnsNameEscrow escrow = DotnsNameEscrow(payable(escrowProxy));

        _requireVersion(protocolRegistry.version(), PROTOCOL_REGISTRY_VERSION, "ProtocolRegistry");
        _requireVersion(DotnsRegistry(REGISTRY_PROXY).version(), REGISTRY_VERSION, "Registry");
        _requireVersion(DotnsRegistrar(REGISTRAR_PROXY).version(), REGISTRAR_VERSION, "Registrar");
        _requireVersion(
            DotnsRegistrarController(CONTROLLER_PROXY).version(), CONTROLLER_VERSION, "Controller"
        );
        _requireVersion(escrow.version(), ESCROW_VERSION, "Escrow");

        require(
            protocolRegistry.get(protocolRegistry.NAME_ESCROW()) == escrowProxy,
            "NAME_ESCROW not wired to escrow proxy"
        );
        require(
            address(escrow.protocolRegistry()) == PROTOCOL_REGISTRY_PROXY,
            "Escrow protocol registry mismatch"
        );

        console.log("=== Upgrade verification complete ===");
        console.log("ProtocolRegistry:", PROTOCOL_REGISTRY_PROXY);
        console.log("Registry:        ", REGISTRY_PROXY);
        console.log("NameEscrow:      ", escrowProxy);
        console.log("Registrar:       ", REGISTRAR_PROXY);
        console.log("Controller:      ", CONTROLLER_PROXY);
    }

    /// @notice Upgrades a proxy, pinning the reference contract for storage-layout validation.
    /// @dev OZ's `referenceContract` check MUST NOT be skipped — it's the upgrade-safety gate.
    function _upgrade(
        address proxy,
        string memory newArtifact,
        string memory oldArtifact,
        address caller
    )
        internal
    {
        Options memory opts;
        opts.referenceContract = oldArtifact;
        Upgrades.upgradeProxy(proxy, newArtifact, "", opts, caller);
    }

    /// @notice Asserts an on-chain version string matches the expected constant.
    function _requireVersion(
        string memory actual,
        string memory expected,
        string memory label
    )
        internal
        pure
    {
        require(
            keccak256(bytes(actual)) == keccak256(bytes(expected)),
            string.concat(label, " version mismatch")
        );
    }
}
