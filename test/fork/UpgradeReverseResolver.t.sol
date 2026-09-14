// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {DotnsReverseResolver} from "../../contracts/resolvers/DotnsReverseResolver.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {UpgradeReverseResolver} from "../../scripts/deploy/UpgradeReverseResolver.s.sol";

/// @title UpgradeReverseResolverHarness
/// @notice Exposes the upgrade script's internal upgrade path so the fork test drives the exact
///         code the production run executes, including the fail-closed storage-layout diff.
/// @dev Mirrors the `DeterministicDeploymentHarness` pattern: forward to the script internal
///      rather than re-implement the upgrade, so the test tracks the production path one-to-one.
contract UpgradeReverseResolverHarness is UpgradeReverseResolver {
    /// @notice Upgrades `proxy` under `owner` through the script's `_upgradeReverseResolver`.
    function upgradeReverseResolver(address owner, address proxy) external {
        _upgradeReverseResolver(owner, proxy);
    }
}

/// @title UpgradeReverseResolverForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradeReverseResolver.s.sol`. Forks the live
/// Paseo Asset Hub through the ETH-RPC adapter, upgrades the deployed reverse resolver proxy with
///         the script, and reads it back to prove the swap preserves the proxy address and owner
/// and leaves the reverse-lookup entrypoint callable.
/// @dev PR-scoped: deleted before merge with the upgrade script and the `DotnsReverseResolverOld`
///      snapshot. Requires the local adapter on `paseo_local`; between upgrade PRs `test/fork/` is
///      empty, so the suite is skipped by default with `--no-match-path 'test/fork/**'`.
///
///      This upgrade adds no storage: the new implementation reads a lite name's owner through the
///      registry at its hierarchical node instead of from the registrar, so the layout diff is a
///      no-op and the assertions below focus on the swap leaving state and the read path intact.
/// @custom:security-contact admin@parity.io
contract UpgradeReverseResolverForkTest is Test {
    /// @notice Manifest recording the live deployment addresses this fork resolves against.
    string internal constant MANIFEST_PATH = "deployments/paseo-assethub/420420417.json";

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradeReverseResolverHarness internal upgrader;

    /// @notice The deployed reverse resolver proxy under upgrade.
    DotnsReverseResolver internal reverseResolver;

    /// @notice Reverse resolver proxy owner, impersonated to authorise the upgrade.
    address internal reverseResolverOwner;

    /// @notice Forks Paseo, resolves the live reverse resolver, and reads the owner.
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("paseo_local"));

        string memory manifest = vm.readFile(MANIFEST_PATH);
        reverseResolver =
            DotnsReverseResolver(vm.parseJsonAddress(manifest, ".DotnsReverseResolver"));
        reverseResolverOwner = OwnableUpgradeable(address(reverseResolver)).owner();

        upgrader = new UpgradeReverseResolverHarness();
    }

    /// @notice The upgrade keeps the same proxy address and owner, and the reverse-lookup
    /// entrypoint stays callable and returns the same answer for an address with no record.
    function test_upgrade_preservesAddressOwnerAndReadPath() public {
        address noRecord = makeAddr("noReverseRecord");
        string memory nameBefore = reverseResolver.nameOf(noRecord);

        address proxy = address(reverseResolver);
        upgrader.upgradeReverseResolver(reverseResolverOwner, proxy);

        assertEq(address(reverseResolver), proxy, "upgrade keeps the same proxy address");
        assertEq(
            OwnableUpgradeable(proxy).owner(),
            reverseResolverOwner,
            "post-upgrade: proxy owner preserved"
        );
        assertEq(
            reverseResolver.nameOf(noRecord),
            nameBefore,
            "post-upgrade: reverse lookup callable and unchanged for an address with no record"
        );
    }
}
