// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

library StringUtils {
    /// @dev Returns the length of a given string (UTF-8 aware)
    /// @param s The string to measure the length of
    /// @return The length of the input string in characters
    function strlen(string memory s) internal pure returns (uint256) {
        uint256 len;
        uint256 i = 0;
        uint256 bytelength = bytes(s).length;
        for (len = 0; i < bytelength; len++) {
            bytes1 b = bytes(s)[i];
            if (b < 0x80) {
                i += 1;
            } else if (b < 0xE0) {
                i += 2;
            } else if (b < 0xF0) {
                i += 3;
            } else {
                i += 4; // UTF-8 max is 4 bytes per character
            }
        }
        return len;
    }

    /// @dev Escapes special characters in a given string
    /// @param str The string to escape
    /// @return The escaped string
    function escape(string memory str) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        uint256 extraChars = 0;

        // count extra space needed for escaping
        for (uint256 i = 0; i < strBytes.length; i++) {
            if (_needsEscaping(strBytes[i])) {
                extraChars++;
            }
        }

        // allocate buffer with the exact size needed
        bytes memory buffer = new bytes(strBytes.length + extraChars);
        uint256 index = 0;

        // escape characters
        for (uint256 i = 0; i < strBytes.length; i++) {
            if (_needsEscaping(strBytes[i])) {
                buffer[index++] = "\\";
                buffer[index++] = _getEscapedChar(strBytes[i]);
            } else {
                buffer[index++] = strBytes[i];
            }
        }

        return string(buffer);
    }

    // determine if a character needs escaping
    function _needsEscaping(bytes1 char) private pure returns (bool) {
        return char == '"' || char == "/" || char == "\\" || char == "\n" || char == "\r"
            || char == "\t";
    }

    // get the escaped character
    function _getEscapedChar(bytes1 char) private pure returns (bytes1) {
        if (char == "\n") return "n";
        if (char == "\r") return "r";
        if (char == "\t") return "t";
        return char;
    }

    /// @dev Check if string ends with .XX where X are ASCII digits (0-9)
    /// @param s The string to check
    /// @return True if string ends with dot followed by exactly 2 digits
    function endsWithDotDigits(string memory s) internal pure returns (bool) {
        bytes memory b = bytes(s);
        uint256 len = b.length;
        if (len < 3) return false;
        return b[len - 3] == '.' &&
               b[len - 2] >= '0' && b[len - 2] <= '9' &&
               b[len - 1] >= '0' && b[len - 1] <= '9';
    }

    /// @dev Count UTF-8 characters in first `pos` bytes
    /// @param b The bytes to count characters in
    /// @param pos The byte position to count up to
    /// @return Number of UTF-8 characters
    function _charsInBytes(bytes memory b, uint256 pos) private pure returns (uint256) {
        uint256 chars = 0;
        for (uint256 i = 0; i < pos;) {
            if (b[i] < 0x80) i += 1;
            else if (b[i] < 0xE0) i += 2;
            else if (b[i] < 0xF0) i += 3;
            else i += 4;
            chars++;
        }
        return chars;
    }

    /// @dev Check if domain has 9 or more characters (NONE tier - first come first served)
    /// @param s The string to check
    /// @return True if 9+ characters
    function hasNineOrMoreChars(string memory s) internal pure returns (bool) {
        return strlen(s) >= 9;
    }

    /// @dev Check if domain has 6-8 chars + .XX suffix (PERSON_LIGHT tier)
    /// @param s The string to check
    /// @return True if matches format: 6-8 characters followed by .XX (dot + 2 digits)
    function isPersonLightFormat(string memory s) internal pure returns (bool) {
        bytes memory b = bytes(s);
        // Minimum: 6 chars + 3 bytes (.XX) = 9 bytes for ASCII
        if (b.length < 9) return false;
        // Must end with .XX
        if (!endsWithDotDigits(s)) return false;
        // Count chars before the dot (excluding last 3 bytes: .XX)
        uint256 chars = _charsInBytes(b, b.length - 3);
        // Must be 6-8 characters (9+ would be NONE tier)
        return chars >= 6 && chars < 9;
    }

    /// @dev Check if domain has 6-8 chars without .XX suffix (PROOF_OF_PERSONHOOD tier)
    /// @param s The string to check
    /// @return True if 6-8 characters and does NOT end with .XX
    function isProofOfPersonhoodFormat(string memory s) internal pure returns (bool) {
        uint256 len = strlen(s);
        // Must be 6-8 characters
        if (len < 6 || len >= 9) return false;
        // Must NOT end with .XX (that would be PERSON_LIGHT)
        return !endsWithDotDigits(s);
    }

    /// @dev Check if domain has less than 6 characters (GOVERNANCE tier)
    /// @param s The string to check
    /// @return True if less than 6 characters
    function isGovernanceFormat(string memory s) internal pure returns (bool) {
        return strlen(s) < 6;
    }
}
