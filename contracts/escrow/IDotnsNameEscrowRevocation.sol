// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

/// @title dotNS Name Escrow revocation
/// @notice The escrow's part in revoking a name: settling and removing the name's position.
/// @dev Kept apart from @custom:contract IDotnsNameEscrow so the interface id that one reports
/// through ERC-165 stays the same. The escrow reports both.
/// @custom:security-contact admin@parity.io
interface IDotnsNameEscrowRevocation {
    /// @notice Emitted when a revoked name's position is removed.
    /// @param tokenId The revoked token.
    /// @param recipient The position recipient, credited with any deposit still held.
    event PositionRevoked(uint256 indexed tokenId, address indexed recipient);

    /// @notice Settles and removes the position of a name being revoked.
    /// @dev Callable only by the registrar, otherwise @custom:reverts
    /// IDotnsNameEscrow.NotRegistrar. Any deposit the position still holds is credited to the
    /// position recipient's pull-payment balance, emitting
    /// @custom:emits IDotnsNameEscrow.RefundWithdrawn, and is claimable at once through
    /// @custom:function IDotnsNameEscrow.claimWithdrawal. The
    /// credit is written under the Root origin the revocation runs in, which carries the
    /// storage-deposit caveat of KNOWN_ISSUES.md issue 4. The position is then deleted and the
    /// token leaves the released set, so a released name loses its redeem window and a later
    /// registration of the name can seed a fresh position. A name with no position returns the zero
    /// address and changes nothing. Emits @custom:emits PositionRevoked when a position was
    /// removed.
    /// @param tokenId The token being revoked.
    /// @return recipient The position recipient, or the zero address when there was no position.
    function revoke(uint256 tokenId) external returns (address recipient);
}
