// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IDotnsNameWhitelist
/// @notice Interface for the pre-launch name whitelist. A name is Open until governance either
///         reserves it or a claim is accepted for it. Several beneficiaries may claim the same
///         Open name, each with a reason, and governance accepts one as the winner.
/// @dev Callers never supply a hash. Every entry point takes the bare label and derives the node
///      from the label and the TLD in the protocol registry, so a caller cannot supply a
///      mismatched hash. Claims are keyed by the beneficiary `user`, not the submitter, so a
///      relayer or a cross-chain sovereign account can submit a claim on a user's behalf and the
///      name still binds to that user. All state is on-chain and queryable through views; no event
///      indexing is required. The entire admin surface is substrate Root: the gates check
///      `originIsRoot` and read no `msg.sender`, so Root's lack of an address is not a problem, and
///      no signed account grants, revokes, reserves, or retunes a cap. The controllers hold only
///      the `consume` hook.
/// @custom:security-contact admin@parity.io
interface IDotnsNameWhitelist {
    /// @notice Status of a name.
    /// @dev `Open` is the zero-value default: claimable, not reserved, not won. `Reserved` is
    ///      withheld by governance. `Claimed` has a single winner.
    enum NameStatus {
        Open,
        Reserved,
        Claimed
    }

    /// @notice Status of a single claim on a name.
    /// @dev `None` is the zero-value default of an absent claim. `Rejected` is sticky: it is kept
    ///      only when the beneficiary filed the claim themselves, so they cannot re-request; a
    ///      claim filed on their behalf is deleted on rejection and does not bind them.
    enum ClaimStatus {
        None,
        Requested,
        Rejected
    }

    /// @notice A claim by one beneficiary on one name.
    /// @dev `user`, `status` and `requestedAt` co-locate in one storage slot; `submitter` takes the
    ///      next, and the dynamic `reason` is stored separately.
    /// @param user Beneficiary the name would bind to if this claim wins.
    /// @param status Claim status; see ClaimStatus.
    /// @param requestedAt Timestamp the claim was made.
    /// @param submitter Address that filed the claim, which may differ from the beneficiary.
    /// @param reason Free-text justification for the claim.
    struct Claim {
        address user;
        ClaimStatus status;
        uint64 requestedAt;
        address submitter;
        string reason;
    }

    /// @notice A name and its resolved state, for review.
    /// @param node Namehash of the label under the active TLD.
    /// @param label Bare label.
    /// @param status Name status; see NameStatus.
    /// @param winner Winning beneficiary when `Claimed`, otherwise the zero address.
    struct NameView {
        bytes32 node;
        string label;
        NameStatus status;
        address winner;
    }

    /// @notice Stored resolved state of a name.
    /// @dev `status` and `winner` are ordered first so the 1-byte enum and 20-byte address share
    ///      one storage slot; the dynamic `label` is stored separately.
    /// @param status Name status; see NameStatus.
    /// @param winner Winning beneficiary when `Claimed`, otherwise the zero address.
    /// @param label Bare label, kept so reserved and claimed names are reviewable.
    struct NameRecord {
        NameStatus status;
        address winner;
        string label;
    }

    /// @notice Emitted when a beneficiary claims a name.
    event NameRequested(bytes32 indexed node, address indexed user, string label, string reason);

    /// @notice Emitted when a claim wins a name, including a direct governance grant.
    event NameAccepted(bytes32 indexed node, address indexed user, string label);

    /// @notice Emitted when a claim is cleared without winning.
    event NameRejected(bytes32 indexed node, address indexed user, string label);

    /// @notice Emitted when a name is reset to Open by governance.
    event NameRevoked(bytes32 indexed node, address indexed winner, string label);

    /// @notice Emitted when a winner registers the name and its entry is consumed.
    event NameConsumed(bytes32 indexed node, address indexed user, string label);

    /// @notice Emitted when governance withholds a name from claiming.
    event NameReserved(bytes32 indexed node, string label);

    /// @notice Emitted when governance releases a reserved name back to Open.
    event NameUnreserved(bytes32 indexed node, string label);

    /// @notice Emitted when the request window is set.
    /// @param openAt Timestamp requests start being accepted.
    /// @param closeAt Timestamp requests stop being accepted.
    event WindowSet(uint64 openAt, uint64 closeAt);

