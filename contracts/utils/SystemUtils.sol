// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {ISystem} from "../external/revive/ISystem.sol";
import {DotnsConstants} from "./DotnsConstants.sol";

/// @title SystemUtils
/// @notice Shared access to revive's System precompile for dotNS contracts.
/// @dev Canonical wrapper around `ISystem` at `DotnsConstants.REVIVE_SYSTEM`, so the precompile
///      address and interface are wired in one place rather than duplicated per consumer.
/// @custom:security-contact admin@parity.io
library SystemUtils {
    /// @notice Returns whether substrate Root called this contract directly.
    /// @dev Reads `ISystem.callerIsRoot`, which is true only in the contract a Root dispatch
    ///      targets, including behind its UUPS proxy, and false in any contract that contract
    ///      calls. A contract reached later in the same Root transaction therefore cannot pass
    ///      the check. A Root origin has no account behind it, so a function gated on this must
    ///      not read `msg.sender` in the frame Root calls: reading it traps. Calls it makes are
    ///      fine, because they see a contract as caller.
    /// @return root True when the immediate caller is Root.
    function callerIsRoot() internal view returns (bool root) {
        return ISystem(DotnsConstants.REVIVE_SYSTEM).callerIsRoot();
    }
}
