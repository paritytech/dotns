// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

/// @title IDotnsStore
/// @notice Baseline interface implemented by every per-user DotNS store.
/// @dev Marker interface shared by `ILabelStore` (protocol-written, labels-only) and
///      `IUserStore` (user-written, generic key/value). Every DotNS store type binds
///      to exactly one user forever, so `owner()` is the single shared surface.
///      Identity of a store is proven by its position in the `StoreFactory` mapping,
///      not by interface probing; the factory is the canonical source of truth.
/// @dev Shared base so the factory and any cross-store consumer can prove which user a store
///      is bound to via a single uniform `owner()` call regardless of the concrete store type.
/// @custom:security-contact admin@parity.io
interface IDotnsStore {
    /// @notice Returns the permanent user this store is bound to.
    /// @dev Set once at `initialize` and never mutated; used as the binding-mismatch oracle
    ///      and immutable thereafter.
    /// @return owner_ The bound user address.
    function owner() external view returns (address owner_);
}
