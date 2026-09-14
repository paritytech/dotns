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
    /// Checks whether the caller of the contract calling this function is root.
    ///
    /// @dev Returns `false` on a signed origin; it does not revert.
    ///
    ///      Frame caveat, and the reason this cannot be used from a DotNS contract directly: the
    ///      check resolves the caller two frames below the precompile, and a `delegatecall`
    ///      occupies a frame of its own. A UUPS implementation therefore reads `false` here even
    ///      on a direct one-hop Root dispatch, because the frame at that depth is the proxy's own
    ///      rather than Root. Only a contract Root calls directly, with no proxy in front of it,
    ///      reads `true`. See @custom:contract DotnsRootGateway, which exists to be that shape.
    function callerIsRoot() external view returns (bool);

    /// Checks whether the origin of the whole call stack is root.
    ///
    /// @dev Unlike `callerIsRoot`, this does not require the immediate caller to be the origin: it
    ///      returns `true` whenever the top-level dispatch was made with a root origin, regardless
    ///      of how many contract or delegate-call frames separate the precompile from that
    ///      dispatch. This is the analogue of `tx.origin == ROOT` and is intended for upgradeable
    ///      proxy patterns where root authority needs to flow through intermediate frames. Returns
    ///      false, rather than reverting, on a non-Root origin.
    ///
    ///      NOT AN AUTHORISATION PRIMITIVE. Because it holds in every frame of a Root transaction,
    ///      any contract reached during that transaction reads `true` here, including code the
    ///      Root dispatch did not intend to trust. It answers "was this transaction
    ///      Root-dispatched", not "is Root my caller". DotNS gates on the latter, through
    ///      @custom:contract DotnsRootGateway.
    function originIsRoot() external view returns (bool);
}
