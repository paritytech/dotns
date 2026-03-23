// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsContentResolver} from "../../../contracts/resolvers/IDotnsContentResolver.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

contract DotnsContentResolverTests is BaseDotns {
    function test_set_contenthash() public {
        address nameOwner = ed;

        bytes32 node = _register("contenthash01", nameOwner, IPopRules.PopStatus.NoStatus);

        bytes memory contentHash =
            hex"e30101701220aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

        vm.expectEmit(true, false, false, true);
        emit IDotnsContentResolver.ContentHashUpdated(node, contentHash);

        vm.startPrank(nameOwner);
        dotnsContentResolver.setContenthash(node, contentHash);
        vm.stopPrank();

        assertEq(dotnsContentResolver.contenthash(node), contentHash);
    }

    function test_set_text() public {
        address nameOwner = ed;

        bytes32 node = _register("textrecord01", nameOwner, IPopRules.PopStatus.NoStatus);

        string memory textKey = "ipfs";
        string memory textValue = "bafytextcid1";

        vm.expectEmit(true, true, false, true);
        emit IDotnsContentResolver.TextUpdated(node, textKey, textValue);

        vm.startPrank(nameOwner);
        dotnsContentResolver.setText(node, textKey, textValue);
        vm.stopPrank();

        assertEq(dotnsContentResolver.text(node, textKey), textValue);
    }

    function test_operator_can_modify_records() public {
        address nameOwner = ed;
        address operator = address(this);

        bytes32 node = _register("operatorrr01", nameOwner, IPopRules.PopStatus.NoStatus);

        vm.expectEmit(true, true, false, true);
        emit IDotnsContentResolver.ApprovalForAll(nameOwner, operator, true);

        vm.startPrank(nameOwner);
        dotnsContentResolver.setApprovalForAll(operator, true);
        vm.stopPrank();

        assertTrue(dotnsContentResolver.isApprovedForAll(nameOwner, operator));

        string memory textKey = "ipfs";
        string memory textValue = "operatorCid";

        vm.expectEmit(true, true, false, true);
        emit IDotnsContentResolver.TextUpdated(node, textKey, textValue);

        vm.startPrank(operator);
        dotnsContentResolver.setText(node, textKey, textValue);
        vm.stopPrank();

        assertEq(dotnsContentResolver.text(node, textKey), textValue);
    }
}
