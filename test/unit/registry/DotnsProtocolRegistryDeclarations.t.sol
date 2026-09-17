// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {DotnsProtocolRegistry} from "../../../contracts/registry/DotnsProtocolRegistry.sol";
import {UserStore} from "../../../contracts/store/UserStore.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title DotnsProtocolRegistryDeclarationTests
/// @notice Coverage for the registry's release declarations: the network-level
///         `protocolVersion` and the per-key `expectedCodehash`. Both are written by the deploy
///         and upgrade tooling and read by consumers, so the tests pin the owner gating, the
///         narrow input validation, the undeclared defaults, and survival across an
///         implementation upgrade.
contract DotnsProtocolRegistryDeclarationTests is BaseDotns {
    bytes32 private constant UNREGISTERED_KEY = bytes32("test.key.unregistered");

    IDotnsProtocolRegistry private registry;

    function setUp() public override {
        super.setUp();
        registry = IDotnsProtocolRegistry(address(protocolRegistry));
    }

    /// @notice A deployment that never declared a version reports the empty string, the value
    ///         consumers treat as "predates the scheme".
    function test_protocol_version_is_empty_until_declared() public view {
        assertEq(registry.protocolVersion(), "");
    }

    /// @notice A declared version round-trips and announces itself.
    function test_set_protocol_version_round_trips_and_emits() public {
        vm.expectEmit(false, false, false, true, address(registry));
        emit IDotnsProtocolRegistry.ProtocolVersionSet("0.8.0");

        vm.prank(owner);
        registry.setProtocolVersion("0.8.0");

        assertEq(registry.protocolVersion(), "0.8.0");
    }

    /// @notice Redeclaring overwrites: the value tracks the latest fully applied release, not
    ///         the first.
    function test_redeclaring_protocol_version_overwrites() public {
        vm.startPrank(owner);
        registry.setProtocolVersion("0.8.0");
        registry.setProtocolVersion("0.9.0");
        vm.stopPrank();

        assertEq(registry.protocolVersion(), "0.9.0");
    }

    /// @notice Declaring the version is owner-gated, like every registry write.
    function test_set_protocol_version_is_owner_only() public {
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ed));
        registry.setProtocolVersion("0.8.0");

        assertEq(registry.protocolVersion(), "", "a rejected declaration still landed");
    }

    /// @notice The empty string cannot be declared; clearing is not a supported operation and
    ///         an accidental empty write must not masquerade as "predates the scheme".
    function test_set_protocol_version_rejects_empty() public {
        vm.prank(owner);
        vm.expectRevert(IDotnsProtocolRegistry.InvalidProtocolVersion.selector);
        registry.setProtocolVersion("");
    }

    /// @notice A tag with the leading `v` is rejected: consumers parse the value as bare
    ///         semver, and this is the one operator mistake worth catching on chain.
    function test_set_protocol_version_rejects_v_prefix() public {
        vm.prank(owner);
        vm.expectRevert(IDotnsProtocolRegistry.InvalidProtocolVersion.selector);
        registry.setProtocolVersion("v0.8.0");
    }

    /// @notice Build metadata is rejected: consumers compare declared versions, and semver
    ///         defines `+...` as excluded from precedence, so it must never reach storage.
    function test_set_protocol_version_rejects_build_metadata() public {
        vm.prank(owner);
        vm.expectRevert(IDotnsProtocolRegistry.InvalidProtocolVersion.selector);
        registry.setProtocolVersion("0.8.0+paseo");
    }

    /// @notice Pre-release identifiers are accepted: deploys run from pre-release tags, so the
    ///         declared value can legitimately be one.
    function test_set_protocol_version_accepts_prerelease_identifiers() public {
        vm.prank(owner);
        registry.setProtocolVersion("0.8.0-rc.1");

        assertEq(registry.protocolVersion(), "0.8.0-rc.1");
    }

    /// @notice The registry can register itself and carry a declared codehash, the sloppy-drift
    ///         signal for a registry-implementation upgrade. The fixture leaves the key unset so
    ///         it still models a network that predates self-registration.
    function test_protocol_registry_can_declare_its_own_codehash() public {
        bytes32 declared = address(protocolRegistry).codehash;

        vm.startPrank(owner);
        registry.set(DotnsConstants.PROTOCOL_REGISTRY, address(protocolRegistry));
        registry.setExpectedCodehash(DotnsConstants.PROTOCOL_REGISTRY, declared);
        vm.stopPrank();

        assertEq(registry.get(DotnsConstants.PROTOCOL_REGISTRY), address(protocolRegistry));
        assertEq(registry.expectedCodehash(DotnsConstants.PROTOCOL_REGISTRY), declared);
    }

    /// @notice An undeclared key reports the zero hash.
    function test_expected_codehash_is_zero_until_declared() public view {
        assertEq(registry.expectedCodehash(DotnsConstants.REGISTRAR), bytes32(0));
    }

    /// @notice A declared codehash round-trips and announces itself.
    function test_set_expected_codehash_round_trips_and_emits() public {
        bytes32 declared = address(dotnsRegistrar).codehash;

        vm.expectEmit(true, false, false, true, address(registry));
        emit IDotnsProtocolRegistry.ExpectedCodehashSet(DotnsConstants.REGISTRAR, declared);

        vm.prank(owner);
        registry.setExpectedCodehash(DotnsConstants.REGISTRAR, declared);

        assertEq(registry.expectedCodehash(DotnsConstants.REGISTRAR), declared);
    }

    /// @notice Declaring a codehash is owner-gated.
    function test_set_expected_codehash_is_owner_only() public {
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ed));
        registry.setExpectedCodehash(DotnsConstants.REGISTRAR, bytes32(uint256(1)));

        assertEq(
            registry.expectedCodehash(DotnsConstants.REGISTRAR),
            bytes32(0),
            "a rejected declaration still landed"
        );
    }

    /// @notice A codehash can only be declared for a key that currently resolves, so a typo'd
    ///         key cannot hold a claim nothing points at.
    function test_set_expected_codehash_requires_registered_key() public {
        vm.prank(owner);
        vm.expectRevert(IDotnsProtocolRegistry.KeyNotRegistered.selector);
        registry.setExpectedCodehash(UNREGISTERED_KEY, bytes32(uint256(1)));
    }

    /// @notice The zero hash is an explicit reset back to "undeclared".
    function test_zero_codehash_resets_the_declaration() public {
        vm.startPrank(owner);
        registry.setExpectedCodehash(DotnsConstants.REGISTRAR, bytes32(uint256(1)));
        registry.setExpectedCodehash(DotnsConstants.REGISTRAR, bytes32(0));
        vm.stopPrank();

        assertEq(registry.expectedCodehash(DotnsConstants.REGISTRAR), bytes32(0));
    }

    /// @notice Removing a key clears its declaration, so a later re-registration under the same
    ///         key never starts out with a stale claim.
    function test_remove_clears_the_declared_codehash() public {
        vm.startPrank(owner);
        registry.setExpectedCodehash(DotnsConstants.REGISTRAR, bytes32(uint256(1)));
        registry.remove(DotnsConstants.REGISTRAR);
        vm.stopPrank();

        assertEq(registry.expectedCodehash(DotnsConstants.REGISTRAR), bytes32(0));
    }

    /// @notice `version()` on every DotNS contract mirrors the registry's declared release, so
    ///         the whole network answers with one synchronised value: empty before the first
    ///         declaration, the declared tag after, with no per-contract bookkeeping. Sampled
    ///         across every mirror the fixture deploys, including a claimed user store.
    function test_version_mirrors_the_declared_protocol_version() public {
        vm.prank(ed);
        UserStore claimedStore = UserStore(storeFactory.claimUserStore());

        assertEq(protocolRegistry.version(), "");
        assertEq(dotnsRegistrar.version(), "");
        assertEq(claimedStore.version(), "");

        vm.prank(owner);
        registry.setProtocolVersion("0.8.0");

        assertEq(protocolRegistry.version(), "0.8.0");
        assertEq(dotnsRegistry.version(), "0.8.0");
        assertEq(dotnsRegistrar.version(), "0.8.0");
        assertEq(dotnsRegistrarController.version(), "0.8.0");
        assertEq(dotnsPopController.version(), "0.8.0");
        assertEq(popRules.version(), "0.8.0");
        assertEq(dotnsResolver.version(), "0.8.0");
        assertEq(dotnsContentResolver.version(), "0.8.0");
        assertEq(dotnsReverseResolver.version(), "0.8.0");
        assertEq(dotnsPopResolver.version(), "0.8.0");
        assertEq(dotnsNameEscrow.version(), "0.8.0");
        assertEq(storeFactory.version(), "0.8.0");
        assertEq(claimedStore.version(), "0.8.0");
    }

    /// @notice Both declarations live in proxy storage, so they survive an implementation
    ///         upgrade of the registry itself.
    function test_declarations_survive_implementation_upgrade() public {
        bytes32 declared = address(dotnsRegistrar).codehash;
        vm.startPrank(owner);
        registry.setProtocolVersion("0.8.0");
        registry.setExpectedCodehash(DotnsConstants.REGISTRAR, declared);

        DotnsProtocolRegistry newImplementation = new DotnsProtocolRegistry();
        protocolRegistry.upgradeToAndCall(address(newImplementation), bytes(""));
        vm.stopPrank();

        assertEq(registry.protocolVersion(), "0.8.0");
        assertEq(registry.expectedCodehash(DotnsConstants.REGISTRAR), declared);
    }
}
