// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {DotnsConstants} from "./DotnsConstants.sol";

/// @title DotNS Label Utilities Library
/// @notice Canonical keccak labelhash and `.dot`-TLD namehash helpers shared by every
///         DotNS contract that derives node identifiers from user-supplied labels.
/// @dev Exists so that the identical inline-assembly keccak sequences don't need to
///      live in every controller, registrar, or resolver. Every caller that maps a
///      label to an on-chain node goes through this library, which is the single
///      source of truth for how a label hashes.
///
/// @dev Deliberate non-goals:
///      - Validation (single-label checks, min-length rules, availability): each caller
///        owns its own validation policy alongside its own interface-declared errors.
///        Centralising validation here would require centralising the error types, which
///        breaks interface-level error ownership.
/// @custom:security-contact admin@parity.io
library LabelUtils {
    /// @notice Computes `keccak256(bytes(label))` via memory-safe scratch space.
    /// @param label Label string.
    /// @return hash `keccak256(bytes(label))`.
    function labelhash(string calldata label) internal pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            let len := label.length
            calldatacopy(pointer, label.offset, len)
            hash := keccak256(pointer, len)
        }
    }

    /// @notice Computes `keccak256(bytes(label))` for a `memory` string.
    /// @dev Overload used by call sites that hold the label in memory (e.g. the
    ///      registrar's transfer sync path reading `_labels[tokenId]`). Same
    ///      semantics as {labelhash}, different calldata shape.
    /// @param label Label string held in memory.
    /// @return hash `keccak256(bytes(label))`.
    function labelhashMemory(string memory label) internal pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            hash := keccak256(add(label, 0x20), mload(label))
        }
    }

    /// @notice Computes `namehash(parent, labelhash)` against an arbitrary parent.
    /// @dev General form of {namehash}; use when the parent is not the `.dot` TLD
    ///      (e.g. subnode derivation under a non-TLD parent in the forward registry).
    /// @param parent Parent node.
    /// @param labelhash_ `keccak256(bytes(label))`.
    /// @return node `namehash(parent, labelhash)`.
    function namehashUnder(bytes32 parent, bytes32 labelhash_)
        internal
        pure
        returns (bytes32 node)
    {
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, parent)
            mstore(add(pointer, 0x20), labelhash_)
            node := keccak256(pointer, 0x40)
        }
    }

    /// @notice Computes `namehash(DOT_NODE, labelhash)` via memory-safe scratch space.
    /// @param labelhash_ `keccak256(bytes(label))`.
    /// @return node The node identifier under the `.dot` TLD.
    function namehash(bytes32 labelhash_) internal pure returns (bytes32 node) {
        bytes32 dotNode = DotnsConstants.DOT_NODE;
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, dotNode)
            mstore(add(pointer, 0x20), labelhash_)
            node := keccak256(pointer, 0x40)
        }
    }

    /// @notice Derives `(labelhash, node)` from a label in one call.
    /// @dev Convenience combinator; every controller that consumes a label needs both.
    /// @param label Label string.
    /// @return hash `keccak256(bytes(label))`.
    /// @return node `namehash(DOT_NODE, hash)`.
    function deriveNode(string calldata label) internal pure returns (bytes32 hash, bytes32 node) {
        hash = labelhash(label);
        node = namehash(hash);
    }
}
