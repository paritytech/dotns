// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BasePopFork} from "./BasePopFork.t.sol";
import {UpgradePopRulesHarness} from "./UpgradePopRules.t.sol";
import {UpgradePopController} from "../../scripts/deploy/UpgradePopController.s.sol";
import {IDotnsPopController} from "../../contracts/registrars/IDotnsPopController.sol";
import {DotnsPopController} from "../../contracts/registrars/DotnsPopController.sol";
import {LabelUtils} from "../../contracts/utils/LabelUtils.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";

/// @title UpgradePopControllerHarness
/// @notice Exposes the upgrade script's internal path so the test drives the code the production
///         run executes, including the fail-closed storage-layout diff.
contract UpgradePopControllerHarness is UpgradePopController {
    /// @notice Upgrades `controller` under `owner` through the script's own internal.
    function upgrade(address owner, address controller, address rules) external {
        _upgradePopController(owner, controller, rules);
    }
}

/// @title UpgradePopControllerForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradePopController.s.sol`. Proves the step
///         waits for the rules, that live state survives the swap, and that issuance works on
///         the upgraded pair.
/// @dev Requires the local ETH-RPC adapter on `paseo_local`, or `PASEO_FORK_RPC`; see
///      `DEPLOYMENTS.md`. Run the suite with `bun run test:fork`.
/// @custom:security-contact admin@parity.io
contract UpgradePopControllerForkTest is BasePopFork {
    /// @notice Storage slot of `_deviceContainers`, as `PrepareDeviceContainers` reads it.
    uint256 internal constant DEVICE_CONTAINERS_SLOT = 10;

    /// @notice The deployed controller proxy under upgrade.
    address internal controller;

    /// @notice The deployed PopRules proxy the controller depends on.
    address internal rules;

    /// @notice Owner of both proxies.
    address internal owner;

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradePopControllerHarness internal upgrader;

    function setUp() public override {
        super.setUp();
        controller = _live("DotnsPopController");
        rules = _live("PopRules");
        owner = _ownerOf(controller);
        upgrader = new UpgradePopControllerHarness();
    }

    /// @notice The step refuses to run while PopRules still runs the previous implementation.
    function test_refuses_before_the_rules() public {
        address implementationBefore = _implementationOf(controller);

        vm.expectRevert(bytes("UpgradePopController: upgrade PopRules first"));
        upgrader.upgrade(owner, controller, rules);

        assertEq(_implementationOf(controller), implementationBefore, "nothing swapped");
    }

    /// @notice After the rules, the swap lands and the live configuration and counters survive.
    function test_upgrade_preserves_live_state() public {
        IDotnsPopController popController = IDotnsPopController(controller);
        address implementationBefore = _implementationOf(controller);
        uint64 durationBefore = popController.reservationDuration();
        uint256 claimUsersBefore = popController.pendingClaimUserCount();

        new UpgradePopRulesHarness().upgrade(_ownerOf(rules), rules);
        upgrader.upgrade(owner, controller, rules);

        assertTrue(
            _implementationOf(controller) != implementationBefore, "the implementation changed"
        );
        assertEq(
            DotnsPopController(controller).MAX_QUEUE_STEPS_PER_CALL(), 4, "bounded queue steps"
        );
        assertEq(_ownerOf(controller), owner, "owner preserved");
        assertEq(popController.reservationDuration(), durationBefore, "duration preserved");
        assertEq(
            popController.pendingClaimUserCount(), claimUsersBefore, "pending claims preserved"
        );
    }

    /// @notice The upgraded pair issues a linked device and personhood pair, and records the
    ///         device name's container in the slot `PrepareDeviceContainers` reads.
    function test_upgraded_pair_issues_and_records_the_container() public {
        new UpgradePopRulesHarness().upgrade(_ownerOf(rules), rules);
        upgrader.upgrade(owner, controller, rules);
        bytes32 tldNode = IDotnsProtocolRegistry(_live("DotnsProtocolRegistry")).tldNode();
        bytes32 container = LabelUtils.namehashUnder(tldNode, LabelUtils.labelhashMemory("07"));
        bytes32 slot = keccak256(abi.encode(container, DEVICE_CONTAINERS_SLOT));
        assertEq(vm.load(controller, slot), bytes32(0), "container not yet recorded");

        bytes32 personhoodNode = _issueLinkedPair(controller);

        (bool ok, bytes memory data) = _live("DotnsRegistry")
            .staticcall(abi.encodeWithSignature("owner(bytes32)", personhoodNode));
        assertTrue(ok, "registry readable");
        assertEq(abi.decode(data, (address)), popUser, "personhood name issued");
        assertTrue(vm.load(controller, slot) != bytes32(0), "container recorded at the read slot");
    }

    /// @notice A second run against the upgraded proxy swaps nothing.
    function test_rerun_is_a_no_op() public {
        new UpgradePopRulesHarness().upgrade(_ownerOf(rules), rules);
        upgrader.upgrade(owner, controller, rules);
        address implementationAfter = _implementationOf(controller);

        upgrader.upgrade(owner, controller, rules);

        assertEq(_implementationOf(controller), implementationAfter, "no second swap");
    }
}
