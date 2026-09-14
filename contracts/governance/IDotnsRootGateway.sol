// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IDotnsRootGateway
/// @notice Interface for the non-upgradeable gateway that fronts every governance entry point in
///         DotNS.
/// @dev Exists to give the Root-gated surface a caller-side constraint. revive exposes two
///      primitives and neither is usable directly from a UUPS implementation frame:
///      `ISystem.callerIsRoot` resolves the caller two frames below the precompile and a
///      `delegatecall` occupies a frame of its own, so a proxy reads false even on a direct
///      one-hop Root dispatch; and `msg.sender` traps under a Root origin, which has no account.
///      That left `ISystem.originIsRoot`, which is transaction-scoped and therefore true in every
///      frame of a Root transaction, including frames belonging to code the Root dispatch did not
///      intend to trust.
///
///      This contract closes that gap by being the one shape where `callerIsRoot` works: a plain,
///      non-upgradeable contract that Root calls directly, with no proxy in front of it. It proves
///      Root in its own frame and forwards by regular `CALL`, so every gated contract downstream
///      sees a readable `msg.sender` equal to this address and can authorise on it.
/// @custom:security-contact admin@parity.io
interface IDotnsRootGateway {
    /// @notice Thrown when the constructor is given a zero protocol registry.
    error InvalidRegistry();

    /// @notice Thrown when the dispatch is not a direct substrate Root call into this contract.
    /// @dev Also thrown when Root reaches this contract through another contract rather than
    ///      directly: an intermediate frame displaces the one `callerIsRoot` inspects. Governance
    ///      must make this contract the `dest` of the `Revive.call` dispatch, not a callee of some
    ///      other contract such as `Multicall3`. Batch through `execute` instead.
    error NotRoot();

    /// @notice Thrown when `targets` and `payloads` differ in length.
    error LengthMismatch();

    /// @notice Thrown when an empty batch is submitted.
    error EmptyBatch();

    /// @notice Thrown when a target is not a member of the protocol registry.
    /// @param target Rejected target address.
    error TargetNotProtocol(address target);

    /// @notice Emitted for each call the gateway forwards.
    /// @param target Contract called.
    /// @param selector First four bytes of the payload, or zero for an empty payload.
    event RootCallForwarded(address indexed target, bytes4 indexed selector);

    /// @notice Forwards one or more calls to protocol contracts under Root authority.
    /// @dev Reverts unless substrate Root is the immediate caller of this contract. Each target
    ///      must be registered in the protocol registry, so the gateway can never be used to reach
    ///      code outside the protocol. Calls run in order and the whole batch reverts if any one
    ///      of them does, bubbling the callee's revert data unchanged.
    /// @param targets Protocol contracts to call, in order.
    /// @param payloads ABI-encoded calldata for each target, positionally matched.
    function execute(address[] calldata targets, bytes[] calldata payloads) external;
}
