// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

/// @title dotNS PoP controller governance
/// @notice Governance calls on the PoP controller: revoking a name it issued, and evicting a
/// personhood name's reservation queue.
/// @dev Kept apart from @custom:interface IDotnsPopController so the interface id that one
/// reports through ERC-165 stays the same. The controller reports both. Both calls are
/// Root-gated, read no `msg.sender`, and revert with
/// @custom:reverts IDotnsPopController.NotRoot outside a Root origin.
/// @custom:security-contact admin@parity.io
interface IDotnsPopGovernance {
    /// @notice Thrown when @custom:function revokeName names a label this controller did not
    /// issue, or one already revoked.
    error NotPopIssued(bytes32 labelhash);

    /// @notice Emitted when a name this controller issued is revoked.
    /// @param labelhash `keccak256` of the label, as in the issuance events.
    /// @param label The bare label without the TLD.
    event NameRevoked(bytes32 indexed labelhash, string label);

    /// @notice Emitted when a personhood name's reservation queue is evicted.
    /// @dev Ends every reservation the queue held, the way @custom:event
    /// IDotnsPopController.ReservationClaimed does, so an indexer rebuilding queues from events
    /// drops them all.
    /// @param labelhash `keccak256` of the personhood name.
    event ReservationsEvicted(bytes32 indexed labelhash);

    /// @notice Revokes a device name or a personhood name this controller issued.
    /// @dev Root-gated. `label` must be one @custom:function IDotnsPopController.isPopIssued
    /// reports, otherwise @custom:reverts NotPopIssued; a numeric container is never one, so
    /// containers cannot be revoked. The gateway's state about the name goes first: the issued
    /// flag, then the chat key and the device link on the PoP resolver
    /// (@custom:function IDotnsPopResolverClearing.clearRecords). The name follows: a device name
    /// is deleted from the registry under the container this controller holds
    /// (@custom:function IDotnsRegistry.deleteSubname), and a personhood name is revoked on the
    /// registrar (@custom:function IDotnsRegistrar.revokeIssued). Either way its records and
    /// subnames are cleared and it can be issued or registered again. A pending claim for the
    /// label is left in the holder's queue, because settling it only writes the label into the
    /// holder's own store, and readers already check that store against the registry. The
    /// gateway pallet's own record of the account's names is not on this chain, so governance
    /// updates it in the same dispatch. Emits @custom:emits NameRevoked.
    /// @param label The bare label without the TLD, for example `joseph.42` or `josephine`.
    function revokeName(string calldata label) external;

    /// @notice Clears a personhood name's whole reservation queue and frees the name.
    /// @dev Root-gated. `label` must be a personhood label, otherwise
    /// @custom:reverts IDotnsPopController.InvalidPersonhoodLabel. Every entry is evicted in one
    /// step, whatever the queue holds: the front moves to the end, as on a claim, and the
    /// PopRules slot the queue held is released, so the name is reservable and registrable at
    /// once. Each evicted user's pointer reads as no reservation, and their next reservation
    /// clears it. An empty queue is left as it is and emits nothing, so a governance dispatch that
    /// races a claim or an expiry does not fail. Emits @custom:emits ReservationsEvicted.
    /// @param label The personhood name, bare, without the TLD.
    function evictReservations(string calldata label) external;
}
