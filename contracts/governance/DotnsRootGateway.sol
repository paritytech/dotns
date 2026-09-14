// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {IDotnsRootGateway} from "./IDotnsRootGateway.sol";
import {SystemUtils} from "../utils/SystemUtils.sol";

/// @title DotnsRootGateway
/// @notice Sole authorised caller of the governance surface on the registrar controller,
///         `PopRules`, `DotnsNameWhitelist` and `DotnsPopController`.
/// @dev MUST NOT be deployed behind a proxy, and MUST NOT be made upgradeable. The entire value of
///      this contract is that it is the frame shape in which `ISystem.callerIsRoot` reads true: a
///      plain contract that Root calls directly. A `delegatecall` frame, or any contract sitting
///      between Root and this one, displaces the frame the precompile inspects and the check reads
///      false. There is deliberately no owner, no initialiser and no mutable storage.
///
///      `msg.sender` is never read here. This contract is called by Root, which has no account, so
///      the PVM `caller` syscall would trap. Authority comes from `callerIsRoot` alone.
///
///      Registration under `ROOT_GATEWAY` makes `IDotnsProtocolRegistry.isRegisteredAddress` true
///      for this address. That confers nothing on its own: store writes are gated by
///      @custom:contract StoreAuth, which admits the registrar, the registrar's controllers and
///      the registry, and deliberately rejects registry membership as authority.
///
///      Forwards no value. `execute` is not `payable` and makes every call with zero value, so a
///      governance entry point that is made `payable` later would be reachable from here but
///      never funded. Add value plumbing deliberately if that day comes; do not assume it works.
/// @custom:security-contact admin@parity.io
contract DotnsRootGateway is IDotnsRootGateway {
    /// @notice Protocol-level address registry used to validate forwarding targets.
    /// @dev Immutable and set at construction. The repository's rule that contracts resolve
    ///      siblings through the registry rather than an immutable peer address is satisfied: the
    ///      immutable here *is* the registry, which remains the indirection layer. This contract
    ///      is a non-upgradeable leaf, so it holds no storage to rewire.
    IDotnsProtocolRegistry public immutable protocolRegistry;

    /// @param registry Protocol-level address registry.
    constructor(IDotnsProtocolRegistry registry) {
        require(address(registry) != address(0), InvalidRegistry());
        protocolRegistry = registry;
    }

    /// @inheritdoc IDotnsRootGateway
    function execute(address[] calldata targets, bytes[] calldata payloads) external override {
        // Asks "is Root my caller", not "was this transaction Root-dispatched". It is answerable
        // here, and only here, because this contract is not behind a proxy: `callerIsRoot`
        // resolves the caller two frames below the precompile, and with no delegatecall frame in
        // the path that resolution falls through to the transaction origin.
        //
        // This is also what makes the function non-reentrant without a guard. A callee that calls
        // back into `execute` puts its own frame at the depth the precompile inspects, so the
        // check reads false and the re-entry reverts. Do not add a reentrancy guard on the
        // assumption that re-entry is otherwise possible, and do not weaken this check without
        // reinstating that property some other way.
        require(SystemUtils.callerIsRoot(), NotRoot());
        require(targets.length == payloads.length, LengthMismatch());
        require(targets.length != 0, EmptyBatch());

        for (uint256 i = 0; i < targets.length; i++) {
            address target = targets[i];
            bytes calldata payload = payloads[i];

            // Confine the gateway to the protocol. Root can dispatch anywhere on its own; what it
            // must not be able to do is borrow this contract's identity to reach code outside the
            // set, since downstream gates authorise on exactly that identity.
            require(protocolRegistry.isRegisteredAddress(target), TargetNotProtocol(target));

            emit RootCallForwarded(target, payload.length >= 4 ? bytes4(payload[:4]) : bytes4(0));

            // A regular CALL, not a delegatecall: the callee must observe this contract as
            // `msg.sender`, which is the whole authorisation mechanism.
            (bool ok, bytes memory returndata) = target.call(payload);
            if (!ok) {
                // Bubble the callee's revert data unchanged so governance sees the real error
                // rather than a generic gateway failure.
                assembly ("memory-safe") {
                    revert(add(returndata, 0x20), mload(returndata))
                }
            }
        }
    }
}
