// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IUserStore} from "../../../contracts/store/IUserStore.sol";

/// @title UserStoreFuzzTest
/// @notice Property-based tests for @custom:contract UserStore writes, history accounting and
/// pagination.
contract UserStoreFuzzTest is BaseDotns {
    /// @notice Claim a fresh @custom:contract UserStore for `user` via the store factory.
    function _freshUserStore(address user) internal returns (IUserStore store) {
        vm.prank(user);
        store = IUserStore(storeFactory.claimUserStore());
    }

    function testFuzz_setValue_accepts_arbitrary_inputs(
        bytes32 key,
        bytes calldata value
    ) public {
        vm.assume(key != bytes32(0));

        IUserStore store = _freshUserStore(ed);
        vm.prank(ed);
        store.setValue(key, value);

        assertEq(store.getValue(key), value);
        assertEq(store.getKeyCount(), 1);
        assertEq(store.getKeyAt(0), key);
    }

    function testFuzz_history_length_equals_prior_nonempty_writes(
        uint8 rawCount
    ) public {
        // 1..8
        uint256 count = (uint256(rawCount) % 8) + 1;
        bytes32 key = keccak256("k");

        IUserStore store = _freshUserStore(ed);

        uint256 priorNonEmpty = 0;
        vm.startPrank(ed);
        for (uint256 i; i < count; ++i) {
            bytes memory value;
            if (i % 3 == 0) {
                // intentionally empty some of the time
                value = "";
            } else {
                // Safe because `count` is bounded to 1..8, so `i` is always < 8 here.
                // forge-lint: disable-next-line(unsafe-typecast)
                value = bytes(abi.encodePacked("v", uint8(i)));
            }

            // The PRIOR value dictates whether history grows. Capture it before the write.
            bool priorWasNonEmpty = store.getValue(key).length != 0;

            store.setValue(key, value);

            if (priorWasNonEmpty) ++priorNonEmpty;
        }
        vm.stopPrank();

        assertEq(store.getHistoryCount(key), priorNonEmpty);
    }

    function testFuzz_getHistory_pagination_consistent(
        uint8 rawVersions,
        uint256 offset,
        uint256 limit
    ) public {
        bytes32 key = keccak256("k");
        // rawVersions writes; each call after the first leaves one history entry, so
        // history length == rawVersions - 1 when every value is non-empty.
        // 2..9
        uint256 versions = (uint256(rawVersions) % 8) + 2;

        IUserStore store = _freshUserStore(ed);

        vm.startPrank(ed);
        for (uint256 i; i < versions; ++i) {
            // Safe because `versions` is bounded to 2..9, so `i` is always < 9 here.
            // forge-lint: disable-next-line(unsafe-typecast)
            store.setValue(key, bytes(abi.encodePacked("v", uint8(i))));
        }
        vm.stopPrank();

        uint256 total = versions - 1;
        offset = bound(offset, 0, total + 2);
        limit = bound(limit, 0, total + 2);

        IUserStore.Entry[] memory slice = store.getHistory(key, offset, limit);

        uint256 expected = 0;
        if (offset < total) {
            uint256 available = total - offset;
            expected = limit < available ? limit : available;
        }
        assertEq(slice.length, expected);
    }
}
