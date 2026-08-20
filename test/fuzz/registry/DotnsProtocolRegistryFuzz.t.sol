// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DotnsProtocolRegistry} from "../../../contracts/registry/DotnsProtocolRegistry.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";

/// @title DotnsProtocolRegistryFuzzTest
/// @notice Property-based tests for @custom:contract DotnsProtocolRegistry reference-counted
/// registration, plus TLD-initialisation guards.
contract DotnsProtocolRegistryFuzzTest is BaseDotns {
    /// @notice Deploys an uninitialised registry behind a bare proxy.
    /// @dev Wires the proxy directly so `initialize` is called in the open and its revert
    ///      surfaces raw, rather than wrapped by the upgrades plugin's deploy helper.
    function _uninitialisedRegistry() internal returns (DotnsProtocolRegistry registry) {
        DotnsProtocolRegistry implementation = new DotnsProtocolRegistry();
        registry = DotnsProtocolRegistry(address(new ERC1967Proxy(address(implementation), "")));
    }

    function test_initialise_reverts_on_empty_tld() public {
        DotnsProtocolRegistry registry = _uninitialisedRegistry();
        vm.expectRevert(IDotnsProtocolRegistry.InvalidTld.selector);
        registry.initialize("");
    }

    function test_initialise_reverts_on_multi_label_tld() public {
        DotnsProtocolRegistry registry = _uninitialisedRegistry();
        vm.expectRevert(IDotnsProtocolRegistry.InvalidTld.selector);
        registry.initialize("bad.label");
    }

    function testFuzz_isRegisteredAddress_matches_ground_truth(
        bytes32 k1,
        bytes32 k2,
        bytes32 k3,
        address a,
        address b
    )
        public
    {
        vm.assume(k1 != k2 && k2 != k3 && k1 != k3);
        vm.assume(a != address(0) && b != address(0) && a != b);
        // Exclude fixture-registered addresses so the refcount transitions under test aren't
        // masked by pre-existing references introduced by BaseDotns setUp.
        vm.assume(!protocolRegistry.isRegisteredAddress(a));
        vm.assume(!protocolRegistry.isRegisteredAddress(b));

        vm.startPrank(owner);
        protocolRegistry.set(k1, a);
        protocolRegistry.set(k2, a);
        protocolRegistry.set(k3, b);

        assertTrue(protocolRegistry.isRegisteredAddress(a));
        assertTrue(protocolRegistry.isRegisteredAddress(b));

        // Rotate k2 away from a. a is still referenced by k1.
        protocolRegistry.set(k2, b);
        assertTrue(protocolRegistry.isRegisteredAddress(a));
        assertTrue(protocolRegistry.isRegisteredAddress(b));

        // Rotate k1 away from a. a is now orphaned.
        protocolRegistry.set(k1, b);
        assertFalse(protocolRegistry.isRegisteredAddress(a));
        assertTrue(protocolRegistry.isRegisteredAddress(b));

        vm.stopPrank();
    }

    function testFuzz_set_same_pair_is_no_op(bytes32 key, address a, address b) public {
        vm.assume(a != address(0) && b != address(0) && a != b);
        // Exclude addresses already wired up by the BaseDotns fixture (registrar,
        // controller, resolvers, etc.) so the single-key accounting this test exercises
        // isn't aliased by unrelated references introduced during setUp.
        vm.assume(!protocolRegistry.isRegisteredAddress(a));
        vm.assume(!protocolRegistry.isRegisteredAddress(b));

        vm.startPrank(owner);
        protocolRegistry.set(key, a);
        // no-op
        protocolRegistry.set(key, a);
        // no-op
        protocolRegistry.set(key, a);
        // rotate away
        protocolRegistry.set(key, b);

        // If set(key, a) had been counted three times, a would still appear registered.
        assertFalse(protocolRegistry.isRegisteredAddress(a));
        assertTrue(protocolRegistry.isRegisteredAddress(b));
        vm.stopPrank();
    }

    function testFuzz_zero_address_never_registered(bytes32 key, address a) public {
        vm.assume(a != address(0));

        assertFalse(protocolRegistry.isRegisteredAddress(address(0)));

        vm.prank(owner);
        protocolRegistry.set(key, a);

        assertFalse(protocolRegistry.isRegisteredAddress(address(0)));
        assertTrue(protocolRegistry.isRegisteredAddress(a));
    }
}
