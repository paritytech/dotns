// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BasePopFork} from "./BasePopFork.t.sol";
import {UpgradePopResolverAndControllerHarness} from "./UpgradePopResolverAndController.t.sol";
import {RedeployPopLens} from "../../scripts/deploy/RedeployPopLens.s.sol";
import {IDotnsPopLens} from "../../contracts/registrars/IDotnsPopLens.sol";
import {IDotnsPopResolver} from "../../contracts/resolvers/IDotnsPopResolver.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";

/// @title RedeployPopLensHarness
/// @notice Exposes the script's internal path so the test drives the code the production run
///         executes.
/// @dev The script's `run` reads the network folder and writes the manifest, neither of which a
///      fork test should touch, so the harness enters below both.
contract RedeployPopLensHarness is RedeployPopLens {
    /// @notice Deploys and wires the lens under `owner` through the script's own internal.
    function redeploy(
        address owner,
        address protocolRegistry,
        address outgoing,
        string memory releaseTag
    )
        external
        returns (address lens)
    {
        lens = _redeployPopLens(owner, protocolRegistry, outgoing, releaseTag);
    }
}

/// @title RedeployPopLensForkTest
/// @notice Pairs one-to-one with `scripts/deploy/RedeployPopLens.s.sol`. Runs after the PoP
///         resolver and controller swap, as on chain, then redeploys the lens and proves the key,
///         the declaration and the reads it serves.
/// @dev Requires the local ETH-RPC adapter on `paseo_local`; see `DEPLOYMENTS.md`.
/// @custom:security-contact admin@parity.io
contract RedeployPopLensForkTest is BasePopFork {
    /// @notice Release tag the salt is scoped to.
    string internal constant RELEASE_TAG = "1.0.0";

    /// @notice The protocol registry holding the `popLens` key.
    IDotnsProtocolRegistry internal registry;

    /// @notice Lens the manifest records today.
    address internal outgoing;

    /// @notice Protocol registry owner, impersonated to authorise the rewire.
    address internal registryOwner;

    /// @notice Drives the script's redeploy path.
    RedeployPopLensHarness internal redeployer;

    function setUp() public override {
        super.setUp();
        registry = IDotnsProtocolRegistry(_live("DotnsProtocolRegistry"));
        outgoing = _live("DotnsPopLens");
        registryOwner = _ownerOf(address(registry));
        redeployer = new RedeployPopLensHarness();

        UpgradePopResolverAndControllerHarness pair = new UpgradePopResolverAndControllerHarness();
        address controller = _live("DotnsPopController");
        pair.upgrade(_ownerOf(controller), _live("DotnsPopResolver"), controller);
    }

    /// @notice The key moves to the new lens with a matching declaration, and the lens serves the
    ///         link the upgraded pair writes.
    function test_redeploy_rewires_declares_and_serves_links() public {
        assertEq(registry.get(DotnsConstants.POP_LENS), outgoing, "key starts on the outgoing lens");

        address lens = redeployer.redeploy(registryOwner, address(registry), outgoing, RELEASE_TAG);

        assertTrue(lens != outgoing, "a new lens");
        assertEq(registry.get(DotnsConstants.POP_LENS), lens, "key points at the new lens");
        assertEq(
            registry.expectedCodehash(DotnsConstants.POP_LENS),
            lens.codehash,
            "declaration matches the executing code"
        );
        assertEq(IDotnsPopLens(lens).protocolRegistry(), address(registry), "bound to the registry");

        bytes32 personhoodNode = _issueLinkedPair(_live("DotnsPopController"));
        IDotnsPopLens.NameDetail memory detail = IDotnsPopLens(lens).nameDetail(PERSONHOOD_LABEL);
        assertEq(detail.node, personhoodNode, "node");
        assertEq(detail.owner, popUser, "owner");
        assertEq(
            detail.deviceLabelhash,
            IDotnsPopResolver(_live("DotnsPopResolver")).deviceLabelhashOf(personhoodNode),
            "device link read through the lens"
        );

        IDotnsPopLens.NameDetail memory device = IDotnsPopLens(lens).nameDetail(DEVICE_LABEL);
        assertEq(device.personhoodNode, personhoodNode, "personhood link read through the lens");
    }

    /// @notice A second run adopts the lens the first one deployed and broadcasts nothing new.
    function test_rerun_adopts_the_deployed_lens() public {
        address first = redeployer.redeploy(registryOwner, address(registry), outgoing, RELEASE_TAG);
        address second =
            redeployer.redeploy(registryOwner, address(registry), outgoing, RELEASE_TAG);

        assertEq(second, first, "same lens");
        assertEq(registry.get(DotnsConstants.POP_LENS), first, "key unchanged");
    }

    /// @notice A key pointing somewhere unexpected stops the run before it broadcasts.
    function test_refuses_a_key_the_manifest_does_not_describe() public {
        vm.expectRevert(
            bytes(
                "RedeployPopLens: popLens key matches neither the manifest nor this release's lens"
            )
        );
        redeployer.redeploy(registryOwner, address(registry), makeAddr("elsewhere"), RELEASE_TAG);
    }
}
