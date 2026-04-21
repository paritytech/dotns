// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";

contract DotnsProtocolRegistryTests is BaseDotns {
    bytes32 internal popGatewayKey;

    function setUp() public override {
        super.setUp();
        popGatewayKey = protocolRegistry.POP_GATEWAY();
    }

    function test_popGateway_key_is_distinct_from_other_well_known_keys() public view {
        assertTrue(popGatewayKey != protocolRegistry.REGISTRAR());
        assertTrue(popGatewayKey != protocolRegistry.CONTROLLER());
        assertTrue(popGatewayKey != protocolRegistry.REGISTRY());
        assertTrue(popGatewayKey != protocolRegistry.REVERSE_RESOLVER());
        assertTrue(popGatewayKey != protocolRegistry.POP_RULES());
        assertTrue(popGatewayKey != protocolRegistry.STORE_FACTORY());
        assertTrue(popGatewayKey != protocolRegistry.RESOLVER());
        assertTrue(popGatewayKey != protocolRegistry.CONTENT_RESOLVER());
    }

    function test_popGateway_key_matches_expected_bytes32_literal() public view {
        assertEq(popGatewayKey, bytes32("popGateway"));
    }

    function test_popGateway_is_set_by_base_setup() public view {
        assertEq(protocolRegistry.get(popGatewayKey), popGateway);
    }

    function test_owner_can_set_popGateway_address_and_emits_event() public {
        address gateway = makeAddr("popGateway");

        vm.expectEmit(true, true, false, false, address(protocolRegistry));
        emit IDotnsProtocolRegistry.AddressUpdated(popGatewayKey, gateway);

        vm.prank(owner);
        protocolRegistry.set(popGatewayKey, gateway);

        assertEq(protocolRegistry.get(popGatewayKey), gateway);
    }

    function test_owner_can_update_popGateway_address() public {
        address first = makeAddr("popGateway1");
        address second = makeAddr("popGateway2");

        vm.startPrank(owner);
        protocolRegistry.set(popGatewayKey, first);
        protocolRegistry.set(popGatewayKey, second);
        vm.stopPrank();

        assertEq(protocolRegistry.get(popGatewayKey), second);
    }

    function test_setting_popGateway_to_zero_reverts() public {
        vm.prank(owner);
        vm.expectRevert(IDotnsProtocolRegistry.ZeroAddress.selector);
        protocolRegistry.set(popGatewayKey, address(0));
    }

    function test_non_owner_cannot_set_popGateway() public {
        address gateway = makeAddr("popGateway");

        vm.prank(ed);
        vm.expectRevert();
        protocolRegistry.set(popGatewayKey, gateway);
    }

    function test_setting_popGateway_does_not_affect_other_keys() public {
        address gateway = makeAddr("popGateway");
        address registrarBefore = protocolRegistry.get(protocolRegistry.REGISTRAR());
        address controllerBefore = protocolRegistry.get(protocolRegistry.CONTROLLER());

        vm.prank(owner);
        protocolRegistry.set(popGatewayKey, gateway);

        assertEq(protocolRegistry.get(protocolRegistry.REGISTRAR()), registrarBefore);
        assertEq(protocolRegistry.get(protocolRegistry.CONTROLLER()), controllerBefore);
    }
}
