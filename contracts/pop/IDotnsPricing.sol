// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title DotNS Pricing Cost Model
/// @notice Prices a registration from the base length of its label alone.
/// @dev The seam between name policy and the wei amount a registration costs. `PopRules` and the
///      public commit-reveal controller keep the classification, reservation, and tier rules; the
///      model owns only the amount for a given base length, so the curve can be swapped by
///      registering a new model under `DotnsConstants.COST_MODEL` without touching either. Only the
///      base length crosses the seam: the model reads no personhood band or `PopStatus`. The public
///      controller prices NoStatus deposits through this same path, so the model carries no PoP
///      name.
/// @custom:security-contact admin@parity.io
interface IDotnsPricing {
    /// @notice Thrown when a model constructor parameter breaks a pricing invariant.
    /// @param reason Human-readable explanation of the failed invariant.
    error PricingError(string reason);

    /// @notice Returns the registration cost in wei for a label of the given base length.
    /// @dev Pure amount lookup: the caller supplies the digit-stripped base length and the model
    ///      returns the curve value for it. Runs on the ERC721 transfer floor read, so it stays a
    ///      view with no state writes.
    /// @param baseLength Digit-stripped length of the label being priced.
    /// @return weiPrice Registration cost in wei for that base length.
    function priceForBaseLength(uint256 baseLength) external view returns (uint256 weiPrice);

    /// @notice Returns a stable identifier for this model and its parameters.
    /// @dev Changes when the model shape or its parameters change, so clients and telemetry can
    ///      tell one live curve from another. Not consulted on the pricing path. This is the
    ///      cost-model identity used by `DotnsCostModelRegistry`, unrelated to the network's
    ///      release declaration (`protocolVersion()` on the protocol registry).
    /// @return modelVersion Identifier derived from the model form and its parameters.
    function version() external view returns (uint256 modelVersion);
}
