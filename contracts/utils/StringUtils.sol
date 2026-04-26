// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title String Utilities Library
/// @notice Provides string manipulation utilities for DotNS contracts.
/// @dev Extends OpenZeppelin's Strings library with additional UTF-8 and conversion helpers.
/// @custom:security-contact admin@parity.io
library StringUtils {
    using Strings for uint256;
    using Strings for int256;
    using Strings for address;

    /// @notice Minimum number of trailing digits required in a lite-person PoP label
    ///         suffix.
    /// @dev Matches `pallet_resources::MIN_LITE_USERNAME_DIGITS` to avoid drift between
    ///      what People Chain emits and what DotNS accepts.
    uint256 internal constant MIN_LITE_SUFFIX_DIGITS = 2;

    /// @notice Computes the character length of a UTF-8 encoded string.
    /// @dev Counts Unicode code points, not bytes. Handles multi-byte UTF-8 sequences:
    ///      - 1 byte:  0x00-0x7F (ASCII)
    ///      - 2 bytes: 0xC0-0xDF
    ///      - 3 bytes: 0xE0-0xEF
    ///      - 4 bytes: 0xF0-0xF7
    ///      - 5 bytes: 0xF8-0xFB (rare, outside Unicode standard)
    ///      - 6 bytes: 0xFC-0xFD (rare, outside Unicode standard)
    /// @param s The UTF-8 encoded string to measure.
    /// @return len The number of Unicode characters in the string.
    function strlen(string memory s) internal pure returns (uint256 len) {
        uint256 i = 0;
        uint256 bytelength = bytes(s).length;
        for (len = 0; i < bytelength; len++) {
            bytes1 b = bytes(s)[i];
            if (b < 0x80) i += 1;
            else if (b < 0xE0) i += 2;
            else if (b < 0xF0) i += 3;
            else if (b < 0xF8) i += 4;
            else if (b < 0xFC) i += 5;
            else i += 6;
        }
    }

    /// @notice Validates that `s` is a single canonical DNS label.
    /// @dev Lowercase ASCII letters, digits, and hyphen only; hyphen may not be
    ///      the first or last character. No dots allowed; use {isNamePath} for
    ///      dotted forms. Mirrors the label rules enforced at the registrar.
    /// @param s Candidate label.
    /// @return isValid True if `s` is a canonical DNS label.
    function isSingleLabel(string calldata s) internal pure returns (bool isValid) {
        bytes calldata label = bytes(s);
        return _isDnsLabel(label, 0, label.length);
    }

    /// @notice Validates the lite-person PoP label format: `<stem><digits>`.
    /// @dev A lite-person label is a single DNS label whose trailing characters are
    ///      digits, with at least {MIN_LITE_SUFFIX_DIGITS} digits at the tail. Mirrors
    ///      `pallet_resources::MIN_LITE_USERNAME_DIGITS`. Lite and public registrations
    ///      share the same namespace; the gateway strips any separator before calling
    ///      so the on-chain label is a flat DNS label (e.g. `alice42`). First-to-mint
    ///      wins at the ERC721 layer; cross-flow priority on the stripped stem is
    ///      arbitrated by {IPopRules.reserveBaseNameForPop}. Keeping a single
    ///      namespace avoids the ambiguity dotli/dweb would otherwise see between
    ///      `andrew.47` (lite) and `andrew` owning `47` as a subname.
    /// @param s Candidate label.
    /// @return isValid True if the label is a DNS label with at least
    ///         {MIN_LITE_SUFFIX_DIGITS} trailing digits.
    function isLitePersonLabel(string calldata s) internal pure returns (bool isValid) {
        bytes calldata raw = bytes(s);
        uint256 length = raw.length;
        if (length < MIN_LITE_SUFFIX_DIGITS + 1) return false;

        if (!_isDnsLabel(raw, 0, length)) return false;

        // Count trailing digits from the right; reject if fewer than the minimum.
        uint256 trailingDigits;
        for (uint256 i = length; i > 0; --i) {
            bytes1 char = raw[i - 1];
            if (char < bytes1(0x30) || char > bytes1(0x39)) break;
            unchecked {
                ++trailingDigits;
            }
        }
        return trailingDigits >= MIN_LITE_SUFFIX_DIGITS;
    }

    /// @notice Validates that `s` is a dot-separated path of canonical DNS labels.
    /// @dev Each segment between dots must satisfy {isSingleLabel}. Empty
    ///      segments (leading, trailing, or consecutive dots) fail. Used when
    ///      callers submit multi-label paths (e.g. `alice.dot`) rather than
    ///      bare labels.
    /// @param s Candidate name path.
    /// @return isValid True if every dot-separated segment is a canonical DNS label.
    function isNamePath(string calldata s) internal pure returns (bool isValid) {
        bytes calldata path = bytes(s);
        uint256 length = path.length;
        if (length == 0) return false;

        uint256 start = 0;
        for (uint256 i = 0; i < length; ++i) {
            if (path[i] != bytes1(0x2e)) continue;
            if (!_isDnsLabel(path, start, i)) return false;
            start = i + 1;
        }

        return _isDnsLabel(path, start, length);
    }

    function _isDnsLabel(
        bytes calldata label,
        uint256 start,
        uint256 end
    )
        private
        pure
        returns (bool isValid)
    {
        if (end <= start) return false;
        if (label[start] == bytes1(0x2d) || label[end - 1] == bytes1(0x2d)) return false;

        for (uint256 i = start; i < end; ++i) {
            bytes1 char = label[i];
            bool isLowercase = char >= 0x61 && char <= 0x7a;
            bool isDigit = char >= 0x30 && char <= 0x39;
            if (!(isLowercase || isDigit || char == bytes1(0x2d))) return false;
        }

        return true;
    }

    /// @notice Converts a uint256 to its decimal string representation.
    /// @dev Wraps OpenZeppelin's Strings.toString().
    /// @param value The unsigned integer to convert.
    /// @return The decimal string representation.
    function uintToString(uint256 value) internal pure returns (string memory) {
        return value.toString();
    }

    /// @notice Converts an address to its checksummed hexadecimal string representation.
    /// @dev Wraps OpenZeppelin's Strings.toHexString(). Returns lowercase hex with "0x" prefix.
    /// @param a The address to convert.
    /// @return The hexadecimal string representation (42 characters including "0x").
    function addressToHex(address a) internal pure returns (string memory) {
        return a.toHexString();
    }

    /// @notice Converts a bytes32 value to a string, treating it as a null-terminated ASCII string.
    /// @dev Reads bytes until the first null byte (0x00) or end of bytes32.
    ///      Useful for converting short strings stored in bytes32 back to string type.
    /// @param _bytes32 The bytes32 value containing a null-terminated ASCII string.
    /// @return The extracted string (up to 32 characters).
    function bytes32ToString(bytes32 _bytes32) internal pure returns (string memory) {
        uint8 i = 0;
        while (i < 32 && _bytes32[i] != 0) {
            i++;
        }
        bytes memory bytesArray = new bytes(i);
        for (uint8 j = 0; j < i; j++) {
            bytesArray[j] = _bytes32[j];
        }
        return string(bytesArray);
    }
}
