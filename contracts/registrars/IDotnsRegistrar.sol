// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {IERC721} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {IDotnsController} from "./IDotnsController.sol";

/// @title dotNS Registrar
/// @notice ERC721-backed ownership for dotNS names with controller-gated registration.
/// @dev Intentionally minimal and policy-free. Provides ERC721 ownership for registered name
/// token IDs and controller-gated registration; pricing, PoP enforcement, and flow-specific
/// policy live in the controllers. The ERC721 transfer functions carry no fee and are not
/// payable; a soulbound name reverts on every one of them with @custom:reverts NameSoulbound.
/// @custom:security-contact admin@parity.io
interface IDotnsRegistrar is IERC721 {
    /// @notice Thrown when a name is already registered.
    error NameNotAvailable(uint256 tokenId);

    /// @notice Thrown when the caller is not an authorised controller.
    error NotController(address caller);

    /// @notice Thrown when the protocol registry has no escrow address configured.
    error EscrowNotConfigured();

    /// @notice Thrown when @custom:function initialize is called with the zero address as
    /// the protocol registry.
    error ProtocolRegistryRequired();

    /// @notice Thrown when a mint carries `msg.value`. Nothing forwards value onward, so attached
    /// value would be permanently trapped.
    error UnexpectedValue();

    /// @notice Thrown when @custom:function register is called with the escrow address as
    /// `owner`, which would mint directly into escrow custody with no @custom:struct
    /// ReleasePosition recorded.
    error InvalidOwner();

    /// @notice Thrown when @custom:function register receives an empty or non-canonical
    /// label.
    error InvalidLabel();

    /// @notice Thrown when a transfer targets a soulbound name.
    /// @dev Soulbound names are minted through the dotNS gateway pallet and are permanently
    /// non-transferable. Raised by the `_update` transfer gate.
    error NameSoulbound(uint256 tokenId);

    /// @notice Thrown when a name is transferred into escrow custody by anything other than the
    /// escrow's own release path.
    /// @dev `redeem` and `reclaim`, the two calls that return a name from custody, gate on the
    /// release position the escrow records before it moves the name, so custody reached any other
    /// way has no exit.
    /// @custom:function IDotnsNameEscrow.onERC721Received refuses such a deposit but does not run
    /// on a plain `transferFrom`, which is why the gate is enforced here too.
    error UnsolicitedEscrowDeposit(uint256 tokenId);

    /// @notice Emitted when a name is registered.
    /// @param id The token id (namehash node) that was minted.
    /// @param owner The address that received the name.
    /// @param soulbound True when the name is soulbound: PoP-gateway minted and non-transferable.
    /// Lets indexers classify registrations without a per-token @custom:function isSoulbound read.
    event NameRegistered(uint256 indexed id, address indexed owner, bool soulbound);

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
    /// empty (a fresh @custom:function register call may mint) OR when the current owner is
    /// the configured escrow and the released position's redeem window has elapsed (the
    /// controller must then route through @custom:function IDotnsNameEscrow.reclaim instead of
    /// @custom:function register, because `register` calls `_mint` which rejects existing
    /// tokens). All other holders return `false`. The controller distinguishes the two `true`
    /// cases via @custom:function exists.
    /// Escrow custody inside the redeem window returns `false`: that window belongs to the
    /// previous holder, who may still @custom:function IDotnsNameEscrow.redeem the name, and
    /// reclaim would revert until it elapses. Clients wanting the exact moment a released name
    /// becomes registrable should read `redeemableUntil` from
    /// @custom:function IDotnsNameEscrow.getReleasePosition.
    function available(uint256 id) external view returns (bool isAvailable);

    /// @notice Registers a name permanently.
    /// @dev Permanence is by construction: there is no `expire`, `renew`, or `release` path on
    /// the registrar. Custody only moves via ERC721 transfers (which the registrar polices via
    /// the fee-on-transfer hook) or via escrow reclaim. Restricted to authorised controllers
    /// (otherwise @custom:reverts NotController) and rejects ids that are not available
    /// (otherwise @custom:reverts NameNotAvailable). Emits @custom:emits NameRegistered on
    /// success.
    /// @dev When the caller is the address registered under `DotnsConstants.POP_CONTROLLER`, the
    /// name is marked soulbound and becomes permanently non-transferable (see
    /// @custom:function isSoulbound). Provenance is read from the protocol registry at mint time,
    /// so no other authorised controller can mint a soulbound name and the PoP controller cannot
    /// mint an unlocked one. Public registrations from any other controller stay transferable.
    /// @param label The human-readable label string (e.g. "alice").
    function register(uint256 id, address owner, string calldata label) external;

    /// @notice Returns whether a token is soulbound (PoP-gateway minted and non-transferable).
    /// @dev Durable on-chain marker set once at mint by @custom:function register and never
    /// cleared. A `true` result means every transfer overload reverts with
    /// @custom:reverts NameSoulbound.
    /// @param tokenId The name's token id.
    /// @return soulbound True when the name was minted through the gateway pallet.
    function isSoulbound(uint256 tokenId) external view returns (bool soulbound);

    /// @notice Returns whether a given token id has been minted.
    function exists(uint256 tokenId) external view returns (bool tokenExists);

    /// @notice Adds an authorised controller.
    /// @dev Typed against the baseline `IDotnsController` (not a concrete subtype) so a single
    /// authorisation surface accepts every controller flavour (commit-reveal, gateway path,
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
}
