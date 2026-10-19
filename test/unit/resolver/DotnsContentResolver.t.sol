// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsContentResolver} from "../../../contracts/resolvers/IDotnsContentResolver.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

/// @title DotnsContentResolverTests
/// @notice Unit tests for content-hash, text-record and operator authorisation on
///         @custom:contract DotnsContentResolver.
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
        emit IDotnsContentResolver.TextUpdated(node, textKey, textKey, textValue);

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
        emit IDotnsContentResolver.TextUpdated(node, textKey, textKey, textValue);

        vm.startPrank(operator);
        dotnsContentResolver.setText(node, textKey, textValue);
        vm.stopPrank();

        assertEq(dotnsContentResolver.text(node, textKey), textValue);
    }

    /// @notice The text key is recoverable from the log alone, so an indexer can list a node's
    ///         keys without knowing them in advance.
    function test_set_text_logs_the_key_readably() public {
        bytes32 node = _register("textrecord03", ed, IPopRules.PopStatus.NoStatus);

        vm.recordLogs();
        vm.prank(ed);
        dotnsContentResolver.setText(node, "com.twitter", "@dotns");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IDotnsContentResolver.TextUpdated.selector);
        assertEq(logs[0].topics[1], node);
        assertEq(logs[0].topics[2], keccak256("com.twitter"), "the indexed copy is the key hash");

        (string memory key, string memory value) = abi.decode(logs[0].data, (string, string));
        assertEq(key, "com.twitter", "the data copy is the key itself");
        assertEq(value, "@dotns");
    }
}
