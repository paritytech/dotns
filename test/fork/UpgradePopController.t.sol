// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {DotnsPopController} from "../../contracts/registrars/DotnsPopController.sol";
import {IDotnsPopController} from "../../contracts/registrars/IDotnsPopController.sol";
import {IDotnsRegistrar} from "../../contracts/registrars/IDotnsRegistrar.sol";
import {IDotnsController} from "../../contracts/registrars/IDotnsController.sol";
import {ISystem} from "../../contracts/external/revive/ISystem.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {UpgradePopController} from "../../scripts/deploy/UpgradePopController.s.sol";

/// @title UpgradePopControllerHarness
/// @notice Exposes the upgrade script's internal upgrade path so the fork test drives the exact
///         code the production run executes, including the fail-closed storage-layout diff.
/// @dev Mirrors the `DeterministicDeploymentHarness` pattern: forward to the script internal
///      rather than re-implement the upgrade, so the test tracks the production path one-to-one.
contract UpgradePopControllerHarness is UpgradePopController {
    /// @notice Upgrades `proxy` under `owner` through the script's `_upgradePopController`.
    function upgradePopController(address owner, address proxy) external {
        _upgradePopController(owner, proxy);
    }
}

/// @title UpgradePopControllerForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradePopController.s.sol`. Forks the live Paseo
///         Asset Hub through the ETH-RPC adapter, upgrades the deployed PoP controller proxy with
///         the script, and re-runs the controller's reservation path against real on-chain state to
///         prove the swap preserves ownership and queue state and keeps issuance working.
/// @dev PR-scoped: deleted before merge with the upgrade script and the `DotnsPopControllerOld`
///      snapshot. Requires the local adapter on `paseo_local`; between upgrade PRs `test/fork/` is
///      empty, so the suite is skipped by default with `--no-match-path 'test/fork/**'`.
///
///      The live siblings are not upgraded here, so the reservation path is exercised with
///      base-name (letters-only) labels, which the deployed `PopRules` classifies without change.
///      The dotted lite-person flow depends on a matching `PopRules` upgrade and is therefore out
/// of scope for a controller-only fork run.
/// @custom:security-contact admin@parity.io
contract UpgradePopControllerForkTest is Test {
    /// @notice Manifest recording the live deployment addresses this fork resolves against.
    string internal constant MANIFEST_PATH = "deployments/paseo-assethub/420420417.json";

    /// @notice Base label reserved to prove queue state survives the swap and stays writable.
    /// @dev Lowercase letters only and long enough to classify outside the governance-reserved
    ///      tier, so the reservation path accepts it as a base name.
    string internal constant BASE_LABEL = "zqxwvutsrq";

    /// @notice A never-issued label, used to prove the new `isPopIssued` surface answers false.
    string internal constant UNISSUED_LABEL = "neverissued";

    /// @notice A base label registered through the upgraded controller to prove `isPopIssued`
    ///         answers true once a label is genuinely issued.
    /// @dev Letters only and long enough to classify outside the governance-reserved tier, so the
    ///      deployed `PopRules` accepts it as a base name without change. The base path is used
    ///      rather than the dotted lite path because the live siblings are not upgraded here: the
    ///      live `PopRules` still rejects the lite separator, so a dotted lite mint reverts before
    ///      `_popIssued` is written. A base registration exercises the same issuance write through
    ///      the label form the live classifier already admits.
    string internal constant ISSUED_BASE_LABEL = "qzwxrvtsplk";

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradePopControllerHarness internal upgrader;

    /// @notice The deployed PoP controller proxy under upgrade.
    DotnsPopController internal popController;

    /// @notice The deployed registrar the controller reserves and mints against.
    IDotnsRegistrar internal registrar;

    /// @notice PoP controller proxy owner, impersonated to authorise the upgrade.
    address internal popControllerOwner;

    /// @notice Registrar owner, impersonated to authorise the controller on the registrar.
    address internal registrarOwner;

    /// @notice Beneficiary accounts for the reservation paths.
    address internal alice;
    address internal bob;

    /// @notice Forks Paseo, resolves the live addresses, authorises the controller, and mocks Root.
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("paseo_local"));

        string memory manifest = vm.readFile(MANIFEST_PATH);
        popController = DotnsPopController(vm.parseJsonAddress(manifest, ".DotnsPopController"));
        registrar = IDotnsRegistrar(vm.parseJsonAddress(manifest, ".DotnsRegistrar"));
        popControllerOwner = OwnableUpgradeable(address(popController)).owner();
        registrarOwner = OwnableUpgradeable(address(registrar)).owner();

        upgrader = new UpgradePopControllerHarness();

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Reserving on `PopRules` gates on the caller being a registrar-authorised controller.
        // Re-asserting the live PoP controller is a no-op when it is already registered and keeps
        // the test independent of the exact wiring state of the fork.
        vm.prank(registrarOwner);
        registrar.addController(IDotnsController(address(popController)));

        // Both the deployed and the upgraded implementation gate their entrypoints on
        // `ISystem.originIsRoot`. The precompile is not part of the fork state, so the origin is
        // mocked to Root for every reservation call, including the pre-upgrade seed below.
        vm.mockCall(
            DotnsConstants.REVIVE_SYSTEM,
            abi.encodeWithSelector(ISystem.originIsRoot.selector),
            abi.encode(true)
        );
    }

    /// @notice The upgrade preserves ownership, sibling wiring, and reservation state on the real
    ///         proxy, and exposes an `isPopIssued` surface that reports false for an unissued label
    ///         and true for a label the upgraded controller genuinely issues.
    function test_upgrade_preservesStateAndExposesNewSurface() public {
        // Seed a base-name reservation on the pre-upgrade implementation so its survival across the
        // implementation swap is observable. The deployed code path admits it under the mocked Root
        // origin.
        popController.reserveBaseNameOnly(
            IDotnsPopController.BaseNameReservation({user: bob, reservedBaseLabel: BASE_LABEL})
        );
        IDotnsPopController.UserReservation memory seeded = popController.userReservation(bob);
        assertTrue(seeded.labelhash != bytes32(0), "pre-upgrade: bob holds a reservation");

        address proxy = address(popController);
        address registryBefore = address(popController.protocolRegistry());
        uint64 durationBefore = popController.reservationDuration();

        upgrader.upgradePopController(popControllerOwner, proxy);

        assertEq(address(popController), proxy, "upgrade keeps the same proxy address");
        assertEq(
            address(popController.protocolRegistry()),
            registryBefore,
            "post-upgrade: protocol registry pointer preserved"
        );
        assertEq(
            popController.reservationDuration(),
            durationBefore,
            "post-upgrade: reservation duration preserved"
        );

        // The reservation queued before the upgrade is still live and still keyed to bob.
        IDotnsPopController.UserReservation memory kept = popController.userReservation(bob);
        assertEq(kept.labelhash, seeded.labelhash, "post-upgrade: reservation labelhash preserved");
        (bool reserved, address holder) = popController.isReservedForClaim(BASE_LABEL);
        assertTrue(reserved, "post-upgrade: reservation still live at the queue head");
        assertEq(holder, bob, "post-upgrade: reservation still held by bob");

        // The new surface is callable and reports the honest answer for a label never issued.
        assertFalse(
            popController.isPopIssued(UNISSUED_LABEL),
            "post-upgrade: an unissued label reports false"
        );

        // Drive a real issuance through the upgraded controller so a concrete label is genuinely
        // marked issued, then confirm the new surface reports it. The base registration runs under
        // the mocked Root origin with no chat key and no lite link, against a fresh beneficiary
        // with no store, so it exercises the real `_popIssued` write and stashes a pending claim
        // without touching the resolver or deploying a store.
        assertFalse(
            popController.isPopIssued(ISSUED_BASE_LABEL),
            "pre-issue: the base label is not yet issued"
        );
        popController.registerBaseName(
            IDotnsPopController.FullRegistration({
                label: ISSUED_BASE_LABEL,
                user: alice,
                link: IDotnsPopController.Link({
                    kind: IDotnsPopController.LinkKind.None, liteLabel: "", chatKey: ""
                })
            })
        );
        assertTrue(
            popController.isPopIssued(ISSUED_BASE_LABEL),
            "post-upgrade: a genuinely issued label reports true"
        );
    }

    /// @notice After the upgrade, the Root-gated base-name reservation path still mutates queue
    ///         state and syncs the reservation to the queue head.
    function test_upgrade_keepsBaseReservationWorkingUnderRoot() public {
        upgrader.upgradePopController(popControllerOwner, address(popController));

        // P0: a real reservation still writes queue state on the upgraded implementation under a
        // mocked Root origin, and syncs the head so the label reads back as reserved for alice.
        popController.reserveBaseNameOnly(
            IDotnsPopController.BaseNameReservation({user: alice, reservedBaseLabel: BASE_LABEL})
        );

        IDotnsPopController.UserReservation memory res = popController.userReservation(alice);
        assertTrue(res.labelhash != bytes32(0), "post-upgrade: alice holds a fresh reservation");
        (bool reserved, address holder) = popController.isReservedForClaim(BASE_LABEL);
        assertTrue(reserved, "post-upgrade: the fresh reservation is live at the queue head");
        assertEq(holder, alice, "post-upgrade: the fresh reservation is held by alice");
    }
}
