// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

/// @title dotNS PoP resolver clearing
/// @notice Removes the records the PoP flow keeps for a name: its chat key and its device link.
/// @dev Kept apart from @custom:interface IDotnsPopResolver so the interface id that one reports
/// through ERC-165 stays the same. The resolver reports both.
/// @custom:security-contact admin@parity.io
interface IDotnsPopResolverClearing {
    /// @notice Deletes the chat key stored at `node` and every device link that names it.
    /// @dev Callable only by the address registered as `POP_CONTROLLER`, otherwise
    /// @custom:reverts IDotnsPopResolver.NotPopController. The controller calls it when a name it
    /// issued is revoked, so whoever gets the name next does not inherit the previous holder's
    /// identity records. A personhood name's link to its device name is removed in both
    /// directions. A device name is linked by its labelhash rather than its node, so the caller
    /// passes it as `deviceLabelhash`, and the link from the personhood name that names it is
    /// removed in both directions too; pass zero for a personhood name. Emits
    /// @custom:emits IDotnsPopResolver.ChatKeyUpdated with empty bytes when a chat key was
    /// deleted, and @custom:emits IDotnsPopResolver.DeviceLinkUpdated with a zero labelhash for
    /// each personhood name that loses its link.
    /// @param node Node of the name being revoked.
    /// @param deviceLabelhash Labelhash of the device name at `node`, or zero when `node` is a
    /// personhood name.
    function clearRecords(bytes32 node, bytes32 deviceLabelhash) external;
}
