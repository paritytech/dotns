// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

/// @title dotNS Name Escrow withdrawal to another address
/// @notice Lets an account collect its pull-payment balance at an address it names.
/// @dev Kept apart from @custom:contract IDotnsNameEscrow so the interface id that one reports
/// through ERC-165 stays the same. The escrow reports both.
/// @custom:security-contact admin@parity.io
interface IDotnsNameEscrowWithdrawalTo {
    /// @notice Pulls the caller's accumulated pending refund balance and sends it to `recipient`.
    /// @dev The same as @custom:function IDotnsNameEscrow.claimWithdrawal, except where the value
    /// goes. It is how a contract that rejects incoming value collects a balance credited to it,
    /// such as a registration overpayment refund. `recipient` must be non-zero, otherwise
    /// @custom:reverts IDotnsNameEscrow.InvalidRecipient. Emits
    /// @custom:emits IDotnsNameEscrow.WithdrawalClaimed for the caller.
    /// @param recipient Address the balance is sent to.
    /// @return amount Native amount transferred to `recipient`.
    function claimWithdrawalTo(address recipient) external returns (uint256 amount);
}
