// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title Dotns Name Escrow Interface
/// @notice Escrows refundable deposits for registered names and manages the release lifecycle.
/// @custom:security-contact admin@parity.io
interface IDotnsNameEscrow {
    /// @notice Parameters for recording a deposit position.
    /// @dev The refund recipient is seeded at deposit time but is not locked: it rebinds to the
    ///      current NFT holder on every transfer that moves the name off the prior recipient, so
    ///      the deposit follows the name rather than the original payer. Only the current holder
    ///      can release into escrow and pull the refund.
    /// @param asset Deposit asset. The zero address denotes the native token.
    /// @param recipient Initial refund recipient; rebound to the current NFT holder on transfer.
    struct DepositParams {
        uint256 tokenId;
        address asset;
        uint256 amount;
        address recipient;
    }

    /// @notice Parameters for recording a cross-tier registration fee into the insurance fund.
    /// @dev Funds the shared insurance pool used by `withdraw` to top up refunds whose per-asset
    ///      reserve is short; `payer` is preserved purely for event accounting since the deposit
    ///      itself is non-refundable.
    /// @param payer Original `msg.sender` of the controller's `register` call.
    /// @param recipient The NFT registrant the fee was paid on behalf of.
    struct InsuranceDepositParams {
        uint256 tokenId;
        address payer;
        address recipient;
    }

    /// @notice Inputs for charging transfer friction and rebinding the escrow position.
    /// @dev The fee charged is the flat reach floor returned by @custom:function
    ///      PopRules.transferFloor, settled to the insurance fund. The deposit, when present,
    ///      travels with the NFT: the position is rebound to the recipient so the new holder is
    ///      the only address that can later release into escrow and unlock the locked value.
    ///      There is no transfer-time refund path.
    /// @param reachFloor Required fee paid by the sender on a downward or cross-reach transfer.
    /// @param payer Original sender of the registrar transfer entrypoint.
    /// @param to NFT recipient. Becomes the new position recipient whenever a position exists.
    struct ChargeTransferFeeParams {
        uint256 tokenId;
        uint256 reachFloor;
        address payer;
        address to;
    }

    /// @notice Canonical escrow state for a token.
    /// @dev Tracks the phased lifecycle as two flags: `released` flips on `release` (NFT in escrow,
    ///      cooldown started); `claimed` flips on `withdraw` (refund credited to the pull-payment
    ///      ledger). The position is deleted on `reclaim`, freeing the slot for re-registration.
    /// @param asset Deposit asset. `address(0)` denotes native token.
    /// @param withdrawAvailableAt Earliest timestamp at which withdrawal is permitted.
    /// @param redeemableUntil Timestamp at which the holder's exclusive redeem window closes and
    ///        permissionless reclaim opens. Appended last so every pre-existing field keeps its
    ///        byte offset across the upgrade; it packs into the trailing slot alongside
    ///        `withdrawAvailableAt`, `released` and `claimed` without consuming a new one.
    struct ReleasePosition {
        address recipient;
        address asset;
        uint256 amount;
        uint64 withdrawAvailableAt;
        bool released;
        bool claimed;
        uint64 redeemableUntil;
    }

    /// @notice Time-locked refund entry produced when the protocol owes a recipient value
    ///         outside the registration-overpayment path.
    /// @dev Every credit creates a fresh entry with its own `availableAt`; later credits do not
    ///      reset earlier entries' clocks. Recipients claim entries individually or in batches.
    /// @param recipient Address that may claim this entry once `availableAt` has elapsed.
    /// @param amount Native value credited.
    /// @param availableAt Earliest block timestamp at which the recipient may claim.
    /// @param tokenId Token this entry was produced for, retained for traceability.
    struct RefundEntry {
        address recipient;
        uint256 amount;
        uint64 availableAt;
        uint256 tokenId;
    }

    /// @notice Emitted when a native-token deposit is recorded.
    event NativeDepositRecorded(uint256 indexed tokenId, uint256 amount);

    /// @notice Emitted when a token is released into escrow.
    /// @param recipient Refund recipient snapshotted at release time.
    /// @param asset Deposit asset. `address(0)` denotes native token.
    /// @param withdrawAvailableAt Earliest withdrawal timestamp.
    /// @param redeemableUntil Timestamp at which the redeem window closes and reclaim opens.
    event NameReleased(
        uint256 indexed tokenId,
        address indexed recipient,
        address indexed asset,
        uint256 amount,
        uint256 withdrawAvailableAt,
        uint256 redeemableUntil
    );

