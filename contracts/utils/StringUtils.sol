// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

library StringUtils {
    using Strings for uint256;
    using Strings for int256;
    using Strings for address;

    function strlen(string memory s) internal pure returns (uint256) {
        uint256 len;
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
        return len;
    }

    function uintToString(uint256 value) internal pure returns (string memory) {
        return value.toString();
    }

    function addressToHex(address a) internal pure returns (string memory) {
        return a.toHexString();
    }

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
