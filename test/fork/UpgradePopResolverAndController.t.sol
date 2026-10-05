// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BasePopFork} from "./BasePopFork.t.sol";
import {
    UpgradePopResolverAndController
} from "../../scripts/deploy/UpgradePopResolverAndController.s.sol";
import {IDotnsPopController} from "../../contracts/registrars/IDotnsPopController.sol";
import {IDotnsPopResolver} from "../../contracts/resolvers/IDotnsPopResolver.sol";
import {IDotnsRegistry} from "../../contracts/registry/IDotnsRegistry.sol";

/// @title UpgradePopResolverAndControllerHarness
/// @notice Exposes the upgrade script's internal path so the test drives the code the production
///         run executes, including both fail-closed storage-layout diffs.
contract UpgradePopResolverAndControllerHarness is UpgradePopResolverAndController {
    /// @notice Upgrades both proxies under `owner` through the script's own internal.
    function upgrade(address owner, address resolver, address controller) external {
        _upgradeResolverAndController(owner, resolver, controller);
    }

    /// @notice Upgrades the resolver alone, leaving the state a run that died between its two
    ///         transactions leaves behind.
    function upgradeResolverOnly(address owner, address resolver) external {
        vm.startBroadcast(owner);
        Upgrades.upgradeProxy(resolver, RESOLVER_ARTEFACT, "", _resolverOptions());
        vm.stopBroadcast();
    }
}

/// @title UpgradePopResolverAndControllerForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradePopResolverAndController.s.sol`. Upgrades
///         the deployed PoP resolver and controller and proves they work as a pair: reservation
///         state survives, and a linked personhood issuance through the gateway's legacy
///         entrypoints writes the link in both directions.
/// @dev Requires the local ETH-RPC adapter on `paseo_local`; see `DEPLOYMENTS.md`. Run the suite
///      with `bun run test:fork`, which also checks every snapshot against the deployed bytecode
///      before the first test runs.
/// @custom:security-contact admin@parity.io
contract UpgradePopResolverAndControllerForkTest is BasePopFork {
    /// @notice The deployed PoP resolver proxy.
    address internal resolver;

    /// @notice The deployed PoP controller proxy.
    address internal controller;

    /// @notice Owner of both proxies, impersonated to authorise the upgrades.
    address internal proxyOwner;

    /// @notice Drives the script's upgrade path against the live proxies.
    UpgradePopResolverAndControllerHarness internal upgrader;

    function setUp() public override {
        super.setUp();
        resolver = _live("DotnsPopResolver");
        controller = _live("DotnsPopController");
        proxyOwner = _ownerOf(controller);
        assertEq(_ownerOf(resolver), proxyOwner, "one owner for both proxies");
        upgrader = new UpgradePopResolverAndControllerHarness();
    }

    /// @notice Both implementations change, controller state survives, and a linked issuance
    ///         round-trips through the new resolver.
    function test_upgrade_swaps_both_and_links_round_trip() public {
        uint256 pendingUsersBefore = IDotnsPopController(controller).pendingClaimUserCount();
        uint64 durationBefore = IDotnsPopController(controller).reservationDuration();
        address resolverImplementationBefore = _implementationOf(resolver);
        address controllerImplementationBefore = _implementationOf(controller);

        upgrader.upgrade(proxyOwner, resolver, controller);

        assertTrue(
            _implementationOf(resolver) != resolverImplementationBefore,
            "the resolver implementation actually changed"
        );
        assertTrue(
            _implementationOf(controller) != controllerImplementationBefore,
            "the controller implementation actually changed"
        );
        assertEq(
            IDotnsPopController(controller).pendingClaimUserCount(),
            pendingUsersBefore,
            "pending claim users preserved"
        );
        assertEq(
            IDotnsPopController(controller).reservationDuration(),
            durationBefore,
            "reservation window preserved"
        );

        _assertLinkedIssuance();
    }

    /// @notice A run that died between its two transactions is finished by running it again.
    function test_rerun_completes_a_resolver_only_upgrade() public {
        upgrader.upgradeResolverOnly(proxyOwner, resolver);
        address resolverImplementation = _implementationOf(resolver);
        address controllerImplementationBefore = _implementationOf(controller);

        upgrader.upgrade(proxyOwner, resolver, controller);

        assertEq(
            _implementationOf(resolver),
            resolverImplementation,
            "the already-upgraded resolver is left alone"
        );
        assertTrue(
            _implementationOf(controller) != controllerImplementationBefore,
            "the controller is upgraded"
        );
        _assertLinkedIssuance();
    }

    /// @notice A second run after a complete one broadcasts nothing.
    function test_rerun_after_completion_is_a_no_op() public {
        upgrader.upgrade(proxyOwner, resolver, controller);
        address resolverImplementation = _implementationOf(resolver);
        address controllerImplementation = _implementationOf(controller);

        upgrader.upgrade(proxyOwner, resolver, controller);

        assertEq(_implementationOf(resolver), resolverImplementation, "resolver untouched");
        assertEq(_implementationOf(controller), controllerImplementation, "controller untouched");
    }

    /// @notice Issues the linked pair and checks ownership and both link directions.
    function _assertLinkedIssuance() internal {
        bytes32 personhoodNode = _issueLinkedPair(controller);

        IDotnsRegistry registry = IDotnsRegistry(_live("DotnsRegistry"));
        assertEq(registry.owner(personhoodNode), popUser, "personhood name issued to the user");

        IDotnsPopResolver popResolver = IDotnsPopResolver(resolver);
        bytes32 deviceLabelhash = popResolver.deviceLabelhashOf(personhoodNode);
        assertTrue(deviceLabelhash != bytes32(0), "device link written");
        assertEq(
            popResolver.personhoodNodeOf(deviceLabelhash),
            personhoodNode,
            "personhood link written in lockstep"
        );
        assertEq(popResolver.chatKey(personhoodNode), _chatKey(), "chat key inherited");
    }
}
