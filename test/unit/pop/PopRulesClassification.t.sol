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
    /// @notice Guard message for a string that is neither a DNS label nor a device name.
    string internal constant SHAPE_ERROR =
        "Name must be a lowercase ASCII DNS label or a device name";

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

    /// @dev Base length is the length of the base name, so a two-digit suffix does not count
    ///      towards the band whether or not it carries the gateway's separator.
    function test_classify_measures_a_device_name_by_its_stem() public view {
        _assertTier("alice.42", IPopRules.PopStatus.Reserved);
        _assertTier("joseph.42", IPopRules.PopStatus.Devicehood);
        _assertTier("benjamin.42", IPopRules.PopStatus.Devicehood);
        _assertTier("elizabeth.42", IPopRules.PopStatus.NoStatus);
    }

    /// @notice The separator is meaning, not presentation: it is what makes a name an identity.
    /// @dev A device name is measured by the stem the candidate chose, because the gateway
    ///      allocated the digits. An ordinary label is measured as written. So the two spellings
    ///      are different names in different bands, and only the separated one is Devicehood.
    function test_classify_differs_with_and_without_the_separator() public view {
        _assertTier("joseph.42", IPopRules.PopStatus.Devicehood);
        _assertTier("joseph42", IPopRules.PopStatus.Personhood);

        _assertTier("michael.01", IPopRules.PopStatus.Devicehood);
        _assertTier("michael01", IPopRules.PopStatus.NoStatus);

        _assertTier("elizabeth.42", IPopRules.PopStatus.NoStatus);
        _assertTier("elizabeth42", IPopRules.PopStatus.NoStatus);
    }

    /// @notice The regression test for deriving the digit count by subtraction.
    /// @dev `bytes(name).length - baseLength` is 3 for a device name, never 2, so a subtraction
    ///      based check classifies every device name in the 6-8 band as Personhood. These rows
    ///      catch it, which is why they assert Devicehood rather than merely "not Reserved".
    function test_classify_puts_a_device_name_in_the_devicehood_tier_not_the_personhood_tier()
        public
        view
    {
        (IPopRules.PopStatus sixChar,) = rules.classifyName("joseph.42");
        assertEq(uint256(sixChar), uint256(IPopRules.PopStatus.Devicehood), "stem 6 is Devicehood");

        (IPopRules.PopStatus eightChar,) = rules.classifyName("benjamin.42");
        assertEq(
            uint256(eightChar), uint256(IPopRules.PopStatus.Devicehood), "stem 8 is Devicehood"
        );
    }

    function test_classify_measures_a_label_without_a_suffix_whole() public view {
        _assertTier("alice", IPopRules.PopStatus.Reserved);
        _assertTier("joseph", IPopRules.PopStatus.Personhood);
        _assertTier("benjamin", IPopRules.PopStatus.Personhood);
        _assertTier("elizabeth", IPopRules.PopStatus.NoStatus);
    }

    /// @dev An ordinary name carrying digits stays registrable, measured as written.
    function test_classify_accepts_an_ordinary_flat_digit_suffix() public view {
        _assertTier("longnamebob01", IPopRules.PopStatus.NoStatus);
        _assertTier("lights01", IPopRules.PopStatus.Personhood);
    }

    /// @dev No digit count is privileged or rejected, and none is stripped: a name ending in
    ///      digits is measured as written, whatever the count.
    function test_classify_accepts_a_flat_suffix_of_any_length() public view {
        _assertTier("iamtherealbob0", IPopRules.PopStatus.NoStatus);
        _assertTier("elizabeth12345", IPopRules.PopStatus.NoStatus);
        _assertTier("blink182", IPopRules.PopStatus.Personhood);
        _assertTier("web3", IPopRules.PopStatus.Reserved);
    }

    /// @dev A device name's suffix is fixed by its shape, so a wrong count fails the shape check
    ///      before the count check can see it.
    /// @dev A separator is legal only on a device name, so a string carrying one that misses
    ///      the shape in any way is neither a DNS label nor a device name.
    function test_classify_reverts_for_a_malformed_device_name() public {
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

    /// @dev Only a device name is shortened, so `joseph.42` contends with a reservation on
    ///      `joseph` while `joseph42` is an unrelated name that contends with nothing.
    function test_stripDigits_shortens_only_the_separated_form() public view {
        assertEq(rules.stripDigits("joseph.42"), "joseph");
        assertEq(rules.stripDigits("joseph42"), "joseph42");
        assertEq(rules.stripDigits("blink182"), "blink182");
    }

    /// @dev A base name returned as `joseph.` would fail `isSingleLabelMemory` in the registrar
    ///      controller and silently skip the reclaim branch's reservation release.
    function test_stripDigits_leaves_no_trailing_separator() public view {
        string memory baseName = rules.stripDigits("joseph.42");
        bytes memory raw = bytes(baseName);
        assertTrue(raw.length > 0, "base name is not empty");
        assertTrue(raw[raw.length - 1] != ".", "base name carries no trailing separator");
    }

    function test_stripDigits_returns_a_suffixless_label_verbatim() public view {
        assertEq(rules.stripDigits("elizabeth"), "elizabeth");
    }

    /// @dev Must answer the question rather than revert, since the controller asks it of
    ///      labels that may be device-name.
    function test_isBaseName_answers_false_for_a_device_name() public view {
        assertFalse(rules.isBaseName("joseph.42"));
        assertTrue(rules.isBaseName("elizabeth"));
    }
}
