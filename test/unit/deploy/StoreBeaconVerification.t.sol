// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {WireDeployments} from "../../../scripts/deploy/WireDeployments.s.sol";
import {DotnsProtocolRegistry} from "../../../contracts/registry/DotnsProtocolRegistry.sol";
import {LabelStore} from "../../../contracts/store/LabelStore.sol";
import {StoreFactory} from "../../../contracts/store/StoreFactory.sol";

/// @notice Exposes the wire stage's beacon check on its own.
contract WireVerifyHarness is WireDeployments {
    function verifyStoreImplementations(
        address storeFactory,
        address protocolRegistry
    )
        external
        view
    {
        _verifyStoreImplementations(storeFactory, protocolRegistry);
    }
}

/// @notice A factory that owns its beacons, like the real one, but points them wherever it is
///         told. Isolates the implementation check from the ownership check.
contract ForeignImplFactory {
    address public labelStoreBeacon;
    address public userStoreBeacon;
    address public protocolRegistry;

    constructor(address labelImpl, address userImpl, address protocolRegistry_) {
        labelStoreBeacon = address(new UpgradeableBeacon(labelImpl, address(this)));
        userStoreBeacon = address(new UpgradeableBeacon(userImpl, address(this)));
        protocolRegistry = protocolRegistry_;
    }
}

/// @notice A factory pointing at beacons it does not own. Isolates the ownership check.
contract PrebuiltBeaconFactory {
    address public labelStoreBeacon;
    address public userStoreBeacon;
    address public protocolRegistry;

    constructor(address labelBeacon, address userBeacon, address protocolRegistry_) {
        labelStoreBeacon = labelBeacon;
        userStoreBeacon = userBeacon;
        protocolRegistry = protocolRegistry_;
    }
}

/// @notice A beacon that answers the verification views correctly and can change its mind
///         afterwards. Only the codehash pin catches this.
contract LyingBeacon {
    address private impl;
    address public owner;

    constructor(address implementation_, address owner_) {
        impl = implementation_;
        owner = owner_;
    }

    function implementation() external view returns (address) {
        return impl;
    }

    function setImplementation(address implementation_) external {
        impl = implementation_;
    }
}

/// @notice Store implementation that is not the artefact this release builds.
contract ForeignStore {
    function hello() external pure returns (uint256) {
        return 1;
    }
}

