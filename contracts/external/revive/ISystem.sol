// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.34;

/// @title ISystem
/// @notice Minimal subset of revive's System precompile, vendored from
///         polkadot-sdk's `substrate/frame/revive/uapi/sol/ISystem.sol`.
///         Exposed at @custom:address SYSTEM_ADDR on every revive runtime that opts the
///         precompile in.
/// @dev Kept intentionally minimal. New methods should be added on demand
///      rather than mirrored wholesale, so the audit surface stays small
///      and any upstream change is a deliberate review event.
interface ISystem {
    /// Returns true iff the calling contract was called directly by a `Root` origin.
    /// @dev Delegate calls are skipped, so it holds in a UUPS implementation behind the proxy
    ///      Root called. Returns false for a signed origin and in any contract reached through
    ///      another contract.
    function callerIsRoot() external view returns (bool);
}
