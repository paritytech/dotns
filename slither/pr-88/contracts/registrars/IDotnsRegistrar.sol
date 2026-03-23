// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC721} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {IDotnsRegistrarController} from "./IDotnsRegistrarController.sol";
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

    /// @notice Emitted when a name is registered.
    /// @param id Token identifier.
    /// @param owner Owner of the name.
    event NameRegistered(uint256 indexed id, address indexed owner);

    /// @notice Emitted when a controller is added.
    /// @param controller Address granted controller permissions.
    event ControllerAdded(IDotnsRegistrarController indexed controller);

    /// @notice Emitted when a controller is removed.
    /// @param controller Address whose controller permissions were revoked.
    event ControllerRemoved(IDotnsRegistrarController indexed controller);

    /// @notice Emitted when the protocol registry is updated.
    /// @param newRegistry The address of the new protocol registry.
    event ProtocolRegistryUpdated(IDotnsProtocolRegistry indexed newRegistry);

    /// @notice Emitted when a label is synced to the labels mapping.
    /// @param tokenId The token identifier.
    /// @param label The synced label string.
    event LabelSynced(uint256 indexed tokenId, string label);

    /// @notice Returns whether a name is available for registration.
    /// @dev A name is available if and only if it has not been registered yet.
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
    /// @dev Callable only by the contract owner.
    /// @param controller Address to authorise.
    function addController(IDotnsRegistrarController controller) external;

    /// @notice Removes an authorised controller.
    /// @dev Callable only by the contract owner.
    /// @param controller Address to deauthorise.
    function removeController(IDotnsRegistrarController controller) external;

    /// @notice Updates the protocol registry address.
    /// @dev Callable only by the contract owner.
    /// @dev  TODO: This is temporary as we need to upgrade the contract we need to remember to remove this function
    ///       If we deploy to a new environment
    /// @param registry The address of the new protocol registry.
    function updateProtocolRegistry(IDotnsProtocolRegistry registry) external;

    /// @notice Syncs a label to the internal labels mapping for a token.
    /// @dev Callable only by the token owner. The label is verified cryptographically
    ///      against the token identifier. Reverts if the label is already set.
    ///      TODO: We need to remove this before a fresh deployment
    /// @param tokenId The token identifier.
    /// @param label The human-readable label string (e.g. "alice").
    function syncLabel(uint256 tokenId, string calldata label) external;
}
