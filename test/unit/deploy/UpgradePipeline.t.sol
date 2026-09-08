// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {UpgradePipelineHarness} from "./UpgradePipelineHarness.t.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {DotnsProtocolRegistry} from "../../../contracts/registry/DotnsProtocolRegistry.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsReverseResolver} from "../../../contracts/resolvers/DotnsReverseResolver.sol";
import {LabelStore} from "../../../contracts/store/LabelStore.sol";
import {UpgradeVerifyHarness} from "./UpgradeVerifyHarness.t.sol";

/// @title UpgradePipelineTest
/// @notice Covers the decisions the in-place upgrade pipeline makes: what it skips, what it
///         treats as already current, and how it reads a proxy's implementation.
/// @dev The upgrade path is the one place where doing nothing and doing the wrong thing look
///      alike from outside: a re-run that silently rotates every store, or a skip that quietly
///      leaves a contract behind, both end with a green log. These assert the branch taken, not
///      just the absence of a revert.
contract UpgradePipelineTest is Test {
    UpgradePipelineHarness private harness;
    DotnsProtocolRegistry private registry;
    address private owner;

    function setUp() public {
        harness = new UpgradePipelineHarness();
        owner = address(this);

        DotnsProtocolRegistry implementation = new DotnsProtocolRegistry();
        registry = DotnsProtocolRegistry(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(DotnsProtocolRegistry.initialize, ("testnet"))
                )
            )
        );
    }

    /// @notice A registry key the deployment does not hold is skipped, not treated as an error.
    /// @dev This is what lets a stage run against a deployment predating a contract's
    ///      introduction. A revert here would make the pipeline unusable on older networks.
    function test_skipsAnUnregisteredKey() public {
        harness.upgradeProxy(
            owner,
            address(registry),
            DotnsConstants.POP_LENS,
            "DotnsReverseResolver.sol:DotnsReverseResolver",
            "DotnsReverseResolver",
            bytes("")
        );

        assertEq(harness.upgradedCount(), 0, "an unregistered key was counted as upgraded");
        assertEq(harness.unchangedCount(), 0, "an unregistered key was counted as unchanged");
    }

    /// @notice A proxy already running the target bytecode is reported unchanged and not swapped.
    /// @dev Without this a re-run would deploy and install a fresh copy of identical code on
    ///      every contract, which is what makes "re-running is safe" true rather than merely
    ///      harmless.
    function test_reportsUnchangedWhenBytecodeMatches() public {
        address proxy = _deployReverseResolverProxy();
        vm.prank(owner);
        registry.set(DotnsConstants.REVERSE_RESOLVER, proxy);

        address before = harness.implementationOf(proxy);

        harness.upgradeProxy(
            owner,
            address(registry),
            DotnsConstants.REVERSE_RESOLVER,
            "DotnsReverseResolver.sol:DotnsReverseResolver",
            "DotnsReverseResolver",
            bytes("")
        );

        assertEq(harness.unchangedCount(), 1, "identical bytecode was not detected");
        assertEq(harness.upgradedCount(), 0, "identical bytecode was swapped anyway");
        assertEq(harness.implementationOf(proxy), before, "implementation moved on a no-op run");
    }

    /// @notice `_implementationOf` reads the EIP-1967 slot, and answers zero for a plain contract.
    /// @dev The verifier relies on the zero answer to tell a proxy from a non-proxy, so a
    ///      non-proxy must not be mistaken for a proxy pointing at nothing.
    function test_readsTheImplementationSlot() public {
        address proxy = _deployReverseResolverProxy();
        assertTrue(harness.implementationOf(proxy) != address(0), "proxy read back no slot");
        assertEq(
            harness.implementationOf(address(new LabelStore())),
            address(0),
            "non-proxy read back a slot"
        );
    }

    /// @notice A beacon already running the target bytecode needs no rotation.
    /// @dev `UpgradeableBeacon.upgradeTo` accepts an address whose code is identical, so the
    ///      codehash check is the only thing stopping a re-run from rotating every store on the
    ///      network to a fresh copy of the code it already ran.
    function test_beaconRotationSkippedWhenBytecodeMatches() public {
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(new LabelStore()), owner);

        address rotation = harness.prepareBeaconRotation(
            owner, address(beacon), "LabelStore.sol:LabelStore", "LabelStore"
        );

        assertEq(rotation, address(0), "identical beacon bytecode asked for a rotation");
        assertEq(harness.unchangedCount(), 1, "beacon skip was not counted");
    }

    /// @notice A beacon running different code is given a freshly deployed implementation.
    function test_beaconRotationProposedWhenBytecodeDiffers() public {
        // Any contract whose code differs from LabelStore stands in for an older implementation.
        UpgradeableBeacon beacon =
            new UpgradeableBeacon(address(new DotnsProtocolRegistry()), owner);

        address rotation = harness.prepareBeaconRotation(
            owner, address(beacon), "LabelStore.sol:LabelStore", "LabelStore"
        );

        assertTrue(rotation != address(0), "differing beacon bytecode was treated as current");
        assertTrue(rotation.code.length != 0, "proposed implementation has no code");
        assertEq(harness.upgradedCount(), 1, "beacon rotation was not counted");
    }

    /// @notice `_basename` yields the build-info directory's short name, which is how
    /// OpenZeppelin identifies a layout reference.
    function test_basenameNamesTheReferenceDirectory() public view {
        assertEq(harness.basename("previous-builds/build-info-v1"), "build-info-v1");
        assertEq(harness.basename("build-info-v1"), "build-info-v1");
        assertEq(harness.basename("previous-builds/build-info-v1/"), "build-info-v1");
    }

    /// @notice The swap actually lands: a proxy whose code differs points at the new
    ///         implementation afterwards. Asserted on the EIP-1967 slot rather than on the log
    ///         line, which would read the same whether or not the call took effect.
    /// @dev Upgrading to a different contract is the only way to get genuinely differing code:
    ///      two builds of one artefact are now equal under the immutable-masked comparison, which
    ///      is what `test_reportsUnchangedWhenBytecodeMatches` covers.
    function test_upgradesTheProxyWhenCodeDiffers() public {
        address proxy = _deployReverseResolverProxy();
        vm.prank(owner);
        registry.set(DotnsConstants.REVERSE_RESOLVER, proxy);

        address before = harness.implementationOf(proxy);

        harness.upgradeProxy(
            owner,
            address(registry),
            DotnsConstants.REVERSE_RESOLVER,
            "DotnsProtocolRegistry.sol:DotnsProtocolRegistry",
            "DotnsProtocolRegistry",
            bytes("")
        );

        address current = harness.implementationOf(proxy);
        assertEq(harness.upgradedCount(), 1, "a differing implementation was not upgraded");
        assertEq(harness.unchangedCount(), 0, "a differing implementation was reported unchanged");
        assertTrue(current != before, "the implementation slot did not move");
        assertTrue(current.code.length != 0, "the new implementation has no code");
    }

    /// @notice A beacon rotation applied end to end: the address `_prepareBeaconRotation` hands
    ///         back is one `upgradeTo` accepts, and every store behind the beacon follows it.
    function test_beaconRotationAppliesToTheBeacon() public {
        address labelStore = harness.deployImplementation("LabelStore.sol:LabelStore");
        UpgradeableBeacon beacon = new UpgradeableBeacon(labelStore, owner);

        address rotated = harness.prepareBeaconRotation(
            owner, address(beacon), "UserStore.sol:UserStore", "UserStore"
        );
        assertTrue(rotated != address(0), "differing store code proposed no rotation");

        vm.prank(owner);
        beacon.upgradeTo(rotated);

        assertEq(beacon.implementation(), rotated, "the beacon did not follow the rotation");
        assertTrue(rotated.code.length != 0, "the rotated implementation has no code");
    }

    /// @notice `_present` fails on an owner that drifted. This is the check that stops a
    ///         deployment whose next upgrade would be impossible from passing verification.
    function test_verifyRejectsAnOwnerThatDrifted() public {
        address proxy = _deployReverseResolverProxy();
        vm.prank(owner);
        registry.set(DotnsConstants.REVERSE_RESOLVER, proxy);

        UpgradeVerifyHarness verify = new UpgradeVerifyHarness();

        verify.present(
            IDotnsProtocolRegistry(address(registry)),
            DotnsConstants.REVERSE_RESOLVER,
            "reverseResolver",
            owner,
            false
        );

        vm.expectRevert(bytes("wrong owner: reverseResolver"));
        verify.present(
            IDotnsProtocolRegistry(address(registry)),
            DotnsConstants.REVERSE_RESOLVER,
            "reverseResolver",
            address(0xBAD),
            false
        );
    }

    /// @notice `_verifyStoreBeacons` fails when a beacon points at an address with no code: the
    ///         beacon still answers, while every store behind it is bricked.
    function test_verifyRejectsABeaconPointingAtEmptyCode() public {
        address labelStore = harness.deployImplementation("LabelStore.sol:LabelStore");
        UpgradeableBeacon labelBeacon = new UpgradeableBeacon(labelStore, owner);
        UpgradeableBeacon userBeacon = new UpgradeableBeacon(labelStore, owner);

        StoreFactoryStub factory = new StoreFactoryStub(address(labelBeacon), address(userBeacon));
        vm.prank(owner);
        registry.set(DotnsConstants.STORE_FACTORY, address(factory));

        UpgradeVerifyHarness verify = new UpgradeVerifyHarness();
        verify.verifyStoreBeacons(IDotnsProtocolRegistry(address(registry)));

        factory.setUserStoreBeacon(address(new EmptyBeacon()));
        vm.expectRevert(bytes("userStoreBeacon: implementation has no code"));
        verify.verifyStoreBeacons(IDotnsProtocolRegistry(address(registry)));
    }

    /// @notice `_verifyRegistrySelf` covers the one entry that cannot be looked up through the
    ///         registry, so an owner drift there would otherwise go unchecked.
    function test_verifyRejectsARegistryOwnerThatDrifted() public {
        UpgradeVerifyHarness verify = new UpgradeVerifyHarness();

        verify.verifyRegistrySelf(address(registry), owner);

        vm.expectRevert(bytes("wrong owner: protocolRegistry"));
        verify.verifyRegistrySelf(address(registry), address(0xBAD));
    }

    /// @notice `_verifyControllers` fails when the registrar stops authorising a minting
    ///         controller. Registration is registry-independent state, so every address can still
    ///         resolve while no name can be minted.
    function test_verifyRejectsAnUnauthorisedController() public {
        RegistrarStub registrar = new RegistrarStub();
        address controller = address(0xC0);
        address popController = address(0xC1);

        vm.startPrank(owner);
        registry.set(DotnsConstants.REGISTRAR, address(registrar));
        registry.set(DotnsConstants.CONTROLLER, controller);
        registry.set(DotnsConstants.POP_CONTROLLER, popController);
        vm.stopPrank();

        registrar.authorise(controller, true);
        registrar.authorise(popController, true);

        UpgradeVerifyHarness verify = new UpgradeVerifyHarness();
        verify.verifyControllers(IDotnsProtocolRegistry(address(registry)));

        registrar.authorise(popController, false);
        vm.expectRevert(bytes("registrar: popController not authorised"));
        verify.verifyControllers(IDotnsProtocolRegistry(address(registry)));
    }

    /// @notice A reverse resolver proxy over a baseline implementation.
    /// @dev The baseline is deployed the way the script deploys one, from the artefact, so a
    ///      comparison against it exercises the path the pipeline actually takes.
    function _deployReverseResolverProxy() private returns (address proxy) {
        DotnsReverseResolver implementation = DotnsReverseResolver(
            harness.deployImplementation("DotnsReverseResolver.sol:DotnsReverseResolver")
        );
        proxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(
                    DotnsReverseResolver.initialize, (IDotnsProtocolRegistry(address(registry)))
                )
            )
        );
    }
}

/// @notice Minimal `IStoreFactory` surface `_verifyStoreBeacons` reads, with a settable user
///         store beacon so the failing branch can be reached.
contract StoreFactoryStub {
    address public labelStoreBeacon;
    address public userStoreBeacon;

    constructor(address labelBeacon, address userBeacon) {
        labelStoreBeacon = labelBeacon;
        userStoreBeacon = userBeacon;
    }

    function setUserStoreBeacon(address beacon) external {
        userStoreBeacon = beacon;
    }
}

/// @notice A beacon that answers with an address holding no code.
contract EmptyBeacon {
    function implementation() external pure returns (address) {
        return address(0xDEAD);
    }
}

/// @notice Minimal registrar surface `_verifyControllers` reads. `IDotnsController` encodes as
///         `address`, so this matches the real selector.
contract RegistrarStub {
    mapping(address => bool) public controllers;

    function authorise(address controller, bool allowed) external {
        controllers[controller] = allowed;
    }
}
