// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {DotnsRegistrar} from "../../contracts/registrars/DotnsRegistrar.sol";
import {IDotnsRegistrar} from "../../contracts/registrars/IDotnsRegistrar.sol";
import {IDotnsController} from "../../contracts/registrars/IDotnsController.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {UpgradeRegistrar} from "../../scripts/deploy/UpgradeRegistrar.s.sol";

/// @title UpgradeRegistrarHarness
/// @notice Exposes the upgrade script's internal upgrade path so the fork test drives the exact
///         code the production run executes, including the fail-closed storage-layout diff.
/// @dev Mirrors the `DeterministicDeploymentHarness` pattern: forward to the script internal
///      rather than re-implement the upgrade, so the test tracks the production path one-to-one.
contract UpgradeRegistrarHarness is UpgradeRegistrar {
    /// @notice Upgrades `proxy` under `owner` through the script's `_upgradeRegistrar`.
    function upgradeRegistrar(address owner, address proxy) external {
        _upgradeRegistrar(owner, proxy);
    }
}

/// @title UpgradeRegistrarForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradeRegistrar.s.sol`. Forks the live Paseo
///         Asset Hub through the ETH-RPC adapter, upgrades the deployed registrar proxy with the
///         script, and re-runs the registrar's P0 paths against real on-chain state to prove the
///         swap preserves ownership and keeps registration, transfer, and soulbound gating working.
/// @dev PR-scoped: deleted before merge with the upgrade script and the `DotnsRegistrarOld`
///      snapshot. Requires the local adapter on `paseo_local`; between upgrade PRs `test/fork/` is
///      empty, so the suite is skipped by default with `--no-match-path 'test/fork/**'`.
/// @custom:security-contact admin@parity.io
contract UpgradeRegistrarForkTest is Test {
    /// @notice Manifest recording the live deployment addresses this fork resolves against.
    string internal constant MANIFEST_PATH = "deployments/paseo-assethub/420420417.json";

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradeRegistrarHarness internal upgrader;

    /// @notice The deployed registrar proxy under upgrade.
    DotnsRegistrar internal registrar;

    /// @notice The deployed protocol registry the registrar resolves siblings through.
    IDotnsProtocolRegistry internal protocolRegistry;

    /// @notice Proxy owner, impersonated to authorise the upgrade and controller writes.
    address internal registrarOwner;

    /// @notice The deployed commit-reveal controller, impersonated to mint public names.
    address internal registrarController;

    /// @notice The deployed PoP controller, impersonated to mint soulbound names.
    address internal popController;

    /// @notice Recipient accounts for the transfer paths.
    address internal alice;
    address internal bob;

    /// @notice Forks Paseo, resolves the live addresses, and guarantees both controllers are set.
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("paseo_local"));

        string memory manifest = vm.readFile(MANIFEST_PATH);
        registrar = DotnsRegistrar(vm.parseJsonAddress(manifest, ".DotnsRegistrar"));
        protocolRegistry =
            IDotnsProtocolRegistry(vm.parseJsonAddress(manifest, ".DotnsProtocolRegistry"));
        registrarController = vm.parseJsonAddress(manifest, ".DotnsRegistrarController");
        popController = vm.parseJsonAddress(manifest, ".DotnsPopController");
        registrarOwner = OwnableUpgradeable(address(registrar)).owner();

        upgrader = new UpgradeRegistrarHarness();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        // The mint paths call through the registrar's controller set. Re-asserting the two live
        // controllers is a no-op when they are already registered and keeps the test independent of
        // the exact wiring state of the fork.
        vm.startPrank(registrarOwner);
        registrar.addController(IDotnsController(registrarController));
        registrar.addController(IDotnsController(popController));
        vm.stopPrank();
    }

    /// @notice The upgrade preserves ownership state on the real proxy and keeps minting and
    ///         transferring public names working.
    function test_upgrade_preservesStateAndKeepsCoreP0Working() public {
        uint256 seedToken = uint256(keccak256("dotns.fork.upgrade.seed"));

        // Seed ownership on the pre-upgrade implementation. An empty label takes the gateway-cold
        // mint path, so the seed does not depend on a `LabelStore` deploy.
        vm.prank(registrarController);
        registrar.register(seedToken, alice, "");
        assertEq(registrar.ownerOf(seedToken), alice, "pre-upgrade: alice owns the seed name");

        address proxy = address(registrar);
        address registryBefore = address(registrar.protocolRegistry());

        upgrader.upgradeRegistrar(registrarOwner, proxy);

        assertEq(address(registrar), proxy, "upgrade keeps the same proxy address");
        assertEq(registrar.ownerOf(seedToken), alice, "post-upgrade: ownership preserved");
        assertEq(
            address(registrar.protocolRegistry()),
            registryBefore,
            "post-upgrade: protocol registry pointer preserved"
        );
        assertFalse(
            registrar.isSoulbound(seedToken),
            "post-upgrade: a name minted before the upgrade is not soulbound"
        );

        // P0: minting still works on the upgraded implementation.
        uint256 postToken = uint256(keccak256("dotns.fork.upgrade.post"));
        vm.prank(registrarController);
        registrar.register(postToken, bob, "");
        assertEq(registrar.ownerOf(postToken), bob, "post-upgrade: registration still mints");

        // P0: a public name is still transferable. The empty-label seed carries no transfer floor.
        uint256 fee = registrar.quoteTransferFee(seedToken, bob);
        vm.prank(alice);
        registrar.transferFrom{value: fee}(alice, bob, seedToken);
        assertEq(registrar.ownerOf(seedToken), bob, "post-upgrade: a public name still transfers");
    }

    /// @notice After the upgrade, a name minted through the PoP controller is soulbound and every
    ///         transfer path reverts.
    function test_upgrade_enablesSoulboundGatingForGatewayMints() public {
        upgrader.upgradeRegistrar(registrarOwner, address(registrar));

        uint256 gatewayToken = uint256(keccak256("dotns.fork.upgrade.gateway"));
        vm.prank(popController);
        registrar.register(gatewayToken, alice, "");
        assertTrue(registrar.isSoulbound(gatewayToken), "gateway mint is soulbound");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrar.NameSoulbound.selector, gatewayToken)
        );
        registrar.transferFrom(alice, bob, gatewayToken);

        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrar.NameSoulbound.selector, gatewayToken)
        );
        registrar.quoteTransferFee(gatewayToken, bob);
    }
}
