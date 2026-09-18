// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Vm} from "forge-std/Vm.sol";

import {BaseUpgradeFork} from "./BaseUpgradeFork.t.sol";
import {MigrateStoreFactory} from "../../scripts/deploy/MigrateStoreFactory.s.sol";
import {StoreFactory} from "../../contracts/store/StoreFactory.sol";
import {IStoreFactory} from "../../contracts/store/IStoreFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title MigrateStoreFactoryHarness
/// @notice Exposes the migration script's internals so the test drives the production path.
/// @dev The script's `run` resolves the destination from the manifest, which on a fork still
///      names the factory being migrated from: the replacement is deployed during the upgrade,
///      and the manifest is updated afterwards. The internals take the addresses directly, which
///      is what lets this test run the real sequence before that entry exists.
contract MigrateStoreFactoryHarness is MigrateStoreFactory {
    /// @notice Runs the import leg against an explicit destination.
    function importInto(
        address owner,
        address proxy,
        address oldFactory,
        address[] memory users,
        uint256 expectedCount
    )
        external
    {
        _importBindings(owner, proxy, oldFactory, users, expectedCount);
    }

    /// @notice Runs the restore leg against an explicit destination.
    function restore(address owner, address proxy) external {
        _restoreShippedImplementation(owner, proxy);
    }
}

/// @title MigrateStoreFactoryForkTest
/// @notice Pairs one-to-one with `scripts/deploy/MigrateStoreFactory.s.sol`. Stands up the
///         replacement factory against live state, imports the bindings the deployed factory
///         holds, and proves an existing holder keeps the store they already had.
/// @dev This is the only part of the upgrade that moves user state between contracts rather than
///      swapping code underneath it, so it is the part where a mistake is least reversible. The
///      holders are read from the chain rather than invented: a fixture would prove the import
///      copies a fixture, and what needs proving is that it copies what the network holds.
///
///      The deployed factory exposes no enumeration, so the test takes its holders the same way
///      the operator does, through `LabelStoreDeployed`. Where the fork's RPC does not serve
///      historical logs the test has nothing to assert against and skips rather than passing
///      vacuously, which matters because an import of an empty list succeeds.
/// @custom:security-contact admin@parity.io
contract MigrateStoreFactoryForkTest is BaseUpgradeFork {
    /// @notice keccak("LabelStoreDeployed(address,address)").
    bytes32 internal constant LABEL_STORE_DEPLOYED =
        0x6294914f6f12fb260c6b69d8a5435317a9318b45790f0b19b42cdd06708fcdea;

    /// @notice The factory being migrated from, as the manifest currently names it.
    IStoreFactory internal oldFactory;

    /// @notice The replacement proxy, deployed here as the pipeline deploys it in production.
    address internal replacement;

    /// @notice Owner of both, impersonated to authorise every step.
    address internal factoryOwner;

    /// @notice Drives the script's own migration path.
    MigrateStoreFactoryHarness internal migrator;

    function setUp() public override {
        super.setUp();

        oldFactory = IStoreFactory(_live("StoreFactory"));
        factoryOwner = _ownerOf(address(oldFactory));

        replacement = address(
            new ERC1967Proxy(
                address(new StoreFactory()),
                abi.encodeCall(
                    StoreFactory.initialize, (factoryOwner, _live("DotnsProtocolRegistry"))
                )
            )
        );

        migrator = new MigrateStoreFactoryHarness();
    }

    /// @notice Every holder on the deployed factory keeps their store on the replacement.
    /// @dev The assertion that decides whether the migration is worth doing at all. Without the
    ///      import, each of these users is unbound on the replacement, and the next registration
    ///      for any of them deploys a second, empty store: their names survive, held in the
    ///      registry, but the labels indexed against their address do not.
    function test_import_carries_every_live_holder_onto_the_replacement() public {
        address[] memory holders = _liveHolders();
        if (holders.length == 0) {
            vm.skip(true);
            return;
        }

        uint256 expectedCount = oldFactory.getLabelStoreCount();

        address[] memory storesBefore = new address[](holders.length);
        for (uint256 i; i < holders.length; ++i) {
            storesBefore[i] = oldFactory.getLabelStore(holders[i]);
            assertTrue(storesBefore[i] != address(0), "fork precondition: holder has a store");
        }

        migrator.importInto(factoryOwner, replacement, address(oldFactory), holders, expectedCount);
        migrator.restore(factoryOwner, replacement);

        StoreFactory migrated = StoreFactory(replacement);
        for (uint256 i; i < holders.length; ++i) {
            assertEq(
                migrated.getLabelStore(holders[i]),
                storesBefore[i],
                "holder keeps the store they already had"
            );
        }
        assertEq(
            migrated.getLabelStoreCount(), expectedCount, "every binding lands in the enumeration"
        );
    }

    /// @notice A user who never had a store is still unbound afterwards.
    /// @dev The import writes bindings directly, so it is worth showing it writes only what it was
    ///      given. A spurious binding is worse than a missing one: it consumes the user's single
    ///      permanent slot, and the factory then refuses to deploy them a real store ever after.
    function test_import_binds_nobody_it_was_not_given() public {
        address[] memory holders = _liveHolders();
        if (holders.length == 0) {
            vm.skip(true);
            return;
        }

        address stranger = makeAddr("stranger");
        assertEq(
            oldFactory.getLabelStore(stranger), address(0), "fork precondition: stranger is unbound"
        );

        migrator.importInto(
            factoryOwner, replacement, address(oldFactory), holders, oldFactory.getLabelStoreCount()
        );
        migrator.restore(factoryOwner, replacement);

        assertEq(
            StoreFactory(replacement).getLabelStore(stranger),
            address(0),
            "a user who was not imported stays unbound"
        );
    }

    /// @notice Recovers the holders from the factory's own deployment events.
    /// @dev Returns empty when the fork's RPC does not serve historical logs, which the callers
    ///      treat as "cannot run here" rather than "nothing to import". The production path uses
    ///      `scripts/shell/store-holders.sh`, which reconciles the same replay against the
    ///      factory's count and refuses to emit a list it cannot account for.
    function _liveHolders() internal returns (address[] memory holders) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = LABEL_STORE_DEPLOYED;

        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(0, block.number, address(oldFactory), topics);

        address[] memory seen = new address[](logs.length);
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            address user = address(uint160(uint256(logs[i].topics[1])));
            bool known;
            for (uint256 j; j < count; ++j) {
                if (seen[j] == user) {
                    known = true;
                    break;
                }
            }
            if (!known) {
                seen[count++] = user;
            }
        }

        holders = new address[](count);
        for (uint256 i; i < count; ++i) {
            holders[i] = seen[i];
        }
    }
}
