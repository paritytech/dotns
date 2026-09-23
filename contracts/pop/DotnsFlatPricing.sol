// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {IDotnsPricing} from "./IDotnsPricing.sol";

/// @title DotNS Flat Pricing
/// @notice Prices every registration at a single deposit, whatever the base length.
/// @dev The launch cost model: one constant amount for any name the bands admit, so a nine-plus
///      character name costs the same flat deposit and shorter names stay gated by `PopRules`. The
///      deposit is fixed at deployment, so a new amount is a fresh deployment registered under
///      `DotnsConstants.COST_MODEL`. `DotnsScarcityPricing` is the length-sensitive alternative
/// held as a later candidate; it is not the registered default.
/// @custom:security-contact admin@parity.io
contract DotnsFlatPricing is IDotnsPricing {
    /// @notice Identifier of the flat model form, mixed into `version`.
    /// @dev Separates this form from another model that reuses the same deposit, so `version`
    /// cannot collide across model forms.
    uint256 public constant FORM_ID = uint256(keccak256("dotns.pricing.flat.v1"));

    /// @notice Deposit in wei charged for every base length.
    uint256 public immutable deposit;

    /// @notice Fixes the deposit for the life of this model.
    /// @dev Requires a strictly positive deposit so the model can never price at zero; a zero
    /// amount triggers @custom:reverts PricingError.
    /// @param depositValue Deposit in wei charged for every base length.
    constructor(uint256 depositValue) {
        require(depositValue > 0, PricingError("Deposit must be greater than 0"));
        deposit = depositValue;
    }

    /// @inheritdoc IDotnsPricing
    /// @dev Returns the same deposit for every base length: the amount does not vary with the
    /// label, so the argument is read only to satisfy the interface.
    function priceForBaseLength(uint256) external view override returns (uint256 weiPrice) {
        return deposit;
    }

    /// @inheritdoc IDotnsPricing
    /// @dev Two deployments with the same deposit share a version; any change to the deposit
    /// changes it.
    function version() external view override returns (uint256 modelVersion) {
        modelVersion = uint256(keccak256(abi.encode(FORM_ID, deposit)));
    }
}
