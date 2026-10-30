// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {IDotnsPopControllerOld} from "./IDotnsPopControllerOld.sol";

/// @title IDotnsPopControllerLegacyOld
/// @notice Deprecated PoP controller entrypoints, kept with their original selectors for callers
/// bound to them.
/// @dev Each function forwards to its replacement on @custom:contract IDotnsPopControllerOld and
/// has the same effect. They take the replacement's struct types: a selector hashes only the
/// function
/// name and the tuple shape, so the selectors are unchanged. Label validation reached through these
/// entrypoints reverts with @custom:reverts InvalidLiteLabel and @custom:reverts InvalidBaseLabel,
/// the errors their callers decode; every other error is shared with the replacements.
/// @custom:security-contact admin@parity.io
interface IDotnsPopControllerLegacyOld {
    /// @notice Thrown on the legacy entrypoints where the replacements throw
    /// @custom:reverts InvalidDeviceLabel.
    error InvalidLiteLabel();

    /// @notice Thrown on the legacy entrypoints where the replacements throw
    /// @custom:reverts InvalidPersonhoodLabel.
    error InvalidBaseLabel();

    /// @notice Deprecated: use @custom:function IDotnsPopControllerOld.issueDeviceName.
    /// @dev Selector `reserveLiteName((string,address,bytes))`.
    /// @param params Issuance request; see @custom:struct
    /// IDotnsPopControllerOld.DeviceNameIssuance.
    function reserveLiteName(IDotnsPopControllerOld.DeviceNameIssuance calldata params) external;

    /// @notice Deprecated: use @custom:function
    /// IDotnsPopControllerOld.issueDeviceNameWithReservation. @dev Selector
    /// `reserveBaseName(((string,address,bytes),string))`.
    /// @param params Issuance and reservation request; see
    /// @custom:struct IDotnsPopControllerOld.DeviceNameIssuanceWithReservation.
    function reserveBaseName(
        IDotnsPopControllerOld.DeviceNameIssuanceWithReservation calldata params
    )
        external;

    /// @notice Deprecated: use @custom:function IDotnsPopControllerOld.issuePersonhoodName.
    /// @dev Selector `registerBaseName((string,address,(uint8,string,bytes)))`.
    /// @param params Issuance request; see
    /// @custom:struct IDotnsPopControllerOld.PersonhoodNameIssuance.
    function registerBaseName(IDotnsPopControllerOld.PersonhoodNameIssuance calldata params)
        external;
}
