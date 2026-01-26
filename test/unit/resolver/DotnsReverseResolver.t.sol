// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsReverseResolver} from "../../../contracts/resolvers/IDotnsReverseResolver.sol";

contract DotnsReverseResolverTests is BaseDotns {
    function test_nameof_empty_when_unset() public view {
        assertEq(bytes(dotnsReverseResolver.nameOf(ed)).length, 0);
    }

    function test_register_sets_reverse_for_owner() public {
        _commitAndRegister("reverserecord01", ed, true);
        assertEq(dotnsReverseResolver.nameOf(ed), "reverserecord01.dot");
    }

    function test_register_overwrites_reverse_when_registering_again() public {
        _commitAndRegister("reverseone01", ed, true);
        _commitAndRegister("reversetwo01", ed, true);
        assertEq(dotnsReverseResolver.nameOf(ed), "reversetwo01.dot");
    }

    function test_register_does_not_affect_other_addresses() public {
        _commitAndRegister("edreverse01", ed, true);
        _commitAndRegister("leoreverse01", leonardo, true);

        assertEq(dotnsReverseResolver.nameOf(ed), "edreverse01.dot");
        assertEq(dotnsReverseResolver.nameOf(leonardo), "leoreverse01.dot");
    }

    function test_updateregistrar_emits_event() public {
        address oldRegistrar = dotnsReverseResolver.registrar();
        address newRegistrar = makeAddr("newregistrar");

        vm.expectEmit(true, true, false, false);
        emit IDotnsReverseResolver.RegistrarUpdated(oldRegistrar, newRegistrar);

        vm.prank(owner);
        dotnsReverseResolver.updateRegistrar(newRegistrar);
    }

    function test_register_sets_reverse_after_registrar_update() public {
        vm.prank(owner);
        dotnsReverseResolver.updateRegistrar(address(dotnsRegistrarController));

        _commitAndRegister("reverseafterupdate01", ed, true);
        assertEq(dotnsReverseResolver.nameOf(ed), "reverseafterupdate01.dot");
    }
}
