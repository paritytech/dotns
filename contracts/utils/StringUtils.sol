// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

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

    /// @notice Maximum number of octets in a single DNS label.
    /// @dev RFC 1035 caps each label at 63 octets. Enforced inside @custom:function _isDnsLabel so
    ///      every public validator (@custom:function isSingleLabel, @custom:function isNamePath,
    ///      @custom:function isSingleDotLiteLabel, @custom:function isLitePersonLabel) inherits
    ///      the bound and oversized labels never reach the registrar.
    uint256 internal constant MAX_DNS_LABEL_OCTETS = 63;

    /// @notice Computes the character length of a UTF-8 encoded string.
    /// @dev Counts Unicode code points, not bytes. Handles multi-byte UTF-8 sequences:
    ///      - 1 byte:  0x00-0x7F (ASCII)
    ///      - 2 bytes: 0xC0-0xDF
    ///      - 3 bytes: 0xE0-0xEF
    ///      - 4 bytes: 0xF0-0xF7
    ///      - 5 bytes: 0xF8-0xFB (rare, outside Unicode standard)
    ///      - 6 bytes: 0xFC-0xFD (rare, outside Unicode standard)
    /// @param value The UTF-8 encoded string to measure.
    /// @return len The number of Unicode characters in the string.
    function strlen(string memory value) internal pure returns (uint256 len) {
        uint256 i = 0;
        uint256 bytelength = bytes(value).length;
        for (len = 0; i < bytelength; len++) {
            bytes1 byteValue = bytes(value)[i];
            if (byteValue < 0x80) i += 1;
            else if (byteValue < 0xE0) i += 2;
            else if (byteValue < 0xF0) i += 3;
            else if (byteValue < 0xF8) i += 4;
            else if (byteValue < 0xFC) i += 5;
            else i += 6;
        }
    }

    /// @notice Validates that `s` is a single canonical DNS label.
    /// @dev Lowercase ASCII letters, digits, and hyphen only; hyphen may not be the first or last
    ///      character; length must be in `(0, MAX_DNS_LABEL_OCTETS]`. No dots allowed; use
    ///      @custom:function isNamePath for dotted forms. Mirrors the label rules enforced at the
    ///      registrar.
    /// @param value Candidate label.
    /// @return isValid True if `value` is a canonical DNS label.
    function isSingleLabel(string calldata value) internal pure returns (bool isValid) {
        bytes memory label = bytes(value);
        return _isDnsLabel(label, 0, label.length);
    }

    /// @notice Memory-location helper for @custom:function isSingleLabel, used where the
    /// candidate label is produced by an upstream string transformation (e.g. the output of
    /// @custom:function stripDigits) so callers do not need a calldata round-trip.
    /// @param value Candidate label held in memory.
    /// @return isValid True if `value` is a canonical DNS label.
    function isSingleLabelMemory(string memory value) internal pure returns (bool isValid) {
        bytes memory label = bytes(value);
        return _isDnsLabel(label, 0, label.length);
    }

    /// @notice Removes dot separators from a dotted label.
    /// @dev Used by the PoP gateway boundary to normalise user-facing
    ///      `name.path` input into the flat label expected by pricing and minting.
    /// @param value Candidate dotted label.
    /// @return stripped Label with all dots removed.
    function stripDots(string calldata value) internal pure returns (string memory stripped) {
        bytes calldata raw = bytes(value);
        uint256 length = raw.length;
        uint256 outputLength;

        for (uint256 i = 0; i < length; ++i) {
            if (raw[i] != bytes1(0x2e)) {
                ++outputLength;
            }
        }

        bytes memory cleaned = new bytes(outputLength);
        uint256 outputIndex;
        for (uint256 i = 0; i < length; ++i) {
            bytes1 char = raw[i];
            if (char == bytes1(0x2e)) continue;
            cleaned[outputIndex] = char;
            ++outputIndex;
        }

        stripped = string(cleaned);
    }

    /// @notice Validates the gateway-facing lite input shape: `stem.suffix`.
    /// @dev Requires exactly one dot separator. The left segment must be a canonical DNS
    ///      label and the right segment must be digits-only with exactly
    ///      @custom:constant MIN_LITE_SUFFIX_DIGITS characters.
    /// @param value Candidate dotted lite label.
    /// @return isValid True when `value` matches the gateway lite input shape.
    function isSingleDotLiteLabel(string calldata value) internal pure returns (bool isValid) {
        bytes calldata raw = bytes(value);
        uint256 length = raw.length;
        if (length == 0) return false;

        uint256 separator = type(uint256).max;
        for (uint256 i = 0; i < length; ++i) {
            if (raw[i] != bytes1(0x2e)) continue;
            if (separator != type(uint256).max) return false;
            separator = i;
        }

        if (separator == type(uint256).max) return false;
        if (separator == 0 || separator + 1 >= length) return false;

        bytes memory stem = new bytes(separator);
        for (uint256 i = 0; i < separator; ++i) {
            stem[i] = raw[i];
        }
        if (!_isDnsLabel(stem, 0, separator)) return false;

        uint256 suffixLength = length - separator - 1;
        if (suffixLength != MIN_LITE_SUFFIX_DIGITS) return false;

        for (uint256 i = separator + 1; i < length; ++i) {
            bytes1 char = raw[i];
            if (char < bytes1(0x30) || char > bytes1(0x39)) return false;
        }

        return true;
    }

    /// @notice Validates the lite-person PoP label format: `<stem><digits>`.
    /// @dev A lite-person label is a single DNS label whose trailing characters are
    ///      digits, with at least @custom:constant MIN_LITE_SUFFIX_DIGITS digits at the tail. It
    /// Mirrors @custom:pallet `pallet_resources::MIN_LITE_USERNAME_DIGITS`. Lite and public
    /// registrations
    ///      share the same namespace; the gateway strips any separator before calling
    ///      so the on-chain label is a flat DNS label (e.g. `alice42`). First-to-mint
    ///      wins at the ERC721 layer; cross-flow priority on the stripped stem is
    ///      arbitrated by @custom:function IPopRules.reserveBaseNameForPop. Keeping a single
    ///      namespace avoids the ambiguity dotli/dweb would otherwise see between
    ///      `andrew.47` (lite) and `andrew` owning `47` as a subname.
    /// @param value Candidate label.
    /// @return isValid True if the label is a DNS label with at least
    ///         @custom:constant MIN_LITE_SUFFIX_DIGITS  trailing digits.
    function isLitePersonLabel(string calldata value) internal pure returns (bool isValid) {
        return _isLitePersonLabel(bytes(value));
    }

    /// @notice Memory-location helper for @custom:function isLitePersonLabel, used by
    /// controller-side normalisation paths.
    /// @param value Candidate label held in memory.
    /// @return isValid True if the label is a DNS label with at least
    ///         @custom:constant MIN_LITE_SUFFIX_DIGITS trailing digits.
    function isLitePersonLabelMemory(string memory value) internal pure returns (bool isValid) {
        return _isLitePersonLabel(bytes(value));
    }

    function _isLitePersonLabel(bytes memory raw) private pure returns (bool isValid) {
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
    /// @dev Each segment between dots must satisfy @custom:function isSingleLabel. Empty
    ///      segments (leading, trailing, or consecutive dots) fail. Used when
    ///      callers submit multi-label paths (e.g. `alice.dot`) rather than
    ///      bare labels.
    /// @param value Candidate name path.
    /// @return isValid True if every dot-separated segment is a canonical DNS label.
    function isNamePath(string calldata value) internal pure returns (bool isValid) {
        bytes memory path = bytes(value);
        uint256 length = path.length;
        if (length == 0) return false;

        uint256 start;
        for (uint256 i = 0; i < length; ++i) {
            if (path[i] != bytes1(0x2e)) continue;
            if (!_isDnsLabel(path, start, i)) return false;
            start = i + 1;
        }

        return _isDnsLabel(path, start, length);
    }

    function _isDnsLabel(
        bytes memory label,
        uint256 start,
        uint256 end
    )
        private
        pure
        returns (bool isValid)
    {
        if (end <= start) return false;
        if (end - start > MAX_DNS_LABEL_OCTETS) return false;
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
    /// @param account The address to convert.
    /// @return The hexadecimal string representation (42 characters including "0x").
    function addressToHex(address account) internal pure returns (string memory) {
        return account.toHexString();
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
