// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseUpgradeFork} from "./BaseUpgradeFork.t.sol";
import {UpgradeNameEscrow} from "../../scripts/deploy/UpgradeNameEscrow.s.sol";
import {IDotnsNameEscrow} from "../../contracts/escrow/IDotnsNameEscrow.sol";

/// @title UpgradeNameEscrowHarness
/// @notice Exposes the upgrade script's internal path so the test drives the code the production
///         run executes, including the fail-closed storage-layout diff.
/// @dev Forwarding to the script internal rather than re-implementing the upgrade is what keeps
///      the test honest: a test that called `Upgrades.upgradeProxy` itself would keep passing
///      after the script stopped doing the same thing.
contract UpgradeNameEscrowHarness is UpgradeNameEscrow {
    /// @notice Upgrades `proxy` under `owner` through the script's own internal.
    function upgrade(address owner, address proxy) external {
        _upgradeNameEscrow(owner, proxy);
    }
}

/// @title UpgradeNameEscrowForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradeNameEscrow.s.sol`. Upgrades the deployed
/// escrow and proves the balances it custodies and the windows governing them survive.
/// @dev Requires the local ETH-RPC adapter on `paseo_local`; see `DEPLOYMENTS.md`. Run the suite
///      with `bun run test:fork`, which also checks every snapshot against the deployed bytecode
///      before the first test runs.
/// @custom:security-contact admin@parity.io
contract UpgradeNameEscrowForkTest is BaseUpgradeFork {
    /// @notice The deployed proxy under upgrade.
    address internal proxy;

    /// @notice Proxy owner, impersonated to authorise the upgrade.
    address internal proxyOwner;

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradeNameEscrowHarness internal upgrader;

    function setUp() public override {
        super.setUp();
        proxy = _live("DotnsNameEscrow");
        proxyOwner = _ownerOf(proxy);
        upgrader = new UpgradeNameEscrowHarness();
    }

    /// @notice Custodied balances and the configured windows survive the swap.
    /// @dev The escrow holds real deposits, so this is the one upgrade where a layout mistake
    ///      loses money rather than state. `redeemWindow` is asserted non-zero as well as
    ///      unchanged: a zero there leaves every release reverting, and `DEPLOYMENTS.md` records
    ///      it as the field an upgrade has historically dropped.
    function test_upgrade_preserves_balances_and_windows() public {
        IDotnsNameEscrow escrow = IDotnsNameEscrow(proxy);

        uint256 feesBefore = escrow.protocolFees();
        uint256 releasedBefore = escrow.releasedTokenCount();
        uint256 cooldownBefore = escrow.cooldown();
        uint256 redeemBefore = escrow.redeemWindow();
        address implementationBefore = _implementationOf(proxy);

        assertTrue(redeemBefore != 0, "fork precondition: redeem window is seeded");

        upgrader.upgrade(proxyOwner, proxy);

        assertTrue(
            _implementationOf(proxy) != implementationBefore, "the implementation actually changed"
        );
        assertEq(escrow.protocolFees(), feesBefore, "protocol fees preserved");
        assertEq(escrow.releasedTokenCount(), releasedBefore, "released token count preserved");
        assertEq(escrow.cooldown(), cooldownBefore, "cooldown preserved");
        assertEq(escrow.redeemWindow(), redeemBefore, "redeem window preserved and still non-zero");
    }
}
