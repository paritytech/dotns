// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {IDotnsNameWhitelist} from "../whitelist/IDotnsNameWhitelist.sol";
import {DotnsConstants} from "./DotnsConstants.sol";

/// @title WhitelistUtils
/// @notice Shared read of the name whitelist's grants for the dotNS controllers.
/// @dev Every controller that refuses a granted name reads the grant through this library, so the
///      whitelist lookup and the network-without-whitelist case are handled in one place. Each
///      controller raises its own error.
/// @custom:security-contact admin@parity.io
library WhitelistUtils {
    /// @notice Returns the live grantee of the name at `node`, or the zero address.
    /// @dev A network with no whitelist configured has no grants to honour, so it returns the zero
    ///      address. Reads by node, so the whitelist makes no TLD lookup of its own.
    /// @param protocolRegistry Protocol registry the whitelist is configured in.
    /// @param node Namehash of the label under the active TLD.
    /// @return grantee Beneficiary of a live grant on the name, or the zero address.
    function granteeOf(
        IDotnsProtocolRegistry protocolRegistry,
        bytes32 node
    )
        internal
        view
        returns (address grantee)
    {
        address whitelist = protocolRegistry.get(DotnsConstants.NAME_WHITELIST);
        if (whitelist == address(0)) return address(0);
        return IDotnsNameWhitelist(whitelist).granteeOfNode(node);
    }
}
