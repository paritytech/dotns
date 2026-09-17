// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title DotnsProtocolRegistryRemovalTests
/// @notice Coverage for clearing a registry key. The registry is a discovery directory that
///         previously could only grow: a retired contract kept its entry, and because
///         `isRegisteredAddress` is refcount-backed it kept whatever that membership conferred.
contract DotnsProtocolRegistryRemovalTests is BaseDotns {
    bytes32 private constant KEY_A = bytes32("test.key.a");
    bytes32 private constant KEY_B = bytes32("test.key.b");

    IDotnsProtocolRegistry private registry;
    address private listed;

    function setUp() public override {
        super.setUp();
        registry = IDotnsProtocolRegistry(address(protocolRegistry));
        listed = address(dotnsRegistrar);
    }

    /// @notice A removed key stops resolving.
    function test_remove_clears_the_key() public {
        vm.prank(owner);
        registry.set(KEY_A, listed);
        assertEq(registry.get(KEY_A), listed, "key did not resolve after set");

        vm.prank(owner);
        registry.remove(KEY_A);

        assertEq(registry.get(KEY_A), address(0), "key still resolves after removal");
    }

    /// @notice Removal is owner-gated, like `set`.
    function test_remove_is_owner_only() public {
        vm.prank(owner);
        registry.set(KEY_A, listed);

        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ed));
        registry.remove(KEY_A);

        assertEq(registry.get(KEY_A), listed, "a rejected removal still cleared the key");
    }

    /// @notice Clearing a key that holds nothing is an error rather than a silent no-op, so a
    ///         mistyped key cannot read as a successful removal.
    function test_remove_reverts_on_an_unset_key() public {
        vm.prank(owner);
        vm.expectRevert(IDotnsProtocolRegistry.KeyNotRegistered.selector);
        registry.remove(bytes32("never.set"));
    }

    /// @notice Removal emits the event, carrying the address that was cleared.
    function test_remove_emits_the_address_it_cleared() public {
        vm.prank(owner);
        registry.set(KEY_A, listed);

        vm.expectEmit(true, true, false, false, address(registry));
        emit IDotnsProtocolRegistry.AddressRemoved(KEY_A, listed);
        vm.prank(owner);
        registry.remove(KEY_A);
    }

    /// @notice Removal decrements the refcount, so an address listed only under the removed key
    ///         loses its registered status. This is the property the whole change exists for:
    ///         `isRegisteredAddress` is what store writes and factory deploys consult.
    function test_remove_revokes_registered_status() public {
        address outsider = address(0xA11CE);

        vm.prank(owner);
        registry.set(KEY_A, outsider);
        assertTrue(registry.isRegisteredAddress(outsider), "set did not register the address");

        vm.prank(owner);
        registry.remove(KEY_A);

        assertFalse(
            registry.isRegisteredAddress(outsider), "removal left the address still registered"
        );
    }

    /// @notice An address reachable under a second key keeps its registered status, so clearing
    ///         one of several entries does not silently deauthorise a live contract.
    function test_remove_keeps_registration_while_another_key_points_at_it() public {
        address outsider = address(0xA11CE);

        vm.startPrank(owner);
        registry.set(KEY_A, outsider);
        registry.set(KEY_B, outsider);
        registry.remove(KEY_A);
        vm.stopPrank();

        assertTrue(
            registry.isRegisteredAddress(outsider),
            "an address still held under another key lost its registration"
        );
        assertEq(registry.get(KEY_B), outsider, "the surviving key stopped resolving");
    }
}
