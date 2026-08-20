// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {ILabelStore} from "../../../contracts/store/ILabelStore.sol";
import {IUserStore} from "../../../contracts/store/IUserStore.sol";

/// @title StoreStressTest
/// @notice Stress-level coverage that exercises Store pagination, deep history,
///         and large-value round-trips for both LabelStore and UserStore.
contract StoreStressTest is BaseDotns {
    /// @notice Deploys and returns a fresh LabelStore for `user` via the factory owner.
    function _freshLabelStore(address user) internal returns (ILabelStore store) {
        vm.prank(owner);
        store = ILabelStore(storeFactory.deployLabelStoreFor(user));
    }

    /// @notice Claims and returns a fresh UserStore on behalf of `user`.
    function _freshUserStore(address user) internal returns (IUserStore store) {
        vm.prank(user);
        store = IUserStore(storeFactory.claimUserStore());
    }

    function test_label_store_many_labels() public {
        ILabelStore store = _freshLabelStore(ed);

        uint256 labelCount = 512;
        vm.startPrank(address(dotnsRegistrarController));
        for (uint256 i; i < labelCount; ++i) {
            store.storeLabel(keccak256(abi.encode("label", i)), _intString(i));
        }
        vm.stopPrank();

        assertEq(store.getLabelCount(), labelCount);

        // Paginated scan of the full list in 64-sized pages.
        uint256 page = 64;
        uint256 seen;
        for (uint256 offset; offset < labelCount; offset += page) {
            string[] memory slice = store.getLabels(offset, page);
            for (uint256 i; i < slice.length; ++i) {
                assertEq(slice[i], _intString(offset + i));
                ++seen;
            }
        }
        assertEq(seen, labelCount);
    }

    function test_user_store_large_value_round_trip() public {
        IUserStore store = _freshUserStore(ed);
        bytes32 key = keccak256("blob");

        bytes memory blob = _buildBlob(16_384);
        vm.prank(ed);
        store.setValue(key, blob);

        bytes memory stored = store.getValue(key);
        assertEq(stored.length, blob.length);
        assertEq(keccak256(stored), keccak256(blob));
    }

    function test_user_store_deep_history() public {
        IUserStore store = _freshUserStore(ed);
        bytes32 key = keccak256("versioned");

        uint256 versions = 64;
        vm.startPrank(ed);
        for (uint256 i; i < versions; ++i) {
            store.setValue(key, bytes(abi.encodePacked("v", _intString(i))));
        }
        vm.stopPrank();

        assertEq(store.getHistoryCount(key), versions - 1);

        IUserStore.Entry[] memory middle = store.getHistory(key, 30, 10);
        assertEq(middle.length, 10);
        assertEq(middle[0].value, bytes(abi.encodePacked("v", _intString(30))));

        IUserStore.Entry[] memory tail = store.getHistory(key, versions - 2, 100);
        assertEq(tail.length, 1);
        assertEq(tail[0].value, bytes(abi.encodePacked("v", _intString(versions - 2))));
    }

    function test_user_store_many_keys() public {
        IUserStore store = _freshUserStore(ed);

        uint256 keyCount = 256;
        vm.startPrank(ed);
        for (uint256 i; i < keyCount; ++i) {
            store.setValue(keccak256(abi.encode("k", i)), bytes(_intString(i)));
        }
        vm.stopPrank();

        assertEq(store.getKeyCount(), keyCount);

        bytes32[] memory page = store.getKeys(200, 100);
        assertEq(page.length, 56);
        assertEq(page[0], keccak256(abi.encode("k", uint256(200))));
    }

    function test_pagination_extreme_bounds() public {
        ILabelStore store = _freshLabelStore(ed);

        vm.startPrank(address(dotnsRegistrarController));
        store.storeLabel(keccak256("only"), "only.dot");
        vm.stopPrank();

        // offset == length → empty
        string[] memory empty1 = store.getLabels(1, 10);
        assertEq(empty1.length, 0);

        // offset > length → empty, no revert, no underflow
        string[] memory empty2 = store.getLabels(1_000_000, 100);
        assertEq(empty2.length, 0);

        // Massive limit → clamps to available.
        string[] memory all = store.getLabels(0, type(uint128).max);
        assertEq(all.length, 1);
    }

    /// @notice Builds a deterministic byte blob of `size` bytes for round-trip tests.
    function _buildBlob(uint256 size) internal pure returns (bytes memory blob) {
        blob = new bytes(size);
        for (uint256 index; index < size; ++index) {
            blob[index] = bytes1(uint8((index * 31 + 7) & 0xff));
        }
    }

    /// @notice Converts `value` to its decimal string representation.
    /// @dev Avoids OpenZeppelin's Strings library so the stress suite stays
    ///      self-contained.
    function _intString(uint256 value) internal pure returns (string memory decimal) {
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