    /// @notice Emitted when a refund is credited to the recipient's pending balance.
    /// @param asset Refund asset. `address(0)` denotes native token.
    event RefundWithdrawn(
        uint256 indexed tokenId, address indexed recipient, address indexed asset, uint256 amount
    );

    /// @notice Emitted when a recipient pulls their accumulated pending refund balance.
    event WithdrawalClaimed(address indexed recipient, uint256 amount);

    /// @notice Emitted when a refund is credited to the time-locked refund ledger.
    /// @param recipient Address that may claim the entry once `availableAt` has elapsed.
    /// @param entryId Newly-assigned identifier for the credited entry.
    /// @param amount Native value credited.
    /// @param availableAt Earliest block timestamp at which the recipient may claim.
    /// @param tokenId Token associated with the credit, retained for traceability.
    event RefundCredited(
        address indexed recipient,
        uint256 indexed entryId,
        uint256 amount,
        uint64 availableAt,
        uint256 indexed tokenId
    );

    /// @notice Emitted when a recipient claims a single refund entry.
    /// @param recipient Address that pulled the entry.
    /// @param entryId Identifier of the claimed entry, now deleted.
    /// @param amount Native value transferred to `recipient`.
    event RefundClaimed(address indexed recipient, uint256 indexed entryId, uint256 amount);

    /// @notice Emitted when a released token is reclaimed by a new owner via registration.
    /// @param previousRecipient Address that received the refund for the prior registration.
    event NameReclaimed(
        uint256 indexed tokenId, address indexed previousRecipient, address indexed newOwner
    );

    /// @notice Emitted when the cooldown duration for future releases is updated.
    event CooldownUpdated(uint256 indexed currentCooldown, uint256 indexed newCooldown);

    /// @notice Emitted when the redeem window for future releases is updated.
    event RedeemWindowUpdated(uint256 indexed currentRedeemWindow, uint256 indexed newRedeemWindow);

    /// @notice Emitted when a released token is redeemed by its previous holder.
    /// @dev The counterpart to @custom:emits NameReleased: custody returns to `recipient` and the
    ///      deposit stays locked, so no value event accompanies this.
    /// @param recipient Address the NFT was returned to, which is also the position recipient.
    event NameRedeemed(uint256 indexed tokenId, address indexed recipient);

    /// @notice Emitted when a cross-tier fee is paid into the insurance fund.
    /// @param payer Original `msg.sender` whose value funded the fee.
    /// @param isRegistration True when emitted from `depositInsurance`; false from
    /// `chargeTransferFee`.
    event CrossTierFeePaid(
        uint256 indexed tokenId,
        address indexed payer,
        address indexed recipient,
        uint256 amount,
        bool isRegistration
    );

    /// @notice Emitted when a withdrawal draws from the insurance fund to cover a shortfall in
    /// `tokenReserved`.
    event InsuranceDraw(uint256 indexed tokenId, uint256 amount);

    /// @notice Emitted when overpayment is refunded to the payer.
    event OverpaymentRefunded(address indexed payer, uint256 amount);

    /// @notice Thrown when the caller is not the configured registrar controller.
    error NotController(address caller);

    /// @notice Thrown when the caller is not the configured registrar.
    error NotRegistrar(address caller);

    /// @notice Thrown when the supplied refund recipient is invalid (e.g. zero address).
    error InvalidRecipient();

    /// @notice Thrown when the attached call value is insufficient to cover the computed charge.
    error InsufficientValue();

    /// @notice Thrown when neither `tokenReserved` nor the insurance fund can cover the refund.
    /// @param available Combined balance available across reserves and insurance.
    error InsufficientFunds(uint256 tokenId, uint256 owed, uint256 available);

    /// @notice Thrown when assets being deposited are not supported by the escrow.
    error AssetNotSupported(address asset);

    /// @notice Thrown when the configured page size is invalid.
    error InvalidPageSize(uint256 limit);

    /// @notice Thrown when the configured cooldown is invalid.
    error InvalidCooldown();

    /// @notice Thrown when the supplied cooldown exceeds the contract's configured upper bound.
    /// @param supplied Cooldown value the caller asked for.
    /// @param maxAllowed Upper bound enforced by the contract.
    error CooldownTooLong(uint256 supplied, uint256 maxAllowed);

