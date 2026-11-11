// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {IDotnsPopController} from "./IDotnsPopController.sol";

/// @title IDotnsPopControllerLegacy
/// @notice Deprecated PoP controller entrypoints, kept with their original selectors for callers
/// bound to them.
/// @dev Each function forwards to its replacement on @custom:contract IDotnsPopController and has
/// the same effect. They take the replacement's struct types: a selector hashes only the function
/// name and the tuple shape, so the selectors are unchanged. Label validation reached through these
/// entrypoints reverts with @custom:reverts InvalidLiteLabel and @custom:reverts InvalidBaseLabel,
/// the errors their callers decode; every other error is shared with the replacements.
/// @custom:security-contact admin@parity.io
interface IDotnsPopControllerLegacy {
    /// @notice Thrown on the legacy entrypoints where the replacements throw
    /// @custom:reverts InvalidDeviceLabel.
    error InvalidLiteLabel();

    /// @notice Thrown on the legacy entrypoints where the replacements throw
    /// @custom:reverts InvalidPersonhoodLabel.
    error InvalidBaseLabel();

    /// @notice Deprecated: use @custom:function IDotnsPopController.issueDeviceName.
    /// @dev Selector `reserveLiteName((string,address,bytes))`.
    /// @param params Issuance request; see @custom:struct IDotnsPopController.DeviceNameIssuance.
    function reserveLiteName(IDotnsPopController.DeviceNameIssuance calldata params) external;

    /// @notice Deprecated: use @custom:function IDotnsPopController.issueDeviceNameWithReservation.
    /// @dev Selector `reserveBaseName(((string,address,bytes),string))`.
    /// @param params Issuance and reservation request; see
    /// @custom:struct IDotnsPopController.DeviceNameIssuanceWithReservation.
    function reserveBaseName(IDotnsPopController.DeviceNameIssuanceWithReservation calldata params)
        external;

    /// @notice Deprecated: use @custom:function IDotnsPopController.issuePersonhoodName.
    /// @dev Selector `registerBaseName((string,address,(uint8,string,bytes)))`.
    /// @param params Issuance request; see
    /// @custom:struct IDotnsPopController.PersonhoodNameIssuance.
    function registerBaseName(IDotnsPopController.PersonhoodNameIssuance calldata params) external;
}
