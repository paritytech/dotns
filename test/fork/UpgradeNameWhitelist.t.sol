// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {DotnsNameWhitelist} from "../../contracts/whitelist/DotnsNameWhitelist.sol";
import {IDotnsNameWhitelist} from "../../contracts/whitelist/IDotnsNameWhitelist.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {ISystem} from "../../contracts/external/revive/ISystem.sol";
import {UpgradeNameWhitelist} from "../../scripts/deploy/UpgradeNameWhitelist.s.sol";

/// @title UpgradeNameWhitelistHarness
/// @notice Exposes the upgrade script's internal upgrade path so the fork test drives the exact
///         code the production run executes, including the fail-closed storage-layout diff.
/// @dev Mirrors the `UpgradeRegistrarHarness` pattern: forward to the script internal rather than
///      re-implement the upgrade, so the test tracks the production path one-to-one.
contract UpgradeNameWhitelistHarness is UpgradeNameWhitelist {
    /// @notice Upgrades `proxy` under `owner` through the script's `_upgradeNameWhitelist`.
    function upgradeNameWhitelist(address owner, address proxy) external {
        _upgradeNameWhitelist(owner, proxy);
    }
}

/// @title UpgradeNameWhitelistForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradeNameWhitelist.s.sol`. Forks the live Paseo
///         Asset Hub through the ETH-RPC adapter, upgrades the deployed whitelist proxy with the
///         script, and re-runs the whitelist's P0 paths against real on-chain state to prove the
///         swap preserves stored names and keeps governance grants, reservations, and the
///         controller consume hook working.
/// @dev PR-scoped: deleted before merge with the upgrade script and the `DotnsNameWhitelistOld`
///      snapshot. Requires the local adapter on `paseo_local`. The whole admin surface is
///      substrate Root, so each governance action mocks `ISystem.originIsRoot` to true through the
///      System precompile the whitelist reads.
/// @custom:security-contact admin@parity.io
contract UpgradeNameWhitelistForkTest is Test {
    /// @notice Manifest recording the live deployment addresses this fork resolves against.
    string internal constant MANIFEST_PATH = "deployments/paseo-assethub/420420417.json";

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradeNameWhitelistHarness internal upgrader;

    /// @notice The deployed whitelist proxy under upgrade.
    DotnsNameWhitelist internal whitelist;

    /// @notice The deployed protocol registry the whitelist resolves the TLD and controllers
    ///         through.
    IDotnsProtocolRegistry internal protocolRegistry;

    /// @notice Proxy owner, impersonated to authorise the upgrade.
    address internal whitelistOwner;

    /// @notice The deployed commit-reveal controller, the caller the consume hook admits.
    address internal controller;

    /// @notice Beneficiary accounts for the grant and consume paths.
    address internal alice;
    address internal bob;

    /// @notice Forks Paseo, resolves the live addresses, and readies the upgrade harness.
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("paseo_local"));

        string memory manifest = vm.readFile(MANIFEST_PATH);
        whitelist = DotnsNameWhitelist(vm.parseJsonAddress(manifest, ".DotnsNameWhitelist"));
        protocolRegistry =
            IDotnsProtocolRegistry(vm.parseJsonAddress(manifest, ".DotnsProtocolRegistry"));
        whitelistOwner = OwnableUpgradeable(address(whitelist)).owner();
        controller = protocolRegistry.get(DotnsConstants.CONTROLLER);

        upgrader = new UpgradeNameWhitelistHarness();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    /// @notice The upgrade preserves both a name reserved and a governance grant seeded before the
    ///         swap, and still binds a fresh grant to its winner on the upgraded implementation.
    function test_upgrade_preservesStateAndKeepsGovernanceP0Working() public {
        // Seed a reservation and a governance grant on the pre-upgrade implementation under a Root
        // origin, so both a reservation slot and a name record cross the swap.
        _mockRoot(true);
        whitelist.setReserved("forkseedname", true);
        whitelist.grantName("forkseedgrant", alice);
        _clearRoot();
        assertTrue(whitelist.isReserved("forkseedname"), "pre-upgrade: seed name is reserved");
        assertEq(
            whitelist.granteeOf("forkseedgrant"), alice, "pre-upgrade: seed grant binds the winner"
        );

        address proxy = address(whitelist);
        address registryBefore = address(whitelist.protocolRegistry());

        upgrader.upgradeNameWhitelist(whitelistOwner, proxy);

        assertEq(address(whitelist), proxy, "upgrade keeps the same proxy address");
        assertTrue(whitelist.isReserved("forkseedname"), "post-upgrade: reservation preserved");
        // The grant seeded on the old implementation still resolves to its winner on the new one,
        // proving the name record survived the swap rather than the new logic recomputing it.
        assertEq(
            whitelist.granteeOf("forkseedgrant"),
            alice,
            "post-upgrade: seed grant preserved"
        );
        assertTrue(
            whitelist.isGrantedTo("forkseedgrant", alice),
            "post-upgrade: seed winner is still granted the name"
        );
        assertEq(
            address(whitelist.protocolRegistry()),
            registryBefore,
            "post-upgrade: protocol registry pointer preserved"
        );

        // P0: a fresh governance grant still binds a name to its winner on the upgraded
        // implementation.
        _mockRoot(true);
        whitelist.grantName("forkgrantname", bob);
        _clearRoot();
        assertEq(
            whitelist.granteeOf("forkgrantname"), bob, "post-upgrade: fresh grant binds the winner"
        );
        assertTrue(
            whitelist.isGrantedTo("forkgrantname", bob),
            "post-upgrade: fresh winner is granted the name"
        );
    }

    /// @notice After the upgrade the admin surface is substrate Root only, so a non-Root governance
    ///         call reverts with the fail-closed gate, and the controller consume hook still clears
    ///         a winner.
    function test_upgrade_governanceIsRootGatedAndConsumeStillClears() public {
        upgrader.upgradeNameWhitelist(whitelistOwner, address(whitelist));

        // New surface: a governance action from a non-Root origin fails closed with the Root gate.
        // The owner holds no allocation authority, only upgrade authority.
        _mockRoot(false);
        vm.prank(whitelistOwner);
        vm.expectRevert(IDotnsNameWhitelist.NotGovernance.selector);
        whitelist.setReserved("forkgatedname", true);
        _clearRoot();

        // P0: a granted name is still cleared by the registrar controller through consume.
        _mockRoot(true);
        whitelist.grantName("forkconsumename", bob);
        _clearRoot();
        assertEq(whitelist.granteeOf("forkconsumename"), bob, "grant binds the winner");

        vm.prank(controller);
        whitelist.consume("forkconsumename", bob);
        assertEq(
            uint256(whitelist.statusOf("forkconsumename")),
            uint256(IDotnsNameWhitelist.NameStatus.Open),
            "consume resets the name to Open"
        );
        assertEq(whitelist.granteeOf("forkconsumename"), address(0), "consume clears the winner");
    }

    /// @notice Mocks revive's System precompile so `originIsRoot` returns true, driving the
    ///         whitelist's Root-only governance gate.
    function _mockRoot(bool root) internal {
        vm.mockCall(
            DotnsConstants.REVIVE_SYSTEM,
            abi.encodeWithSelector(ISystem.originIsRoot.selector),
            abi.encode(root)
        );
    }

    /// @notice Clears the `originIsRoot` mock so later calls read the real precompile result.
    function _clearRoot() internal {
        vm.clearMockedCalls();
    }
}
