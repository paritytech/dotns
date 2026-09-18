// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {IStoreFactory} from "../../contracts/store/IStoreFactory.sol";
import {StoreFactoryMigrator} from "../../contracts/store/StoreFactoryMigrator.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title MigrateStoreFactory
/// @notice Moves the per-user `LabelStore` bindings onto the current `StoreFactory` proxy and
///         points the `storeFactory` key at it.
/// @dev The one contract in the upgrade that cannot be swapped in place. The deployed factory is
///      a plain contract from an earlier release, not a proxy, so there is nothing to upgrade;
///      the current release puts the factory behind its own proxy at a different address. Every
///      store lookup goes through whatever `STORE_FACTORY` resolves to, so re-pointing the key at
///      an empty factory would hand each existing user a second, empty store the next time one
///      was needed, and drop their labels out of per-address enumeration. Their names are
///      untouched either way: ownership lives in the registry, not here.
///
///      Sequence, all under the proxy owner:
///
///        1. upgrade the proxy to `StoreFactoryMigrator`, calling `importStores` in the same
///           transaction, so the proxy is never left sitting on migration tooling between two
///           broadcasts;
///        2. upgrade it back to the shipped `StoreFactory`;
///        3. re-point the `storeFactory` key and declare the new codehash together, because the
///           checklist treats an unpaired rewire as drift.
///
///      Both upgrades supply a layout reference and no unsafe override, so each direction is
///      diffed. The migrator is the shipped factory with four fields widened and one entrypoint
///      added, so both diffs are no-ops that still have to pass.
///
///      What this does not do: the imported stores keep the beacons the old factory minted, and
///      those beacons answer to the old factory. Their code stays upgradeable there, by the same
///      owner. A `BeaconProxy` holds its beacon in an immutable, so no migration can move them.
///
///      The user list is supplied rather than read from the chain: the deployed factory has no
///      enumeration function, so an operator reads its store list out of storage and passes it
///      in. `expectedCount` is read from the old factory here and asserted inside `importStores`,
///      which is what catches a list that silently omits users.
/// @custom:security-contact admin@parity.io
contract MigrateStoreFactory is BaseDeployer {
    /// @notice Manifest label the current `StoreFactory` proxy is recorded under.
    string internal constant STORE_FACTORY_LABEL = "StoreFactory";

    /// @notice Manifest label the protocol registry is recorded under.
    string internal constant PROTOCOL_REGISTRY_LABEL = "DotnsProtocolRegistry";

    /// @notice Imports the bindings, restores the shipped implementation, and rewires the key.
    /// @dev `DOTNS_OLD_STORE_FACTORY` is the factory being migrated from. `DOTNS_STORE_USERS` is
    ///      a comma-separated list of every address holding a `LabelStore` on it.
    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        address proxy = _readAddress(STORE_FACTORY_LABEL);
        address oldFactory = vm.envAddress("DOTNS_OLD_STORE_FACTORY");
        address[] memory users = vm.envAddress("DOTNS_STORE_USERS", ",");

        require(
            owner == OwnableUpgradeable(proxy).owner(),
            "MigrateStoreFactory: broadcaster is not the proxy owner"
        );
        require(
            oldFactory != proxy, "MigrateStoreFactory: old and new factory are the same address"
        );

        uint256 expectedCount = IStoreFactory(oldFactory).getLabelStoreCount();
        console.log("  importing", expectedCount, "bindings from", oldFactory);

        _importBindings(owner, proxy, oldFactory, users, expectedCount);
        _restoreShippedImplementation(owner, proxy);
        _rewireKey(owner, proxy);

        console.log("=== MigrateStoreFactory complete ===");
    }

    /// @notice Swaps in the migrator and imports in one transaction.
    /// @dev `upgradeToAndCall` runs the import as a delegatecall from the proxy, so `msg.sender`
    ///      is preserved and the `onlyOwner` gate on `importStores` is satisfied by the
    ///      broadcaster rather than by the proxy calling itself.
    /// @param owner Account that owns the proxy and broadcasts.
    /// @param proxy The `StoreFactory` proxy being migrated into.
    /// @param oldFactory Factory whose bindings are adopted.
    /// @param users Every address holding a `LabelStore` on `oldFactory`.
    /// @param expectedCount Binding count read from `oldFactory`.
    function _importBindings(
        address owner,
        address proxy,
        address oldFactory,
        address[] memory users,
        uint256 expectedCount
    )
        internal
    {
        Options memory opts;
        opts.referenceContract = "StoreFactory.sol:StoreFactory";

        vm.startBroadcast(owner);
        Upgrades.upgradeProxy(
            proxy,
            "StoreFactoryMigrator.sol:StoreFactoryMigrator",
            abi.encodeCall(StoreFactoryMigrator.importStores, (oldFactory, users, expectedCount)),
            opts
        );
        vm.stopBroadcast();

        console.log("  imported bindings into", proxy);
    }

    /// @notice Returns the proxy to the shipped implementation.
    /// @dev Left on the migrator, the deployment would be running tooling that no release
    ///      describes, and the codehash declared in step three would be the tooling's.
    /// @param owner Account that owns the proxy and broadcasts.
    /// @param proxy The `StoreFactory` proxy.
    function _restoreShippedImplementation(address owner, address proxy) internal {
        Options memory opts;
        opts.referenceContract = "StoreFactoryMigrator.sol:StoreFactoryMigrator";

        vm.startBroadcast(owner);
        Upgrades.upgradeProxy(proxy, "StoreFactory.sol:StoreFactory", "", opts);
        vm.stopBroadcast();

        console.log("  restored the shipped StoreFactory implementation");
    }

    /// @notice Points the `storeFactory` key at the proxy and declares its codehash.
    /// @dev Paired on purpose. `DEPLOYMENT_CHECKLIST.md` treats a rewire without a matching
    ///      declaration as drift, indistinguishable from an unauthorised swap.
    /// @param owner Account that owns the protocol registry and broadcasts.
    /// @param proxy The `StoreFactory` proxy the key should resolve to.
    function _rewireKey(address owner, address proxy) internal {
        IDotnsProtocolRegistry registry =
            IDotnsProtocolRegistry(_readAddress(PROTOCOL_REGISTRY_LABEL));

        address implementation =
            address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));

        vm.startBroadcast(owner);
        registry.set(DotnsConstants.STORE_FACTORY, proxy);
        registry.setExpectedCodehash(DotnsConstants.STORE_FACTORY, implementation.codehash);
        vm.stopBroadcast();

        console.log("  storeFactory key now resolves to", proxy);
    }
}
