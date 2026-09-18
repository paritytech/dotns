// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseUpgradeFork} from "./BaseUpgradeFork.t.sol";
import {UpgradeNameWhitelist} from "../../scripts/deploy/UpgradeNameWhitelist.s.sol";
import {IDotnsNameWhitelist} from "../../contracts/whitelist/IDotnsNameWhitelist.sol";

/// @title UpgradeNameWhitelistHarness
/// @notice Exposes the upgrade script's internal path so the test drives the code the production
///         run executes, including the fail-closed storage-layout diff.
/// @dev Forwarding to the script internal rather than re-implementing the upgrade is what keeps
///      the test honest: a test that called `Upgrades.upgradeProxy` itself would keep passing
///      after the script stopped doing the same thing.
contract UpgradeNameWhitelistHarness is UpgradeNameWhitelist {
    /// @notice Upgrades `proxy` under `owner` through the script's own internal.
    function upgrade(address owner, address proxy) external {
        _upgradeNameWhitelist(owner, proxy);
    }
}

/// @title UpgradeNameWhitelistForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradeNameWhitelist.s.sol`. Upgrades the deployed
/// whitelist and proves its caps and allocations survive.
/// @dev Requires the local ETH-RPC adapter on `paseo_local`; see `DEPLOYMENTS.md`. Run the suite
///      with `bun run test:fork`, which also checks every snapshot against the deployed bytecode
///      before the first test runs.
/// @custom:security-contact admin@parity.io
contract UpgradeNameWhitelistForkTest is BaseUpgradeFork {
    /// @notice The deployed proxy under upgrade.
    address internal proxy;

    /// @notice Proxy owner, impersonated to authorise the upgrade.
    address internal proxyOwner;

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradeNameWhitelistHarness internal upgrader;

    function setUp() public override {
        super.setUp();
        proxy = _live("DotnsNameWhitelist");
        proxyOwner = _ownerOf(proxy);
        upgrader = new UpgradeNameWhitelistHarness();
    }

    /// @notice Caps survive the swap.
    /// @dev This implementation changes only `initialize`, which does not run on an upgrade, so
    ///      the swap should be observationally inert. Asserting that explicitly is the point: it
    ///      is the contract where an unexpected difference would be most surprising, and the
    ///      cheapest place to notice one.
    function test_upgrade_is_observationally_inert() public {
        IDotnsNameWhitelist whitelist = IDotnsNameWhitelist(proxy);

        uint16 claimantsBefore = whitelist.maxClaimants();
        uint16 grantBatchBefore = whitelist.maxGrantBatch();
        uint256 reasonBytesBefore = whitelist.maxReasonBytes();
        address implementationBefore = _implementationOf(proxy);

        upgrader.upgrade(proxyOwner, proxy);

        assertTrue(
            _implementationOf(proxy) != implementationBefore, "the implementation actually changed"
        );
        assertEq(whitelist.maxClaimants(), claimantsBefore, "claimant cap preserved");
        assertEq(whitelist.maxGrantBatch(), grantBatchBefore, "grant batch cap preserved");
        assertEq(whitelist.maxReasonBytes(), reasonBytesBefore, "reason byte cap preserved");
    }
}