/// @title StoreBeaconVerificationTests
/// @notice Covers the one property the CREATE3 occupancy check cannot assert: which
///         implementations the store beacons point at, and who owns the beacons.
/// @dev `StoreFactory` is a UUPS proxy, and a proxy's runtime code says nothing about what its
///      initialiser wrote, so an occupant compared byte for byte matches on code alone. Everything
///      a squatter controls, the registry pointer and the beacons, lives in proxy storage and has
///      to be read back.
contract StoreBeaconVerificationTests is Test {
    WireVerifyHarness private wire;
    address private owner;
    address private registry;

    function setUp() public {
        wire = new WireVerifyHarness();
        owner = makeAddr("wire-owner");
        registry = address(new DotnsProtocolRegistry());
    }

    /// @notice An honestly deployed factory passes.
    function test_accepts_an_honestly_deployed_factory() public {
        StoreFactory factory = _honestFactory();
        wire.verifyStoreImplementations(address(factory), registry);
    }

    /// @notice Beacons pointing at implementations this release did not build are rejected.
    /// @dev The factory owns its beacons here, so ownership passes and the implementation
    ///      comparison is what fires. This is the attacker's actual position: everything else
    ///      about their factory can be made to look right.
    function test_rejects_foreign_store_implementations() public {
        ForeignImplFactory factory = new ForeignImplFactory(
            address(new ForeignStore()), address(new ForeignStore()), registry
        );

        vm.expectRevert(bytes("LabelStoreBeacon: unexpected implementation"));
        wire.verifyStoreImplementations(address(factory), registry);
    }

    /// @notice A correct label store with a foreign user store is still rejected, so the second
    ///         beacon is not left unchecked once the first passes.
    function test_rejects_a_foreign_user_store_alone() public {
        StoreFactory honest = _honestFactory();
        address realLabelImpl = UpgradeableBeacon(honest.labelStoreBeacon()).implementation();

        ForeignImplFactory factory =
            new ForeignImplFactory(realLabelImpl, address(new ForeignStore()), registry);

        vm.expectRevert(bytes("UserStoreBeacon: unexpected implementation"));
        wire.verifyStoreImplementations(address(factory), registry);
    }

    /// @notice A beacon the factory does not own is rejected: the verified factory owner could
    ///         never rotate the store implementations, and nothing else would show it.
    function test_rejects_a_beacon_the_factory_does_not_own() public {
        StoreFactory honest = _honestFactory();
        address realLabelImpl = UpgradeableBeacon(honest.labelStoreBeacon()).implementation();
        address realUserImpl = UpgradeableBeacon(honest.userStoreBeacon()).implementation();

        // Correct implementations, but the beacons answer to an outsider.
        address outsider = makeAddr("outsider");
        address labelBeacon = address(new UpgradeableBeacon(realLabelImpl, outsider));
        address userBeacon = address(new UpgradeableBeacon(realUserImpl, outsider));
        PrebuiltBeaconFactory factory = new PrebuiltBeaconFactory(labelBeacon, userBeacon, registry);

        vm.expectRevert(bytes("LabelStoreBeacon: not owned by the factory"));
        wire.verifyStoreImplementations(address(factory), registry);
    }

    /// @notice A beacon that is not `UpgradeableBeacon` is rejected even when it answers both
    ///         views exactly as the check wants.
    /// @dev Without pinning the beacon's own code, verification proves only what an address said
    ///      at verification time. This one reports the release's implementation and the factory
    ///      as owner, passes both semantic checks, and can be repointed immediately afterwards.
    function test_rejects_a_beacon_that_merely_answers_the_views() public {
        StoreFactory honest = _honestFactory();
        address realLabelImpl = UpgradeableBeacon(honest.labelStoreBeacon()).implementation();
        address realUserImpl = UpgradeableBeacon(honest.userStoreBeacon()).implementation();

        address factory = makeAddr("factory");
        address labelBeacon = address(new LyingBeacon(realLabelImpl, factory));
        address userBeacon = address(new LyingBeacon(realUserImpl, factory));
        vm.etch(factory, address(new PrebuiltBeaconFactory(labelBeacon, userBeacon, registry)).code);
        vm.store(factory, bytes32(uint256(0)), bytes32(uint256(uint160(labelBeacon))));
        vm.store(factory, bytes32(uint256(1)), bytes32(uint256(uint160(userBeacon))));
        // `vm.etch` copies code, not storage, so the registry pointer has to be planted too or
        // this fixture would trip the pointer check before reaching the beacon check under test.
        vm.store(factory, bytes32(uint256(2)), bytes32(uint256(uint160(registry))));

        vm.expectRevert(bytes("LabelStoreBeacon: unexpected beacon code"));
        wire.verifyStoreImplementations(factory, registry);
    }

    /// @notice A factory built from this release's artefacts but initialised against someone
    ///         else's registry is rejected.
    /// @dev Every beacon assertion still passes here: the factory really did mint its own beacons
    ///      off the real implementations. Only the pointer is wrong.
    function test_rejects_a_factory_initialised_against_a_foreign_registry() public {
        address foreignRegistry = address(new DotnsProtocolRegistry());
        StoreFactory squat = StoreFactory(
            address(
                new ERC1967Proxy(
                    address(new StoreFactory()),
                    abi.encodeCall(StoreFactory.initialize, (owner, foreignRegistry))
                )
            )
        );

        // The beacon topology is genuine, so nothing else in the check would object.
        assertEq(UpgradeableBeacon(squat.labelStoreBeacon()).owner(), address(squat));
        assertEq(UpgradeableBeacon(squat.userStoreBeacon()).owner(), address(squat));

        vm.expectRevert(bytes("StoreFactory: wrong protocol registry"));
        wire.verifyStoreImplementations(address(squat), registry);
    }

    /// @notice A real factory deployed the way the pipeline deploys it, behind its own UUPS proxy.
    function _honestFactory() private returns (StoreFactory factory) {
        factory = StoreFactory(
            address(
                new ERC1967Proxy(
                    address(new StoreFactory()),
                    abi.encodeCall(StoreFactory.initialize, (owner, registry))
                )
            )
        );
    }
}
