// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title DotnsProtocolRegistryKeysTests
/// @notice Coverage for listing the registry's keys on chain: `set` and `remove` keep the list
///         current, and `initializeKeys` lists the well-known keys set before the list existed.
contract DotnsProtocolRegistryKeysTests is BaseDotns {
    using stdStorage for StdStorage;

    bytes32 private constant KEY_A = bytes32("test.key.a");

    IDotnsProtocolRegistry private registry;

    function setUp() public override {
        super.setUp();
        registry = IDotnsProtocolRegistry(address(protocolRegistry));
    }

    /// @notice Every key the deploy set is listed, and each one resolves.
    function test_keys_lists_every_key_the_deploy_set() public view {
        bytes32[] memory listed = registry.keys();
        bytes32[] memory known = DotnsConstants.registryKeys();

        for (uint256 i = 0; i < known.length; ++i) {
            bool resolves = registry.get(known[i]) != address(0);
            assertEq(_contains(listed, known[i]), resolves, "keys() disagrees with get()");
        }
        for (uint256 i = 0; i < listed.length; ++i) {
            assertTrue(registry.get(listed[i]) != address(0), "a listed key does not resolve");
        }
    }

    function test_set_lists_a_new_key() public {
        vm.prank(owner);
        registry.set(KEY_A, address(dotnsRegistrar));

        assertTrue(_contains(registry.keys(), KEY_A));
    }

    function test_remove_drops_the_key() public {
        vm.prank(owner);
        registry.set(KEY_A, address(dotnsRegistrar));
        vm.prank(owner);
        registry.remove(KEY_A);

        assertFalse(_contains(registry.keys(), KEY_A));
    }

    /// @notice Setting a key to the address it already holds still lists it, so re-setting a key
    ///         is a way to list it.
    function test_set_with_an_unchanged_address_lists_the_key() public {
        _writeAddressBypassingSet(KEY_A, address(dotnsRegistrar));
        assertFalse(_contains(registry.keys(), KEY_A));

        vm.prank(owner);
        registry.set(KEY_A, address(dotnsRegistrar));

        assertTrue(_contains(registry.keys(), KEY_A));
    }

    /// @notice The backfill lists every well-known key that resolves, and nothing else.
    function test_initializeKeys_lists_the_well_known_keys_set_before_the_list() public {
        bytes32 registrarKey = DotnsConstants.REGISTRAR;
        address registrarAddress = registry.get(registrarKey);
        vm.prank(owner);
        registry.remove(registrarKey);
        _writeAddressBypassingSet(registrarKey, registrarAddress);
        _writeAddressBypassingSet(KEY_A, address(dotnsRegistrar));
        assertFalse(_contains(registry.keys(), registrarKey));

        vm.prank(owner);
        registry.initializeKeys();

        assertTrue(_contains(registry.keys(), registrarKey), "a well-known key was not listed");
        assertFalse(_contains(registry.keys(), KEY_A), "a key outside DotnsConstants was listed");
        assertFalse(
            _contains(registry.keys(), DotnsConstants.MULTICALL3), "an unset key was listed"
        );
    }

    function test_revert_initializeKeys_runs_once() public {
        vm.prank(owner);
        registry.initializeKeys();

        vm.prank(owner);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initializeKeys();
    }

    function test_revert_initializeKeys_is_owner_only() public {
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ed));
        registry.initializeKeys();
    }

    /// @dev Writes `key`'s address straight into storage, as a registry set before `keys`
    ///      existed would hold it.
    function _writeAddressBypassingSet(bytes32 key, address addr) private {
        stdstore.target(address(registry)).sig(IDotnsProtocolRegistry.get.selector).with_key(key)
            .checked_write(addr);
    }

    function _contains(bytes32[] memory list, bytes32 key) private pure returns (bool found) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == key) return true;
        }
    }
}
