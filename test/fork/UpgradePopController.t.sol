// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseUpgradeFork} from "./BaseUpgradeFork.t.sol";
import {UpgradePopController} from "../../scripts/deploy/UpgradePopController.s.sol";
import {IDotnsPopController} from "../../contracts/registrars/IDotnsPopController.sol";

/// @title UpgradePopControllerHarness
/// @notice Exposes the upgrade script's internal path so the test drives the code the production
///         run executes, including the fail-closed storage-layout diff.
/// @dev Forwarding to the script internal rather than re-implementing the upgrade is what keeps
///      the test honest: a test that called `Upgrades.upgradeProxy` itself would keep passing
///      after the script stopped doing the same thing.
contract UpgradePopControllerHarness is UpgradePopController {
    /// @notice Upgrades `proxy` under `owner` through the script's own internal.
    function upgrade(address owner, address proxy) external {
        _upgradePopController(owner, proxy);
    }
}

/// @title UpgradePopControllerForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradePopController.s.sol`. Upgrades the deployed
/// PoP controller and proves the reservation queues and issuance records survive.
/// @dev Requires the local ETH-RPC adapter on `paseo_local`; see `DEPLOYMENTS.md`. Run the suite
///      with `bun run test:fork`, which also checks every snapshot against the deployed bytecode
///      before the first test runs.
/// @custom:security-contact admin@parity.io
contract UpgradePopControllerForkTest is BaseUpgradeFork {
    /// @notice The deployed proxy under upgrade.
    address internal proxy;

    /// @notice Proxy owner, impersonated to authorise the upgrade.
    address internal proxyOwner;

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradePopControllerHarness internal upgrader;

    function setUp() public override {
        super.setUp();
        proxy = _live("DotnsPopController");
        proxyOwner = _ownerOf(proxy);
        upgrader = new UpgradePopControllerHarness();
    }

    /// @notice Reservation and claim state survive the swap.
    /// @dev The controller holds the queues real users are waiting in, so these counts are the
    ///      state worth asserting. They are read rather than seeded: a fixture would prove the
    ///      upgrade preserves a fixture, which is not the question.
    function test_upgrade_preserves_reservation_and_claim_state() public {
        IDotnsPopController controller = IDotnsPopController(proxy);

        uint256 pendingUsersBefore = controller.pendingClaimUserCount();
        uint64 durationBefore = controller.reservationDuration();
        address implementationBefore = _implementationOf(proxy);

        upgrader.upgrade(proxyOwner, proxy);

        assertTrue(
            _implementationOf(proxy) != implementationBefore, "the implementation actually changed"
        );
        assertEq(
            controller.pendingClaimUserCount(), pendingUsersBefore, "pending claim users preserved"
        );
        assertEq(controller.reservationDuration(), durationBefore, "reservation window preserved");
    }
}