    /// @notice Emitted when the live-claim cap is set.
    /// @param maxClaimants New per-name claim cap.
    event MaxClaimantsSet(uint16 maxClaimants);

    /// @notice Emitted when the reason byte cap is set.
    /// @param maxReasonBytes New reason byte cap.
    event MaxReasonBytesSet(uint256 maxReasonBytes);

    /// @notice Emitted when the grant-batch cap is set.
    /// @param maxGrantBatch New `grantNames` batch cap.
    event MaxGrantBatchSet(uint16 maxGrantBatch);

    /// @notice Thrown when a claim names the zero-address beneficiary.
    error ZeroUser();

    /// @notice Thrown when a label is not a canonical single DNS label.
    error InvalidLabel();

    /// @notice Thrown when a reason exceeds `maxReasonBytes`.
    error ReasonTooLong();

    /// @notice Thrown when a name is not Open and the action requires it.
    /// @param node Namehash of the label under the active TLD.
    error NameNotOpen(bytes32 node);

    /// @notice Thrown when `user` already holds a claim on the name.
    /// @param node Namehash of the label under the active TLD.
    /// @param user Beneficiary already holding a claim.
    error AlreadyClaimed(bytes32 node, address user);

    /// @notice Thrown when a name already holds `maxClaimants` claims.
    /// @param node Namehash of the label under the active TLD.
    error TooManyClaimants(bytes32 node);

    /// @notice Thrown when the claim cap is set to zero or above
    /// `DotnsConstants.WHITELIST_MAX_CLAIMANTS_LIMIT`.
    error MaxClaimantsOutOfRange();

    /// @notice Thrown when the reason cap is set to zero or above
    /// `DotnsConstants.WHITELIST_MAX_REASON_LIMIT`.
    error MaxReasonBytesOutOfRange();

    /// @notice Thrown when the grant-batch cap is set to zero or above
    /// `DotnsConstants.WHITELIST_MAX_GRANT_BATCH_LIMIT`.
    error MaxGrantBatchOutOfRange();

    /// @notice Thrown when a claim is not in the `Requested` status.
    /// @param node Namehash of the label under the active TLD.
    /// @param user Beneficiary whose claim was expected to be pending.
    error NotRequested(bytes32 node, address user);

    /// @notice Thrown when releasing a name that is not reserved.
    /// @param node Namehash of the label under the active TLD.
    error NotReserved(bytes32 node);

    /// @notice Thrown when revoking a name that is not Claimed and holds no claims.
    /// @param node Namehash of the label under the active TLD.
    error NothingToRevoke(bytes32 node);

    /// @notice Thrown when a governance-gated call is not a substrate Root dispatch.
    /// @dev The whitelist's whole admin surface is Root-only: no signed account, owner included,
    ///      grants, revokes, reserves, or retunes a cap.
    error NotGovernance();

    /// @notice Thrown when `consume` is called by any address other than a registrar controller.
    /// @param caller Rejected caller.
    error NotController(address caller);

    /// @notice Thrown when `consume` is called for a name not won by the registrant.
    /// @param registrant Address attempting to register the name.
    /// @param node Namehash of the label under the active TLD.
    error NotWinner(address registrant, bytes32 node);

    /// @notice Thrown when the request window is set with a zero duration.
    error BadWindow();

    /// @notice Thrown when a claim is made outside the open window.
    error WindowClosed();

    /// @notice Thrown when `grantNames` is passed more than `maxGrantBatch` labels.
    error TooManyLabels();

    /// @notice Claims `label` for `user`.
    /// @dev Permissionless within the window; the submitter may differ from `user`. Requires the
    ///      name Open, the window open, `user` non-zero, a canonical label, `user` without an
    ///      existing claim, and fewer than `maxClaimants` claims on the name.
    ///      @custom:reverts WindowClosed, @custom:reverts NameNotOpen, @custom:reverts ZeroUser,
    ///      @custom:reverts InvalidLabel, @custom:reverts ReasonTooLong,
    ///      @custom:reverts AlreadyClaimed, or @custom:reverts TooManyClaimants.
    ///      @custom:emits NameRequested.
    /// @param label Bare label to claim.
    /// @param reason Free-text justification, at most `maxReasonBytes` bytes.
    /// @param user Beneficiary the name binds to if this claim wins.
    function requestName(string calldata label, string calldata reason, address user) external;

