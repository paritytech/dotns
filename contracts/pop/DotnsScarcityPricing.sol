// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {IDotnsPricing} from "./IDotnsPricing.sol";

/// @title DotNS Scarcity Pricing
/// @notice Prices a registration on a geometric scarcity curve driven by base length.
/// @dev The curve doubles the base fee for each character below nine and halves it for each
///      character from nine upward, never below the floor. The base fee is the curve's value at
///      nine characters. Both parameters are fixed at deployment, so a new curve is a fresh
///      deployment registered under `DotnsConstants.COST_MODEL`. Held as a length-sensitive
///      candidate for a later cost-model version; the launch default is the constant
///      `DotnsFlatPricing`, so this model ships unregistered until governance registers it.
/// @custom:security-contact admin@parity.io
contract DotnsScarcityPricing is IDotnsPricing {
    /// @notice Identifier of the scarcity curve form, mixed into `version`.
    /// @dev Distinguishes this curve shape from another model that reuses the same base fee and
    ///      floor, so `version` cannot collide across model forms.
    uint256 public constant FORM_ID = uint256(keccak256("dotns.pricing.scarcity.v1"));

    /// @notice Base fee D in wei: the curve's value at nine characters.
    uint256 public immutable baseFee;

    /// @notice Price floor F in wei: the least any name can cost. Never above the base fee.
    uint256 public immutable minPrice;

    /// @notice Fixes the base fee and floor for the life of this model.
    /// @dev Carries the curve invariants: the base fee and floor are both strictly positive, the
    ///      floor does not exceed the base fee, and the base fee stays within
    ///      `type(uint256).max / 512` so the multiplication below nine characters cannot overflow.
    ///      An all-digit label such as "42" strips to base length 0 and reaches the 2**9
    /// multiplier, which sets the /512 ceiling. Any breach triggers @custom:reverts PricingError.
    /// @param baseFeeValue Base fee D in wei.
    /// @param minPriceValue Price floor F in wei.
    constructor(uint256 baseFeeValue, uint256 minPriceValue) {
        require(baseFeeValue > 0, PricingError("Base fee must be greater than 0"));
        require(minPriceValue > 0, PricingError("Floor must be greater than 0"));
        require(minPriceValue <= baseFeeValue, PricingError("Floor cannot exceed the base fee"));
        require(
            baseFeeValue <= type(uint256).max / 512,
            PricingError("Base fee exceeds the scarcity-curve ceiling")
        );
        baseFee = baseFeeValue;
        minPrice = minPriceValue;
    }

    /// @inheritdoc IDotnsPricing
    /// @dev Below nine the multiplier is at most 512, and the constructor caps the base fee at
    ///      `type(uint256).max / 512` so the multiplication cannot overflow. From nine upward the
    ///      base fee is right-shifted by `baseLength - 9`, so it only decreases and the floor stops
    ///      a long base length costing nothing. The floor stays at or below the base fee, so it
    /// only binds from nine characters upward, never in the doubling range below nine.
    function priceForBaseLength(uint256 baseLength)
        external
        view
        override
        returns (uint256 weiPrice)
    {
        uint256 curve = baseLength < 9
            ? baseFee * (2 ** (9 - baseLength))
            : baseFee >> (baseLength - 9);
        return curve < minPrice ? minPrice : curve;
    }

    /// @inheritdoc IDotnsPricing
    /// @dev Two deployments with the same parameters share a version; any change to the base fee or
    ///      floor changes it.
    function version() external view override returns (uint256 modelVersion) {
        modelVersion = uint256(keccak256(abi.encode(FORM_ID, baseFee, minPrice)));
    }
}
