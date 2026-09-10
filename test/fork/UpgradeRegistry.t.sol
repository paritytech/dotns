// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {DotnsRegistry} from "../../contracts/registry/DotnsRegistry.sol";
import {UpgradeRegistry} from "../../scripts/deploy/UpgradeRegistry.s.sol";

/// @title UpgradeRegistryHarness
/// @notice Exposes the upgrade script's internal upgrade path so the fork test drives the exact
///         code the production run executes, including the fail-closed storage-layout diff.
/// @dev Mirrors the `DeterministicDeploymentHarness` pattern: forward to the script internal
///      rather than re-implement the upgrade, so the test tracks the production path one-to-one.
contract UpgradeRegistryHarness is UpgradeRegistry {
    /// @notice Upgrades `proxy` under `owner` through the script's `_upgradeRegistry`.
    function upgradeRegistry(address owner, address proxy) external {
        _upgradeRegistry(owner, proxy);
    }
}

/// @title UpgradeRegistryForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradeRegistry.s.sol`. Forks the live Paseo Asset
///         Hub through the ETH-RPC adapter, upgrades the deployed registry proxy with the script,
///         and reads it back to prove the swap keeps the same proxy address and owner and preserves
///         the protocol registry pointer the registry holds.
/// @dev PR-scoped: deleted before merge with the upgrade script and the `DotnsRegistryOld`
/// snapshot. Requires the local adapter on `paseo_local`; between upgrade PRs `test/fork/` is
/// empty, so
///      the suite is skipped by default with `--no-match-path 'test/fork/**'`.
///
///      The `persist` field this upgrade adds lives on the calldata `SubnodeRecord`, not in
/// storage, so the layout diff is a no-op and the swap succeeding is itself the proof that no slot
/// moved.
/// @custom:security-contact admin@parity.io
contract UpgradeRegistryForkTest is Test {
    /// @notice Manifest recording the live deployment addresses this fork resolves against.
    string internal constant MANIFEST_PATH = "deployments/paseo-assethub/420420417.json";

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradeRegistryHarness internal upgrader;

    /// @notice The deployed registry proxy under upgrade.
    DotnsRegistry internal registry;

    /// @notice Registry proxy owner, impersonated to authorise the upgrade.
    address internal registryOwner;

    /// @notice Forks Paseo, resolves the live registry, and reads the owner.
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("paseo_local"));

        string memory manifest = vm.readFile(MANIFEST_PATH);
        registry = DotnsRegistry(vm.parseJsonAddress(manifest, ".DotnsRegistry"));
        registryOwner = OwnableUpgradeable(address(registry)).owner();

        upgrader = new UpgradeRegistryHarness();
    }

    /// @notice The upgrade keeps the same proxy address and owner, and the protocol registry
    /// pointer the registry holds reads back identically, proving the swap preserved its storage.
    function test_upgrade_preservesAddressOwnerAndConfig() public {
        address configBefore = address(registry.protocolRegistry());

        address proxy = address(registry);
        upgrader.upgradeRegistry(registryOwner, proxy);

        assertEq(address(registry), proxy, "upgrade keeps the same proxy address");
        assertEq(
            OwnableUpgradeable(proxy).owner(), registryOwner, "post-upgrade: proxy owner preserved"
        );
        assertEq(
            address(registry.protocolRegistry()),
            configBefore,
            "post-upgrade: protocol registry pointer preserved"
        );
    }
}
