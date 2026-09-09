// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {WireDeployments} from "../../../scripts/deploy/WireDeployments.s.sol";
import {DotnsProtocolRegistry} from "../../../contracts/registry/DotnsProtocolRegistry.sol";
import {LabelStore} from "../../../contracts/store/LabelStore.sol";
import {StoreFactory} from "../../../contracts/store/StoreFactory.sol";

/// @notice Exposes the wire stage's beacon check on its own.
contract WireVerifyHarness is WireDeployments {
    function verifyStoreImplementations(address storeFactory) external view {
        _verifyStoreImplementations(storeFactory);
    }
}

/// @notice A factory that owns its beacons, like the real one, but points them wherever it is
///         told. Isolates the implementation check from the ownership check.
contract ForeignImplFactory {
    address public labelStoreBeacon;
    address public userStoreBeacon;

    constructor(address labelImpl, address userImpl) {
        labelStoreBeacon = address(new UpgradeableBeacon(labelImpl, address(this)));
        userStoreBeacon = address(new UpgradeableBeacon(userImpl, address(this)));
    }
}

/// @notice A factory pointing at beacons it does not own. Isolates the ownership check.
contract PrebuiltBeaconFactory {
    address public labelStoreBeacon;
    address public userStoreBeacon;

    constructor(address labelBeacon, address userBeacon) {
        labelStoreBeacon = labelBeacon;
        userStoreBeacon = userBeacon;
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
/// @dev `StoreFactory` deploys its own beacons, so their addresses are immutables that differ on
///      every honest deploy and are skipped when an occupant is compared byte for byte. An
///      attacker adopting the factory address uses the real artefact and the real, public
///      constructor arguments, so the beacons are the only thing left under their control.
contract StoreBeaconVerificationTests is Test {
    WireVerifyHarness private wire;
    address private owner;

    function setUp() public {
        wire = new WireVerifyHarness();
        owner = makeAddr("wire-owner");
    }

    /// @notice An honestly deployed factory passes.
    function test_acceptsAnHonestlyDeployedFactory() public {
        StoreFactory factory = new StoreFactory(address(_registry()), owner);
        wire.verifyStoreImplementations(address(factory));
    }

    /// @notice Beacons pointing at implementations this release did not build are rejected.
    /// @dev The factory owns its beacons here, so ownership passes and the implementation
    ///      comparison is what fires. This is the attacker's actual position: everything else
    ///      about their factory can be made to look right.
    function test_rejectsForeignStoreImplementations() public {
        ForeignImplFactory factory =
            new ForeignImplFactory(address(new ForeignStore()), address(new ForeignStore()));

        vm.expectRevert(bytes("LabelStoreBeacon: unexpected implementation"));
        wire.verifyStoreImplementations(address(factory));
    }

    /// @notice A correct label store with a foreign user store is still rejected, so the second
    ///         beacon is not left unchecked once the first passes.
    function test_rejectsAForeignUserStoreAlone() public {
        StoreFactory honest = new StoreFactory(address(_registry()), owner);
        address realLabelImpl = UpgradeableBeacon(honest.labelStoreBeacon()).implementation();

        ForeignImplFactory factory =
            new ForeignImplFactory(realLabelImpl, address(new ForeignStore()));

        vm.expectRevert(bytes("UserStoreBeacon: unexpected implementation"));
        wire.verifyStoreImplementations(address(factory));
    }

    /// @notice A beacon the factory does not own is rejected: the verified factory owner could
    ///         never rotate the store implementations, and nothing else would show it.
    function test_rejectsABeaconTheFactoryDoesNotOwn() public {
        StoreFactory honest = new StoreFactory(address(_registry()), owner);
        address realLabelImpl = UpgradeableBeacon(honest.labelStoreBeacon()).implementation();
        address realUserImpl = UpgradeableBeacon(honest.userStoreBeacon()).implementation();

        // Correct implementations, but the beacons answer to an outsider.
        address outsider = makeAddr("outsider");
        address labelBeacon = address(new UpgradeableBeacon(realLabelImpl, outsider));
        address userBeacon = address(new UpgradeableBeacon(realUserImpl, outsider));
        PrebuiltBeaconFactory factory = new PrebuiltBeaconFactory(labelBeacon, userBeacon);

        vm.expectRevert(bytes("LabelStoreBeacon: not owned by the factory"));
        wire.verifyStoreImplementations(address(factory));
    }

    /// @notice A beacon that is not `UpgradeableBeacon` is rejected even when it answers both
    ///         views exactly as the check wants.
    /// @dev Without pinning the beacon's own code, verification proves only what an address said
    ///      at verification time. This one reports the release's implementation and the factory
    ///      as owner, passes both semantic checks, and can be repointed immediately afterwards.
    function test_rejectsABeaconThatMerelyAnswersTheViews() public {
        StoreFactory honest = new StoreFactory(address(_registry()), owner);
        address realLabelImpl = UpgradeableBeacon(honest.labelStoreBeacon()).implementation();
        address realUserImpl = UpgradeableBeacon(honest.userStoreBeacon()).implementation();

        address factory = makeAddr("factory");
        address labelBeacon = address(new LyingBeacon(realLabelImpl, factory));
        address userBeacon = address(new LyingBeacon(realUserImpl, factory));
        vm.etch(factory, address(new PrebuiltBeaconFactory(labelBeacon, userBeacon)).code);
        vm.store(factory, bytes32(uint256(0)), bytes32(uint256(uint160(labelBeacon))));
        vm.store(factory, bytes32(uint256(1)), bytes32(uint256(uint160(userBeacon))));

        vm.expectRevert(bytes("LabelStoreBeacon: unexpected beacon code"));
        wire.verifyStoreImplementations(factory);
    }

    function _registry() private returns (DotnsProtocolRegistry registry) {
        registry = new DotnsProtocolRegistry();
    }
}