    /// @notice Thrown when the configured redeem window is invalid.
    /// @dev Also thrown by `release` when the window has never been seeded, which fails the release
    ///      closed rather than collapsing the holder's exclusive redeem phase to zero length.
    error InvalidRedeemWindow();

    /// @notice Thrown when the supplied redeem window exceeds the contract's configured upper
    /// bound.
    /// @param supplied Redeem window value the caller asked for.
    /// @param maxAllowed Upper bound enforced by the contract.
    error RedeemWindowTooLong(uint256 supplied, uint256 maxAllowed);

    /// @notice Thrown when the supplied amount is invalid.
    error InvalidAmount();

    /// @notice Thrown when the supplied ERC20 asset is invalid.
    error InvalidAsset();

    /// @notice Thrown when a deposit position is already funded.
    error PositionAlreadyFunded(uint256 tokenId);

    /// @notice Thrown when no deposit is configured for the token.
    error DepositNotConfigured(uint256 tokenId);

    /// @notice Thrown when the token has already been released.
    error AlreadyReleased(uint256 tokenId);

    /// @notice Thrown when the token has not been released.
    error NotReleased(uint256 tokenId);

    /// @notice Thrown when the refund has already been claimed.
    error AlreadyClaimed(uint256 tokenId);

    /// @notice Thrown when a token is not in a reclaimable state.
    /// @dev Reclaimable means released with the redeem window elapsed. A released token still
    ///      inside its window is deliberately not reclaimable: that window belongs to the previous
    ///      holder. Whether the deposit was withdrawn is irrelevant, because reclaim settles any
    ///      unwithdrawn amount itself.
    error NotReclaimable(uint256 tokenId);

    /// @notice Thrown when a token is not in a redeemable state.
    /// @dev Redeemable means released, not yet withdrawn, and still inside the redeem window.
    ///      A withdrawn position is excluded on purpose: the holder has already taken the deposit
    ///      value out, so returning the name as well would leave it unbacked.
    error NotRedeemable(uint256 tokenId);

    /// @notice Thrown when escrow is not approved to transfer the token.
    error EscrowNotApproved(uint256 tokenId);

    /// @notice Thrown when the caller is not the refund recipient.
    error NotRefundRecipient(address caller, uint256 tokenId);

    /// @notice Thrown when withdrawal is attempted before cooldown has elapsed.
    /// @param availableAt Earliest withdrawal timestamp.
    /// @param currentTime Current block timestamp.
    error WithdrawalTooEarly(uint256 tokenId, uint256 availableAt, uint256 currentTime);

    /// @notice Thrown when a refund transfer fails.
    error RefundFailed(uint256 tokenId);

    /// @notice Thrown when `claimWithdrawal()` is called but the caller has no pending balance.
    error NoPendingWithdrawal();

    /// @notice Thrown when a refund entry is referenced but does not exist.
    error NoSuchRefundEntry(uint256 entryId);

    /// @notice Thrown when a refund entry is claimed before its `availableAt` cooldown has
    ///         elapsed.
    error RefundLocked(uint256 entryId, uint64 availableAt);

    /// @notice Thrown when escrow receives an ERC721 transfer from a non-registrar source.
    error NotAcceptedTransfer(address caller);

    /// @notice Thrown when escrow receives a registrar-sourced ERC721 transfer that does not
    /// correspond to a live release. Blocks holders who try to push a token into custody by
    /// calling @custom:function safeTransferFrom directly without going through @custom:function
    /// release, which would otherwise trap the NFT and any deposit permanently.
    error UnsolicitedDeposit(uint256 tokenId);

    /// @notice Returns total amount of assets liabilities reserved for withdrawals.
    /// @param asset Asset address. `address(0)` denotes native token.
    function reserves(address asset) external view returns (uint256 amount);

    /// @notice Returns the escrow state for a token.
    function getReleasePosition(uint256 tokenId)
        external
        view
        returns (ReleasePosition memory position);

    /// @notice Returns the number of tokens currently held by escrow pending reclaim or withdrawal.
    /// @return count Number of released tokens not yet reclaimed.
    function releasedTokenCount() external view returns (uint256 count);

    /// @notice Returns a bounded paginated slice of released token identifiers.
    /// @dev `limit` must be non-zero and at most `MAX_RELEASED_PAGE_SIZE`, otherwise
    ///      @custom:reverts InvalidPageSize.
    /// @param start Start index into the released-token set.
    /// @param limit Maximum number of token identifiers to return.
    function releasedTokens(
        uint256 start,
        uint256 limit
    )
        external
        view
        returns (uint256[] memory tokenIds);

