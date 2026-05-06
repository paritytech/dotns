// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/// @title ISystem
/// @notice Minimal subset of revive's System precompile, vendored from
///         polkadot-sdk's `substrate/frame/revive/uapi/sol/ISystem.sol`.
///         Exposed at {SYSTEM_ADDR} on every revive runtime that opts the
///         precompile in.
/// @dev Kept intentionally minimal. New methods should be added on demand
///      rather than mirrored wholesale, so the audit surface stays small
///      and any upstream change is a deliberate review event.
interface ISystem {
    /// Returning true iff the immediate caller's substrate origin is `Root`.
    /// Reverts on a `RuntimeOrigin::Signed(_)` or non-Root origin.
    function callerIsRoot() external view returns (bool);
}

// Address at which revive exposes the System precompile. Matches the upstream
// constant in `substrate/frame/revive/uapi/sol/ISystem.sol`.
address constant SYSTEM_ADDR = address(0x0900);
