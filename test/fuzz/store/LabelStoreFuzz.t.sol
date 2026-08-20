// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {ILabelStore} from "../../../contracts/store/ILabelStore.sol";

/// @title LabelStoreFuzzTest
/// @notice Property-based tests for @custom:contract LabelStore writes, pagination and label
/// accounting.
contract LabelStoreFuzzTest is BaseDotns {
    /// @notice Deploy a fresh @custom:contract LabelStore owned by `user` via the store factory.
    function _freshLabelStore(
        address user
    ) internal returns (ILabelStore store) {
        vm.prank(owner);
        store = ILabelStore(storeFactory.deployLabelStoreFor(user));
    }

    function testFuzz_storeLabel_succeeds_for_arbitrary_inputs(
        bytes32 labelhash,
        string calldata label
    ) public {
        vm.assume(labelhash != bytes32(0));

        ILabelStore store = _freshLabelStore(ed);
        vm.prank(address(dotnsRegistrarController));
        store.storeLabel(labelhash, label);

        assertTrue(store.hasLabel(labelhash));
        assertTrue(store.isLocked(labelhash));
        assertEq(store.getLabel(labelhash), label);
        assertEq(store.getLabelCount(), 1);
        assertEq(store.getLabelhashAt(0), labelhash);
        assertEq(store.getLabelAt(0), label);
    }

    function testFuzz_getLabels_pagination_consistent(
        uint8 rawCount,
        uint256 offset,
        uint256 limit
    ) public {
        // 1..10
        uint256 count = (uint256(rawCount) % 10) + 1;
        ILabelStore store = _freshLabelStore(ed);

        vm.startPrank(address(dotnsRegistrarController));
        for (uint256 i; i < count; ++i) {
            store.storeLabel(
                keccak256(abi.encodePacked("label", i)),
                _intString(i)
            );
        }
        vm.stopPrank();

        offset = bound(offset, 0, count + 2);
        limit = bound(limit, 0, count + 2);

        string[] memory labels = store.getLabels(offset, limit);
        bytes32[] memory hashes = store.getLabelhashes(offset, limit);

        uint256 expected = 0;
        if (offset < count) {
            uint256 available = count - offset;
            expected = limit < available ? limit : available;
        }

        assertEq(labels.length, expected);
        assertEq(hashes.length, expected);
        for (uint256 i; i < expected; ++i) {
            assertEq(labels[i], _intString(offset + i));
            assertEq(
                hashes[i],
                keccak256(abi.encodePacked("label", offset + i))
            );
        }
    }

    /// @notice Render `value` as its base-10 decimal string.
    function _intString(
        uint256 value
    ) internal pure returns (string memory decimal) {
        if (value == 0) return "0";
        uint256 length;
        for (uint256 remaining = value; remaining != 0; remaining /= 10) {
            ++length;
        }
        bytes memory buffer = new bytes(length);
        for (uint256 index = length; index != 0; --index) {
            buffer[index - 1] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        decimal = string(buffer);
    }
}
