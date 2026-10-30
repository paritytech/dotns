// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BasePopFork} from "./BasePopFork.t.sol";
import {UpgradePopRulesHarness} from "./UpgradePopRules.t.sol";
import {UpgradePopControllerHarness} from "./UpgradePopController.t.sol";
import {UpgradeRegistrarControllerHarness} from "./UpgradeRegistrarController.t.sol";
import {DeclareRelease} from "../../scripts/deploy/DeclareRelease.s.sol";
import {SetReservationDuration} from "../../scripts/deploy/SetReservationDuration.s.sol";
import {PrepareDeviceContainers} from "../../scripts/deploy/PrepareDeviceContainers.s.sol";
import {IDotnsPopController} from "../../contracts/registrars/IDotnsPopController.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {IDotnsRegistry} from "../../contracts/registry/IDotnsRegistry.sol";

/// @title SetReservationDurationHarness
/// @notice Runs the script's own internal under an explicit owner.
contract SetReservationDurationHarness is SetReservationDuration {
    /// @notice Sets the duration on `controller` under `owner`.
    function set(address owner, address controller) external {
        _setReservationDuration(owner, controller);
    }
}

/// @title PrepareDeviceContainersHarness
/// @notice Runs the script's own internal under an explicit sender, and exposes its slot read.
contract PrepareDeviceContainersHarness is PrepareDeviceContainers {
    /// @notice Prepares containers `from` to `to` on `controller` as `sender`.
    /// @return prepared Number of containers the run prepared.
    function prepare(
        address sender,
        address controller,
        IDotnsRegistry registry,
        bytes32 tldNode,
        uint256 from,
        uint256 to
    )
        external
        returns (uint256 prepared)
    {
        prepared = _prepareContainers(sender, controller, registry, tldNode, from, to);
    }

    /// @notice Whether `controller` has recorded container `number`.
    function recorded(
        address controller,
        bytes32 tldNode,
        uint256 number
    )
        external
        view
        returns (bool)
    {
        return _isRecorded(controller, tldNode, _suffix(number));
    }

    /// @notice Node of container `number`.
    function containerNode(bytes32 tldNode, uint256 number) external pure returns (bytes32) {
        return _containerNode(tldNode, _suffix(number));
    }
}

/// @title PaseoV110CampaignForkTest
/// @notice The whole v1.0.0 to v1.1.0 campaign on one fork, in broadcast order: rules, PoP
///         controller, registrar controller, reservation duration, device containers, then the
///         release declaration.
/// @dev The rehearsal for the label-driven run. Each step's own fork test proves the step; this
///      proves the sequence, and that the release declaration verifies once every step has
///      landed.
/// @custom:security-contact admin@parity.io
contract PaseoV110CampaignForkTest is BasePopFork {
    /// @notice Release the campaign starts from.
    string internal constant PREVIOUS_TAG = "1.0.0";

    /// @notice Bare semver the campaign declares.
    string internal constant RELEASE_TAG = "1.1.0";

    /// @notice Owner of every proxy and of the protocol registry.
    address internal owner;

    /// @notice The protocol registry.
    IDotnsProtocolRegistry internal registry;

    /// @notice The forward registry.
    IDotnsRegistry internal names;

    /// @notice The deployed PoP controller proxy.
    address internal controller;

    /// @notice Node of the TLD the containers sit under.
    bytes32 internal tldNode;

    function setUp() public override {
        super.setUp();
        registry = IDotnsProtocolRegistry(_live("DotnsProtocolRegistry"));
        names = IDotnsRegistry(_live("DotnsRegistry"));
        controller = _live("DotnsPopController");
        owner = _ownerOf(address(registry));
        tldNode = registry.tldNode();
    }

    /// @notice All six steps in order end on a verified 1.1.0 declaration, with the new duration,
    ///         every container recorded, and issuance working end to end.
    function test_campaign_ends_on_a_verified_release() public {
        assertEq(registry.protocolVersion(), PREVIOUS_TAG, "starts on 1.0.0");

        new UpgradePopRulesHarness().upgrade(owner, _live("PopRules"));
        new UpgradePopControllerHarness().upgrade(owner, controller, _live("PopRules"));
        new UpgradeRegistrarControllerHarness().upgrade(owner, _live("DotnsRegistrarController"));
        new SetReservationDurationHarness().set(owner, controller);
        PrepareDeviceContainersHarness containers = new PrepareDeviceContainersHarness();
        containers.prepare(owner, controller, names, tldNode, 0, 99);
        _declare();

        assertEq(registry.protocolVersion(), RELEASE_TAG, "declares 1.1.0");
        assertEq(
            IDotnsPopController(controller).reservationDuration(), 30 days, "30-day reservations"
        );
        for (uint256 number; number <= 99; ++number) {
            assertTrue(containers.recorded(controller, tldNode, number), "container recorded");
        }

        bytes32 personhoodNode = _issueLinkedPair(controller);
        assertEq(names.owner(personhoodNode), popUser, "issuance works end to end");
    }

    /// @notice The settings steps are idempotent: a second run writes nothing.
    function test_settings_steps_rerun_as_no_ops() public {
        _upgradeRulesAndController();
        SetReservationDurationHarness duration = new SetReservationDurationHarness();
        PrepareDeviceContainersHarness containers = new PrepareDeviceContainersHarness();
        duration.set(owner, controller);
        assertEq(
            containers.prepare(owner, controller, names, tldNode, 0, 9), 10, "first run prepares"
        );

        vm.recordLogs();
        duration.set(owner, controller);
        assertEq(vm.getRecordedLogs().length, 0, "a duration rerun emits nothing");
        assertEq(
            containers.prepare(owner, controller, names, tldNode, 0, 9),
            0,
            "a container rerun prepares nothing"
        );
    }

    /// @notice A container another account holds is skipped, and the rest of the range is still
    ///         prepared.
    function test_container_held_elsewhere_is_skipped() public {
        _upgradeRulesAndController();
        PrepareDeviceContainersHarness containers = new PrepareDeviceContainersHarness();
        bytes32 held = containers.containerNode(tldNode, 5);
        vm.mockCall(
            address(names),
            abi.encodeWithSelector(IDotnsRegistry.owner.selector, held),
            abi.encode(makeAddr("someoneElse"))
        );

        assertEq(
            containers.prepare(owner, controller, names, tldNode, 0, 9), 9, "nine of ten prepared"
        );
        assertFalse(containers.recorded(controller, tldNode, 5), "the held container is skipped");
        assertTrue(containers.recorded(controller, tldNode, 6), "the range continues past it");
    }

    /// @notice Preparing containers before the controller swap stops with a clear message.
    function test_containers_wait_for_the_controller() public {
        PrepareDeviceContainersHarness containers = new PrepareDeviceContainersHarness();

        vm.expectRevert(bytes("PrepareDeviceContainers: run UpgradePopController first"));
        containers.prepare(owner, controller, names, tldNode, 0, 9);
    }

    /// @notice Upgrades the rules, then the PoP controller, through the scripts' own internals.
    function _upgradeRulesAndController() internal {
        new UpgradePopRulesHarness().upgrade(owner, _live("PopRules"));
        new UpgradePopControllerHarness().upgrade(owner, controller, _live("PopRules"));
    }

    /// @notice Runs `DeclareRelease.declare` as the owner with the release tag the console sets.
    function _declare() internal {
        vm.setEnv("DOTNS_RELEASE_TAG", RELEASE_TAG);
        DeclareRelease declarer = new DeclareRelease();
        vm.prank(owner);
        declarer.declare();
    }
}
