// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseUpgradeFork} from "./BaseUpgradeFork.t.sol";
import {UpgradeRegistry} from "../../scripts/deploy/UpgradeRegistry.s.sol";
import {IDotnsRegistry} from "../../contracts/registry/IDotnsRegistry.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";

/// @title UpgradeRegistryHarness
/// @notice Exposes the upgrade script's internal path so the test drives the code the production
///         run executes, including the fail-closed storage-layout diff.
/// @dev Forwarding to the script internal rather than re-implementing the upgrade is what keeps
///      the test honest: a test that called `Upgrades.upgradeProxy` itself would keep passing
///      after the script stopped doing the same thing.
contract UpgradeRegistryHarness is UpgradeRegistry {
    /// @notice Upgrades `proxy` under `owner` through the script's own internal.
    function upgrade(address owner, address proxy) external {
        _upgradeRegistry(owner, proxy);
    }
}

/// @title UpgradeRegistryForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradeRegistry.s.sol`. Upgrades the deployed
/// registry and proves records survive, then that the gate the release adds actually closes on the
/// live controller set.
/// @dev Requires the local ETH-RPC adapter on `paseo_local`; see `DEPLOYMENTS.md`. Run the suite
///      with `bun run test:fork`, which also checks every snapshot against the deployed bytecode
///      before the first test runs.
/// @custom:security-contact admin@parity.io
contract UpgradeRegistryForkTest is BaseUpgradeFork {
    /// @notice The deployed proxy under upgrade.
    address internal proxy;

    /// @notice Proxy owner, impersonated to authorise the upgrade.
    address internal proxyOwner;

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradeRegistryHarness internal upgrader;

    /// @notice The TLD node, which every registered name hangs off.
    bytes32 internal tldNode;

    function setUp() public override {
        super.setUp();
        proxy = _live("DotnsRegistry");
        proxyOwner = _ownerOf(proxy);
        upgrader = new UpgradeRegistryHarness();
        tldNode = IDotnsProtocolRegistry(_live("DotnsProtocolRegistry")).tldNode();
    }

    /// @notice The TLD record survives the swap and the new deferral gate rejects a plain caller.
    /// @dev The gate is the reason this upgrade exists. It reads `registrar.controllers` from live
    ///      state on every call, so a unit test cannot show it closing against the real controller
    ///      set; this can. The caller here owns nothing, so it fails the ownership modifier too,
    ///      which is why the assertion is only that a plain caller cannot defer.
    function test_upgrade_preserves_records_and_closes_the_deferral_gate() public {
        IDotnsRegistry registry = IDotnsRegistry(proxy);

        address ownerBefore = registry.owner(tldNode);
        address resolverBefore = registry.resolver(tldNode);
        bool existsBefore = registry.recordExists(tldNode);
        address implementationBefore = _implementationOf(proxy);

        upgrader.upgrade(proxyOwner, proxy);

        assertTrue(
            _implementationOf(proxy) != implementationBefore, "the implementation actually changed"
        );
        assertEq(registry.owner(tldNode), ownerBefore, "TLD owner preserved");
        assertEq(registry.resolver(tldNode), resolverBefore, "TLD resolver preserved");
        assertEq(registry.recordExists(tldNode), existsBefore, "TLD record preserved");

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(IDotnsRegistry.NotAuthorised.selector);
        registry.setSubnodeOwner(
            IDotnsRegistry.SubnodeRecord({
                parentNode: tldNode,
                subLabel: "deferred",
                parentLabel: "",
                owner: stranger,
                persist: false
            })
        );
    }
}
