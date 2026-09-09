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

    /// @notice Number of digits in a lite-person PoP label's suffix.
    /// @dev The count the gateway emits, and an exact requirement here: the separator sits at a
    ///      fixed offset from the end, so a one or three digit suffix is rejected. The pallet
    ///      reads its own constant as a minimum, so widening it there does not widen this.
    uint256 internal constant LITE_SUFFIX_DIGITS = 2;

    /// @notice Maximum number of octets in a single DNS label.
    /// @dev RFC 1035 caps each label at 63 octets. Enforced inside @custom:function _isDnsLabel so
    ///      every public validator (@custom:function isSingleLabel, @custom:function isNamePath,
    ///      @custom:function isLitePersonLabel) inherits the bound and oversized labels never
    ///      reach the registrar. A lite label bounds its stem rather than the whole string, so
    ///      it reaches `MAX_DNS_LABEL_OCTETS + LITE_SUFFIX_DIGITS + 1` octets. Its stem is
    ///      bounded here but checked in @custom:function _isLitePersonLabel, which is stricter
    ///      on charset than a DNS label: letters only.
    uint256 internal constant MAX_DNS_LABEL_OCTETS = 63;

    /// @notice ASCII full stop separating a lite label's stem from its digit suffix.
    /// @dev A lite label is the only label shape in DotNS that carries a separator;
    ///      @custom:function _isDnsLabel rejects it everywhere else.
    bytes1 internal constant LABEL_SEPARATOR = 0x2e;

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

    /// @notice Validates the lite-person PoP label format: `<stem>.<digits>`.
    /// @dev A lite-person label is a stem of lowercase ASCII letters, one
    ///      @custom:constant LABEL_SEPARATOR, then exactly
    ///      @custom:constant LITE_SUFFIX_DIGITS digits (e.g. `joseph.42`). Letters only,
    ///      because the stem is the name a person chose and People Chain restricts that to
    ///      letters. How short a stem may be is policy rather than format, so it is left to the
    ///      governance-reserved band in @custom:function IPopRules.classifyName.
    ///      It is the only label shape in DotNS permitted to carry a separator, which is what
    ///      reserves the dotted space to the gateway. A digit suffix is not exclusive: an
    ///      ordinary label may end in digits, but it is measured as written and so classifies by
    ///      its full length.
    ///      Cross-flow priority is arbitrated on the stem, not on the whole label: a lite
    ///      label's stem is reserved as a base name through
    ///      @custom:function IPopRules.reserveBaseNameForPop, so `joseph.42` contends with
    ///      `joseph`. There is no flat spelling of a lite label for it to contend with.
    /// @param value Candidate label.
    /// @return isValid True if `value` is a stem of lowercase ASCII letters followed by a
    ///         separator and exactly @custom:constant LITE_SUFFIX_DIGITS digits.
    function isLitePersonLabel(string calldata value) internal pure returns (bool isValid) {
        return _isLitePersonLabel(bytes(value));
    }

    /// @notice Memory-location helper for @custom:function isLitePersonLabel.
    /// @dev For callers holding the label in memory rather than calldata: the controller reads
    ///      it back from a struct before deriving the node, and the lens reads it out of a
    ///      store. Same predicate, different data location.
    /// @param value Candidate label held in memory.
    /// @return isValid True if `value` is a stem of lowercase ASCII letters followed by a
    ///         separator and exactly @custom:constant LITE_SUFFIX_DIGITS digits.
    function isLitePersonLabelMemory(string memory value) internal pure returns (bool isValid) {
        return _isLitePersonLabel(bytes(value));
    }

    function _isLitePersonLabel(bytes memory raw) private pure returns (bool isValid) {
        uint256 length = raw.length;
        // One stem letter, the separator, then the digits is the shortest accepted shape. The
        // stem is not bounded below here: how short a name may be is policy, and PopRules
        // already holds it as the governance-reserved band. Mirroring People Chain's
        // `MinUsernameLength` would duplicate that and drift when the runtime changes it.
        if (length < LITE_SUFFIX_DIGITS + 2) return false;

        // Fixing the separator's position is what enforces the exact digit count: a third
        // digit, a missing separator and a trailing separator all land a non-separator byte
        // here. The letters-only stem then admits no second separator, so exactly one is
        // possible without scanning for it.
        uint256 separator = length - LITE_SUFFIX_DIGITS - 1;
        if (raw[separator] != LABEL_SEPARATOR) return false;

        // The stem is a name a person chose, so it follows the same letters-only rule as a
        // full-person label. Uppercase is excluded for the reason it is everywhere else here:
        // a single name must have a single spelling, and so a single node.
        if (!_isPersonLabel(raw, 0, separator)) return false;

        for (uint256 i = separator + 1; i < length; ++i) {
            bytes1 char = raw[i];
            if (char < bytes1(0x30) || char > bytes1(0x39)) return false;
        }

        return true;
    }

    /// @notice Validates that `value` is a name a person chose: lowercase ASCII letters only.
    /// @dev Mirrors `BaseLabel::is_valid_person` on the gateway pallet, which admits no digits
    ///      and no hyphens, so a label outside this shape cannot have been issued. Stricter
    ///      than @custom:function isSingleLabel, and it is the same rule
    ///      @custom:function isLitePersonLabel applies to a lite stem. How short a name may be
    ///      is policy rather than format, so no floor is applied here.
    /// @param value Candidate label.
    /// @return isValid True if every octet of `value` is a lowercase ASCII letter.
    function isPersonLabel(string calldata value) internal pure returns (bool isValid) {
        bytes memory raw = bytes(value);
        return _isPersonLabel(raw, 0, raw.length);
    }

    function _isPersonLabel(
        bytes memory raw,
        uint256 start,
        uint256 end
    )
        private
        pure
        returns (bool isValid)
    {
        if (end <= start) return false;
        if (end - start > MAX_DNS_LABEL_OCTETS) return false;

        for (uint256 i = start; i < end; ++i) {
            bytes1 char = raw[i];
            if (char < bytes1(0x61) || char > bytes1(0x7a)) return false;
        }

        return true;
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
        if (label[start] == bytes1(0x2d) || label[end - 1] == bytes1(0x2d)) {
            return false;
        }

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
