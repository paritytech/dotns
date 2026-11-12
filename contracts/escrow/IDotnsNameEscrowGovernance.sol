// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

/// @title dotNS Name Escrow governance
/// @notice Governance calls on the escrow: spending the protocol fee balance.
/// @dev Kept apart from @custom:contract IDotnsNameEscrow so the interface id that one reports
/// through ERC-165 stays the same. The escrow reports both.
/// @custom:security-contact admin@parity.io
interface IDotnsNameEscrowGovernance {
    /// @notice Emitted when governance sends part of the protocol fee balance to `to`.
    /// @param to Address the fees were sent to.
    /// @param amount Native amount sent.
    event ProtocolFeesWithdrawn(address indexed to, uint256 amount);

    /// @notice Thrown when the caller is not a direct substrate Root dispatch.
    error NotRoot();

    /// @notice Thrown when a withdrawal asks for more than the protocol fee balance.
    /// @param amount Amount asked for.
    /// @param available Current protocol fee balance.
    error ProtocolFeesExceeded(uint256 amount, uint256 available);

    /// @notice Thrown when `to` does not accept the native transfer.
    /// @param to Address that rejected the transfer.
    error ProtocolFeesTransferFailed(address to);

    /// @notice Sends `amount` of the protocol fee balance to `to`.
    /// @dev Restricted to a substrate Root dispatch made to the escrow itself, otherwise
    /// @custom:reverts NotRoot. `to` must be non-zero (@custom:reverts
    /// IDotnsNameEscrow.InvalidRecipient), `amount` non-zero (@custom:reverts
    /// IDotnsNameEscrow.InvalidAmount) and at most the balance (@custom:reverts
    /// ProtocolFeesExceeded). Only the protocol fee balance is spent: deposits, pending
    /// withdrawals and refund entries stay out of reach. A recipient that rejects the transfer
    /// @custom:reverts ProtocolFeesTransferFailed. Emits @custom:emits ProtocolFeesWithdrawn.
    /// @param to Address the fees are sent to.
    /// @param amount Native amount to send, in wei.
    function withdrawProtocolFees(address to, uint256 amount) external;
}
