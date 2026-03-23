// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {IDotnsReverseResolver} from "../../../contracts/resolvers/IDotnsReverseResolver.sol";

contract DotnsReverseResolverTests is BaseDotns {
    function test_nameof_returns_empty_when_unset() public view {
        assertEq(bytes(dotnsReverseResolver.nameOf(ed)).length, 0);
    }

    function test_register_sets_reverse_record_for_owner() public {
        _commitAndRegister("reverserecord01", ed, true);
        assertEq(dotnsReverseResolver.nameOf(ed), "reverserecord01.dot");
    }

    function test_register_overwrites_existing_reverse_record() public {
        _commitAndRegister("reverseone01", ed, true);
        _commitAndRegister("reversetwo01", ed, true);
        assertEq(dotnsReverseResolver.nameOf(ed), "reversetwo01.dot");
    }

    function test_updateprotocolregistry_emits_event_and_persists() public {
        IDotnsProtocolRegistry newRegistry = IDotnsProtocolRegistry(makeAddr("newRegistry"));

        vm.expectEmit(true, false, false, false);
        emit IDotnsReverseResolver.ProtocolRegistryUpdated(newRegistry);

        vm.prank(owner);
        dotnsReverseResolver.updateProtocolRegistry(newRegistry);

        assertEq(address(dotnsReverseResolver.protocolRegistry()), address(newRegistry));
    }
}
