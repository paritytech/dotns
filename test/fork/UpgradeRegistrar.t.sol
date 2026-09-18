// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseUpgradeFork} from "./BaseUpgradeFork.t.sol";
import {UpgradeRegistrar} from "../../scripts/deploy/UpgradeRegistrar.s.sol";
import {IDotnsRegistrar} from "../../contracts/registrars/IDotnsRegistrar.sol";
import {IDotnsController} from "../../contracts/registrars/IDotnsController.sol";

/// @title UpgradeRegistrarHarness
/// @notice Exposes the upgrade script's internal path so the test drives the code the production
///         run executes, including the fail-closed storage-layout diff.
/// @dev Forwarding to the script internal rather than re-implementing the upgrade is what keeps
///      the test honest: a test that called `Upgrades.upgradeProxy` itself would keep passing
///      after the script stopped doing the same thing.
contract UpgradeRegistrarHarness is UpgradeRegistrar {
    /// @notice Upgrades `proxy` under `owner` through the script's own internal.
    function upgrade(address owner, address proxy) external {
        _upgradeRegistrar(owner, proxy);
    }
}

/// @title UpgradeRegistrarForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradeRegistrar.s.sol`. Upgrades the deployed
/// registrar and proves the live controller authorisations and token state survive.
/// @dev Requires the local ETH-RPC adapter on `paseo_local`; see `DEPLOYMENTS.md`. Run the suite
///      with `bun run test:fork`, which also checks every snapshot against the deployed bytecode
///      before the first test runs.
/// @custom:security-contact admin@parity.io
contract UpgradeRegistrarForkTest is BaseUpgradeFork {
    /// @notice The deployed proxy under upgrade.
    address internal proxy;

    /// @notice Proxy owner, impersonated to authorise the upgrade.
    address internal proxyOwner;

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradeRegistrarHarness internal upgrader;

    function setUp() public override {
        super.setUp();
        proxy = _live("DotnsRegistrar");
        proxyOwner = _ownerOf(proxy);
        upgrader = new UpgradeRegistrarHarness();
    }

    /// @notice Controller authorisations survive the swap.
    /// @dev These are what the registry's new deferral gate reads, and what every minting path
    ///      goes through. Losing them would leave the network unable to issue a name, so this is
    ///      the registrar's P0 state rather than any individual token.
    function test_upgrade_preserves_controller_authorisations() public {
        IDotnsRegistrar registrar = IDotnsRegistrar(proxy);

        IDotnsController popController = IDotnsController(_live("DotnsPopController"));
        IDotnsController registrarController = IDotnsController(_live("DotnsRegistrarController"));

        bool popBefore = registrar.controllers(popController);
        bool controllerBefore = registrar.controllers(registrarController);
        address implementationBefore = _implementationOf(proxy);

        assertTrue(popBefore, "fork precondition: the PoP controller is authorised");
        assertTrue(controllerBefore, "fork precondition: the registrar controller is authorised");

        upgrader.upgrade(proxyOwner, proxy);

        assertTrue(
            _implementationOf(proxy) != implementationBefore, "the implementation actually changed"
        );
        assertTrue(registrar.controllers(popController), "PoP controller still authorised");
        assertTrue(
            registrar.controllers(registrarController), "registrar controller still authorised"
        );
    }
}
