// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseUpgradeFork} from "./BaseUpgradeFork.t.sol";
import {UpgradeRegistrarController} from "../../scripts/deploy/UpgradeRegistrarController.s.sol";
import {IDotnsRegistrarController} from "../../contracts/registrars/IDotnsRegistrarController.sol";
import {DotnsRegistrarController} from "../../contracts/registrars/DotnsRegistrarController.sol";

/// @title UpgradeRegistrarControllerHarness
/// @notice Exposes the upgrade script's internal path so the test drives the code the production
///         run executes, including the fail-closed storage-layout diff.
/// @dev Forwarding to the script internal rather than re-implementing the upgrade is what keeps
///      the test honest: a test that called `Upgrades.upgradeProxy` itself would keep passing
///      after the script stopped doing the same thing.
contract UpgradeRegistrarControllerHarness is UpgradeRegistrarController {
    /// @notice Upgrades `proxy` under `owner` through the script's own internal.
    function upgrade(address owner, address proxy) external {
        _upgradeRegistrarController(owner, proxy);
    }
}

/// @title UpgradeRegistrarControllerForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradeRegistrarController.s.sol`. Upgrades the
/// deployed registrar controller and proves the storage-layout fix keeps its protocol registry
/// pointer readable.
/// @dev Requires the local ETH-RPC adapter on `paseo_local`; see `DEPLOYMENTS.md`. Run the suite
///      with `bun run test:fork`, which also checks every snapshot against the deployed bytecode
///      before the first test runs.
/// @custom:security-contact admin@parity.io
contract UpgradeRegistrarControllerForkTest is BaseUpgradeFork {
    /// @notice The deployed proxy under upgrade.
    address internal proxy;

    /// @notice Proxy owner, impersonated to authorise the upgrade.
    address internal proxyOwner;

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradeRegistrarControllerHarness internal upgrader;

    function setUp() public override {
        super.setUp();
        proxy = _live("DotnsRegistrarController");
        proxyOwner = _ownerOf(proxy);
        upgrader = new UpgradeRegistrarControllerHarness();
    }

    /// @notice The protocol registry pointer survives, which is the whole point of the retained
    /// slot.
    /// @dev This proxy is the reason the branch carries a `__whiteListSlot` placeholder. The
    ///      release removed the `whiteList` field, which moved `protocolRegistry` up one slot; an
    ///      implementation built without the placeholder reads it as the zero address and every
    ///      lookup through it fails. Reading it back non-zero after the swap is what shows the
    ///      placeholder did its job against real storage rather than against a fresh deployment.
    function test_upgrade_keeps_the_protocol_registry_pointer_readable() public {
        DotnsRegistrarController controller = DotnsRegistrarController(proxy);

        address registryBefore = address(controller.protocolRegistry());
        address implementationBefore = _implementationOf(proxy);

        assertTrue(registryBefore != address(0), "fork precondition: pointer is set");
        assertEq(
            registryBefore, _live("DotnsProtocolRegistry"), "fork precondition: pointer is correct"
        );

        upgrader.upgrade(proxyOwner, proxy);

        assertTrue(
            _implementationOf(proxy) != implementationBefore, "the implementation actually changed"
        );
        assertEq(
            address(controller.protocolRegistry()),
            registryBefore,
            "protocol registry pointer still on the slot the live proxy uses"
        );
    }
}
