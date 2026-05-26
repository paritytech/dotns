// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IDotnsPopResolver
/// @notice Resolver for per-name records produced by the PoP username flow.
/// @dev Holds three record kinds:
///      - Chat key: ECDH public-key bytes used for end-to-end encrypted messaging.
///      - Lite link: for a full-person node, the labelhash of the lite-person
///        username it was minted from (when the link was made).
///      - Full claim: reverse index mapping a lite labelhash to the full-person
///        node it was promoted to. Mirrors `liteLink` on every write so a
///        caller that holds a lite labelhash can resolve the full-person node
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

    /// @notice Emitted when a full-person node's lite link is set or updated.
    /// @param fullNode The full-person node carrying the link.
    /// @param liteLabelhash The labelhash of the linked lite-person username.
    event LiteLinkUpdated(bytes32 indexed fullNode, bytes32 indexed liteLabelhash);

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

    /// @notice Sets the lite-person link for a full-person `node`.
    /// @dev Callable only by the authorised PoP controller, otherwise
    ///      @custom:reverts NotPopController. Overwrites any previous link. When overwriting, the
    ///      stale inverse entry is nulled so both the forward (`liteLink`) and reverse
    ///      (`fullClaim`) indices remain consistent: re-linking the same `fullNode` to a new
    ///      `liteLabelhash` clears `fullClaim(oldLite)`, and re-linking the same `liteLabelhash`
    ///      to a new `fullNode` clears `liteLink(oldFull)`. The invariant
    ///      `fullClaim(liteLink(node)) == node` always holds after the call. Emits
    ///      @custom:emits LiteLinkUpdated on every successful write.
    /// @param fullNode The full-person node carrying the link.
    /// @param liteLabelhash The labelhash of the linked lite-person username.
    function setLiteLink(bytes32 fullNode, bytes32 liteLabelhash) external;

    /// @notice Returns the chat key associated with a node.
    /// @param node The node to query.
    /// @return chatKey The stored chat key bytes, or empty if unset.
    function chatKey(bytes32 node) external view returns (bytes memory chatKey);

    /// @notice Returns the lite-person labelhash linked to a full-person node.
    /// @param fullNode The full-person node to query.
    /// @return liteLabelhash The linked lite-person labelhash, or zero if unset.
    function liteLink(bytes32 fullNode) external view returns (bytes32 liteLabelhash);

    /// @notice Returns the full-person node a given lite label has claimed.
    /// @dev Reverse of @custom:function liteLink. Written by the same `setLiteLink` call so the
    ///      two directions stay in lockstep. Returns zero when the lite label
    ///      has never been linked to a full claim.
    /// @param liteLabelhash The labelhash of the lite-person username to query.
    /// @return fullNode The full-person node claimed from this lite label, or
    ///         zero if unset.
    function fullClaim(bytes32 liteLabelhash) external view returns (bytes32 fullNode);
}
