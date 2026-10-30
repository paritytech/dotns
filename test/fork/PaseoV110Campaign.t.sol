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
    function prepare(
        address sender,
        address controller,
        bytes32 tldNode,
        uint256 from,
        uint256 to
    )
        external
    {
        _prepareContainers(sender, controller, tldNode, from, to);
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
}

/// @title DeclareReleaseHarness
/// @notice Runs the body of `DeclareRelease.declare` under an explicit owner and release tag.
/// @dev The script reads the owner from `msg.sender` and the tag from the environment; a fork test
///      passes both, and runs the same steps in the same order.
contract DeclareReleaseHarness is DeclareRelease {
    /// @notice Declares every key's codehash, verifies the deployment, then declares `releaseTag`.
    function declareAs(address owner, string memory releaseTag) external {
        initDeployment("paseo-assethub", vm.toString(block.chainid));
        Addresses memory addr = _loadAddresses();
        _requireKeysMatchManifest(addr);
        _wireMissingKeys(owner, addr);
        _declareCodeIdentity(owner, addr);
        _verifyDeployment(addr, owner);
        _declareProtocolVersion(owner, addr, releaseTag);
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

    function setUp() public override {
        super.setUp();
        registry = IDotnsProtocolRegistry(_live("DotnsProtocolRegistry"));
        owner = _ownerOf(address(registry));
    }

    /// @notice All six steps in order end on a verified 1.1.0 declaration, with the new duration,
    ///         every container recorded, and issuance working end to end.
    function test_campaign_ends_on_a_verified_release() public {
        address controller = _live("DotnsPopController");
        bytes32 tldNode = registry.tldNode();
        assertEq(registry.protocolVersion(), PREVIOUS_TAG, "starts on 1.0.0");

        new UpgradePopRulesHarness().upgrade(owner, _live("PopRules"));
        new UpgradePopControllerHarness().upgrade(owner, controller, _live("PopRules"));
        new UpgradeRegistrarControllerHarness().upgrade(owner, _live("DotnsRegistrarController"));
        new SetReservationDurationHarness().set(owner, controller);
        PrepareDeviceContainersHarness containers = new PrepareDeviceContainersHarness();
        containers.prepare(owner, controller, tldNode, 0, 99);
        new DeclareReleaseHarness().declareAs(owner, RELEASE_TAG);

        assertEq(registry.protocolVersion(), RELEASE_TAG, "declares 1.1.0");
        assertEq(
            IDotnsPopController(controller).reservationDuration(), 30 days, "30-day reservations"
        );
        for (uint256 number; number <= 99; ++number) {
            assertTrue(containers.recorded(controller, tldNode, number), "container recorded");
        }

        bytes32 personhoodNode = _issueLinkedPair(controller);
        (bool ok, bytes memory data) = _live("DotnsRegistry")
            .staticcall(abi.encodeWithSignature("owner(bytes32)", personhoodNode));
        assertTrue(ok, "registry readable");
        assertEq(abi.decode(data, (address)), popUser, "issuance works end to end");
    }

    /// @notice The settings steps are idempotent: a second run changes nothing.
    function test_settings_steps_rerun_as_no_ops() public {
        address controller = _live("DotnsPopController");
        bytes32 tldNode = registry.tldNode();
        new UpgradePopRulesHarness().upgrade(owner, _live("PopRules"));
        new UpgradePopControllerHarness().upgrade(owner, controller, _live("PopRules"));

        SetReservationDurationHarness duration = new SetReservationDurationHarness();
        duration.set(owner, controller);
        PrepareDeviceContainersHarness containers = new PrepareDeviceContainersHarness();
        containers.prepare(owner, controller, tldNode, 0, 9);

        vm.recordLogs();
        duration.set(owner, controller);
        containers.prepare(owner, controller, tldNode, 0, 9);
        assertEq(vm.getRecordedLogs().length, 0, "a rerun emits nothing");
    }
}
