// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ISystem} from "../external/revive/ISystem.sol";
import {DotnsConstants} from "./DotnsConstants.sol";

/// @title SystemUtils
/// @notice Shared access to revive's System precompile for DotNS contracts.
/// @dev Canonical wrapper around `ISystem` at `DotnsConstants.REVIVE_SYSTEM`, so the precompile
///      address and interface are wired in one place rather than duplicated per consumer.
/// @custom:security-contact admin@parity.io
library SystemUtils {
    /// @notice Returns whether substrate Root is the immediate caller of the calling contract.
    /// @dev Reads `ISystem.callerIsRoot`, which resolves the caller two frames below the
    ///      precompile. A `delegatecall` occupies a frame of its own, so this returns false inside
    ///      a UUPS implementation even on a direct one-hop Root dispatch. It is usable only from a
    ///      non-proxy contract that Root calls directly, which is what
    ///      @custom:contract DotnsRootGateway is for. Every other DotNS contract authorises on
    ///      `msg.sender == protocolRegistry.get(DotnsConstants.ROOT_GATEWAY)` instead.
    ///
    ///      `ISystem.originIsRoot` is deliberately not wrapped here, and must not be added. It is
    ///      transaction scoped: true in every frame of a Root-origin transaction, so every
    ///      contract such a transaction reaches passes it. Gating an admin surface on it makes all
    ///      of them governance principals. Authorisation belongs in
    ///      @custom:contract GovernanceAuth.
    /// @return root True when the calling contract's immediate caller is Root.
    function callerIsRoot() internal view returns (bool root) {
        return ISystem(DotnsConstants.REVIVE_SYSTEM).callerIsRoot();
    }
}
