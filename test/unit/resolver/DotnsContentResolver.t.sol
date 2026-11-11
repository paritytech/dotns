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

    function test_contenthash_updated_at_block_is_zero_when_unset() public {
        bytes32 node = _register("unsetblock01", ed, IPopRules.PopStatus.NoStatus);

        assertEq(dotnsContentResolver.contenthashUpdatedAtBlock(node), 0);
    }

    function test_set_contenthash_records_block_number() public {
        address nameOwner = ed;

        bytes32 node = _register("blockrecord01", nameOwner, IPopRules.PopStatus.NoStatus);

        bytes memory contentHash =
            hex"e30101701220aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

        vm.roll(1_234);
        vm.startPrank(nameOwner);
        dotnsContentResolver.setContenthash(node, contentHash);
        vm.stopPrank();

        assertEq(dotnsContentResolver.contenthashUpdatedAtBlock(node), 1_234);
    }

    function test_set_contenthash_again_moves_block_number() public {
        address nameOwner = ed;

        bytes32 node = _register("blockmove0001", nameOwner, IPopRules.PopStatus.NoStatus);

        bytes memory contentHash =
            hex"e30101701220aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

        vm.roll(100);
        vm.startPrank(nameOwner);
        dotnsContentResolver.setContenthash(node, contentHash);
        vm.stopPrank();
        assertEq(dotnsContentResolver.contenthashUpdatedAtBlock(node), 100);

        // A rewrite of the identical hash is still a write and is recorded as one, matching
        // ContentHashUpdated, which is emitted on every call rather than only on a change.
        vm.roll(250);
        vm.startPrank(nameOwner);
        dotnsContentResolver.setContenthash(node, contentHash);
        vm.stopPrank();
        assertEq(dotnsContentResolver.contenthashUpdatedAtBlock(node), 250);
    }

    function test_set_text_does_not_touch_contenthash_block() public {
        address nameOwner = ed;

        bytes32 node = _register("textnoblock01", nameOwner, IPopRules.PopStatus.NoStatus);

        bytes memory contentHash =
            hex"e30101701220aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

        vm.roll(40);
        vm.startPrank(nameOwner);
        dotnsContentResolver.setContenthash(node, contentHash);
        vm.stopPrank();

        vm.roll(80);
        vm.startPrank(nameOwner);
        dotnsContentResolver.setText(node, "url", "https://example.org");
        vm.stopPrank();

        assertEq(dotnsContentResolver.contenthashUpdatedAtBlock(node), 40);
    }

    function testFuzz_set_contenthash_records_any_block(uint64 blockNumber) public {
        blockNumber = uint64(bound(blockNumber, 1, type(uint64).max));
        address nameOwner = ed;

        bytes32 node = _register("fuzzblock0001", nameOwner, IPopRules.PopStatus.NoStatus);

        bytes memory contentHash =
            hex"e30101701220aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

        vm.roll(blockNumber);
        vm.startPrank(nameOwner);
        dotnsContentResolver.setContenthash(node, contentHash);
        vm.stopPrank();

        assertEq(dotnsContentResolver.contenthashUpdatedAtBlock(node), blockNumber);
    }

    function test_empty_contenthash_resets_block_number() public {
        bytes32 node = _register("blockdelete01", ed, IPopRules.PopStatus.NoStatus);

        vm.roll(60);
        vm.prank(ed);
        dotnsContentResolver.setContenthash(node, hex"e301017012201111");

        vm.roll(90);
        vm.prank(ed);
        dotnsContentResolver.setContenthash(node, "");

        assertEq(dotnsContentResolver.contenthashUpdatedAtBlock(node), 0);
    }

    function test_cleared_node_reads_zero_block_until_rewritten() public {
        bytes32 node = _register("blockclear001", ed, IPopRules.PopStatus.NoStatus);

        vm.roll(60);
        vm.prank(ed);
        dotnsContentResolver.setContenthash(node, hex"e301017012201111");

        vm.prank(ed);
        dotnsRegistry.clearRecords(node);
        assertEq(dotnsContentResolver.contenthashUpdatedAtBlock(node), 0);

        vm.roll(75);
        vm.prank(ed);
        dotnsContentResolver.setContenthash(node, hex"e301017012202222");
        assertEq(dotnsContentResolver.contenthashUpdatedAtBlock(node), 75);
    }

    /// @notice Every text write logs both events: `TextUpdated`, unchanged for consumers that
    ///         filter on it, and `TextChanged`, from which the key is recoverable without knowing
    ///         it in advance.
    function test_set_text_logs_the_key_readably() public {
        bytes32 node = _register("textrecord03", ed, IPopRules.PopStatus.NoStatus);

        vm.recordLogs();
        vm.prank(ed);
        dotnsContentResolver.setText(node, "com.twitter", "@dotns");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);

        assertEq(logs[0].topics[0], IDotnsContentResolver.TextUpdated.selector);
        assertEq(
            logs[0].topics[0],
            keccak256("TextUpdated(bytes32,string,string)"),
            "the TextUpdated signature consumers filter on"
        );
        assertEq(logs[0].topics[1], node);
        assertEq(logs[0].topics[2], keccak256("com.twitter"));
        assertEq(abi.decode(logs[0].data, (string)), "@dotns");

        assertEq(logs[1].topics[0], IDotnsContentResolver.TextChanged.selector);
        assertEq(logs[1].topics[1], node);
        assertEq(logs[1].topics[2], keccak256("com.twitter"), "the indexed copy is the key hash");
        (string memory key, string memory value) = abi.decode(logs[1].data, (string, string));
        assertEq(key, "com.twitter", "the data copy is the key itself");
        assertEq(value, "@dotns");
    }
}
