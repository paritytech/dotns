// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {IStoreFactory} from "../../contracts/store/IStoreFactory.sol";
import {StoreFactory} from "../../contracts/store/StoreFactory.sol";
import {StoreFactoryMigrator} from "../../contracts/store/StoreFactoryMigrator.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title MigrateStoreFactory
/// @notice Deploys the current `StoreFactory` behind its own proxy, carries the per-user
///         `LabelStore` bindings over from the factory the network runs today, and points the
///         `storeFactory` key at the result.
/// @dev The one contract in the upgrade that cannot be swapped in place. What is deployed is a
///      plain contract from an earlier release, so there is no proxy to upgrade; the current
///      release puts the factory behind one at a different address. Every store lookup goes
///      through whatever `STORE_FACTORY` resolves to, so re-pointing the key at an empty factory
///      would hand each existing holder a second, empty store the next time one was needed and
///      drop their labels out of per-address enumeration. Names are untouched either way:
///      ownership lives in the registry, not here.
///
///      Self-contained on purpose. The manifest's `StoreFactory` entry is the factory the network
///      is running, which is the truth before this script and the thing being migrated from; the
///      replacement does not exist until this deploys it. An earlier draft read the destination
///      from that same entry, which meant the script could only run after some other step had
///      already deployed the proxy and rewritten the manifest, and no such step existed.
///
///      Sequence, all under the proxy owner:
///
///        1. deploy the replacement through the pipeline's CREATE3 helper, which lands it on its
///           deterministic address and adopts it if a previous run got that far;
///        2. upgrade it to `StoreFactoryMigrator`, calling `importStores` in the same transaction
///           so the proxy is never left on migration tooling between two broadcasts;
///        3. upgrade it back to the shipped `StoreFactory`;
///        4. re-point the `storeFactory` key and declare the new codehash together, because the
///           checklist treats an unpaired rewire as drift;
///        5. write the new factory and its beacons into the manifest.
///
///      Run it after the protocol registry swap. Step 4 calls `setExpectedCodehash`, which does
///      not exist on the registry implementation the network starts on.
///
///      What this does not do: the imported stores keep the beacons the old factory minted, and
///      those beacons answer to the old factory. Their code stays upgradeable there, by the same
///      owner, which is why the old factory must not be discarded. A `BeaconProxy` holds its
///      beacon in an immutable, so no migration can move them.
/// @custom:security-contact admin@parity.io
contract MigrateStoreFactory is BaseDeployer {
    /// @notice Manifest label the store factory is recorded under, before and after.
    string internal constant STORE_FACTORY_LABEL = "StoreFactory";

    /// @notice Manifest label the protocol registry is recorded under.
    string internal constant PROTOCOL_REGISTRY_LABEL = "DotnsProtocolRegistry";

    /// @notice Deploys the replacement, imports the bindings, rewires the key, saves the manifest.
    /// @dev `DOTNS_OLD_STORE_FACTORY` is optional. When set it is asserted against the manifest,
    ///      so an operator who believes they are migrating from a particular factory finds out
    ///      here if the manifest disagrees, before anything is broadcast.
    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        address oldFactory = _readAddress(STORE_FACTORY_LABEL);
        address protocolRegistry = _readAddress(PROTOCOL_REGISTRY_LABEL);

        address expected = vm.envOr("DOTNS_OLD_STORE_FACTORY", address(0));
        require(
            expected == address(0) || expected == oldFactory,
            "MigrateStoreFactory: DOTNS_OLD_STORE_FACTORY does not match the manifest"
        );
        require(
            owner == OwnableUpgradeable(oldFactory).owner(),
            "MigrateStoreFactory: broadcaster does not own the deployed factory"
        );

        console.log("  migrating from", oldFactory);
        console.log("  bindings to carry", IStoreFactory(oldFactory).getLabelStoreCount());

        address replacement = _deployReplacement(owner, protocolRegistry);
        require(
            replacement != oldFactory,
            "MigrateStoreFactory: replacement resolved to the deployed factory"
        );

        _importBindings(owner, replacement, oldFactory);
        _restoreShippedImplementation(owner, replacement);
        _rewireKey(owner, replacement, protocolRegistry);
        _recordManifest(replacement);

        saveDeployments();

        console.log("=== MigrateStoreFactory complete ===");
    }

    /// @notice Deploys the replacement proxy, or adopts one a previous run left behind.
    /// @dev The pipeline's own helper, so the replacement lands on the same deterministic address
    ///      a fresh deploy would give it and is checked the same way. Adoption is what makes the
    ///      script resumable: an interrupted run can be repeated without stranding a proxy.
    /// @param owner Account that owns the deployment and broadcasts.
    /// @param protocolRegistry Registry the new factory is initialised against.
    /// @return replacement Address of the replacement proxy.
    function _deployReplacement(
        address owner,
        address protocolRegistry
    )
        internal
        returns (address replacement)
    {
        replacement = _broadcastDeployUups(
            owner,
            "StoreFactory.sol:StoreFactory",
            abi.encodeCall(StoreFactory.initialize, (owner, protocolRegistry)),
            STORE_FACTORY_LABEL
        );

        // The beacons are minted by the initialiser, so they exist only once the proxy does.
        // Asserted here because everything downstream reads through them.
        _verifyStoreImplementations(replacement, protocolRegistry);
        console.log("  replacement factory at", replacement);
    }

    /// @notice Swaps in the migrator and imports in one transaction.
    /// @dev `upgradeToAndCall` runs the import as a delegatecall from the proxy, so `msg.sender`
    ///      is preserved and the `onlyOwner` gate on `importStores` is satisfied by the
    ///      broadcaster. The import reads the holders from `oldFactory` itself, so nothing about
    ///      the set is captured before this transaction runs.
    /// @param owner Account that owns the proxy and broadcasts.
    /// @param replacement The proxy being migrated into.
    /// @param oldFactory Factory whose bindings are adopted.
    function _importBindings(address owner, address replacement, address oldFactory) internal {
        Options memory opts;
        opts.referenceContract = "StoreFactory.sol:StoreFactory";

        vm.startBroadcast(owner);
        Upgrades.upgradeProxy(
            replacement,
            "StoreFactoryMigrator.sol:StoreFactoryMigrator",
            abi.encodeCall(StoreFactoryMigrator.importStores, (oldFactory)),
            opts
        );
        vm.stopBroadcast();

        require(
            IStoreFactory(replacement).getLabelStoreCount()
                == IStoreFactory(oldFactory).getLabelStoreCount(),
            "MigrateStoreFactory: binding counts disagree after the import"
        );
        console.log("  imported bindings into", replacement);
    }

    /// @notice Returns the proxy to the shipped implementation.
    /// @dev Left on the migrator, the deployment would be running tooling that no release
    ///      describes, and the codehash declared below would be the tooling's.
    /// @param owner Account that owns the proxy and broadcasts.
    /// @param replacement The proxy to restore.
    function _restoreShippedImplementation(address owner, address replacement) internal {
        Options memory opts;
        opts.referenceContract = "StoreFactoryMigrator.sol:StoreFactoryMigrator";

        vm.startBroadcast(owner);
        Upgrades.upgradeProxy(replacement, "StoreFactory.sol:StoreFactory", "", opts);
        vm.stopBroadcast();

        console.log("  restored the shipped StoreFactory implementation");
    }

    /// @notice Points the `storeFactory` key at the replacement and declares its codehash.
    /// @dev Paired on purpose. `DEPLOYMENT_CHECKLIST.md` treats a rewire without a matching
    ///      declaration as drift, indistinguishable from an unauthorised swap.
    /// @param owner Account that owns the protocol registry and broadcasts.
    /// @param replacement The proxy the key should resolve to.
    /// @param protocolRegistry The protocol registry holding the key.
    function _rewireKey(address owner, address replacement, address protocolRegistry) internal {
        IDotnsProtocolRegistry registry = IDotnsProtocolRegistry(protocolRegistry);
        address implementation =
            address(uint160(uint256(vm.load(replacement, ERC1967_IMPLEMENTATION_SLOT))));

        vm.startBroadcast(owner);
        registry.set(DotnsConstants.STORE_FACTORY, replacement);
        registry.setExpectedCodehash(DotnsConstants.STORE_FACTORY, implementation.codehash);
        vm.stopBroadcast();

        require(
            registry.get(DotnsConstants.STORE_FACTORY) == replacement,
            "MigrateStoreFactory: storeFactory key did not take"
        );
        console.log("  storeFactory key now resolves to", replacement);
    }

    /// @notice Records the replacement and its beacons in the manifest.
    /// @dev The beacons move with the factory: the replacement's initialiser mints its own, and
    ///      the old ones stay behind owned by the old factory. Leaving the old beacon addresses
    ///      in the manifest would point every later tool at beacons this factory cannot upgrade.
    /// @param replacement The proxy now serving the `storeFactory` key.
    function _recordManifest(address replacement) internal {
        address labelBeacon = IStoreFactory(replacement).labelStoreBeacon();
        address userBeacon = IStoreFactory(replacement).userStoreBeacon();

        vm.label(labelBeacon, "LabelStoreBeacon");
        vm.label(userBeacon, "UserStoreBeacon");
        logDeployment("LabelStoreBeacon", labelBeacon);
        logDeployment("UserStoreBeacon", userBeacon);
    }
}
