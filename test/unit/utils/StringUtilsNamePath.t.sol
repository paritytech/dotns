// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {StringUtils} from "../../../contracts/utils/StringUtils.sol";

/// @notice Exposes the calldata-only validator so the boundary can be driven directly.
contract NamePathHarness {
    function isNamePath(string calldata value) external pure returns (bool isValid) {
        return StringUtils.isNamePath(value);
    }
}

/// @title StringUtilsNamePathTests
/// @notice Pins the whole-path octet ceiling on @custom:function StringUtils.isNamePath.
/// @dev The per-segment bound alone leaves the path unbounded, and
///      @custom:function DotnsRegistry.setSubnodeOwner composes the stored full name out of the
///      caller's `parentLabel`. A `LabelStore` row has no delete path, so an oversized name is a
///      permanent cost on every enumeration that reads it back. Nothing else in the suite fixes
///      this ceiling, so the two cases below are what stop it drifting.
contract StringUtilsNamePathTests is Test {
    NamePathHarness private harness;

    function setUp() public {
        harness = new NamePathHarness();
    }

    /// @notice A path of exactly `MAX_NAME_PATH_OCTETS` octets is still accepted.
    function test_accepts_a_path_at_the_ceiling() public view {
        string memory path = _join(63, 63, 63, 63, 0);
        assertEq(bytes(path).length, StringUtils.MAX_NAME_PATH_OCTETS, "fixture is not at the cap");
        assertTrue(harness.isNamePath(path));
    }

    /// @notice One octet over the ceiling is rejected, with every segment individually legal so
    ///         the refusal cannot come from the per-segment bound.
    function test_rejects_a_path_one_octet_over_the_ceiling() public view {
        string memory path = _join(63, 63, 63, 62, 1);
        assertEq(
            bytes(path).length, StringUtils.MAX_NAME_PATH_OCTETS + 1, "fixture is not one over"
        );
        assertFalse(harness.isNamePath(path));
    }

    /// @notice Joins up to five `a`-runs with dots, skipping any zero-length segment.
    function _join(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d,
        uint256 e
    )
        private
        pure
        returns (string memory path)
    {
        path = _run(a);
        if (b != 0) path = string.concat(path, ".", _run(b));
        if (c != 0) path = string.concat(path, ".", _run(c));
        if (d != 0) path = string.concat(path, ".", _run(d));
        if (e != 0) path = string.concat(path, ".", _run(e));
    }

    /// @notice A run of `count` lowercase `a` octets, which is a canonical DNS label up to 63.
    function _run(uint256 count) private pure returns (string memory run) {
        bytes memory buffer = new bytes(count);
        for (uint256 i = 0; i < count; ++i) {
            buffer[i] = "a";
        }
        run = string(buffer);
    }
}
