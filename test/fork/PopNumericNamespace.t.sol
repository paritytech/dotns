// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {DotnsPopController} from "../../contracts/registrars/DotnsPopController.sol";
import {IDotnsPopController} from "../../contracts/registrars/IDotnsPopController.sol";
import {DotnsRegistry} from "../../contracts/registry/DotnsRegistry.sol";
import {DotnsPopResolver} from "../../contracts/resolvers/DotnsPopResolver.sol";
import {IDotnsRegistrar} from "../../contracts/registrars/IDotnsRegistrar.sol";
import {IDotnsController} from "../../contracts/registrars/IDotnsController.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {ISystem} from "../../contracts/external/revive/ISystem.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {LabelUtils} from "../../contracts/utils/LabelUtils.sol";
import {StringUtils} from "../../contracts/utils/StringUtils.sol";

import {UpgradeRegistryHarness} from "./UpgradeRegistry.t.sol";
import {UpgradePopControllerHarness} from "./UpgradePopController.t.sol";
import {UpgradePopRulesHarness} from "./UpgradePopRules.t.sol";

/// @title PopNumericNamespaceForkTest
/// @notice End-to-end fork check for the numeric-namespace feature. Forks the live Paseo Asset Hub
///         through the ETH-RPC adapter, upgrades every contract the lite path depends on (registry,
///         PoP controller, PoP rules), and issues a lite username to prove it lands as a subname
///         beneath its numeric container on real on-chain state, owned in the registry rather than
///         held as an atomic registrar token.
/// @dev PR-scoped: deleted before merge with the upgrade scripts and their snapshots per the
///      upgrade-PR workflow in CONTRIBUTING.md. Requires the local adapter on `paseo_local`;
///      between upgrade PRs `test/fork/` is empty, so the suite is skipped by default with
///      `--no-match-path 'test/fork/**'`.
///
///      Lite usernames issued before this upgrade were recorded as atomic labels under the top
///      level, and the upgraded code addresses a lite name at the container-then-stem node instead,
///      so a pre-upgrade lite name is not read by the new path and its subname node is free to be
///      issued afresh. That overwrite is accepted: the numeric namespace is the intended shape.
/// @custom:security-contact admin@parity.io
contract PopNumericNamespaceForkTest is Test {
    /// @notice Manifest recording the live deployment addresses this fork resolves against.
    string internal constant MANIFEST_PATH = "deployments/paseo-assethub/420420417.json";

    /// @notice A lite label whose stem lands in the PoP-lite classification band (6 to 8
    ///         characters), so the upgraded rules admit it.
    string internal constant LITE_LABEL = "michael.01";

    /// @notice Drives each upgrade script's internal path against the live proxies.
    UpgradeRegistryHarness internal registryUpgrader;
    UpgradePopControllerHarness internal controllerUpgrader;
    UpgradePopRulesHarness internal rulesUpgrader;

    /// @notice Live deployment handles resolved from the manifest.
    DotnsRegistry internal registry;
    DotnsPopController internal popController;
    DotnsPopResolver internal popResolver;
    IDotnsRegistrar internal registrar;
    IDotnsProtocolRegistry internal protocolRegistry;
    address internal popRules;

    /// @notice Proxy owners, impersonated to authorise each upgrade and the controller wiring.
    address internal registryOwner;
    address internal popControllerOwner;
    address internal popRulesOwner;
    address internal registrarOwner;

    /// @notice Beneficiary of the lite username.
    address internal user;

    /// @notice Forks Paseo and resolves the live addresses and their owners.
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("paseo_local"));

        string memory manifest = vm.readFile(MANIFEST_PATH);
        registry = DotnsRegistry(vm.parseJsonAddress(manifest, ".DotnsRegistry"));
        popController = DotnsPopController(vm.parseJsonAddress(manifest, ".DotnsPopController"));
        popResolver = DotnsPopResolver(vm.parseJsonAddress(manifest, ".DotnsPopResolver"));
        registrar = IDotnsRegistrar(vm.parseJsonAddress(manifest, ".DotnsRegistrar"));
        protocolRegistry =
            IDotnsProtocolRegistry(vm.parseJsonAddress(manifest, ".DotnsProtocolRegistry"));
        popRules = vm.parseJsonAddress(manifest, ".PopRules");

        registryOwner = OwnableUpgradeable(address(registry)).owner();
        popControllerOwner = OwnableUpgradeable(address(popController)).owner();
        popRulesOwner = OwnableUpgradeable(popRules).owner();
        registrarOwner = OwnableUpgradeable(address(registrar)).owner();

        registryUpgrader = new UpgradeRegistryHarness();
        controllerUpgrader = new UpgradePopControllerHarness();
        rulesUpgrader = new UpgradePopRulesHarness();

        user = makeAddr("litePerson");
    }

    /// @notice After the full upgrade, issuing `michael.01` records `michael` as a subname owned in
    ///         the registry beneath the numeric container `01`, and the container is a real name
    ///         held by the controller, not an atomic registrar token.
    function test_lite_username_is_issued_as_a_subname_after_the_upgrade() public {
        rulesUpgrader.upgradePopRules(popRulesOwner, popRules);
        registryUpgrader.upgradeRegistry(registryOwner, address(registry));
        controllerUpgrader.upgradePopController(popControllerOwner, address(popController));

        // Re-assert the controller on the registrar so the container mint is authorised. This is a
        // no-op when the live controller is already registered and keeps the test independent of
        // the exact wiring state of the fork.
        vm.prank(registrarOwner);
        registrar.addController(IDotnsController(address(popController)));

        // The gateway dispatches under a Root origin. That origin precompile is not part of fork
        // state, so it is mocked to Root here. The Root path admits the label by shape and does not
        // read the personhood precompile, so no personhood mock is needed.
        vm.mockCall(
            DotnsConstants.REVIVE_SYSTEM,
            abi.encodeWithSelector(ISystem.originIsRoot.selector),
            abi.encode(true)
        );

        popController.reserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL, user: user, chatKey: _chatKey()
            })
        );

        (, string memory suffix) = StringUtils.splitLiteLabel(LITE_LABEL);
        bytes32 containerNode = LabelUtils.namehashUnder(
            protocolRegistry.tldNode(), LabelUtils.labelhashMemory(suffix)
        );
        bytes32 node = _liteNodeOf(LITE_LABEL);

        assertEq(
            registry.owner(node), user, "lite username owned as a subname beneath the container"
        );
        assertEq(popResolver.chatKey(node), _chatKey(), "chat key persisted at the subname node");
        assertEq(
            registry.owner(containerNode),
            address(popController),
            "numeric container owned by the controller"
        );
        assertFalse(
            registrar.exists(uint256(node)), "lite username is a registry subname, not a token"
        );
    }

    /// @notice Derives the subname node for a lite label as container-then-stem beneath the TLD.
    function _liteNodeOf(string memory liteLabel) internal view returns (bytes32 node) {
        (string memory stem, string memory suffix) = StringUtils.splitLiteLabel(liteLabel);
        bytes32 parentNode = LabelUtils.namehashUnder(
            protocolRegistry.tldNode(), LabelUtils.labelhashMemory(suffix)
        );
        node = LabelUtils.namehashUnder(parentNode, LabelUtils.labelhashMemory(stem));
    }

    /// @notice Returns a valid 65-byte chat key.
    function _chatKey() internal pure returns (bytes memory key) {
        key = new bytes(65);
        key[0] = 0x04;
        for (uint256 i = 1; i < 65; i++) {
            key[i] = 0x07;
        }
    }
}
