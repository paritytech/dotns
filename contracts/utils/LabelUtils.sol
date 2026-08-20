// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title DotNS Label Utilities Library
/// @notice Canonical keccak labelhash and namehash helpers shared by every DotNS contract that
///         derives node identifiers from user-supplied labels.
/// @dev Exists so that the identical inline-assembly keccak sequences don't need to
///      live in every controller, registrar, or resolver. Every caller that maps a
///      label to an on-chain node goes through this library, which is the single
///      source of truth for how a label hashes. The TLD is supplied by the caller (read from the
///      protocol registry), so this library holds no network-specific constant.
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
    /// @dev Pass the TLD node (from the protocol registry) as `parent` for a top-level
    ///      registration, or a subnode/PoP-namespace node for a nested name.
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

    /// @notice Derives `(labelhash, node)` for a label under a given TLD node in one call.
    /// @dev Convenience combinator for registration flows: hashes the label
    ///      exactly once and returns both identifiers callers need without
    ///      recomputing.
    /// @param tldNode TLD node to root the name under, read from the protocol registry.
    /// @param label Label string.
    /// @return hash `keccak256(bytes(label))`.
    /// @return node `namehash(tldNode, hash)`.
    function deriveNode(
        bytes32 tldNode,
        string calldata label
    )
        internal
        pure
        returns (bytes32 hash, bytes32 node)
    {
        hash = labelhash(label);
        node = namehashUnder(tldNode, hash);
    }

    /// @notice Strips the network's TLD suffix from a stored full name.
    /// @dev Returns the empty string when the input does not end in `tld`; callers treat
    ///      an empty return as a "do not trust this record" signal.
    /// @param tldSuffix TLD suffix including the leading dot, read from the protocol registry.
    /// @param fullName Stored full name to strip.
    function stripTld(
        string memory tldSuffix,
        string memory fullName
    )
        internal
        pure
        returns (string memory label)
    {
        bytes memory full = bytes(fullName);
        bytes memory tld = bytes(tldSuffix);
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
