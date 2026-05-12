// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ISystem} from "../external/revive/ISystem.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";

/// @title RootGatewayDispatcher
/// @notice Non-upgradeable shim that the PoP gateway pallet invokes in place of
///         {DotnsPopController} directly. The dispatcher is the direct callee of
///         `RuntimeOrigin::Root`, asks revive's System precompile whether its
///         caller is Root, and forwards the calldata to the controller proxy via
///         a regular `CALL` when (and only when) that check passes.
/// @dev Workaround for upstream polkadot-sdk PR #12051: `ISystem.callerIsRoot()`
///      does not propagate Root authority across the `delegatecall` boundary
///      that an upgradeable proxy introduces. Until that PR ships, the
///      controller cannot ask the precompile from its own implementation
///      context. This dispatcher restores the missing leg by hosting the
///      Root-authority check in a non-proxy contract that is the direct
///      Root callee, and converting that authority into an EVM-observable
///      `msg.sender == gateway` predicate the controller can check after the
///      regular forward call lands on its proxy.
///
/// Lifecycle:
/// - Deployed once per controller proxy with `target` bound to that proxy
///   address.
/// - The controller owner installs this dispatcher via
///   {DotnsPopController.setGateway}.
/// - The PoP gateway pallet is reconfigured to send Root-origin dispatches at
///   the dispatcher's address rather than the controller's.
///
/// Security:
/// - `target` is `immutable` so a deployed dispatcher can only ever forward to
///   the controller it was constructed against. Rotating the controller proxy
///   means deploying a new dispatcher and pointing the gateway pallet at it.
/// - The dispatcher holds no storage and never `delegatecall`s, so it cannot
///   be used as an arbitrary-target proxy.
/// - The fallback is non-payable: gated controller entrypoints are
///   non-payable, and rejecting `msg.value` at the dispatcher boundary keeps
///   the forwarded call shape identical to a direct controller call.
/// @custom:security-contact admin@parity.io
contract RootGatewayDispatcher {
    /// @notice Thrown when the immediate substrate origin is not `Root`.
    /// @dev `ISystem.callerIsRoot()` returns `false` (not revert) on a
    ///      non-Root origin, so the gate has to surface its own error.
    error NotRoot();

    /// @notice Controller proxy address this dispatcher forwards to.
    /// @dev Set once at construction and never reassigned.
    address public immutable target;

    /// @param target_ Address of the {DotnsPopController} proxy.
    constructor(address target_) {
        target = target_;
    }

    /// @notice Verifies Root authority via {ISystem.callerIsRoot} and forwards
    ///         the raw calldata to {target} via a regular `CALL`.
    /// @dev `callerIsRoot()` is evaluated in *this* contract's frame, which is
    ///      the direct callee of Root, so the precompile's pre-#12051 walk
    ///      succeeds. The forwarded `CALL` lands on the controller proxy with
    ///      `msg.sender == address(this)`, which the controller authorises
    ///      against its stored `gateway` slot.
    fallback() external {
        require(ISystem(DotnsConstants.REVIVE_SYSTEM).callerIsRoot(), NotRoot());

        (bool ok, bytes memory ret) = target.call(msg.data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        assembly {
            return(add(ret, 32), mload(ret))
        }
    }
}
