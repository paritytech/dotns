// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseUpgradeFork} from "./BaseUpgradeFork.t.sol";
import {UpgradeContentResolver} from "../../scripts/deploy/UpgradeContentResolver.s.sol";
import {DotnsContentResolver} from "../../contracts/resolvers/DotnsContentResolver.sol";

/// @title UpgradeContentResolverHarness
/// @notice Exposes the upgrade script's internal path so the test drives the code the production
///         run executes, including the fail-closed storage-layout diff.
/// @dev Forwarding to the script internal rather than re-implementing the upgrade is what keeps
///      the test honest: a test that called `Upgrades.upgradeProxy` itself would keep passing
///      after the script stopped doing the same thing.
contract UpgradeContentResolverHarness is UpgradeContentResolver {
    /// @notice Upgrades `proxy` under `owner` through the script's own internal.
    function upgrade(address owner, address proxy) external {
        _upgradeContentResolver(owner, proxy);
    }
}

/// @title UpgradeContentResolverForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradeContentResolver.s.sol`. Upgrades the
/// deployed DotnsContentResolver and proves the content and text records it serves stay readable
/// through the new implementation.
/// @dev Requires the local ETH-RPC adapter on `paseo_local`; see `DEPLOYMENTS.md`. Run the suite
///      with `bun run test:fork`, which also checks every snapshot against the deployed bytecode
///      before the first test runs.
/// @custom:security-contact admin@parity.io
contract UpgradeContentResolverForkTest is BaseUpgradeFork {
    /// @notice The deployed proxy under upgrade.
    address internal proxy;

    /// @notice Proxy owner, impersonated to authorise the upgrade.
    address internal proxyOwner;

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradeContentResolverHarness internal upgrader;

    function setUp() public override {
        super.setUp();
        proxy = _live("DotnsContentResolver");
        proxyOwner = _ownerOf(proxy);
        upgrader = new UpgradeContentResolverHarness();
    }

    /// @notice The protocol registry pointer survives, so every record stays resolvable.
    /// @dev This swap carries no behavioural change: `version()` reads the protocol registry's
    ///      declaration instead of a hardcoded string. The pointer is what every record lookup
    ///      goes through, so it is both the state most worth asserting and the one a layout
    ///      mistake would take out first, turning every read into a call to the zero address.
    function test_upgrade_keeps_records_resolvable() public {
        DotnsContentResolver resolver = DotnsContentResolver(proxy);

        address registryBefore = address(resolver.protocolRegistry());
        address implementationBefore = _implementationOf(proxy);

        assertEq(
            registryBefore, _live("DotnsProtocolRegistry"), "fork precondition: pointer is correct"
        );

        upgrader.upgrade(proxyOwner, proxy);

        assertTrue(
            _implementationOf(proxy) != implementationBefore, "the implementation actually changed"
        );
        assertEq(
            address(resolver.protocolRegistry()), registryBefore, "protocol registry preserved"
        );
    }
}
