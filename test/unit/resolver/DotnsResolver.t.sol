// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsResolver} from "../../../contracts/resolvers/IDotnsResolver.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

/// @title DotnsResolverTests
/// @notice Unit tests for the address record on @custom:contract DotnsResolver.
contract DotnsResolverTests is BaseDotns {
    function test_setaddress_emits_event_and_persists() public {
        bytes32 node = _register("longnamehere01", ed, IPopRules.PopStatus.NoStatus);

        vm.expectEmit(true, true, true, true);
        emit IDotnsResolver.AddressSet(node, leonardo);

        vm.prank(ed);
        dotnsResolver.setAddress(node, leonardo);

        assertEq(dotnsResolver.addressOf(node), leonardo);
    }

    function test_setaddress_overwrites_previous_value() public {
        bytes32 node = _register("overwriteaddr01", ed, IPopRules.PopStatus.NoStatus);

        vm.startPrank(ed);
        dotnsResolver.setAddress(node, leonardo);
        dotnsResolver.setAddress(node, tiago);
        vm.stopPrank();

        assertEq(dotnsResolver.addressOf(node), tiago);
    }
}
