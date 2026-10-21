// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {StringUtils} from "../utils/StringUtils.sol";
import {IPopRules} from "./IPopRules.sol";

/// @title PopClassification
/// @notice The pure dotNS naming rules: a label's base length, its trailing digits, and the PoP
///         tier its base length places it in.
/// @dev Shared by @custom:contract PopRules, which exposes them through
///      @custom:function IPopRules.classifyName and @custom:function IPopRules.isBaseName, and by
///      callers that apply the same rules inside their own call. Calling the library in place of
///      PopRules saves a proxied external call for logic that reads no state. Inputs are the
///      label bytes only; validating the label's shape is the caller's job.
/// @dev Every contract that uses these rules compiles them in, so a change to them takes effect
///      in each contract only when that contract is upgraded. Upgrade PopRules and
///      @custom:contract DotnsPopController together whenever these rules change.
/// @custom:security-contact admin@parity.io
library PopClassification {
    using StringUtils for *;

    /// @notice Index one past `name`'s base name: a device name without its suffix, or the whole
    ///         of any other label.
    /// @dev Only a device name has a suffix to remove. The gateway allocates those two digits to
    ///      tell apart people who chose the same stem, so removing them recovers what the
    ///      candidate actually picked. No such allocation stands behind the digits in an
    ///      ordinary label, where they are part of the name: `web3` is a four-character word,
    ///      not `web` with a counter.
    /// @param name Domain label.
    /// @return end Length of the base name.
    function baseNameEnd(string calldata name) internal pure returns (uint256 end) {
        end = bytes(name).length;
        if (!name.isDeviceLabel()) return end;
        return end - StringUtils.DEVICE_SUFFIX_DIGITS - 1;
    }

    /// @notice Counts trailing digits in a string.
    /// @param label String to analyse.
    /// @return digitCount Number of trailing digits.
    function countTrailingDigits(string calldata label) internal pure returns (uint256 digitCount) {
        bytes calldata bytesLabel = bytes(label);
        for (uint256 i = bytesLabel.length; i > 0; i--) {
            if (bytesLabel[i - 1] >= 0x30 && bytesLabel[i - 1] <= 0x39) {
                digitCount++;
            } else {
                break;
            }
        }
    }

    /// @notice Places a label in its PoP tier by base length.
    /// @dev Base lengths <= 5 are governance-reserved, 6-8 require personhood (devicehood for a
    ///      device name), and 9 or more are open to any caller.
    /// @param name Domain label, already validated as a DNS label or a device name.
    /// @return requirement Tier the label requires.
    /// @return message Human-readable reason for the tier.
    /// @return baseLength Length of the label's base name.
    function classify(string calldata name)
        internal
        pure
        returns (IPopRules.PopStatus requirement, string memory message, uint256 baseLength)
    {
        baseLength = baseNameEnd(name);

        if (baseLength <= 5) {
            return (IPopRules.PopStatus.Reserved, "Reserved for Governance", baseLength);
        }

        if (baseLength >= 6 && baseLength <= 8) {
            // Devicehood is the gateway's separated form. Digits in an ordinary label say nothing
            // about personhood, so such a label sits in the band its length earns.
            if (name.isDeviceLabel()) {
                return (IPopRules.PopStatus.Devicehood, "Requires devicehood", baseLength);
            }
            return (IPopRules.PopStatus.Personhood, "Requires personhood", baseLength);
        }

        // Base length >= 9 is open to any caller, and is reached by a device name whose stem is
        // nine or more through the gateway.
        return (IPopRules.PopStatus.NoStatus, "Available to all", baseLength);
    }
}