    /// @notice Records an asset deposit position for a token.
    /// @dev Only the configured controller may call this, otherwise @custom:reverts NotController.
    ///      `params.amount` must equal `msg.value`, otherwise @custom:reverts InvalidAmount; a
    ///      zero amount is accepted so cross-payer and free-tier registrations can still seed a
    ///      position that the release lifecycle can advance. Only native deposits are accepted
    ///      today, so a non-zero `params.asset` triggers @custom:reverts AssetNotSupported, and
    ///      a zero `params.recipient` triggers @custom:reverts InvalidRecipient. The slot for
    ///      `params.tokenId` must be empty (sentinel: `position.recipient == address(0)`):
    ///      a previously funded position triggers @custom:reverts PositionAlreadyFunded, and a
    ///      position already in the released phase triggers @custom:reverts AlreadyReleased.
    ///      Emits @custom:emits NativeDepositRecorded once the deposit is booked.
    function deposit(DepositParams calldata params) external payable;

    /// @notice Records a cross-tier registration fee into the insurance fund.
    /// @dev Only the configured controller may call this, otherwise @custom:reverts NotController.
    ///      `msg.value` must be non-zero, otherwise @custom:reverts InvalidAmount. Emits
    ///      @custom:emits CrossTierFeePaid with `isRegistration = true` once the fee is booked.
    function depositInsurance(InsuranceDepositParams calldata params) external payable;

    /// @notice Credits `msg.value` to `recipient`'s pull-payment ledger so the caller can later
    ///         pull the balance with @custom:func claimWithdrawal.
    /// @dev Only the configured controller may call this, otherwise @custom:reverts NotController.
    ///      `recipient` must be non-zero (@custom:reverts InvalidRecipient) and `msg.value` must
    ///      be non-zero (@custom:reverts InvalidAmount). Used by the registrar controller to
    ///      refund overpayment without pushing native value into a potentially reverting
    ///      contract receiver. Emits @custom:emits OverpaymentRefunded once the credit lands.
    /// @param recipient Address whose pending balance should grow by `msg.value`.
    function creditOverpayment(address recipient) external payable;

    /// @notice Charges transfer friction and rebinds the token's escrow position to the new holder.
    /// @dev Only the configured registrar may call this, otherwise @custom:reverts NotRegistrar.
    ///      When a fee is owed, the attached value must cover it or @custom:reverts
    ///      InsufficientValue. Whenever a position exists for the token and the NFT is leaving its
    ///      prior recipient, the position recipient is rebound to the new holder so the deposit
    ///      (when funded) and the lifecycle marker (when zero-amount) both follow the NFT. The
    ///      escrow does not refund anyone at transfer time; the only path back to the locked
    ///      deposit is for the current holder to release into escrow and wait the cooldown.
    ///      Emits @custom:emits CrossTierFeePaid (non-registration) when a non-zero fee is credited
    ///      to insurance, and credits any surplus value to the payer on the time-locked refund
    ///      ledger via @custom:emits RefundCredited.
    /// @return charged Amount actually credited to insurance.
    function chargeTransferFee(ChargeTransferFeeParams calldata params)
        external
        payable
        returns (uint256 charged);

    /// @notice Returns the cumulative cross-tier fee balance held against future shortfalls.
    /// @return balance Current insurance fund balance, in wei.
    function insuranceFund() external view returns (uint256 balance);

    /// @notice Releases a token into escrow and starts the withdrawal cooldown.
    /// @dev First step of the phased lifecycle. The caller must be the current NFT holder and the
    ///      current position recipient (the field is rebound to the holder on every transfer that
    ///      moves the name off the prior recipient), otherwise @custom:reverts NotRefundRecipient.
    ///      Approved operators cannot release on behalf of the holder because the recipient field
    ///      is keyed to the holder, not to any approval set, which keeps the deposit refund tied
    ///      to the on-chain owner. The slot for `tokenId` must already hold a position (sentinel:
    ///      `position.recipient != address(0)`); an unseeded slot triggers @custom:reverts
    ///      DepositNotConfigured, and a position already in the released phase triggers
    ///      @custom:reverts AlreadyReleased. Zero-amount positions are still releasable so every
    ///      minted name has a reachable lifecycle. The escrow must additionally be approved to
    ///      move the NFT, otherwise @custom:reverts EscrowNotApproved. Emits @custom:emits
    ///      NameReleased once the NFT is moved into custody.
    ///      Release stamps two independent clocks. `withdrawAvailableAt` (release + `cooldown`)
    ///      opens the deposit withdrawal; `redeemableUntil` (release + `redeemWindow`) closes the
    ///      holder's exclusive redeem phase and opens permissionless reclaim. Both are snapshots
    ///      so later policy changes never move an in-flight position. A release attempted while
    ///      `redeemWindow` is unseeded triggers @custom:reverts InvalidRedeemWindow.
    function release(uint256 tokenId) external;

