// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC721} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {IDotnsController} from "./IDotnsController.sol";

/// @title Dotns Registrar
/// @notice ERC721-backed ownership for DotNS names with controller-gated registration.
/// @dev Intentionally minimal and policy-free. Provides ERC721 ownership for registered name
/// token IDs and controller-gated registration; pricing, PoP enforcement, and flow-specific
/// policy live in the controllers.
/// @custom:security-contact admin@parity.io
interface IDotnsRegistrar is IERC721 {
    /// @notice Thrown when a name is already registered.
    error NameNotAvailable(uint256 tokenId);

    /// @notice Thrown when the caller is not an authorised controller.
    error NotController(address caller);

    /// @notice Thrown when the protocol registry has no escrow address configured.
    error EscrowNotConfigured();

    /// @notice Thrown when a standard ERC721 transfer is attempted but the recipient tier requires
    /// a non-zero fee delta.
    error TransferFeeRequired(uint256 tokenId, address to, uint256 requiredFee);

    /// @notice Emitted when a name is registered.
    event NameRegistered(uint256 indexed id, address indexed owner);

    /// @notice Emitted when a controller is added.
    /// @dev Typed as the shared baseline @custom:contract IDotnsController so the commit-reveal
    /// controller and the PoP controller (and any future controller) all fit the same signature
    /// without
    /// the registrar depending on any specific controller interface.
    event ControllerAdded(IDotnsController indexed controller);

    /// @notice Emitted when a controller is removed.
    event ControllerRemoved(IDotnsController indexed controller);

    /// @notice Returns whether a name is available for registration.
    /// @dev Treats escrow custody as available: a token whose current owner is the configured
    /// `NAME_ESCROW` is considered claimable, so the controller can drive a fresh registration
    /// that reclaims the token from escrow.
    function available(uint256 id) external view returns (bool isAvailable);

    /// @notice Registers a name permanently.
    /// @dev Permanence is by construction: there is no `expire`, `renew`, or `release` path on
    /// the registrar. Custody only moves via ERC721 transfers (which the registrar polices via
    /// the fee-on-transfer hook) or via escrow reclaim. Restricted to authorised controllers
    /// (otherwise @custom:reverts NotController) and rejects ids that are not available
    /// (otherwise @custom:reverts NameNotAvailable). Emits @custom:emits NameRegistered on
    /// success.
    /// @param label The human-readable label string (e.g. "alice").
    function register(uint256 id, address owner, string calldata label) external;

    /// @notice Returns whether a given token id has been minted.
    function exists(uint256 tokenId) external view returns (bool tokenExists);

    /// @notice Adds an authorised controller.
    /// @dev Typed against the baseline `IDotnsController` (not a concrete subtype) so a single
    /// authorisation surface accepts every controller flavour (commit-reveal, PoP gateway,
    /// future variants) without per-flavour setters. Owner-gated (otherwise
    /// @custom:reverts OwnableUnauthorizedAccount); emits @custom:emits ControllerAdded on
    /// success.
    function addController(IDotnsController controller) external;

    /// @notice Removes an authorised controller.
    /// @dev Mirrors the @custom:function addController baseline-typed signature so any registered
    /// controller can
    /// be revoked through the same entry point. Owner-gated (otherwise
    /// @custom:reverts OwnableUnauthorizedAccount); emits @custom:emits ControllerRemoved on
    /// success.
    function removeController(IDotnsController controller) external;

    /// @notice Returns the human-readable label a token was registered with.
    /// @dev Canonical state source for the label string; any client that holds a node or
    /// tokenId can resolve the original label in one view call without scanning registration
    /// events. Returns the empty string when the token does not exist.
    function labelOf(uint256 tokenId) external view returns (string memory label);

    /// @notice Quotes the additional native fee required to transfer a token to `to`.
    /// @dev Returns the maximum of (i) the delta between the recipient-tier price and the
    /// token's running-max paid history and (ii) the flat NoStatus `reachFee`, so
    /// verified-but-below recipients still pay the floor even when the running max would
    /// otherwise cover the move. Rejects a zero `to` with @custom:reverts ERC721InvalidReceiver
    /// and requires the protocol registry to have an escrow configured (otherwise
    /// @custom:reverts EscrowNotConfigured).
    function quoteTransferFee(
        uint256 tokenId,
        address to
    )
        external
        view
        returns (uint256 requiredFee);

    /// @inheritdoc IERC721
    /// @dev The registrar's `_update` hook compares the recipient's running-max paid history and
    /// tier price against the configured escrow's quote; if the caller does not forward the
    /// required delta as `msg.value`, the transfer reverts with
    /// @custom:reverts TransferFeeRequired. The `payable` modifier on every transfer overload
    /// exists so the fee can be forwarded in the same call.
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes calldata data
    )
        external
        payable
        override;

    /// @inheritdoc IERC721
    /// @dev Subject to the same fee-on-transfer gate as the four-argument overload; reverts with
    /// @custom:reverts TransferFeeRequired when the recipient owes a non-zero delta and the
    /// caller has not forwarded it as `msg.value`.
    function safeTransferFrom(address from, address to, uint256 tokenId) external payable override;

    /// @inheritdoc IERC721
    /// @dev Subject to the same fee-on-transfer gate as the safe overloads; reverts with
    /// @custom:reverts TransferFeeRequired when the recipient owes a non-zero delta and the
    /// caller has not forwarded it as `msg.value`.
    function transferFrom(address from, address to, uint256 tokenId) external payable override;
}
