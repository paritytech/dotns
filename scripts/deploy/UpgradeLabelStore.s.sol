// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IStoreFactory} from "../../contracts/store/IStoreFactory.sol";

/// @title UpgradeLabelStore
/// @notice Upgrades the deployed LabelStore implementation for every beacon-proxy store at once.
///         Resolves the store factory from the on-disk manifest, diffs the new storage layout
///         against the pinned @custom:contract LabelStoreOld snapshot, and rotates the shared
///         beacon only when the diff and every unsafe-pattern check pass.
/// @dev The LabelStore proxies are `BeaconProxy` instances behind one `UpgradeableBeacon` owned by
///      the store factory, so the swap is a single call to
///      @custom:function IStoreFactory.upgradeLabelStoreImplementation rather than a per-proxy
///      upgrade. The factory is the beacon owner, so the upgrade broadcasts from the factory
///      owner and the factory delegates the beacon rotation.
/// @dev PR-scoped. This script, the `LabelStoreOld` snapshot it references, and the paired
///      `test/fork/UpgradeLabelStore.t.sol` are deleted before merge per the upgrade-PR workflow
///      in CONTRIBUTING.md. The storage-layout reference is always supplied, so the layout diff is
///      mandatory: there is no environment switch that turns it off, and the run fails closed if a
///      slot moves, shrinks, or changes type.
/// @custom:security-contact admin@parity.io
contract UpgradeLabelStore is BaseDeployer {
    /// @notice Pre-upgrade snapshot the layout diff compares the new implementation against.
    /// @dev Source-file route, not a stored build-info directory, so the snapshot is versioned
    ///      beside the implementation and rebuilt by `forge build`. Deleted before merge.
    string internal constant REFERENCE_CONTRACT = "LabelStoreOld.sol:LabelStoreOld";

    /// @notice Fully-qualified artefact for the current LabelStore implementation.
    string internal constant LABEL_STORE_ARTEFACT = "LabelStore.sol:LabelStore";

    /// @notice Manifest label the store factory is recorded under.
    string internal constant STORE_FACTORY_LABEL = "StoreFactory";

    /// @notice Reads the manifest, resolves the store factory, and upgrades the label beacon as
    ///         `msg.sender`.
    /// @dev `msg.sender` must own the store factory, otherwise the `onlyOwner` gate on
    ///      @custom:function IStoreFactory.upgradeLabelStoreImplementation reverts.
    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        address factory = _readAddress(STORE_FACTORY_LABEL);
        _upgradeLabelStore(owner, factory);

        console.log("=== UpgradeLabelStore complete ===");
    }

    /// @notice Deploys the current LabelStore implementation and swaps the shared beacon under
    ///         `owner`.
    /// @dev The fail-closed layout diff runs first through
    ///      @custom:function Upgrades.validateUpgrade against @custom:contract LabelStoreOld; an
    ///      incompatible layout aborts the run before anything deploys. No `unsafeSkipAllChecks`
    ///      or `unsafeAllow` override is set. The new implementation is then deployed and the
    ///      factory rotates the beacon for every existing and future proxy in one call. No
    ///      initialiser data is passed: existing proxies keep the state they already hold and the
    ///      new implementation adds no storage that needs seeding.
    /// @param owner Account that owns the store factory and broadcasts the upgrade.
    /// @param factory Store factory address resolved from the manifest.
    /// @return newImplementation Address of the freshly deployed LabelStore implementation.
    function _upgradeLabelStore(
        address owner,
        address factory
    )
        internal
        returns (address newImplementation)
    {
        require(
            owner == OwnableUpgradeable(factory).owner(),
            "UpgradeLabelStore: broadcaster is not the store factory owner"
        );

        Options memory opts;
        opts.referenceContract = REFERENCE_CONTRACT;

        Upgrades.validateUpgrade(LABEL_STORE_ARTEFACT, opts);

        vm.startBroadcast(owner);
        newImplementation = Upgrades.deployImplementation(LABEL_STORE_ARTEFACT, opts);
        IStoreFactory(factory).upgradeLabelStoreImplementation(newImplementation);
        vm.stopBroadcast();

        console.log("  upgraded LabelStore implementation to", newImplementation);
    }
}
