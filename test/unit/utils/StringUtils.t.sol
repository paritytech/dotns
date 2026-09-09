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

    function isPersonLabel(string calldata value) external pure returns (bool) {
        return value.isPersonLabel();
    }

    function isLitePersonLabel(string calldata value) external pure returns (bool) {
        return value.isLitePersonLabel();
    }

    function isLitePersonLabelMemory(string calldata value) external pure returns (bool) {
        return StringUtils.isLitePersonLabelMemory(value);
    }
}

/// @title StringUtilsTests
/// @notice Unit tests for the lite-label shape predicate and the letters-only name predicate.
/// @dev A lite label is the only shape in DotNS permitted to carry a separator, and its stem
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
    function _assertLite(string memory value, bool expected) internal view {
        bool fromCalldata = utils.isLitePersonLabel(value);
        bool fromMemory = utils.isLitePersonLabelMemory(value);
        assertEq(fromCalldata, fromMemory, "calldata and memory variants disagree");
        assertEq(fromCalldata, expected, value);
    }

    /// @notice The same letters-only rule a lite stem uses, applied to a whole label.
    /// @dev Mirrors the gateway pallet's `is_valid_person`, so a full-person label admits no
    ///      digits and no hyphens. No floor on length: that is the governance-reserved band.
    function test_isPersonLabel_accepts_letters_only() public view {
        assertTrue(utils.isPersonLabel("alicebob"));
        assertTrue(utils.isPersonLabel("a"));
        assertTrue(utils.isPersonLabel(_stem(63)));

        assertFalse(utils.isPersonLabel("alice-bob"), "no hyphens");
        assertFalse(utils.isPersonLabel("micha3l"), "no interior digits");
        assertFalse(utils.isPersonLabel("alicebob01"), "no digit suffix");
        assertFalse(utils.isPersonLabel("Alicebob"), "no uppercase");
        assertFalse(utils.isPersonLabel(""), "not empty");
        assertFalse(utils.isPersonLabel(_stem(64)), "bounded at 63 octets");
    }

    function test_isLitePersonLabel_accepts_the_dotted_shape() public view {
        _assertLite("joseph.42", true);
        _assertLite("joseph.00", true);
        _assertLite("elizabeth.42", true);
        _assertLite(string.concat(_stem(63), ".42"), true);
    }

    /// @dev The shape puts no floor on the stem: how short a name may be is policy, held by
    ///      PopRules as the governance-reserved band, so a short stem is a well-formed lite
    ///      label that classification then rejects.
    function test_isLitePersonLabel_puts_no_floor_on_the_stem() public view {
        _assertLite("a.42", true);
        _assertLite("josep.42", true);
        _assertLite(string.concat(_stem(1), ".42"), true);
    }

    /// @dev The stem is the name a person chose, which People Chain restricts to lowercase
    ///      letters, so it is stricter than a DNS label: no digits, no hyphens, no uppercase.
    function test_isLitePersonLabel_requires_a_letters_only_stem() public view {
        _assertLite("alice-bob.99", false);
        _assertLite("josep4.42", false);
        _assertLite("jos3ph.42", false);
        _assertLite("joseph1.42", false);
        _assertLite("Joseph.42", false);
    }

    function test_isLitePersonLabel_rejects_a_missing_or_repeated_separator() public view {
        _assertLite("joseph42", false);
        _assertLite("jos.eph.42", false);
        _assertLite(".42", false);
        _assertLite("joseph.", false);
    }

    function test_isLitePersonLabel_rejects_any_suffix_but_two_digits() public view {
        _assertLite("joseph.4", false);
        _assertLite("joseph.123", false);
        _assertLite("joseph.4x", false);
        _assertLite("joseph.x4", false);
    }

    function test_isLitePersonLabel_rejects_a_non_canonical_stem() public view {
        _assertLite("jos_eph.42", false);
        _assertLite("-joseph.42", false);
        _assertLite("joseph-.42", false);
        _assertLite(string.concat(_stem(64), ".42"), false);
    }

    function test_isLitePersonLabel_rejects_the_empty_string() public view {
        _assertLite("", false);
    }

    /// @dev The bound moved from the whole label to the stem, so a lite label runs three octets
    ///      past the single-label limit. Pinned because it is a deliberate widening.
    function test_isLitePersonLabel_bounds_the_stem_not_the_whole_label() public view {
        string memory longest = string.concat(_stem(63), ".42");
        assertEq(bytes(longest).length, 66, "longest lite label is 66 octets");
        _assertLite(longest, true);
        assertFalse(utils.isSingleLabel(longest), "a lite label is not a single DNS label");
    }
}
