// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IDotnsController} from "./IDotnsController.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";

/// @title Dotns Registrar
/// @notice ERC721-backed ownership for DotNS names with controller-gated registration.
/// @dev This interface is intentionally minimal and deliberately policy-free.
///      It provides:
///      - ERC721 ownership for registered name token IDs.
///      - Controller-gated registration.
/// @custom:security-contact admin@parity.io
interface IDotnsRegistrar is IERC721 {
    /// @notice Thrown when a name is already registered.
    /// @param tokenId The token identifier derived from the node.
    error NameNotAvailable(uint256 tokenId);

    /// @notice Thrown when the caller is not an authorised controller.
    /// @param caller The caller address.
    error NotController(address caller);

    /// @notice Thrown when the caller is not the token owner.
    /// @param caller The caller address.
    /// @param tokenId The token identifier.
    error NotTokenOwner(address caller, uint256 tokenId);

    /// @notice Thrown when the label does not match the token identifier.
    /// @param tokenId The token identifier.
    error LabelMismatch(uint256 tokenId);

    /// @notice Thrown when the label is already set for a token.
    /// @param tokenId The token identifier.
    error LabelAlreadySet(uint256 tokenId);

    /// @notice Thrown when a label is not a canonical lowercase ASCII DNS label.
    error InvalidLabel();

    /// @notice Thrown when a transfer is attempted for a token whose label has not been
    ///         synced into the registrar's `_labels` mapping.
    /// @dev Closes the legacy backdoor where labelless tokens could move without paying
    ///      the cross-tier fee. Owners must call `syncLabel` to populate the mapping
    ///      before transfers can proceed for tokens that pre-date label storage.
    /// @param tokenId The token identifier.
    error LabelNotSynced(uint256 tokenId);

    /// @notice Thrown when the protocol registry has no escrow address configured.
    /// @dev Defensive: prevents `_update` from forwarding `msg.value` to `address(0)`
    ///      on a fee-bearing transfer when the registry is unconfigured.
    error EscrowNotConfigured();

    /// @notice Thrown when a standard ERC721 transfer is attempted but the recipient tier
    ///         requires a non-zero fee delta.
    /// @dev Callers should preflight via {quoteTransferFee} and attach the required
    ///      value to the payable ERC721 transfer entrypoint they intend to use.
    /// @param tokenId The token being transferred.
    /// @param to The intended recipient.
    /// @param requiredFee The exact native amount that must accompany the payable path.
    error TransferFeeRequired(uint256 tokenId, address to, uint256 requiredFee);

    /// @notice Emitted when a name is registered.
    /// @param id Token identifier.
    /// @param owner Owner of the name.
    event NameRegistered(uint256 indexed id, address indexed owner);

    /// @notice Emitted when a controller is added.
    /// @dev Typed as the shared baseline {IDotnsController} so the commit-reveal
    ///      controller and the PoP controller (and any future controller) all fit
    ///      the same signature without the registrar depending on any specific
    ///      controller interface.
    /// @param controller Controller granted permissions.
    event ControllerAdded(IDotnsController indexed controller);

    /// @notice Emitted when a controller is removed.
    /// @param controller Controller whose permissions were revoked.
    event ControllerRemoved(IDotnsController indexed controller);

    /// @notice Emitted when the protocol registry is updated.
    /// @param newRegistry The address of the new protocol registry.
    event ProtocolRegistryUpdated(IDotnsProtocolRegistry indexed newRegistry);

    /// @notice Emitted when a label is synced to the labels mapping.
    /// @param tokenId The token identifier.
    /// @param label The synced label string.
    event LabelSynced(uint256 indexed tokenId, string label);

    /// @notice Returns whether a name is available for registration.
    /// @dev A name is available when it has not been registered yet, or when escrow owns
    ///      the token and the release lifecycle has reached the reclaimable state.
    /// @param id Token identifier.
    /// @return isAvailable True if the name can be registered.
    function available(uint256 id) external view returns (bool isAvailable);

    /// @notice Registers a name permanently.
    /// @dev Callable only by an authorised controller.
    ///      Registration mints the ERC721 token to `owner` and stores both the human-readable
    ///      label and its keccak256 hash for use during transfer store writes.
    /// @param id Token identifier.
    /// @param owner Owner of the name.
    /// @param label The human-readable label string (e.g. "alice").
    function register(uint256 id, address owner, string calldata label) external;

    /// @notice Adds an authorised controller.
    /// @dev Callable only by the contract owner. Typed as the shared baseline
    ///      {IDotnsController} so that the commit-reveal controller, the PoP
    ///      controller, and any future controller all pass without the registrar
    ///      depending on a specific controller shape.
    /// @param controller Controller to authorise.
    function addController(IDotnsController controller) external;

    /// @notice Removes an authorised controller.
    /// @dev Callable only by the contract owner.
    /// @param controller Controller to deauthorise.
    function removeController(IDotnsController controller) external;

    /// @notice Syncs a label to the internal labels mapping for a token.
    /// @dev Callable only by the token owner. The label is verified cryptographically
    ///      against the token identifier. Reverts if the label is already set.
    ///      TODO: We need to remove this before a fresh deployment
    /// @param tokenId The token identifier.
    /// @param label The human-readable label string (e.g. "alice").
    function syncLabel(uint256 tokenId, string calldata label) external;

    /// @notice Returns the human-readable label a token was registered with.
    /// @dev Canonical state source for the label string; any client that holds
    ///      a node or tokenId can resolve the original label in one view call
    ///      without scanning registration events. Returns the empty string
    ///      when the token does not exist or the label has never been synced.
    /// @param tokenId The token identifier (equal to `uint256(node)` for base names).
    /// @return label The label the token was registered with.
    function labelOf(uint256 tokenId) external view returns (string memory label);

    /// @notice Returns whether a token currently exists (has been minted and not burned).
    /// @param tokenId Token identifier.
    /// @return tokenExists True if the token has an owner, false otherwise.
    function exists(uint256 tokenId) external view returns (bool tokenExists);

    /// @notice Quotes the additional native fee required to transfer a token to `to`.
    /// @dev Returns the delta between the recipient-tier price and the token's current
    ///      covered running max. Returns zero for same-tier, upward, escrow-custody, or
    ///      already-covered moves. Reverts for nonexistent tokens and unsynced legacy labels.
    /// @param tokenId Token identifier.
    /// @param to Recipient address.
    /// @return requiredFee Native amount the caller must attach to the payable ERC721
    ///         transfer entrypoint; zero means the transfer is already fully covered.
    function quoteTransferFee(
        uint256 tokenId,
        address to
    )
        external
        view
        returns (uint256 requiredFee);

    /// @notice Updates the protocol registry address.
    /// @dev Callable only by the contract owner.
    /// @dev  TODO: This is temporary as we need to upgrade the contract we need to remember to
    /// remove this function If we deploy to a new environment
    /// @param registry The address of the new protocol registry.
    // TODO: On fresh deploy (not upgrade), remove this function. Set protocolRegistry in initialize instead.
    function updateProtocolRegistry(IDotnsProtocolRegistry registry) external;

    /// @inheritdoc IERC721
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
    function safeTransferFrom(address from, address to, uint256 tokenId) external payable override;
    /// @inheritdoc IERC721
    function transferFrom(address from, address to, uint256 tokenId) external payable override;
}