    /// @notice Credits the refundable deposit for a released token to the recipient's pending
    /// balance.
    /// @dev Second step of the phased lifecycle. The position must already be released
    ///      (@custom:reverts NotReleased otherwise) and not yet claimed (@custom:reverts
    ///      AlreadyClaimed on re-entry). Only the current position recipient (the address that
    ///      released the name, which mirrored the NFT holder at that moment) may call this,
    ///      otherwise @custom:reverts NotRefundRecipient, and `block.timestamp` must have reached
    ///      `withdrawAvailableAt`, otherwise @custom:reverts WithdrawalTooEarly. Draws from the
    ///      per-asset `tokenReserved` pool first and falls back to the shared insurance fund on
    ///      shortfall; if even the combined balance is short, @custom:reverts InsufficientFunds.
    ///      Funds are not transferred here, only credited to the pull-payment ledger. Emits
    ///      @custom:emits RefundWithdrawn once the credit lands, and @custom:emits InsuranceDraw
    ///      whenever the insurance fund tops up a shortfall.
    function withdraw(uint256 tokenId) external;

    /// @notice Pulls the caller's accumulated pending refund balance.
    /// @dev Final step of the phased lifecycle. Pull-payment isolation: each recipient owns an
    ///      independent ledger entry, so a failing or reentrant receiver cannot block other users'
    ///      withdrawals. The caller must have a positive pending balance, otherwise
    ///      @custom:reverts NoPendingWithdrawal; a failing native transfer triggers
    ///      @custom:reverts RefundFailed. Emits @custom:emits WithdrawalClaimed once the transfer
    ///      succeeds.
    /// @return amount Native amount transferred to the caller.
    function claimWithdrawal() external returns (uint256 amount);

    /// @notice Returns the pending refund balance owed to `recipient`.
    /// @return amount Native amount currently credited to `recipient` and pullable via
    /// `claimWithdrawal`.
    function pendingWithdrawal(address recipient) external view returns (uint256 amount);

    /// @notice Transfers a released token whose redeem window has elapsed to a new owner.
    /// @dev Hands the NFT back to the controller for re-registration. Only the configured
    ///      controller may call this, otherwise @custom:reverts NotController, and the position
    ///      must be released with `redeemableUntil` reached, otherwise @custom:reverts
    ///      NotReclaimable. Emits @custom:emits NameReclaimed once custody is transferred.
    ///      Reclaim does not require the deposit to have been withdrawn first. If the position
    ///      still holds value, this call settles it: the amount is debited from `tokenReserved`
    ///      (topping up from the insurance fund on shortfall, @custom:reverts InsufficientFunds if
    ///      even the combined balance is short) and credited to the previous recipient's
    ///      pull-payment balance, claimable through @custom:function claimWithdrawal with no
    ///      deadline. That is what keeps a name recyclable when its previous holder never returns:
    ///      the value follows them, the name does not wait for them. Emits @custom:emits
    ///      RefundWithdrawn on settlement, and @custom:emits InsuranceDraw when the insurance fund
    ///      tops up a shortfall.
    /// @param newOwner Address of the new registrant taking over the name.
    function reclaim(uint256 tokenId, address newOwner) external;

    /// @notice Returns a released token to its previous holder during the redeem window.
    /// @dev The undo for an accidental release, and the reason the redeem window exists. Only the
    ///      position recipient may call this (@custom:reverts NotRefundRecipient otherwise), the
    ///      position must be released and not yet withdrawn, and `block.timestamp` must still be
    ///      below `redeemableUntil`; a position failing any of those is not redeemable and
    ///      @custom:reverts NotRedeemable.
    ///      No value moves. The position keeps its recipient, asset and amount, so the deposit
    ///      stays locked exactly as it was before the release and the name returns to its
    ///      pre-release state, releasable again later on a fresh pair of clocks. Excluding
    ///      withdrawn positions is deliberate: a holder who has already pulled the deposit would
    ///      otherwise recover the name without it being deposit-backed, breaking the one-deposit-
    ///      per-live-name bound. The choice is therefore exclusive — take the value back, or take
    ///      the name back. Emits @custom:emits NameRedeemed once custody returns.
    function redeem(uint256 tokenId) external;