    /// @notice Accepts `user`'s claim as the winner of `label`.
    /// @dev Restricted to a substrate Root dispatch. Requires `user`'s claim `Requested`.
    /// Sets the name `Claimed` with `user` the winner and clears every claim on the name, rejecting
    ///      the losers. @custom:reverts NotRequested. @custom:emits NameAccepted for the winner and
    ///      @custom:emits NameRejected for each loser.
    /// @param label Bare label to resolve.
    /// @param user Beneficiary whose claim wins.
    function accept(string calldata label, address user) external;

    /// @notice Rejects `user`'s pending claim on `label` without resolving the name.
    /// @dev Restricted to a substrate Root dispatch. Requires the claim `Requested`.
    /// @custom:reverts NotRequested. @custom:emits NameRejected.
    /// @param label Bare label.
    /// @param user Beneficiary whose claim is rejected.
    function reject(string calldata label, address user) external;

    /// @notice Grants `label` to `user` directly, without a prior claim.
    /// @dev Restricted to a substrate Root dispatch. Requires the name Open, `user` non-zero
    /// and a canonical label. Sets the name `Claimed` with `user` the winner and clears any pending
    ///      claims. @custom:reverts NameNotOpen, @custom:reverts ZeroUser or
    ///      @custom:reverts InvalidLabel. @custom:emits NameAccepted, and
    ///      @custom:emits NameRejected for each cleared claim.
    /// @param label Bare label to grant.
    /// @param user Beneficiary the name binds to.
    function grantName(string calldata label, address user) external;

    /// @notice Grants several labels to one `user` directly.
    /// @dev Restricted to a substrate Root dispatch. Applies @custom:function grantName to
    ///      each, at most `maxGrantBatch` labels per call.
    ///      @custom:reverts TooManyLabels when `labels` exceeds the batch cap.
    /// @param labels Bare labels to grant.
    /// @param user Beneficiary each name binds to.
    function grantNames(string[] calldata labels, address user) external;

    /// @notice Resets `label` to Open, clearing any winner and claims.
    /// @dev Restricted to a substrate Root dispatch. Resolves a Claimed or claim-holding
    /// name; a Reserved name is released through @custom:function setReserved, not here.
    ///      @custom:reverts NothingToRevoke when the name is not Claimed and holds no claims.
    ///      @custom:emits NameRevoked, and @custom:emits NameRejected for each cleared claim.
    /// @param label Bare label to reset.
    function revokeName(string calldata label) external;

    /// @notice Reserves or releases `label`.
    /// @dev Restricted to a substrate Root dispatch. Reserving requires the name Open and clears
    /// any pending claims, rejecting each; releasing requires it `Reserved`. @custom:reverts
    /// NameNotOpen or @custom:reverts NotReserved. @custom:emits NameReserved or @custom:emits
    /// NameUnreserved. @param label Bare label.
    /// @param reserved True to reserve, false to release.
    function setReserved(string calldata label, bool reserved) external;

    /// @notice Removes the win on `label` as `registrant` registers it.
    /// @dev Restricted to the registrar controllers resolved through the protocol registry. Resets
    ///      the name to Open. @custom:reverts NotController for any other caller and
    ///      @custom:reverts NotWinner when `label` is not won by `registrant`.
    ///      @custom:emits NameConsumed.
    /// @param label Bare label being registered.
    /// @param registrant Address registering the name.
    function consume(string calldata label, address registrant) external;

    /// @notice Sets the request window relative to the current time.
    /// @dev Restricted to a substrate Root dispatch. Opens at `block.timestamp + startsIn` for
    /// `duration`. @custom:reverts BadWindow when `duration` is zero. @custom:emits WindowSet.
    /// @param startsIn Seconds from now until requests start being accepted.
    /// @param duration Seconds the window stays open.
    function setWindow(uint64 startsIn, uint64 duration) external;

    /// @notice Sets the live-claim cap per name.
    /// @dev Restricted to a substrate Root dispatch. The cap is bounded by
    /// `DotnsConstants.WHITELIST_MAX_CLAIMANTS_LIMIT`, which bounds the resolution clear-loop.
    /// @custom:reverts MaxClaimantsOutOfRange when `newMax` is zero or above the ceiling.
    /// @custom:emits MaxClaimantsSet.
    /// @param newMax New per-name claim cap.
    function setMaxClaimants(uint16 newMax) external;

