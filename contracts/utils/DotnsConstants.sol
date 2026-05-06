// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title DotNS Constants
/// @notice Protocol-level invariants shared across DotNS contracts.
/// @custom:security-contact admin@parity.io
library DotnsConstants {
    /// @notice Address at which revive exposes the System precompile.
    /// @dev Matches the upstream constant in
    ///      `substrate/frame/revive/uapi/sol/ISystem.sol`.
    address internal constant REVIVE_SYSTEM = address(0x0900);

    /// @notice Namehash of the .dot TLD node.
    /// @dev keccak256(abi.encodePacked(bytes32(0), keccak256("dot")))
    bytes32 internal constant DOT_NODE =
        0x3fce7d1364a893e213bc4212792b517ffc88f5b13b86c8ef9c8d390c3a1370ce;

    /// @notice TLD suffix appended to labels when building full domain names.
    string internal constant TLD = ".dot";

    /// @notice Store key prefix for DotNS registration entries.
    /// @dev The Store is intentionally restricted to label-registration records only
    ///      (user-read, protocol-write). Other per-name data (chat keys, lite links,
    ///      content hashes, text records, reverse names) lives in dedicated resolver
    ///      contracts rather than on the Store.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant DOTNS_REGISTERED_KEY = bytes32("dotns.registered");

    // ── Protocol registry well-known keys ────────────────────────────

    /// @notice Well-known key for the ERC721 registrar backing name ownership.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant REGISTRAR = bytes32("registrar");

    /// @notice Well-known key for the registrar controller orchestrating commit-reveal registration.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant CONTROLLER = bytes32("controller");

    /// @notice Well-known key for the forward registry storing node ownership and resolver.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant REGISTRY = bytes32("registry");

    /// @notice Well-known key for the reverse resolver for address-to-name mapping.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant REVERSE_RESOLVER = bytes32("reverseResolver");

    /// @notice Well-known key for the PoP oracle enforcing eligibility and pricing.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant POP_RULES = bytes32("popRules");

    /// @notice Well-known key for the factory deploying per-user Store instances.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant STORE_FACTORY = bytes32("storeFactory");

    /// @notice Well-known key for the forward resolver storing address records.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant RESOLVER = bytes32("resolver");

    /// @notice Well-known key for the content resolver storing content hashes and text records.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant CONTENT_RESOLVER = bytes32("contentResolver");

    /// @notice Well-known key for the dedicated PoP controller orchestrating lite/full-person
    ///         username issuance on behalf of the PoP gateway.
    /// @dev Kept distinct from `CONTROLLER` (commit-reveal public controller) so the
    ///      two can coexist per `DotnsRegistrar`'s multi-controller affordance.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant POP_CONTROLLER = bytes32("popController");

    /// @notice Well-known key for the PoP resolver holding per-name records produced
    ///         by the PoP username flow (chat keys, lite => full links).
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant POP_RESOLVER = bytes32("popResolver");

    /// @notice Well-known key for the name escrow holding refundable deposits and
    ///         driving the release lifecycle for registered names.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant NAME_ESCROW = bytes32("nameEscrow");
}
