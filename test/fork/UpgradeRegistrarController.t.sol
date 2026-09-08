// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {DotnsRegistrarController} from "../../contracts/registrars/DotnsRegistrarController.sol";
import {IDotnsRegistrarController} from "../../contracts/registrars/IDotnsRegistrarController.sol";
import {IDotnsRegistrar} from "../../contracts/registrars/IDotnsRegistrar.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {IDotnsCostModelRegistry} from "../../contracts/pop/IDotnsCostModelRegistry.sol";
import {ISystem} from "../../contracts/external/revive/ISystem.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {LabelUtils} from "../../contracts/utils/LabelUtils.sol";
import {UpgradeRegistrarController} from "../../scripts/deploy/UpgradeRegistrarController.s.sol";

/// @title UpgradeRegistrarControllerHarness
/// @notice Exposes the upgrade script's internal upgrade path so the fork test drives the exact
///         code the production run executes, including the fail-closed storage-layout diff.
/// @dev Mirrors the reference `UpgradeRegistrarHarness` pattern: forward to the script internal
///      rather than re-implement the upgrade, so the test tracks the production path one-to-one.
contract UpgradeRegistrarControllerHarness is UpgradeRegistrarController {
    /// @notice Upgrades `proxy` under `owner` through the script's internal upgrade path.
    function upgradeRegistrarController(address owner, address proxy) external {
        _upgradeRegistrarController(owner, proxy);
    }
}

/// @title UpgradeRegistrarControllerForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradeRegistrarController.s.sol`. Forks the live
///         Paseo Asset Hub through the ETH-RPC adapter, upgrades the deployed controller proxy with
///         the script, and re-runs the controller's commit-reveal P0 against real on-chain state to
///         prove the swap preserves ownership, the protocol registry pointer, the commitment window
///         bounds, and a commitment made on the pre-upgrade implementation.
/// @dev PR-scoped: deleted before merge with the upgrade script and the
/// `DotnsRegistrarControllerOld` snapshot. Requires the local adapter on `paseo_local`; between
/// upgrade PRs `test/fork/` is
///      empty, so the suite is skipped by default with `--no-match-path 'test/fork/**'`.
/// @custom:security-contact admin@parity.io
contract UpgradeRegistrarControllerForkTest is Test {
    /// @notice Manifest recording the live deployment addresses this fork resolves against.
    string internal constant MANIFEST_PATH = "deployments/paseo-assethub/420420417.json";

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradeRegistrarControllerHarness internal upgrader;

    /// @notice The deployed registrar controller proxy under upgrade.
    DotnsRegistrarController internal controller;

    /// @notice The deployed protocol registry the controller resolves siblings through.
    IDotnsProtocolRegistry internal protocolRegistry;

    /// @notice The deployed registrar the controller mints names on.
    IDotnsRegistrar internal registrar;

    /// @notice Proxy owner, impersonated to authorise the upgrade.
    address internal controllerOwner;

    /// @notice Beneficiary the reserved commit-reveal flow mints to.
    address internal alice;

    /// @notice Forks Paseo and resolves the live addresses the P0 flow drives against.
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("paseo_local"));

        string memory manifest = vm.readFile(MANIFEST_PATH);
        controller =
            DotnsRegistrarController(vm.parseJsonAddress(manifest, ".DotnsRegistrarController"));
        protocolRegistry =
            IDotnsProtocolRegistry(vm.parseJsonAddress(manifest, ".DotnsProtocolRegistry"));
        registrar = IDotnsRegistrar(vm.parseJsonAddress(manifest, ".DotnsRegistrar"));
        controllerOwner = OwnableUpgradeable(address(controller)).owner();

        upgrader = new UpgradeRegistrarControllerHarness();

        alice = makeAddr("alice");
        vm.deal(alice, 100 ether);
    }

    /// @notice The upgrade preserves the proxy address, the protocol registry pointer, and the
    ///         commitment window bounds, and a commitment submitted on the pre-upgrade
    ///         implementation still reveals into a mint on the upgraded implementation.
    function test_upgrade_preservesStateAndKeepsCommitRevealWorking() public {
        // Build a Root-issuable reserved registration. Root skips the whitelist grant and the PoP
        // price check, so the flow exercises the full commit -> wait -> reveal -> mint path without
        // seeding pricing or personhood on the fork.
        IDotnsRegistrarController.Registration memory reg = IDotnsRegistrarController.Registration({
            label: "forkupgradectrl",
            owner: alice,
            secret: keccak256("dotns.fork.upgrade.controller.secret"),
            reserved: false,
            maxPrice: 0,
            pricingVersion: _currentPricingVersion()
        });

        assertTrue(controller.available(reg.label), "pre-upgrade: label is available");

        // Commit on the pre-upgrade implementation. This stamps the pricing version into the
        // commitment slot, so the post-upgrade reveal proves the commitment storage survived.
        bytes32 commitment = controller.makeCommitment(reg);
        controller.commit(commitment);
        assertEq(controller.commitments(commitment), block.timestamp, "pre-upgrade: commit stored");

        address proxy = address(controller);
        address registryBefore = address(controller.protocolRegistry());
        uint256 minAgeBefore = controller.minCommitmentAge();
        uint256 maxAgeBefore = controller.maxCommitmentAge();

        upgrader.upgradeRegistrarController(controllerOwner, proxy);

        // (a) proxy address unchanged.
        assertEq(address(controller), proxy, "upgrade keeps the same proxy address");
        // (b) key storage pointer preserved.
        assertEq(
            address(controller.protocolRegistry()),
            registryBefore,
            "post-upgrade: protocol registry pointer preserved"
        );
        // (c) commitment window bounds preserved across the layout change.
        assertEq(controller.minCommitmentAge(), minAgeBefore, "post-upgrade: minCommitmentAge kept");
        assertEq(controller.maxCommitmentAge(), maxAgeBefore, "post-upgrade: maxCommitmentAge kept");
        // The commitment stored before the upgrade is still readable at the same slot.
        assertGt(controller.commitments(commitment), 0, "post-upgrade: commitment preserved");

        // (d) P0: reveal the pre-upgrade commitment through the new registerReserved surface under
        // a substrate Root origin and confirm the name mints to the beneficiary.
        vm.warp(block.timestamp + minAgeBefore + 1);
        vm.mockCall(
            DotnsConstants.REVIVE_SYSTEM,
            abi.encodeWithSelector(ISystem.originIsRoot.selector),
            abi.encode(true)
        );

        controller.registerReserved(reg);

        bytes32 node = LabelUtils.namehashUnder(
            protocolRegistry.tldNode(), LabelUtils.labelhashMemory(reg.label)
        );
        assertEq(
            registrar.ownerOf(uint256(node)), alice, "post-upgrade: reserved mint reaches owner"
        );
        assertFalse(controller.available(reg.label), "post-upgrade: label is no longer available");
    }

    /// @notice Resolves the cost model's current version through the protocol registry.
    function _currentPricingVersion() internal view returns (uint256 version) {
        version = IDotnsCostModelRegistry(protocolRegistry.get(DotnsConstants.COST_MODEL))
            .currentVersion();
    }
}