    /// @notice Updates the cooldown duration for future releases.
    /// @dev Owner-only. Affects only releases recorded after this call; positions already released
    ///      keep the `withdrawAvailableAt` snapshot taken at their release time. `newCooldown`
    ///      must be non-zero, otherwise @custom:reverts InvalidCooldown, and must not exceed the
    ///      contract's `MAX_COOLDOWN` upper bound, otherwise @custom:reverts CooldownTooLong; the
    ///      bound keeps the release-to-reclaim window short and protects the `uint64` cast in
    ///      release from truncation. Emits @custom:emits CooldownUpdated with the prior and new
    ///      values.
    function updateCooldown(uint256 newCooldown) external;

    /// @notice Updates the redeem window for future releases.
    /// @dev Owner-only. Affects only releases recorded after this call; positions already released
    ///      keep the `redeemableUntil` snapshot taken at their release time. `newRedeemWindow` must
    ///      be non-zero, otherwise @custom:reverts InvalidRedeemWindow, and must not exceed the
    ///      contract's `MAX_REDEEM_WINDOW` upper bound, otherwise @custom:reverts
    ///      RedeemWindowTooLong; the bound limits how long policy can hold a released name out of
    ///      circulation and protects the `uint64` cast in release from truncation. Emits
    ///      @custom:emits RedeemWindowUpdated with the prior and new values.
    ///      This is also the post-upgrade seeding hook: pair it with `upgradeToAndCall` so an
    ///      upgraded proxy never runs with an unseeded window.
    function updateRedeemWindow(uint256 newRedeemWindow) external;

    /// @notice Pulls a single time-locked refund entry.
    /// @dev Caller must be the entry's recipient (@custom:reverts NotRefundRecipient otherwise),
    ///      the entry must exist (@custom:reverts NoSuchRefundEntry on a deleted or unknown id),
    ///      and `block.timestamp` must have reached `availableAt` (@custom:reverts
    ///      RefundLocked otherwise). The entry is deleted before the transfer; a failing native
    ///      transfer triggers @custom:reverts RefundFailed. Emits @custom:emits RefundClaimed.
    /// @param entryId Identifier of the entry to claim.
    /// @return amount Native amount transferred to the caller.
    function claimRefund(uint256 entryId) external returns (uint256 amount);

    /// @notice Pulls multiple time-locked refund entries in one call.
    /// @dev Atomic: any invalid entry in the batch (wrong recipient, missing, or locked) reverts
    ///      the entire call. The batch size is bounded by `MAX_REFUND_PAGE_SIZE`
    ///      (@custom:reverts InvalidPageSize otherwise). Aggregates the per-entry amounts and
    ///      transfers once; on transfer failure @custom:reverts RefundFailed. Emits
    ///      @custom:emits RefundClaimed once per entry.
    /// @param entryIds List of entry identifiers to claim.
    /// @return totalAmount Sum of the credited amounts transferred to the caller.
    function claimRefundsBatch(uint256[] calldata entryIds) external returns (uint256 totalAmount);

    /// @notice Returns the number of pending refund entries owed to `recipient`.
    function pendingRefundCount(address recipient) external view returns (uint256 count);

    /// @notice Returns up to `limit` pending refund entry ids for `recipient`, starting at
    ///         `offset`.
    /// @dev Limit must be in `(0, MAX_REFUND_PAGE_SIZE]`, otherwise @custom:reverts
    ///      InvalidPageSize.
    function pendingRefundIds(
        address recipient,
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (uint256[] memory entryIds);

    /// @notice Returns up to `limit` pending refund entries for `recipient`, paired with their
    ///         entry ids.
    /// @dev Limit must be in `(0, MAX_REFUND_PAGE_SIZE]`, otherwise @custom:reverts
    ///      InvalidPageSize.
    function pendingRefunds(
        address recipient,
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (uint256[] memory entryIds, RefundEntry[] memory entries);

    /// @notice Returns a single refund entry by id, or a zero-filled struct if the id is unknown.
    function refundEntry(uint256 entryId) external view returns (RefundEntry memory entry);
}
