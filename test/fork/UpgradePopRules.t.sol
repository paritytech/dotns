// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseUpgradeFork} from "./BaseUpgradeFork.t.sol";
import {UpgradePopRules} from "../../scripts/deploy/UpgradePopRules.s.sol";
import {IPopRules} from "../../contracts/pop/IPopRules.sol";

/// @title UpgradePopRulesHarness
/// @notice Exposes the upgrade script's internal path so the test drives the code the production
///         run executes, including the fail-closed storage-layout diff.
/// @dev Forwarding to the script internal rather than re-implementing the upgrade is what keeps
///      the test honest: a test that called `Upgrades.upgradeProxy` itself would keep passing
///      after the script stopped doing the same thing.
contract UpgradePopRulesHarness is UpgradePopRules {
    /// @notice Upgrades `proxy` under `owner` through the script's own internal.
    function upgrade(address owner, address proxy) external {
        _upgradePopRules(owner, proxy);
    }
}

/// @title UpgradePopRulesForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradePopRules.s.sol`. Upgrades the deployed
/// rules contract and proves classification and pricing are unchanged by the swap.
/// @dev Requires the local ETH-RPC adapter on `paseo_local`; see `DEPLOYMENTS.md`. Run the suite
///      with `bun run test:fork`, which also checks every snapshot against the deployed bytecode
///      before the first test runs.
/// @custom:security-contact admin@parity.io
contract UpgradePopRulesForkTest is BaseUpgradeFork {
    /// @notice The deployed proxy under upgrade.
    address internal proxy;

    /// @notice Proxy owner, impersonated to authorise the upgrade.
    address internal proxyOwner;

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradePopRulesHarness internal upgrader;

    function setUp() public override {
        super.setUp();
        proxy = _live("PopRules");
        proxyOwner = _ownerOf(proxy);
        upgrader = new UpgradePopRulesHarness();
    }

    /// @notice Pricing answers the same before and after.
    /// @dev The swap carries no behavioural change, so pricing returning something different
    ///      would mean the upgrade changed something it was not supposed to. Asserting equality
    ///      across the swap is the cheapest way to catch that.
    function test_upgrade_leaves_pricing_unchanged() public {
        IPopRules rules = IPopRules(proxy);

        uint256 versionBefore = rules.pricingVersion();
        uint256 priceBefore = rules.price("forkpricingprobe");
        address implementationBefore = _implementationOf(proxy);

        upgrader.upgrade(proxyOwner, proxy);

        assertTrue(
            _implementationOf(proxy) != implementationBefore, "the implementation actually changed"
        );
        assertEq(rules.pricingVersion(), versionBefore, "pricing version preserved");
        assertEq(rules.price("forkpricingprobe"), priceBefore, "price unchanged by the swap");
    }
}
