// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {StoreUtils} from "../../../contracts/utils/StoreUtils.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";

contract StoreUtilsTests is Test {
    function test_chatKeyStoreKey_matches_keccak_of_prefix_and_labelhash() public pure {
        bytes32 labelhash = keccak256(bytes("alice"));
        bytes32 expected = keccak256(abi.encodePacked(DotnsConstants.DOTNS_CHAT_KEY, labelhash));

        assertEq(StoreUtils.chatKeyStoreKey(labelhash), expected);
    }

    function test_liteLinkStoreKey_matches_keccak_of_prefix_and_labelhash() public pure {
        bytes32 labelhash = keccak256(bytes("alice"));
        bytes32 expected =
            keccak256(abi.encodePacked(DotnsConstants.DOTNS_LITE_LINK_KEY, labelhash));

        assertEq(StoreUtils.liteLinkStoreKey(labelhash), expected);
    }

    function test_all_store_keys_are_distinct_for_same_labelhash() public pure {
        bytes32 labelhash = keccak256(bytes("alice"));

        bytes32 registered = StoreUtils.storeKey(labelhash);
        bytes32 chatKey = StoreUtils.chatKeyStoreKey(labelhash);
        bytes32 liteLink = StoreUtils.liteLinkStoreKey(labelhash);

        assertTrue(registered != chatKey);
        assertTrue(registered != liteLink);
        assertTrue(chatKey != liteLink);
    }

    function test_chatKeyStoreKey_differs_across_labelhashes() public pure {
        bytes32 alice = StoreUtils.chatKeyStoreKey(keccak256(bytes("alice")));
        bytes32 bob = StoreUtils.chatKeyStoreKey(keccak256(bytes("bob")));

        assertTrue(alice != bob);
    }

    function test_liteLinkStoreKey_differs_across_labelhashes() public pure {
        bytes32 alice = StoreUtils.liteLinkStoreKey(keccak256(bytes("alice")));
        bytes32 bob = StoreUtils.liteLinkStoreKey(keccak256(bytes("bob")));

        assertTrue(alice != bob);
    }

    function testFuzz_chatKeyStoreKey_is_deterministic(bytes32 labelhash) public pure {
        assertEq(StoreUtils.chatKeyStoreKey(labelhash), StoreUtils.chatKeyStoreKey(labelhash));
    }

    function testFuzz_liteLinkStoreKey_is_deterministic(bytes32 labelhash) public pure {
        assertEq(StoreUtils.liteLinkStoreKey(labelhash), StoreUtils.liteLinkStoreKey(labelhash));
    }

    function testFuzz_store_keys_distinct_per_labelhash(bytes32 labelhash) public pure {
        bytes32 registered = StoreUtils.storeKey(labelhash);
        bytes32 chatKey = StoreUtils.chatKeyStoreKey(labelhash);
        bytes32 liteLink = StoreUtils.liteLinkStoreKey(labelhash);

        assertTrue(registered != chatKey);
        assertTrue(registered != liteLink);
        assertTrue(chatKey != liteLink);
    }
}
