// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseUpgradeFork} from "./BaseUpgradeFork.t.sol";
import {MigrateStoreFactory} from "../../scripts/deploy/MigrateStoreFactory.s.sol";
import {UpgradeProtocolRegistryHarness} from "./UpgradeProtocolRegistry.t.sol";
import {StoreFactory} from "../../contracts/store/StoreFactory.sol";
import {IStoreFactory} from "../../contracts/store/IStoreFactory.sol";
import {IDotnsStore} from "../../contracts/store/IDotnsStore.sol";
import {StoreUtils} from "../../contracts/utils/StoreUtils.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";

/// @title MigrateStoreFactoryHarness
/// @notice Exposes the migration script's legs so the test drives the production path.
/// @dev The script's `run` reads the network folder and writes the manifest, neither of which a
///      fork should do. The legs underneath take their addresses directly, so the test runs the
///      same code in the same order without touching the working tree.
contract MigrateStoreFactoryHarness is MigrateStoreFactory {
    /// @notice Deploys the replacement proxy, as the script's first step does.
    function deployReplacement(
        address owner,
        address protocolRegistry
    )
        external
        returns (address replacement)
    {
        replacement = _deployReplacement(owner, protocolRegistry);
    }

    /// @notice Imports the bindings from `oldFactory` into `replacement`.
    function importInto(address owner, address replacement, address oldFactory) external {
        _importBindings(owner, replacement, oldFactory);
    }

    /// @notice Returns the proxy to the shipped implementation.
    function restore(address owner, address replacement) external {
        _restoreShippedImplementation(owner, replacement);
    }

    /// @notice Points the `storeFactory` key at the replacement and declares its codehash.
    function rewire(address owner, address replacement, address protocolRegistry) external {
        _rewireKey(owner, replacement, protocolRegistry);
    }
}

/// @title MigrateStoreFactoryForkTest
/// @notice Pairs one-to-one with `scripts/deploy/MigrateStoreFactory.s.sol`. Runs the migration
///         against live state and checks the condition that actually matters: after the rewire,
///         the path every registration takes returns the store a holder already has.
/// @dev The only part of the upgrade that moves user state between contracts instead of swapping
///      code underneath it, so it is where a mistake is least reversible. Holders are read from
///      the chain, never invented: a fixture would show the import copies a fixture, and what
///      needs showing is that it copies what the network holds.
///
///      The protocol registry is upgraded first, because the rewire declares a codehash and that
///      entrypoint does not exist on the implementation the network starts on. That is also the
///      production ordering, so running it here keeps the two honest.
/// @custom:security-contact admin@parity.io
contract MigrateStoreFactoryForkTest is BaseUpgradeFork {
    /// @notice The factory the network runs today, which the manifest still names.
    IStoreFactory internal oldFactory;

    /// @notice The live protocol registry, rewired to the replacement by the migration.
    IDotnsProtocolRegistry internal protocolRegistry;

    /// @notice Owner of the deployment, impersonated to authorise every step.
    address internal factoryOwner;

    /// @notice Drives the script's own migration path.
    MigrateStoreFactoryHarness internal migrator;

    function setUp() public override {
        super.setUp();

        oldFactory = IStoreFactory(_live("StoreFactory"));
        protocolRegistry = IDotnsProtocolRegistry(_live("DotnsProtocolRegistry"));
        factoryOwner = _ownerOf(address(oldFactory));
        migrator = new MigrateStoreFactoryHarness();

        // `_rewireKey` declares a codehash, which the deployed registry cannot do until it is
        // swapped. Production runs the registry first for the same reason.
        UpgradeProtocolRegistryHarness registryUpgrade = new UpgradeProtocolRegistryHarness();
        registryUpgrade.upgrade(_ownerOf(address(protocolRegistry)), address(protocolRegistry));
    }

    /// @notice After the migration, a lookup through the registry returns the holder's own store.
    /// @dev The success condition for the whole exercise, and the one an earlier version of this
    ///      test never reached. Every mint and transfer resolves `STORE_FACTORY` through the
    ///      protocol registry and calls `ensureLabelStore`, which deploys a store when the caller
    ///      has none. Had the bindings not come across, this call would quietly deploy a second,
    ///      empty store for a user who already has one, and their labels would stop being
    ///      enumerable against their address.
    function test_after_rewire_a_live_holder_resolves_to_their_existing_store() public {
        uint256 total = oldFactory.getLabelStoreCount();
        assertTrue(total != 0, "fork precondition: the network has stores to migrate");

        address[] memory stores = oldFactory.getLabelStores(0, total);
        address holderStore = stores[0];
        address holder = IDotnsStore(holderStore).owner();
        assertEq(oldFactory.getLabelStore(holder), holderStore, "fork precondition: binding agrees");

        address replacement = migrator.deployReplacement(factoryOwner, address(protocolRegistry));
        migrator.importInto(factoryOwner, replacement, address(oldFactory));
        migrator.restore(factoryOwner, replacement);
        migrator.rewire(factoryOwner, replacement, address(protocolRegistry));

        assertEq(
            protocolRegistry.get(DotnsConstants.STORE_FACTORY),
            replacement,
            "the key resolves to the replacement"
        );

        // The production path, reached the way registration reaches it.
        IStoreFactory resolved = IStoreFactory(protocolRegistry.get(DotnsConstants.STORE_FACTORY));
        vm.prank(factoryOwner);
        address ensured = StoreUtils.ensureLabelStore(resolved, holder);

        assertEq(ensured, holderStore, "the holder resolves to the store they already had");
        assertEq(resolved.getLabelStoreCount(), total, "no extra store was deployed for anyone");
    }

    /// @notice Every holder the old factory reports comes across, not only the first.
    /// @dev The count is the cheap end-to-end check. A partial import would satisfy any
    ///      single-holder assertion while leaving the rest to be handed empty stores later.
    function test_every_live_holder_is_carried() public {
        uint256 total = oldFactory.getLabelStoreCount();
        address[] memory stores = oldFactory.getLabelStores(0, total);

        address replacement = migrator.deployReplacement(factoryOwner, address(protocolRegistry));
        migrator.importInto(factoryOwner, replacement, address(oldFactory));
        migrator.restore(factoryOwner, replacement);

        StoreFactory migrated = StoreFactory(replacement);
        assertEq(migrated.getLabelStoreCount(), total, "every binding landed");

        for (uint256 i; i < total; ++i) {
            address holder = IDotnsStore(stores[i]).owner();
            assertEq(migrated.getLabelStore(holder), stores[i], "holder keeps their existing store");
        }
    }

    /// @notice A user the old factory never held is still unbound afterwards.
    /// @dev The import writes bindings directly, so it is worth showing it writes only what the
    ///      old factory holds. A spurious binding is worse than a missing one: it consumes the
    ///      user's single permanent slot, and the factory then refuses them a real store forever.
    function test_import_binds_nobody_the_old_factory_did_not_hold() public {
        address stranger = makeAddr("stranger");
        assertEq(
            oldFactory.getLabelStore(stranger), address(0), "fork precondition: stranger is unbound"
        );

        address replacement = migrator.deployReplacement(factoryOwner, address(protocolRegistry));
        migrator.importInto(factoryOwner, replacement, address(oldFactory));
        migrator.restore(factoryOwner, replacement);

        assertEq(
            StoreFactory(replacement).getLabelStore(stranger),
            address(0),
            "a user the old factory never held stays unbound"
        );
    }
}
