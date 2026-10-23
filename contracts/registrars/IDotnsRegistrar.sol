// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {IERC721} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {IDotnsController} from "./IDotnsController.sol";

/// @title dotNS Registrar
/// @notice ERC721-backed ownership for dotNS names with controller-gated registration.
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
    /// tier requires a non-zero transfer fee and the caller forwarded no `msg.value`.
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

    /// @notice Thrown when a transfer or a transfer-fee quote targets a soulbound name.
    /// @dev Soulbound names are minted through the dotNS gateway pallet and are permanently
    /// non-transferable. Raised by the `_update` transfer gate and by
    /// @custom:function quoteTransferFee.
    error NameSoulbound(uint256 tokenId);

    /// @notice Thrown when a name is transferred into escrow custody by anything other than the
    /// escrow's own release path.
    /// @dev `redeem` and `reclaim`, the two calls that return a name from custody, gate on the
    /// release position the escrow records before it moves the name, so custody reached any other
    /// way has no exit.
    /// @custom:function IDotnsNameEscrow.onERC721Received refuses such a deposit but does not run
    /// on a plain `transferFrom`, which is why the gate is enforced here too.
    error UnsolicitedEscrowDeposit(uint256 tokenId);

    /// @notice Thrown when @custom:function revoke is called outside a Root origin.
    error NotRoot();

    /// @notice Thrown when @custom:function revokeIssued is called by anything other than the
    /// PoP controller.
    error NotPopController(address caller);

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

    /// @notice Emitted when a name is revoked.
    /// @param id The token id (namehash node) that was burned.
    /// @param holder The account the name was taken from: the token holder, or the previous
    /// holder when the name was in escrow custody after a release.
    event NameRevoked(uint256 indexed id, address indexed holder);

    /// @notice Emitted when a controller is removed.
    event ControllerRemoved(IDotnsController indexed controller);

    /// @notice Revokes a name: clears it, settles its escrow position, and burns the token so the
    /// name can be registered again.
    /// @dev Callable only under a Root origin, otherwise @custom:reverts NotRoot. Takes back a name
    /// registered on the public or reserved path, whoever holds it, including a name in escrow
    /// custody after a release. A name the gateway issued goes through
    /// @custom:function IDotnsPopGovernance.revokeName instead. The name's records and subnames are
    /// cleared before the token is burned (@custom:function IDotnsRegistry.revokeName), and its
    /// escrow position
    /// is settled with any deposit credited to the holder's pull-payment balance
    /// (@custom:function IDotnsNameEscrowRevocation.revoke). Revocation is final: the holder has
    /// no redeem window, and the name is available to anyone at once. A soulbound name reverts
    /// @custom:reverts NameSoulbound, because the gateway keeps state about it that only the PoP
    /// controller clears. A name that does not exist reverts
    /// @custom:reverts ERC721NonexistentToken. Emits @custom:emits NameRevoked and the ERC-721
    /// `Transfer` to the zero address.
    /// @param tokenId The token id (namehash node) of the name.
    function revoke(uint256 tokenId) external;

    /// @notice Revokes a name issued through the PoP controller, once the controller has cleared
    /// the state it keeps about it.
    /// @dev Callable only by the address registered as `POP_CONTROLLER`, otherwise
    /// @custom:reverts NotPopController. Does what @custom:function revoke does, for a soulbound
    /// name as well, and leaves the soulbound flag cleared so a later public registration of the
    /// same name is transferable. Reached through
    /// @custom:function IDotnsPopGovernance.revokeName, which is Root-gated.
    /// @param tokenId The token id (namehash node) of the name.
    function revokeIssued(uint256 tokenId) external;

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

    /// @notice Registers a name with no expiry.
    /// @dev There is no `expire` or `renew` path on the registrar. Custody only moves via ERC721
    /// transfers (which the registrar polices via the fee-on-transfer hook), via the escrow's
    /// release, redeem and reclaim, or ends when governance revokes the name
    /// (@custom:function revoke, @custom:function revokeIssued). Restricted to authorised
    /// controllers (otherwise @custom:reverts NotController) and rejects ids that are not available
    /// (otherwise @custom:reverts NameNotAvailable). Emits @custom:emits NameRegistered on
    /// success.
    /// @dev When the caller is the address registered under `DotnsConstants.POP_CONTROLLER`, the
    /// name is marked soulbound and stays non-transferable for as long as it exists (see
    /// @custom:function isSoulbound). Provenance is read from the protocol registry at mint time,
    /// so no other authorised controller can mint a soulbound name and the PoP controller cannot
    /// mint an unlocked one. Public registrations from any other controller stay transferable.
    /// @param label The human-readable label string (e.g. "alice").
    function register(uint256 id, address owner, string calldata label) external;

    /// @notice Returns whether a token is soulbound (PoP-gateway minted and non-transferable).
    /// @dev Durable on-chain marker set once at mint by @custom:function register and cleared
    /// only when the name is revoked. A `true` result means every transfer overload reverts with
    /// @custom:reverts NameSoulbound and @custom:function quoteTransferFee reverts likewise.
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

    /// @notice Quotes the additional native fee required to transfer a token to `to`.
    /// @dev Returns the fee from @custom:function PopRules.transferFloor: the name's own price
    /// as the maximum of (i) the reach component charged when the recipient does not meet
    /// the label's required tier and (ii) the downgrade component charged when the
    /// recipient tier is strictly below the sender tier. Self-transfers and
    /// escrow-touching transfers (release into escrow, reclaim out of escrow) return
    /// zero. A token whose sender has no stored label also returns zero because there
    /// is no label-derived price to charge against. Soulbound names are non-transferable
    /// and have no transfer price, so a soulbound `tokenId` reverts with
    /// @custom:reverts NameSoulbound rather than returning zero. Rejects a zero `to` with
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
    /// to compute the required transfer fee; if the caller does not forward at least that
    /// amount as `msg.value`, the transfer reverts with @custom:reverts TransferFeeRequired.
    /// A soulbound name is non-transferable and reverts with @custom:reverts NameSoulbound.
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
    /// @custom:reverts TransferFeeRequired when the recipient owes a non-zero transfer fee and
    /// the caller has not forwarded it as `msg.value`, and with @custom:reverts NameSoulbound when
    /// the token is soulbound.
    function safeTransferFrom(address from, address to, uint256 tokenId) external payable override;

    /// @inheritdoc IERC721
    /// @dev Subject to the same fee-on-transfer gate as the safe overloads; reverts with
    /// @custom:reverts TransferFeeRequired when the recipient owes a non-zero transfer fee and
    /// the caller has not forwarded it as `msg.value`, and with @custom:reverts NameSoulbound when
    /// the token is soulbound.
    function transferFrom(address from, address to, uint256 tokenId) external payable override;
}
