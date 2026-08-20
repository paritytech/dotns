// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ISystem} from "../external/revive/ISystem.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";

/// @title RootGatewayDispatcher
/// @notice Non-upgradeable shim that translates a substrate Root-origin
///         dispatch into an EVM-observable authority on the PoP controller
///         proxy. The dispatcher is the direct callee of the Root runtime
///         origin, asks the revive System precompile whether its caller is
///         Root, and forwards the calldata to the controller via a regular
///         message call when, and only when, that check passes.
/// @dev The Root-authority check must live in the frame that is the direct
///      callee of Root. A UUPS implementation runs inside the proxy's
///      delegatecall, so the controller cannot ask the precompile from its
///      own frame. The dispatcher hosts that check in a non-proxy contract
///      and converts the result into the immediate-caller predicate the
///      controller checks on the forwarded call.
///
/// Lifecycle:
/// - Deployed once per controller proxy with its target bound to that proxy
///   address.
/// - Registered on the protocol registry under the PoP gateway key; the
///   controller resolves this key on every gated call.
/// - The PoP gateway pallet sends Root-origin dispatches at the dispatcher's
///   address rather than the controller's.
///
/// Security:
/// - The target is immutable, so a deployed dispatcher can only ever forward
///   to the controller it was constructed against. Rotating the controller
///   proxy means deploying a new dispatcher and pointing the gateway pallet
///   at it.
/// - The dispatcher holds no storage and never delegatecalls, so it cannot
///   be used as an arbitrary-target proxy.
/// - The fallback is non-payable: gated controller entrypoints are
///   non-payable, and rejecting value transfers at the dispatcher boundary
///   keeps the forwarded call shape identical to a direct controller call.
/// @custom:security-contact admin@parity.io
contract RootGatewayDispatcher {
    /// @notice Thrown when the immediate substrate origin is not Root.
    /// @dev The revive System precompile returns false rather than reverting
    ///      on a non-Root origin, so the gate has to surface its own error.
    error NotRoot();

    /// @notice Controller proxy address this dispatcher forwards to.
    /// @dev Set once at construction and never reassigned.
    address public immutable TARGET;

    /// @param target_ Address of the PoP controller proxy.
    constructor(address target_) {
        TARGET = target_;
    }

    /// @notice Verifies Root authority through the revive System precompile
    ///         and forwards the raw calldata to the controller proxy via a
    ///         regular message call.
    /// @dev The precompile check is evaluated in this contract's frame, which
    ///      is the direct callee of Root, so the precompile resolves the
    ///      origin walk successfully. The forwarded call lands on the
    ///      controller proxy with this contract as the immediate caller,
    ///      which the controller authorises against the gateway address
    ///      registered on the protocol registry.
    fallback() external {
        require(ISystem(DotnsConstants.REVIVE_SYSTEM).callerIsRoot(), NotRoot());

        (bool ok, bytes memory ret) = TARGET.call(msg.data);
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
