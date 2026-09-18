// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseUpgradeFork} from "./BaseUpgradeFork.t.sol";
import {UpgradeProtocolRegistry} from "../../scripts/deploy/UpgradeProtocolRegistry.s.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";

/// @title UpgradeProtocolRegistryHarness
/// @notice Exposes the upgrade script's internal path so the test drives the code the production
///         run executes, including the fail-closed storage-layout diff.
/// @dev Forwarding to the script internal rather than re-implementing the upgrade is what keeps
///      the test honest: a test that called `Upgrades.upgradeProxy` itself would keep passing
///      after the script stopped doing the same thing.
contract UpgradeProtocolRegistryHarness is UpgradeProtocolRegistry {
    /// @notice Upgrades `proxy` under `owner` through the script's own internal.
    function upgrade(address owner, address proxy) external {
        _upgradeProtocolRegistry(owner, proxy);
    }
}

/// @title UpgradeProtocolRegistryForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradeProtocolRegistry.s.sol`. Upgrades the
/// deployed protocol registry and proves every key still resolves to the same address, then that
/// the declaration surface the release adds is live.
/// @dev Requires the local ETH-RPC adapter on `paseo_local`; see `DEPLOYMENTS.md`. Run the suite
///      with `bun run test:fork`, which also checks every snapshot against the deployed bytecode
///      before the first test runs.
/// @custom:security-contact admin@parity.io
contract UpgradeProtocolRegistryForkTest is BaseUpgradeFork {
    /// @notice The deployed proxy under upgrade.
    address internal proxy;

    /// @notice Proxy owner, impersonated to authorise the upgrade.
    address internal proxyOwner;

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradeProtocolRegistryHarness internal upgrader;

    function setUp() public override {
        super.setUp();
        proxy = _live("DotnsProtocolRegistry");
        proxyOwner = _ownerOf(proxy);
        upgrader = new UpgradeProtocolRegistryHarness();
    }

    /// @notice Key resolution and the TLD survive the swap, and the declarations become callable.
    /// @dev The protocol registry is upgraded first in the production order because every other
    ///      contract's `version()` reads through it. If this swap lost a key, every later swap
    ///      would be pointed at the zero address, so the resolution assertions here are what make
    ///      the rest of the sequence safe to run.
    function test_upgrade_preserves_every_key_and_adds_the_declarations() public {
        IDotnsProtocolRegistry registry = IDotnsProtocolRegistry(proxy);

        bytes32[6] memory keys = [
            DotnsConstants.REGISTRY,
            DotnsConstants.REGISTRAR,
            DotnsConstants.CONTROLLER,
            DotnsConstants.POP_CONTROLLER,
            DotnsConstants.RESOLVER,
            DotnsConstants.STORE_FACTORY
        ];

        address[6] memory before;
        for (uint256 i; i < keys.length; ++i) {
            before[i] = registry.get(keys[i]);
        }
        string memory tldBefore = registry.tld();
        bytes32 tldNodeBefore = registry.tldNode();
        address implementationBefore = _implementationOf(proxy);

        upgrader.upgrade(proxyOwner, proxy);

        assertTrue(
            _implementationOf(proxy) != implementationBefore, "the implementation actually changed"
        );
        for (uint256 i; i < keys.length; ++i) {
            assertEq(registry.get(keys[i]), before[i], "key still resolves to the same address");
        }
        assertEq(registry.tld(), tldBefore, "TLD preserved");
        assertEq(registry.tldNode(), tldNodeBefore, "TLD node preserved");

        // Undeclared until `DeclareRelease` runs, which is deliberate: the release is declared
        // once, after every swap has verified, so an abandoned upgrade cannot leave a false claim.
        assertEq(registry.protocolVersion(), "", "version starts undeclared after the swap");
    }
}
