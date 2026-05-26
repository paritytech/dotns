// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {DotnsConstants} from "./DotnsConstants.sol";

/// @title DotNS Label Utilities Library
/// @notice Canonical keccak labelhash and `.dot`-TLD namehash helpers shared by every
///         DotNS contract that derives node identifiers from user-supplied labels.
/// @dev Exists so that the identical inline-assembly keccak sequences don't need to
///      live in every controller, registrar, or resolver. Every caller that maps a
///      label to an on-chain node goes through this library, which is the single
///      source of truth for how a label hashes.
/// @dev Deliberate non-goals:
///      - Validation (single-label checks, min-length rules, availability): each caller
///        owns its own validation policy alongside its own interface-declared errors.
///        Centralising validation here would require centralising the error types, which
///        breaks interface-level error ownership.
///      - Lowercase ASCII letters/digits/hyphen rules with hyphen-position constraints
///        live in @custom:function StringUtils.isSingleLabel; this library treats the input as
/// opaque bytes once a caller has run its own checks.
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
    ///      semantics as @custom:function labelhash, different calldata shape.
    /// @param label Label string held in memory.
    /// @return hash `keccak256(bytes(label))`.
    function labelhashMemory(string memory label) internal pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            hash := keccak256(add(label, 0x20), mload(label))
        }
    }

    /// @notice Computes `namehash(parent, labelhash)` against an arbitrary parent.
    /// @dev General form of @custom:function namehash; use when the parent is not the `.dot` TLD
    ///      (e.g. subnode derivation under a non-TLD parent in the forward registry,
    ///      or a PoP namespace root). For top-level `.dot` registrations prefer
    ///      @custom:function namehash which hard-codes `DOT_NODE`.
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
    /// @dev Specialised to the `.dot` TLD; cheaper than @custom:function namehashUnder because
    ///      the parent constant is folded in at compile time.
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
    /// @dev Convenience combinator for registration flows: hashes the label
    ///      exactly once and returns both identifiers callers need without
    ///      recomputing.
    /// @param label Label string.
    /// @return hash `keccak256(bytes(label))`.
    /// @return node `namehash(DOT_NODE, hash)`.
    function deriveNode(string calldata label) internal pure returns (bytes32 hash, bytes32 node) {
        hash = labelhash(label);
        node = namehash(hash);
    }

    /// @notice Strips the configured `.dot` TLD suffix from a stored full name.
    /// @dev Returns the empty string when the input does not end in the TLD; callers treat
    ///      an empty return as a "do not trust this record" signal.
    function stripDotTld(string memory fullName) internal pure returns (string memory label) {
        bytes memory full = bytes(fullName);
        bytes memory tld = bytes(DotnsConstants.TLD);
        if (full.length <= tld.length) return "";

        uint256 baseLength = full.length - tld.length;
        for (uint256 i; i < tld.length; ++i) {
            if (full[baseLength + i] != tld[i]) return "";
        }

        bytes memory bare = new bytes(baseLength);
        for (uint256 i; i < baseLength; ++i) {
            bare[i] = full[i];
        }
        return string(bare);
    }
}