    /// @notice Sets the reason byte cap.
    /// @dev Restricted to a substrate Root dispatch, bounded by
    /// `DotnsConstants.WHITELIST_MAX_REASON_LIMIT`. @custom:reverts MaxReasonBytesOutOfRange when
    /// `newMax` is zero or above the ceiling. @custom:emits MaxReasonBytesSet.
    /// @param newMax New reason byte cap.
    function setMaxReasonBytes(uint256 newMax) external;

    /// @notice Sets the cap on labels per `grantNames` call.
    /// @dev Restricted to a substrate Root dispatch, bounded by
    /// `DotnsConstants.WHITELIST_MAX_GRANT_BATCH_LIMIT`. @custom:reverts MaxGrantBatchOutOfRange
    /// when `newMax` is zero or above the ceiling. @custom:emits MaxGrantBatchSet.
    /// @param newMax New batch cap.
    function setMaxGrantBatch(uint16 newMax) external;

    /// @notice Returns the live-claim cap per name.
    /// @return cap Current per-name claim cap.
    function maxClaimants() external view returns (uint16 cap);

    /// @notice Returns the reason byte cap.
    /// @return cap Current reason byte cap.
    function maxReasonBytes() external view returns (uint256 cap);

    /// @notice Returns the cap on labels per `grantNames` call.
    /// @return cap Current batch cap.
    function maxGrantBatch() external view returns (uint16 cap);

    /// @notice Returns the status of `label`.
    /// @param label Bare label to look up.
    /// @return status Name status; see NameStatus.
    function statusOf(string calldata label) external view returns (NameStatus status);

    /// @notice Returns whether `label` is reserved.
    /// @param label Bare label to look up.
    /// @return reserved True when the name is `Reserved`.
    function isReserved(string calldata label) external view returns (bool reserved);

    /// @notice Returns the winner of `label`, or the zero address when not `Claimed`.
    /// @param label Bare label to look up.
    /// @return winner Winning beneficiary.
    function granteeOf(string calldata label) external view returns (address winner);

    /// @notice Returns whether `account` won `label`.
    /// @dev The pair check the controllers use to admit a registrant. False for the zero address.
    /// @param label Bare label to look up.
    /// @param account Address to test against the winner.
    /// @return granted True when `account` is the winner.
    function isGrantedTo(
        string calldata label,
        address account
    )
        external
        view
        returns (bool granted);

    /// @notice Returns `user`'s claim on `label`.
    /// @param label Bare label to look up.
    /// @param user Beneficiary to look up.
    /// @return claim The stored claim; a zeroed struct with `None` status when absent.
    function claimOf(string calldata label, address user) external view returns (Claim memory claim);

    /// @notice Returns the number of live claims on `label`.
    /// @param label Bare label to look up.
    /// @return count Live claim count.
    function claimantCount(string calldata label) external view returns (uint256 count);

    /// @notice Returns a page of claims on `label` for review.
    /// @dev Reads the canonical offset and limit window.
    /// @param label Bare label to look up.
    /// @param offset Index of the first claim.
    /// @param limit Maximum number of claims to return.
    /// @return page Claims in the window.
    function claims(
        string calldata label,
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (Claim[] memory page);

    /// @notice Returns the number of names with reserved, claimed or claim-holding state.
    /// @return count Active name count.
    function nameCount() external view returns (uint256 count);

    /// @notice Returns a page of active names for review.
    /// @dev Reads the canonical offset and limit window. Iteration order is not stable.
    /// @param offset Index of the first name.
    /// @param limit Maximum number of names to return.
    /// @return page Names in the window.
    function names(uint256 offset, uint256 limit) external view returns (NameView[] memory page);

    /// @notice Returns the request window.
    /// @return openAt Timestamp requests start being accepted.
    /// @return closeAt Timestamp requests stop being accepted.
    function window() external view returns (uint64 openAt, uint64 closeAt);

    /// @notice Returns whether requests are currently accepted.
    /// @return open True when the current time is within the window.
    function isWindowOpen() external view returns (bool open);
}
