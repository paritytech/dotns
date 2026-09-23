// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

/// @title IDotnsProtocolRegistry
/// @author Parity
/// @notice Interface for the DotNS protocol-level address registry.
/// @dev Single source of truth for sibling lookups. Contracts resolve each other via well-known
///      `bytes32` constants in `DotnsConstants` so an upgrade or rewire only mutates the
///      registry, never the consumers. The registry also holds the network's top-level domain,
///      so every consumer reads one TLD rather than compiling its own.
/// @custom:security-contact admin@parity.io
interface IDotnsProtocolRegistry {
    /// @notice Emitted when a protocol address is set or updated.
    event AddressUpdated(bytes32 indexed key, address indexed addr);

    /// @notice Emitted when a key is cleared from the registry.
    event AddressRemoved(bytes32 indexed key, address indexed addr);

    /// @notice Emitted when the declared protocol release changes.
    event ProtocolVersionSet(string semver);

    /// @notice Emitted when the codehash declared for a key is set or reset.
    event ExpectedCodehashSet(bytes32 indexed key, bytes32 codehash);

    /// @notice Thrown when a zero address is provided where one is not allowed.
    error ZeroAddress();

    /// @notice Thrown when clearing a key that holds no address.
    error KeyNotRegistered();

    /// @notice Thrown when the TLD label supplied at initialisation is not a single DNS label.
    error InvalidTld();

    /// @notice Thrown when a declared protocol version is empty or does not start with a digit.
    error InvalidProtocolVersion();

    /// @notice Returns the address stored for a given key.
    /// @dev Returns `address(0)` when the key is unset; callers must validate when non-zero is
    ///      required.
    function get(bytes32 key) external view returns (address addr);

    /// @notice Sets or updates the address for a given key.
    /// @dev Owner-restricted, otherwise @custom:reverts OwnableUnauthorizedAccount. `addr`
    ///      must be non-zero, otherwise @custom:reverts ZeroAddress. Idempotent when the new
    ///      value matches the stored one (no event emitted in that case). Maintains a
    ///      per-address refcount so the same contract can occupy multiple keys without losing
    ///      its registered status until every key is rewired. Emits
    ///      @custom:emits AddressUpdated on each effective change.
    function set(bytes32 key, address addr) external;

    /// @notice Clears the address stored for a given key.
    /// @dev Owner-restricted, otherwise @custom:reverts OwnableUnauthorizedAccount. The key must
    ///      hold an address, otherwise @custom:reverts KeyNotRegistered. Decrements the removed
    ///      address's refcount, so a contract still reachable under another key keeps its
    ///      registered status. Exists because the registry is a discovery directory that would
    ///      otherwise only ever grow: a contract retired from the protocol, or one published for
    ///      lookup that should no longer be listed, has no other way out. Also clears any
    ///      codehash declared for the key, so a later re-registration never starts out with a
    ///      stale claim. Emits @custom:emits AddressRemoved.
    function remove(bytes32 key) external;

    /// @notice Returns true iff `addr` is currently registered under at least one well-known key.
    /// @dev O(1) refcount-backed lookup answering discovery, not authority: it reports that
    ///      governance listed an address, not that the address may act. Store writes and
    ///      `StoreFactory` deploys are gated on the specific components in
    ///      @custom:function StoreAuth.isStoreWriter, not on this, precisely so that listing a
    ///      contract for discovery does not confer write authority. Treats `address(0)` as never
    ///      registered regardless of refcount.
    function isRegisteredAddress(address addr) external view returns (bool registered);

    /// @notice Returns the namehash of the network's TLD node.
    /// @dev `namehash(0, keccak256(bytes(tldLabel)))`, fixed at initialisation. Consumers use it
    ///      as the root parent when deriving a name's node.
    function tldNode() external view returns (bytes32 node);

    /// @notice Returns the network's TLD suffix, including the leading dot (e.g. `.dot`).
    /// @dev Fixed at initialisation. Consumers append it when rendering a label as a full name.
    function tld() external view returns (string memory suffix);

    /// @notice Returns the release tag this network was last declared to run, as bare semver
    ///         (e.g. `0.8.0`, never `v0.8.0` and never with build metadata).
    /// @dev Written by the deploy and upgrade tooling as the final step of a fully applied
    ///      deployment or upgrade, so a crashed or partial run leaves the previous value
    ///      standing rather than over-claiming. Empty until first set; consumers treat empty
    ///      as "this deployment predates version declarations" and fall back to probing. A
    ///      declaration, not a proof: the owner is trusted to keep it truthful, and
    ///      @custom:function expectedCodehash is the per-contract cross-check.
    function protocolVersion() external view returns (string memory semver);

    /// @notice Declares the release tag this network runs.
    /// @dev Owner-restricted, otherwise @custom:reverts OwnableUnauthorizedAccount. `semver`
    ///      must be non-empty, start with an ASCII digit, and contain only alphanumerics, dots,
    ///      and hyphens, otherwise @custom:reverts InvalidProtocolVersion. That admits semver
    ///      core and pre-release identifiers (`0.8.0`, `0.8.0-rc.1`) while rejecting the two
    ///      values consumers cannot parse and compare: a leading `v` and `+` build metadata.
    ///      Full semver validation stays in the tooling. Emits
    ///      @custom:emits ProtocolVersionSet.
    function setProtocolVersion(string calldata semver) external;

    /// @notice Returns the codehash declared for the code that executes for `key`.
    /// @dev For a proxy entry this is the implementation's codehash; for a plain contract, its
    ///      own. `bytes32(0)` means never declared (or reset). Comparing this against the
    ///      actual codehash behind @custom:function get detects an upgrade performed outside
    ///      the release tooling: the declaration lives here while the code lives there, so
    ///      drift between the two is the signal, and clearing it requires re-declaring, which
    ///      is the discipline the check enforces. Verification against release artifacts is
    ///      the trustless escalation and lives off chain.
    function expectedCodehash(bytes32 key) external view returns (bytes32 codehash);

    /// @notice Declares the codehash of the code that executes for `key`.
    /// @dev Owner-restricted, otherwise @custom:reverts OwnableUnauthorizedAccount. The key
    ///      must currently be registered, otherwise @custom:reverts KeyNotRegistered; a
    ///      removal clears the declaration, so an unregistered key never carries a stale
    ///      claim. `bytes32(0)` is allowed as an explicit reset to "undeclared". Kept separate
    ///      from @custom:function set so the write API stays minimal: the deploy tooling pairs
    ///      the two calls, and an unpaired rewire is not silent, it surfaces as
    ///      declared-versus-actual drift to any verifier. Emits
    ///      @custom:emits ExpectedCodehashSet.
    function setExpectedCodehash(bytes32 key, bytes32 codehash) external;
}
