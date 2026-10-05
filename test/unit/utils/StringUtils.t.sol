// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {StringUtils} from "../../../contracts/utils/StringUtils.sol";

/// @title StringUtilsHarness
/// @notice Exposes the library's internal validators as external functions so tests can call
///         them across both data locations.
/// @dev The `Memory` wrapper takes `calldata` and forwards it, which is what produces the
///      calldata-to-memory copy the controller paths rely on.
contract StringUtilsHarness {
    using StringUtils for *;

    function isSingleLabel(string calldata value) external pure returns (bool) {
        return value.isSingleLabel();
    }

    function isPersonhoodLabel(string calldata value) external pure returns (bool) {
        return value.isPersonhoodLabel();
    }

    function isDeviceLabel(string calldata value) external pure returns (bool) {
        return value.isDeviceLabel();
    }

    function isDeviceLabelMemory(string calldata value) external pure returns (bool) {
        return StringUtils.isDeviceLabelMemory(value);
    }

    function isNamePath(string calldata value) external pure returns (bool) {
        return value.isNamePath();
    }
}

/// @title StringUtilsTests
/// @notice Unit tests for the device-name shape predicate and the letters-only name predicate.
/// @dev A device name is the only shape in dotNS permitted to carry a separator, and its stem
///      is letters only, which is stricter than a DNS label. A digit suffix is not exclusive:
///      an ordinary label may end in digits. These tests are the definition of that boundary.
contract StringUtilsTests is Test {
    StringUtilsHarness internal utils;

    function setUp() public {
        utils = new StringUtilsHarness();
    }

    /// @notice Builds a string of `count` repetitions of "a".
    function _stem(uint256 count) internal pure returns (string memory) {
        bytes memory out = new bytes(count);
        for (uint256 i = 0; i < count; ++i) {
            out[i] = "a";
        }
        return string(out);
    }

    /// @notice Asserts both data locations agree, then that they agree with `expected`.
    function _assertDeviceLabel(string memory value, bool expected) internal view {
        bool fromCalldata = utils.isDeviceLabel(value);
        bool fromMemory = utils.isDeviceLabelMemory(value);
        assertEq(fromCalldata, fromMemory, "calldata and memory variants disagree");
        assertEq(fromCalldata, expected, value);
    }

    /// @notice The same letters-only rule a device-name stem uses, applied to a whole label.
    /// @dev Mirrors the gateway pallet's `is_valid_person`, so a personhood name admits no
    ///      digits and no hyphens. No floor on length: that is the governance-reserved band.
    function test_isPersonhoodLabel_accepts_letters_only() public view {
        assertTrue(utils.isPersonhoodLabel("alicebob"));
        assertTrue(utils.isPersonhoodLabel("a"));
        assertTrue(utils.isPersonhoodLabel(_stem(63)));

        assertFalse(utils.isPersonhoodLabel("alice-bob"), "no hyphens");
        assertFalse(utils.isPersonhoodLabel("micha3l"), "no interior digits");
        assertFalse(utils.isPersonhoodLabel("alicebob01"), "no digit suffix");
        assertFalse(utils.isPersonhoodLabel("Alicebob"), "no uppercase");
        assertFalse(utils.isPersonhoodLabel(""), "not empty");
        assertFalse(utils.isPersonhoodLabel(_stem(64)), "bounded at 63 octets");
    }

    function test_isDeviceLabel_accepts_the_dotted_shape() public view {
        _assertDeviceLabel("joseph.42", true);
        _assertDeviceLabel("joseph.00", true);
        _assertDeviceLabel("elizabeth.42", true);
        _assertDeviceLabel(string.concat(_stem(63), ".42"), true);
    }

    /// @dev The shape puts no floor on the stem: how short a name may be is policy, held by
    ///      PopRules as the governance-reserved band, so a short stem is a well-formed device-name
    ///      label that classification then rejects.
    function test_isDeviceLabel_puts_no_floor_on_the_stem() public view {
        _assertDeviceLabel("a.42", true);
        _assertDeviceLabel("josep.42", true);
        _assertDeviceLabel(string.concat(_stem(1), ".42"), true);
    }

    /// @dev The stem is the name a person chose, which People Chain restricts to lowercase
    ///      letters, so it is stricter than a DNS label: no digits, no hyphens, no uppercase.
    function test_isDeviceLabel_requires_a_letters_only_stem() public view {
        _assertDeviceLabel("alice-bob.99", false);
        _assertDeviceLabel("josep4.42", false);
        _assertDeviceLabel("jos3ph.42", false);
        _assertDeviceLabel("joseph1.42", false);
        _assertDeviceLabel("Joseph.42", false);
    }

    function test_isDeviceLabel_rejects_a_missing_or_repeated_separator() public view {
        _assertDeviceLabel("joseph42", false);
        _assertDeviceLabel("jos.eph.42", false);
        _assertDeviceLabel(".42", false);
        _assertDeviceLabel("joseph.", false);
    }

    function test_isDeviceLabel_rejects_any_suffix_but_two_digits() public view {
        _assertDeviceLabel("joseph.4", false);
        _assertDeviceLabel("joseph.123", false);
        _assertDeviceLabel("joseph.4x", false);
        _assertDeviceLabel("joseph.x4", false);
    }

    function test_isDeviceLabel_rejects_a_non_canonical_stem() public view {
        _assertDeviceLabel("jos_eph.42", false);
        _assertDeviceLabel("-joseph.42", false);
        _assertDeviceLabel("joseph-.42", false);
        _assertDeviceLabel(string.concat(_stem(64), ".42"), false);
    }

    function test_isDeviceLabel_rejects_the_empty_string() public view {
        _assertDeviceLabel("", false);
    }

    /// @dev The bound moved from the whole label to the stem, so a device name runs three octets
    ///      past the single-label limit. Pinned because it is a deliberate widening.
    function test_isDeviceLabel_bounds_the_stem_not_the_whole_label() public view {
        string memory longest = string.concat(_stem(63), ".42");
        assertEq(bytes(longest).length, 66, "longest device name is 66 octets");
        _assertDeviceLabel(longest, true);
        assertFalse(utils.isSingleLabel(longest), "a device name is not a single DNS label");
    }

    /// @notice A path of exactly @custom:constant StringUtils.MAX_NAME_PATH_OCTETS octets passes.
    /// @dev The per-segment bound leaves the path itself unbounded, and `setSubnodeOwner` stores
    ///      the full name composed from a caller's path in a `LabelStore` row that has no delete
    ///      path. The two cases below are what fix that ceiling: moving the constant without
    ///      moving them is a failing build.
    function test_isNamePath_accepts_a_path_at_the_ceiling() public view {
        string memory segment = _stem(63);
        string memory path = string.concat(segment, ".", segment, ".", segment, ".", segment);
        assertEq(bytes(path).length, StringUtils.MAX_NAME_PATH_OCTETS, "fixture is not at the cap");
        assertTrue(utils.isNamePath(path));
    }

    /// @notice One octet over the ceiling is refused, with every segment individually legal so
    ///         the refusal cannot come from the per-segment bound.
    function test_isNamePath_rejects_a_path_one_octet_over_the_ceiling() public view {
        string memory segment = _stem(63);
        string memory path =
            string.concat(segment, ".", segment, ".", segment, ".", _stem(62), ".", _stem(1));
        assertEq(
            bytes(path).length, StringUtils.MAX_NAME_PATH_OCTETS + 1, "fixture is not one over"
        );
        assertFalse(utils.isNamePath(path));
    }
}
