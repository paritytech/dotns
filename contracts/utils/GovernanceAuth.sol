// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "./DotnsConstants.sol";

/// @title GovernanceAuth
/// @notice Decides which caller is governance for the protocol's admin surfaces.
/// @dev Authority is an address, never a property of the transaction. The one accepted caller is
///      whatever `DotnsConstants.ROOT_GATEWAY` resolves to: a non-upgradeable contract that
///      substrate Root calls directly, which proves Root in its own frame and forwards by regular
///      `CALL` so its callees see it as `msg.sender`.
/// @dev Do NOT gate an admin surface on `ISystem.originIsRoot`. That predicate is transaction
///      scoped rather than frame scoped: it is true in every frame of a Root-origin transaction,
///      so any contract that such a transaction happens to reach would pass, including code
///      governance never chose to trust. `ISystem.callerIsRoot` asks the right question but cannot
///      answer it from behind a proxy, because a `delegatecall` occupies a frame of its own and
///      displaces the one the precompile inspects. The gateway exists to resolve that, and every
///      other contract compares `msg.sender` against it through here.
/// @dev Reading `msg.sender` is safe on this path and only on this path. Under a Root origin there
///      is no account behind the caller and the PVM `caller` syscall traps, so a contract Root
///      calls directly must not read it. Everything downstream of the gateway is called by an
///      ordinary address.
/// @custom:security-contact admin@parity.io
library GovernanceAuth {
    /// @notice Whether `caller` is the protocol's governance entry point.
    /// @dev Resolved on every call rather than stored, so rotating the gateway is a single
    ///      `protocolRegistry.set` with no upgrade of the contracts that gate on it.
    /// @param protocolRegistry The canonical DotNS protocol registry.
    /// @param caller The address being checked, normally `msg.sender`.
    /// @return authorised True if `caller` is the currently registered Root gateway.
    function isGovernance(
        IDotnsProtocolRegistry protocolRegistry,
        address caller
    )
        internal
        view
        returns (bool authorised)
    {
        address gateway = protocolRegistry.get(DotnsConstants.ROOT_GATEWAY);
        // An unset key reads as the zero address. Without this guard a caller of `address(0)`
        // would match it and a partially wired deployment would sit open rather than closed.
        return gateway != address(0) && caller == gateway;
    }
}
