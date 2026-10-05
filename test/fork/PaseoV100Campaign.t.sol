// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BasePopFork} from "./BasePopFork.t.sol";
import {UpgradeRegistryHarness} from "./UpgradeRegistry.t.sol";
import {UpgradePopRulesHarness} from "./UpgradePopRules.t.sol";
import {UpgradePopResolverAndControllerHarness} from "./UpgradePopResolverAndController.t.sol";
import {RedeployPopLensHarness} from "./RedeployPopLens.t.sol";
import {DeclareRelease} from "../../scripts/deploy/DeclareRelease.s.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {IDotnsPopLens} from "../../contracts/registrars/IDotnsPopLens.sol";

/// @title DeclareReleaseHarness
/// @notice Runs `DeclareRelease.declare` against the manifest with the lens the campaign deployed.
/// @dev On chain, the operator commits the manifest `RedeployPopLens` wrote before `DeclareRelease`
///      runs. A fork test must not write the manifest, so the harness substitutes the new lens in
///      the loaded addresses and runs the same steps in the same order.
contract DeclareReleaseHarness is DeclareRelease {
    /// @notice The body of `declare`, with `popLens` replaced by `lens`.
    function declareWithLens(address owner, address lens, string memory releaseTag) external {
        initDeployment("paseo-assethub", vm.toString(block.chainid));
        Addresses memory addr = _loadAddresses();
        addr.popLens = lens;

        _requireKeysMatchManifest(addr);
        _wireMissingKeys(owner, addr);
        _declareCodeIdentity(owner, addr);
        _verifyDeployment(addr, owner);
        _declareProtocolVersion(owner, addr, releaseTag);
    }
}

/// @title PaseoV100CampaignForkTest
/// @notice The whole v0.8.0 to v1.0.0 campaign on one fork, in broadcast order: registry, rules,
///         the PoP resolver and controller pair, the lens, then the release declaration.
/// @dev The rehearsal for the label-driven run. Each step's own fork test proves the step; this
///      proves the sequence, including that the release declaration verifies once every swap has
///      landed and that the network is consistent between the steps.
/// @custom:security-contact admin@parity.io
contract PaseoV100CampaignForkTest is BasePopFork {
    /// @notice Bare semver the campaign declares.
    string internal constant RELEASE_TAG = "1.0.0";

    /// @notice Owner of every proxy and of the protocol registry.
    address internal owner;

    /// @notice The protocol registry.
    IDotnsProtocolRegistry internal registry;

    function setUp() public override {
        super.setUp();
        registry = IDotnsProtocolRegistry(_live("DotnsProtocolRegistry"));
        owner = _ownerOf(address(registry));
    }

    /// @notice All five steps in order end on a verified 1.0.0 declaration.
    function test_campaign_ends_on_a_verified_release() public {
        assertEq(registry.protocolVersion(), "0.8.0", "starts on 0.8.0");

        new UpgradeRegistryHarness().upgrade(owner, _live("DotnsRegistry"));
        new UpgradePopRulesHarness().upgrade(owner, _live("PopRules"));
        new UpgradePopResolverAndControllerHarness()
            .upgrade(owner, _live("DotnsPopResolver"), _live("DotnsPopController"));
        address lens = new RedeployPopLensHarness()
            .redeploy(owner, address(registry), _live("DotnsPopLens"), RELEASE_TAG);

        new DeclareReleaseHarness().declareWithLens(owner, lens, RELEASE_TAG);

        assertEq(registry.protocolVersion(), RELEASE_TAG, "declares 1.0.0");

        bytes32 personhoodNode = _issueLinkedPair(_live("DotnsPopController"));
        assertEq(
            IDotnsPopLens(lens).nameDetail(DEVICE_LABEL).personhoodNode,
            personhoodNode,
            "issuance and lens work end to end"
        );
    }

    /// @notice A declaration run against a manifest that still names the outgoing lens stops
    ///         before it writes a codehash.
    function test_declaration_refuses_a_stale_manifest() public {
        address outgoing = _live("DotnsPopLens");
        new UpgradePopResolverAndControllerHarness()
            .upgrade(owner, _live("DotnsPopResolver"), _live("DotnsPopController"));
        new RedeployPopLensHarness().redeploy(owner, address(registry), outgoing, RELEASE_TAG);

        DeclareReleaseHarness declarer = new DeclareReleaseHarness();
        vm.expectRevert(bytes("DeclareRelease: key popLens points away from the manifest"));
        declarer.declareWithLens(owner, outgoing, RELEASE_TAG);
    }

    /// @notice After the first two steps alone, the v0.8.0 PoP controller still issues against the
    ///         upgraded registry and rules, so the pause between labels leaves a working network.
    function test_v080_controller_still_issues_after_registry_and_rules() public {
        new UpgradeRegistryHarness().upgrade(owner, _live("DotnsRegistry"));
        new UpgradePopRulesHarness().upgrade(owner, _live("PopRules"));

        bytes32 personhoodNode = _issueLinkedPair(_live("DotnsPopController"));
        (bool ok, bytes memory data) = _live("DotnsRegistry")
            .staticcall(abi.encodeWithSignature("owner(bytes32)", personhoodNode));
        assertTrue(ok, "registry readable");
        assertEq(abi.decode(data, (address)), popUser, "issued through the v0.8.0 controller");
    }
}
