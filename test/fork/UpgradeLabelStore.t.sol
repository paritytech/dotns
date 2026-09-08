// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

import {ILabelStore} from "../../contracts/store/ILabelStore.sol";
import {IStoreFactory} from "../../contracts/store/IStoreFactory.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {UpgradeLabelStore} from "../../scripts/deploy/UpgradeLabelStore.s.sol";

/// @title UpgradeLabelStoreHarness
/// @notice Exposes the upgrade script's internal beacon-swap path so the fork test drives the exact
///         code the production run executes, including the fail-closed storage-layout diff.
/// @dev Mirrors the deploy-harness pattern: forward to the script internal rather than
///      re-implement the upgrade, so the test tracks the production path one-to-one.
contract UpgradeLabelStoreHarness is UpgradeLabelStore {
    /// @notice Upgrades the label beacon owned by `factory` under `owner` through the script's
    ///         `_upgradeLabelStore`.
    /// @param owner Account that owns the store factory and broadcasts the upgrade.
    /// @param factory Store factory that owns the label beacon.
    /// @return newImplementation Address of the freshly deployed LabelStore implementation.
    function upgradeLabelStore(
        address owner,
        address factory
    )
        external
        returns (address newImplementation)
    {
        newImplementation = _upgradeLabelStore(owner, factory);
    }
}

/// @title UpgradeLabelStoreForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradeLabelStore.s.sol`. Forks the live Paseo
///         Asset Hub through the ETH-RPC adapter, rotates the shared LabelStore beacon with the
///         script, and proves an existing store proxy keeps its stored labels and that the new
///         write-authorisation gate is live afterwards.
/// @dev PR-scoped: deleted before merge with the upgrade script and the `LabelStoreOld` snapshot.
///      Requires the local adapter on `paseo_local`; between upgrade PRs `test/fork/` is empty, so
///      the suite is skipped by default with `--no-match-path 'test/fork/**'`.
/// @custom:security-contact admin@parity.io
contract UpgradeLabelStoreForkTest is Test {
    /// @notice Manifest recording the live deployment addresses this fork resolves against.
    string internal constant MANIFEST_PATH = "deployments/paseo-assethub/420420417.json";

    /// @notice A representative label persisted before the upgrade and read back after it.
    string internal constant SEED_LABEL = "alice.paseo";

    /// @notice Drives the script's beacon-swap path against the live factory.
    UpgradeLabelStoreHarness internal upgrader;

    /// @notice The deployed store factory that owns the label beacon.
    IStoreFactory internal storeFactory;

    /// @notice The deployed protocol registry the stores authorise writers through.
    IDotnsProtocolRegistry internal protocolRegistry;

    /// @notice Factory owner, impersonated to authorise the beacon swap.
    address internal factoryOwner;

    /// @notice The registrar, a store writer impersonated to seed and write labels.
    address internal registrar;

    /// @notice The name escrow: registered in the protocol registry but not a store writer, used
    ///         to prove the new authorisation gate rejects a merely-registered address.
    address internal nameEscrow;

    /// @notice Forks Paseo and resolves the live factory, registry, and writer addresses.
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("paseo_local"));

        string memory manifest = vm.readFile(MANIFEST_PATH);
        storeFactory = IStoreFactory(vm.parseJsonAddress(manifest, ".StoreFactory"));
        protocolRegistry =
            IDotnsProtocolRegistry(vm.parseJsonAddress(manifest, ".DotnsProtocolRegistry"));

        factoryOwner = Ownable(address(storeFactory)).owner();
        registrar = protocolRegistry.get(DotnsConstants.REGISTRAR);
        nameEscrow = protocolRegistry.get(DotnsConstants.NAME_ESCROW);

        upgrader = new UpgradeLabelStoreHarness();
    }

    /// @notice The beacon swap keeps an existing store's stored label readable and leaves the
    ///         registrar-driven write path working on the new implementation.
    function test_upgrade_preservesStoredLabelAndKeepsWritesWorking() public {
        address user = makeAddr("labelStoreUser.writes");
        address store = _deployStoreFor(user);

        bytes32 seedHash = keccak256("dotns.fork.labelstore.seed");
        vm.prank(registrar);
        ILabelStore(store).storeLabel(seedHash, SEED_LABEL);
        assertEq(ILabelStore(store).getLabel(seedHash), SEED_LABEL, "pre-upgrade: label stored");

        address beacon = storeFactory.labelStoreBeacon();
        address implBefore = IBeacon(beacon).implementation();

        address newImplementation = upgrader.upgradeLabelStore(factoryOwner, address(storeFactory));

        // The beacon now serves the freshly deployed implementation to every proxy.
        assertEq(
            IBeacon(beacon).implementation(),
            newImplementation,
            "post-upgrade: beacon serves the new implementation"
        );
        assertTrue(newImplementation != implBefore, "post-upgrade: implementation changed");

        // The proxy is the same address and still resolves through the factory mapping.
        assertEq(storeFactory.getLabelStore(user), store, "post-upgrade: proxy address unchanged");
        assertEq(ILabelStore(store).owner(), user, "post-upgrade: store owner preserved");
        assertEq(
            ILabelStore(store).getLabel(seedHash),
            SEED_LABEL,
            "post-upgrade: stored label survives the beacon swap"
        );

        // P0: the registrar can still write a fresh label on the upgraded implementation.
        bytes32 postHash = keccak256("dotns.fork.labelstore.post");
        vm.prank(registrar);
        ILabelStore(store).storeLabel(postHash, "bob.paseo");
        assertEq(
            ILabelStore(store).getLabel(postHash), "bob.paseo", "post-upgrade: registrar writes"
        );
    }

    /// @notice After the upgrade, a merely-registered address that is not a store writer is
    ///         rejected, proving the `StoreAuth.isStoreWriter` gate is the live authorisation.
    function test_upgrade_activatesStoreAuthGate() public {
        address user = makeAddr("labelStoreUser.gate");
        address store = _deployStoreFor(user);

        upgrader.upgradeLabelStore(factoryOwner, address(storeFactory));

        // The name escrow is registered in the protocol registry yet is neither the registrar, a
        // controller, nor the registry, so the live gate must reject its write.
        bytes32 gateHash = keccak256("dotns.fork.labelstore.gate");
        vm.prank(nameEscrow);
        vm.expectRevert(abi.encodeWithSelector(ILabelStore.NotAuthorised.selector, nameEscrow));
        ILabelStore(store).storeLabel(gateHash, "mallory.paseo");
    }

    /// @notice Resolves `user`'s existing LabelStore proxy, deploying one through the registrar
    ///         when the fork has none yet.
    /// @dev The proxy is a `BeaconProxy` created before the upgrade, so it is the existing store
    ///      the beacon swap must keep intact. `deployLabelStoreFor` is gated to the owner or a
    ///      store writer, so the registrar drives it.
    /// @param user The user the store binds to.
    /// @return store The resolved or freshly deployed store proxy.
    function _deployStoreFor(address user) internal returns (address store) {
        store = storeFactory.getLabelStore(user);
        if (store == address(0)) {
            vm.prank(registrar);
            store = storeFactory.deployLabelStoreFor(user);
        }
    }
}
