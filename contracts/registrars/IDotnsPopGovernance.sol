// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

/// @title dotNS PoP controller governance
/// @notice Governance calls on the PoP controller: revoking a name it issued, and evicting a
/// personhood name's reservation queue.
/// @dev Kept apart from @custom:contract IDotnsPopController so the interface id that one
/// reports through ERC-165 stays the same. The controller reports both. All three calls are
/// Root-gated, read no `msg.sender` (see SystemUtils.originIsRoot), and revert with
/// @custom:reverts IDotnsPopController.NotRoot outside a Root origin.
/// @custom:security-contact admin@parity.io
interface IDotnsPopGovernance {
    /// @notice Thrown when @custom:function revokeName names a label this controller did not
    /// issue, or one already revoked.
    error NotPopIssued(bytes32 labelhash);

    /// @notice Emitted when a name this controller issued is revoked.
    /// @dev Named apart from the whitelist's and the registrar's `NameRevoked`, so a log filter on
    /// the event signature alone never mixes a labelhash with a node.
    /// @param labelhash `keccak256` of the label, as in the issuance events.
    /// @param holder The account the name was taken from.
    /// @param label The bare label without the TLD.
    event IssuedNameRevoked(bytes32 indexed labelhash, address indexed holder, string label);

    /// @notice Emitted when a personhood name's reservation queue is evicted.
    /// @dev Ends every reservation the queue held, the way
    /// @custom:emits IDotnsPopController.ReservationClaimed does, so an indexer rebuilding queues
    /// from events drops them all.
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
    /// linked subnames are cleared and it can be issued again; a personhood name can also be
    /// registered on the public path, under the usual rules. A pending claim for the label stays
    /// in the holder's queue and is dropped without a write when it is settled
    /// (@custom:function IDotnsPopController.settlePendingClaims). The gateway pallet keeps its
    /// own record of the account's names and its alias, and has no call that clears them, so the
    /// pallet keeps rejecting that account and person for a new personhood name (KNOWN_ISSUES.md
    /// issue 5). Revoking a device name leaves its holder's personhood reservation in place,
    /// because the reservation does not depend on it; @custom:function evictReservation removes
    /// it when governance wants that too. Emits @custom:emits IssuedNameRevoked.
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

    /// @notice Ends one user's personhood-name reservation, wherever it sits in its queue.
    /// @dev Root-gated. The precise remedy when only some entries in a queue should go, such as
    /// candidates an attester controls, without evicting the users waiting behind them. The entry
    /// is removed as @custom:function IDotnsPopController.relinquishReservation removes it: in
    /// place when it is behind the front, and when it is the front, the reservation and the
    /// PopRules slot move to the next user with an active reservation, or the slot is released
    /// when none is left. A user with no active reservation is left as they are and nothing is
    /// emitted, so a dispatch that races a claim or an expiry does not fail. Emits
    /// @custom:emits IDotnsPopController.ReservationRelinquished.
    /// @param user Account whose reservation is ended.
    function evictReservation(address user) external;
}
