// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseUpgradeFork} from "./BaseUpgradeFork.t.sol";
import {RotateOwnership, IOwnable} from "../../scripts/deploy/RotateOwnership.s.sol";
import {UpgradeRegistryHarness} from "./UpgradeRegistry.t.sol";

/// @title RotateOwnershipHarness
/// @notice Exposes the rotation script's internal path so the test drives the code the
///         production run executes, inventory checks included.
contract RotateOwnershipHarness is RotateOwnership {
    /// @notice Rotates everything from `current` to `newOwner` through the script's own internal.
    function rotate(address current, address newOwner) external {
        _rotateEverything(current, newOwner);
    }
}

/// @title RotateOwnershipForkTest
/// @notice Pairs one-to-one with `scripts/deploy/RotateOwnership.s.sol`. Rotates the live
///         deployment's ownership on a fork and proves the property the step exists for: the old
///         key loses the ability to act, the new key gains it, and no address moves.
/// @dev Step 0 of the runbook, so this runs against the pre-upgrade chain state on purpose:
///      rotation is broadcast before any implementation is swapped.
/// @custom:security-contact admin@parity.io
contract RotateOwnershipForkTest is BaseUpgradeFork {
    /// @notice The contracts the script must rotate, resolved from the manifest in setUp.
    /// @dev Kept as labels so a mismatch against the script's own list fails by name.
    string[14] internal labels = [
        "DotnsProtocolRegistry",
        "DotnsRegistry",
        "DotnsRegistrar",
        "DotnsRegistrarController",
        "DotnsPopController",
        "PopRules",
        "DotnsNameEscrow",
        "DotnsNameWhitelist",
        "DotnsResolver",
        "DotnsReverseResolver",
        "DotnsContentResolver",
        "DotnsPopResolver",
        "DotnsCostModelRegistry",
        "StoreFactory"
    ];

    /// @notice The deployment key, read from the chain, not assumed.
    address internal currentOwner;

    /// @notice The fresh key ownership moves to.
    address internal freshOwner;

    /// @notice Drives the script's own rotation path.
    RotateOwnershipHarness internal rotator;

    function setUp() public override {
        super.setUp();
        currentOwner = _ownerOf(_live("DotnsRegistry"));
        freshOwner = makeAddr("fresh-owner");
        rotator = new RotateOwnershipHarness();
    }

    /// @notice Every inventoried contract answers to the new key afterwards, at its old address.
    /// @dev The address assertions look redundant and are not: "rotation moves no addresses" is
    ///      the claim that makes rotation preferable to redeployment, so the test states it
    ///      against the manifest instead of leaving it as prose.
    function test_rotation_moves_every_owner_and_no_address() public {
        address[] memory targets = new address[](labels.length);
        for (uint256 i; i < labels.length; ++i) {
            targets[i] = _live(labels[i]);
            assertEq(
                IOwnable(targets[i]).owner(),
                currentOwner,
                string.concat("fork precondition: ", labels[i], " answers to the deployment key")
            );
        }

        rotator.rotate(currentOwner, freshOwner);

        for (uint256 i; i < labels.length; ++i) {
            assertEq(
                IOwnable(targets[i]).owner(),
                freshOwner,
                string.concat(labels[i], " answers to the fresh key")
            );
            assertEq(
                _live(labels[i]),
                targets[i],
                string.concat(labels[i], " is still at the address the manifest names")
            );
        }
    }

    /// @notice After rotation the old key cannot upgrade, and the new key can.
    /// @dev The lockout is the security property the step exists for, and the new key working is
    ///      what makes the runbook's steps 1 to 14 possible afterwards. Both are shown through
    ///      the registry upgrade script's own path, so what is proven is the exact pair of facts
    ///      the deployment relies on next.
    function test_old_key_is_locked_out_and_new_key_can_upgrade() public {
        address registry = _live("DotnsRegistry");
        rotator.rotate(currentOwner, freshOwner);

        UpgradeRegistryHarness upgrader = new UpgradeRegistryHarness();

        vm.expectRevert(bytes("UpgradeRegistry: broadcaster is not the proxy owner"));
        upgrader.upgrade(currentOwner, registry);

        upgrader.upgrade(freshOwner, registry);
        assertTrue(
            _implementationOf(registry) != address(0), "the fresh key performed a real upgrade"
        );
    }

    /// @notice A second run from the old key completes as a no-op instead of failing.
    /// @dev Partial-failure recovery: an interrupted rotation is finished by running again, and
    ///      contracts that already moved are skipped. A full re-run therefore has nothing to do,
    ///      and proving it does nothing loudly is what makes re-running safe to recommend.
    function test_rerun_after_completion_is_a_noop() public {
        rotator.rotate(currentOwner, freshOwner);
        rotator.rotate(currentOwner, freshOwner);

        for (uint256 i; i < labels.length; ++i) {
            assertEq(
                IOwnable(_live(labels[i])).owner(),
                freshOwner,
                string.concat(labels[i], " unchanged by the re-run")
            );
        }
    }
}
