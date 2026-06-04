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

    /// @notice Thrown when a standard ERC721 transfer is attempted but the recipient
    /// tier requires a non-zero reach floor and the caller forwarded no `msg.value`.
    error TransferFeeRequired(uint256 tokenId, address to, uint256 requiredFee);

    /// @notice Thrown when @custom:function initialize is called with the zero address as
    /// the protocol registry.
    error ProtocolRegistryRequired();

    /// @notice Thrown when a mint, burn, or self-transfer carries `msg.value`. None of those
    /// paths forward value onward, so attached value would be permanently trapped.
    error UnexpectedValue();

    /// @notice Thrown when @custom:function register is called with the escrow address as
    /// `owner`, which would mint directly into escrow custody with no @custom:struct
    /// ReleasePosition recorded.
    error InvalidOwner();

    /// @notice Thrown when @custom:function register receives an empty or non-canonical
    /// label.
    error InvalidLabel();

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

    /// @notice Returns whether a registration call may proceed for `id`.
    /// @dev Signals two distinct paths to the controller. Returns `true` when the owner slot is
    /// empty (a fresh @custom:function register call may mint) AND when the current owner is
    /// the configured escrow (the controller must then route through
    /// @custom:function IDotnsNameEscrow.reclaim instead of @custom:function register, because
    /// `register` calls `_mint` which rejects existing tokens). All other holders return
    /// `false`. The controller distinguishes the two `true` cases via @custom:function exists.
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

    /// @notice Returns whether `controller` is currently authorised to call
    /// @custom:function register.
    /// @param controller Candidate controller.
    /// @return authorised True when `controller` was added via @custom:function addController and
    /// has not been removed.
    function controllers(IDotnsController controller) external view returns (bool authorised);

    /// @notice Returns the human-readable label a token was registered with.
    /// @dev Canonical state source for the label string; any client that holds a node or
    /// tokenId can resolve the original label in one view call without scanning registration
    /// events. Returns the empty string when the token does not exist.
    function labelOf(uint256 tokenId) external view returns (string memory label);

    /// @notice Quotes the additional native fee required to transfer a token to `to`.
    /// @dev Returns the reach floor from @custom:function PopRules.transferFloor: the
    /// maximum of (i) the flat reach component charged when the recipient does not meet
    /// the label's required tier and (ii) the downgrade component charged when the
    /// recipient tier is strictly below the sender tier. Self-transfers and
    /// escrow-touching transfers (release into escrow, reclaim out of escrow) return
    /// zero. A token whose sender has no stored label also returns zero because there
    /// is no label-derived price to charge against; this covers gateway-cold PoP mints
    /// (the controller passes an empty label to @custom:function register so substrate
    /// Root does not have to deploy a `LabelStore`) until the user settles via
    /// @custom:function IDotnsPopController.claimLabelStore. Because settlement writes
    /// the label into the original claimant's store, a transfer that happens before
    /// settlement leaves the recipient with no label entry and the zero-fee branch
    /// persists for that token under all future holders. A token registered with no
    /// label that is moved off-chain prior to settlement therefore carries no PoP-tier
    /// transfer friction. Off-chain consumers integrating PoP mints should treat
    /// @custom:function claimLabelStore as a prerequisite for accurate transfer-time
    /// pricing on gateway-issued names. Rejects a zero `to` with
    /// @custom:reverts ERC721InvalidReceiver, an unminted `tokenId` with
    /// @custom:reverts ERC721NonexistentToken via the underlying `ownerOf`, and requires
    /// the protocol registry to have an escrow configured (otherwise
    /// @custom:reverts EscrowNotConfigured). Returns zero when the protocol registry
    /// has no `STORE_FACTORY` configured because no label-derived price is reachable.
    function quoteTransferFee(
        uint256 tokenId,
        address to
    )
        external
        view
        returns (uint256 requiredFee);

    /// @inheritdoc IERC721
    /// @dev The registrar's `_update` hook consults @custom:function PopRules.transferFloor
    /// to compute the required reach floor; if the caller does not forward at least that
    /// amount as `msg.value`, the transfer reverts with @custom:reverts TransferFeeRequired.
    /// The `payable` modifier on every transfer overload exists so the fee can be forwarded
    /// in the same call.
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
    /// @custom:reverts TransferFeeRequired when the recipient owes a non-zero reach floor and
    /// the caller has not forwarded it as `msg.value`.
    function safeTransferFrom(address from, address to, uint256 tokenId) external payable override;

    /// @inheritdoc IERC721
    /// @dev Subject to the same fee-on-transfer gate as the safe overloads; reverts with
    /// @custom:reverts TransferFeeRequired when the recipient owes a non-zero reach floor and
    /// the caller has not forwarded it as `msg.value`.
    function transferFrom(address from, address to, uint256 tokenId) external payable override;
}
