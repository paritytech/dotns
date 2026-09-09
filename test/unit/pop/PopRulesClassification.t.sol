// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {PopRules} from "../../../contracts/pop/PopRules.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

/// @title PopRulesClassificationTests
/// @notice Unit tests for label shape and tier classification.
/// @dev Runs against the implementation directly rather than a proxy: classification is `pure`
///      and reads no storage, so a tier is a function of the label alone. Anything that needs a
///      cost model or a reservation belongs in the proxy-backed suite instead.
contract PopRulesClassificationTests is Test {
    /// @notice Guard message for a string that is neither a DNS label nor a lite label.
    string internal constant SHAPE_ERROR =
        "Name must be a lowercase ASCII DNS label or a lite label";

    PopRules internal rules;

    function setUp() public {
        rules = new PopRules();
    }

    function _assertTier(string memory name, IPopRules.PopStatus expected) internal view {
        (IPopRules.PopStatus actual,) = rules.classifyName(name);
        assertEq(uint256(actual), uint256(expected), name);
    }

    function _expectRevert(string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(IPopRules.PopError.selector, reason));
    }

    /// @dev Base length is the stem, so a two-digit suffix does not count towards the band
    ///      whether or not it carries the gateway's separator.
    function test_classify_measures_a_lite_label_by_its_stem() public view {
        _assertTier("alice.42", IPopRules.PopStatus.Reserved);
        _assertTier("joseph.42", IPopRules.PopStatus.PopLite);
        _assertTier("benjamin.42", IPopRules.PopStatus.PopLite);
        _assertTier("elizabeth.42", IPopRules.PopStatus.NoStatus);
    }

    /// @notice The separator is meaning, not presentation: it is what makes a name an identity.
    /// @dev A lite label is measured by the stem the candidate chose, because the gateway
    ///      allocated the digits. An ordinary label is measured as written. So the two spellings
    ///      are different names in different bands, and only the separated one is PopLite.
    function test_classify_differs_with_and_without_the_separator() public view {
        _assertTier("joseph.42", IPopRules.PopStatus.PopLite);
        _assertTier("joseph42", IPopRules.PopStatus.PopFull);

        _assertTier("michael.01", IPopRules.PopStatus.PopLite);
        _assertTier("michael01", IPopRules.PopStatus.NoStatus);

        _assertTier("elizabeth.42", IPopRules.PopStatus.NoStatus);
        _assertTier("elizabeth42", IPopRules.PopStatus.NoStatus);
    }

    /// @notice The regression test for deriving the digit count by subtraction.
    /// @dev `bytes(name).length - baseLength` is 3 for a lite label, never 2, so a subtraction
    ///      based check classifies every lite name in the 6-8 band as PopFull. These rows catch
    ///      it, which is why they assert PopLite rather than merely "not Reserved".
    function test_classify_puts_a_lite_label_in_the_lite_tier_not_the_full_tier() public view {
        (IPopRules.PopStatus sixChar,) = rules.classifyName("joseph.42");
        assertEq(uint256(sixChar), uint256(IPopRules.PopStatus.PopLite), "stem 6 is PopLite");

        (IPopRules.PopStatus eightChar,) = rules.classifyName("benjamin.42");
        assertEq(uint256(eightChar), uint256(IPopRules.PopStatus.PopLite), "stem 8 is PopLite");
    }

    function test_classify_measures_a_label_without_a_suffix_whole() public view {
        _assertTier("alice", IPopRules.PopStatus.Reserved);
        _assertTier("joseph", IPopRules.PopStatus.PopFull);
        _assertTier("benjamin", IPopRules.PopStatus.PopFull);
        _assertTier("elizabeth", IPopRules.PopStatus.NoStatus);
    }

    /// @dev An ordinary name carrying digits stays registrable, measured as written.
    function test_classify_accepts_an_ordinary_flat_digit_suffix() public view {
        _assertTier("longnamebob01", IPopRules.PopStatus.NoStatus);
        _assertTier("lights01", IPopRules.PopStatus.PopFull);
    }

    /// @dev No digit count is privileged or rejected, and none is stripped: a name ending in
    ///      digits is measured as written, whatever the count.
    function test_classify_accepts_a_flat_suffix_of_any_length() public view {
        _assertTier("iamtherealbob0", IPopRules.PopStatus.NoStatus);
        _assertTier("elizabeth12345", IPopRules.PopStatus.NoStatus);
        _assertTier("blink182", IPopRules.PopStatus.PopFull);
        _assertTier("web3", IPopRules.PopStatus.Reserved);
    }

    /// @dev A lite label's suffix is fixed by its shape, so a wrong count fails the shape check
    ///      before the count check can see it.
    /// @dev A separator is legal only on a lite label, so a string carrying one that misses
    ///      the shape in any way is neither a DNS label nor a lite label.
    function test_classify_reverts_for_a_malformed_lite_label() public {
        _expectRevert(SHAPE_ERROR);
        rules.classifyName("joseph.4");

        _expectRevert(SHAPE_ERROR);
        rules.classifyName("joseph.123");

        _expectRevert(SHAPE_ERROR);
        rules.classifyName("jos.eph.42");

        // A digit in the stem, which the letters-only rule excludes.
        _expectRevert(SHAPE_ERROR);
        rules.classifyName("jos3ph.42");
    }

    /// @dev Only a lite label is shortened, so `joseph.42` contends with a reservation on
    ///      `joseph` while `joseph42` is an unrelated name that contends with nothing.
    function test_stripDigits_shortens_only_the_separated_form() public view {
        assertEq(rules.stripDigits("joseph.42"), "joseph");
        assertEq(rules.stripDigits("joseph42"), "joseph42");
        assertEq(rules.stripDigits("blink182"), "blink182");
    }

    /// @dev A stem returned as `joseph.` would fail `isSingleLabelMemory` in the registrar
    ///      controller and silently skip the reclaim branch's reservation release.
    function test_stripDigits_leaves_no_trailing_separator() public view {
        string memory stem = rules.stripDigits("joseph.42");
        bytes memory raw = bytes(stem);
        assertTrue(raw.length > 0, "stem is not empty");
        assertTrue(raw[raw.length - 1] != ".", "stem carries no trailing separator");
    }

    function test_stripDigits_returns_a_suffixless_label_verbatim() public view {
        assertEq(rules.stripDigits("elizabeth"), "elizabeth");
    }

    /// @dev Must answer the question rather than revert, since the controller asks it of
    ///      labels that may be lite.
    function test_isBaseName_answers_false_for_a_lite_label() public view {
        assertFalse(rules.isBaseName("joseph.42"));
        assertTrue(rules.isBaseName("elizabeth"));
    }
}
