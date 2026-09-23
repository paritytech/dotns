// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {ISystem} from "../external/revive/ISystem.sol";
import {DotnsConstants} from "./DotnsConstants.sol";

/// @title SystemUtils
/// @notice Shared access to revive's System precompile for DotNS contracts.
/// @dev Canonical wrapper around `ISystem` at `DotnsConstants.REVIVE_SYSTEM`, so the precompile
///      address and interface are wired in one place rather than duplicated per consumer.
/// @custom:security-contact admin@parity.io
library SystemUtils {
    /// @notice Returns whether the transaction-level origin is substrate Root.
    /// @dev Reads the stack origin through `ISystem.originIsRoot`, which holds through a UUPS
    ///      proxy's delegatecall frame where `callerIsRoot` returns false, and returns false
    ///      rather than reverting on a non-Root origin.
    /// @return root True when the transaction origin is Root.
    function originIsRoot() internal view returns (bool root) {
        return ISystem(DotnsConstants.REVIVE_SYSTEM).originIsRoot();
    }
}
