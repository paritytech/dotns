// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

/// @title IDotnsPopResolver
/// @notice Resolver for per-name records produced by the dotNS gateway pallet.
/// @dev Holds three record kinds:
///      - Chat key: ECDH public-key bytes used for end-to-end encrypted messaging.
///      - Device link (`deviceLabelhashOf`): for a personhood-name node, the labelhash of the
///        device name it was linked to when it was issued.
///      - Personhood link (`personhoodNodeOf`): reverse index mapping a device-name labelhash to
///        the personhood-name node it is linked to. Mirrors `deviceLabelhashOf` on every write so a
///        caller that holds a device-name labelhash can resolve the personhood name
///        without scanning events.
///
///      Lives separately from the per-user `LabelStore` so that the store can remain
///      a labels-only, protocol-write / user-read surface, and follows the project's
///      resolver-per-record-category convention used by @custom:contract IDotnsContentResolver and
///      @custom:contract IDotnsReverseResolver.
///
///      Write authorisation is delegated to the address registered as
///      `DotnsProtocolRegistry.POP_CONTROLLER` at call time, so rotating the PoP
///      controller is a single `set` on the protocol registry with no resolver
///      upgrade required.
/// @custom:security-contact admin@parity.io
interface IDotnsPopResolver {
    /// @notice Emitted when a node's chat key is set or updated.
    /// @param node The node whose chat key was written.
    /// @param chatKey The new chat key bytes.
    event ChatKeyUpdated(bytes32 indexed node, bytes chatKey);

    /// @notice Emitted when a personhood name's device link is set or updated.
    /// @param personhoodNode The personhood-name node carrying the link.
    /// @param deviceLabelhash The labelhash of the linked device name.
    event DeviceLinkUpdated(bytes32 indexed personhoodNode, bytes32 indexed deviceLabelhash);

    /// @notice Thrown when the caller is not the authorised PoP controller.
    /// @param caller The address that attempted the write.
    error NotPopController(address caller);

    /// @notice Thrown when the provided chat key does not match the expected 65-byte length.
    /// @param length The length of the payload that was rejected.
    error InvalidChatKeyLength(uint256 length);

    /// @notice Sets the chat key for `node`.
    /// @dev Callable only by the address registered under `DotnsProtocolRegistry.POP_CONTROLLER`,
    ///      otherwise @custom:reverts NotPopController. Overwrites any previous value. The payload
    ///      must be exactly 65 bytes: the uncompressed secp256k1 public key encoding (1 prefix
    ///      byte followed by the 32-byte X and 32-byte Y affine coordinates); any other length
    ///      reverts with @custom:reverts InvalidChatKeyLength. Emits @custom:emits ChatKeyUpdated
    ///      on every successful write.
    /// @param node The node whose chat key is being written.
    /// @param chatKey ECDH public key bytes (pallet-side type is `[u8; 65]`).
    function setChatKey(bytes32 node, bytes calldata chatKey) external;

    /// @notice Sets the device link for a personhood-name node.
    /// @dev Callable only by the authorised PoP controller, otherwise
    ///      @custom:reverts NotPopController. Overwrites any previous link. When overwriting, the
    ///      stale inverse entry is nulled so both the forward (`deviceLabelhashOf`) and reverse
    ///      (`personhoodNodeOf`) indices remain consistent: re-linking the same `personhoodNode` to
    ///      a new `deviceLabelhash` clears `personhoodNodeOf(oldDevice)`, and re-linking the same
    ///      `deviceLabelhash` to a new `personhoodNode` clears `deviceLabelhashOf(oldPersonhood)`.
    ///      The invariant `personhoodNodeOf(deviceLabelhashOf(node)) == node` always holds after
    ///      the call. Emits @custom:emits DeviceLinkUpdated on every successful write.
    /// @param personhoodNode The personhood-name node carrying the link.
    /// @param deviceLabelhash The labelhash of the linked device name.
    function setDeviceLink(bytes32 personhoodNode, bytes32 deviceLabelhash) external;

    /// @notice Returns the chat key associated with a node.
    /// @param node The node to query.
    /// @return chatKey The stored chat key bytes, or empty if unset.
    function chatKey(bytes32 node) external view returns (bytes memory chatKey);

    /// @notice Returns the device-name labelhash linked to a personhood-name node.
    /// @param personhoodNode The personhood-name node to query.
    /// @return deviceLabelhash The linked device-name labelhash, or zero if unset.
    function deviceLabelhashOf(bytes32 personhoodNode)
        external
        view
        returns (bytes32 deviceLabelhash);

    /// @notice Returns the personhood-name node a device name is linked to.
    /// @dev Reverse of @custom:function deviceLabelhashOf. Written by the same `setDeviceLink` call
    ///      so the two directions stay in lockstep. Returns zero when the device name has never
    ///      been linked to a personhood name.
    /// @param deviceLabelhash The labelhash of the device name to query.
    /// @return personhoodNode The linked personhood-name node, or zero if unset.
    function personhoodNodeOf(bytes32 deviceLabelhash)
        external
        view
        returns (bytes32 personhoodNode);
}
