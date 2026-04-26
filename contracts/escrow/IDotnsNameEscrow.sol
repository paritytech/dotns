// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Dotns Name Escrow Interface
/// @notice Escrows refundable deposits for .dot registrations and manages the release lifecycle.
/// @dev Canonical escrow state is keyed by tokenId. A token may be funded with a refundable
///      deposit, released into escrow, withdrawn after cooldown by the snapshotted recipient,
///      and reclaimed by a new registrant via the controller during re-registration.
///
/// @custom:security-contact admin@parity.io
interface IDotnsNameEscrow {
    /// @notice Parameters for recording a deposit position.
    /// @dev `recipient` is locked at deposit time and is the only address eligible for the
    ///      refund via `withdraw()` after release + cooldown. Subsequent transfers of the
    ///      ERC721 do not change the refund recipient — the original depositor's payer is
    ///      always made whole, regardless of who currently holds the name.
    /// @param tokenId Token identifier.
    /// @param asset Deposit asset. `address(0)` denotes native token.
    /// @param amount Deposit amount.
    /// @param recipient Refund recipient locked at deposit time.
    struct DepositParams {
        uint256 tokenId;
        address asset;
        uint256 amount;
        address recipient;
    }

    /// @notice Parameters for recording a cross-tier registration fee into the insurance fund.
    /// @dev Used by the controller when the registrant pays for someone else (e.g. tier mismatch
    ///      registration where `msg.sender != registration.owner`). The payer is the original
    ///      caller (used for refunds and event indexing); the recipient is the NFT registrant
    ///      (informational, surfaced via the event).
    /// @param tokenId Token identifier the fee is recorded against.
    /// @param payer Original `msg.sender` of the controller's `register` call.
    /// @param recipient The NFT registrant the fee was paid on behalf of.
    struct InsuranceDepositParams {
        uint256 tokenId;
        address payer;
        address recipient;
    }

    /// @notice Inputs for charging a cross-tier transfer fee.
    /// @dev Routed via the registrar's payable ERC721 transfer entrypoints from `_update`.
    ///      The struct keeps the call site self-documenting and matches the project
    ///      idiom of structs for >=4 params.
    /// @param tokenId Token being transferred.
    /// @custom:contract IPopRules.priceWithoutCheck
    /// @param priceForTo Recipient-tier price quoted from PopRules. Drives the
    ///         running-max delta path: `max(priceForTo - runningMax, 0)`.
    /// @custom:contract IPopRules.reachFee
    /// @param reachFloor Length-scaled friction owed when the recipient cannot meet
    ///         the label's required tier (verified-but-below). Forms a floor on the
    ///         charge: `fee = max(delta, reachFloor)`. Pure-friction charges (delta
    ///         zero, floor non-zero) credit insurance without bumping the running max.
    /// @param payer The original `msg.sender` of the registrar transfer entrypoint.
    /// @param to NFT recipient (used in event emission for indexer clarity).
    struct ChargeTransferFeeParams {
        uint256 tokenId;
        uint256 priceForTo;
        uint256 reachFloor;
        address payer;
        address to;
    }

    /// @notice Canonical escrow state for a token.
    /// @param recipient Address entitled to the refund after release.
    /// @param asset Deposit asset. `address(0)` denotes native token.
    /// @param amount Refundable amount currently reserved for the token.
    /// @param withdrawAvailableAt Earliest timestamp at which withdrawal is permitted.
    /// @param released Whether the token has entered the release flow.
    /// @param claimed Whether the refund has already been withdrawn.
    struct ReleasePosition {
        address recipient;
        address asset;
        uint256 amount;
        uint64 withdrawAvailableAt;
        bool released;
        bool claimed;
    }

    /// @notice Emitted when a native-token deposit is recorded.
    /// @param tokenId Token identifier.
    /// @param amount Native deposit amount.
    event NativeDepositRecorded(uint256 indexed tokenId, uint256 amount);

    /// @notice Emitted when a token is released into escrow.
    /// @param tokenId Token identifier.
    /// @param recipient Refund recipient snapshotted at release time.
    /// @param asset Deposit asset. `address(0)` denotes native token.
    /// @param amount Refundable amount.
    /// @param withdrawAvailableAt Earliest withdrawal timestamp.
    event NameReleased(
        uint256 indexed tokenId,
        address indexed recipient,
        address indexed asset,
        uint256 amount,
        uint256 withdrawAvailableAt
    );

    /// @notice Emitted when a refund is credited to the recipient's pending balance.
    /// @dev With the pull-payment model, this signals that a refund is OWED to the recipient.
    ///      The recipient must call `claimWithdrawal()` to actually pull the funds; that pull
    ///      emits `WithdrawalClaimed`.
    /// @param tokenId Token identifier.
    /// @param recipient Refund recipient.
    /// @param asset Refund asset. `address(0)` denotes native token.
    /// @param amount Refunded amount.
    event RefundWithdrawn(
        uint256 indexed tokenId, address indexed recipient, address indexed asset, uint256 amount
    );

    /// @notice Emitted when a recipient pulls their accumulated pending refund balance.
    /// @dev Fires from `claimWithdrawal()` after the native transfer succeeds. The amount
    ///      may aggregate refunds credited from multiple `withdraw()` calls.
    /// @param recipient Address that pulled the refund.
    /// @param amount Total native amount transferred.
    event WithdrawalClaimed(address indexed recipient, uint256 amount);

    /// @notice Emitted when a released token is reclaimed by a new owner via registration.
    /// @param tokenId Token identifier.
    /// @param previousRecipient Address that received the refund for the prior registration.
    /// @param newOwner New registrant taking over custody from escrow.
    event NameReclaimed(
        uint256 indexed tokenId, address indexed previousRecipient, address indexed newOwner
    );

    /// @notice Emitted when controller-held native funds are migrated into escrow.
    /// @param controller Controller address that sent the funds.
    /// @param amount Native amount received.
    event ControllerFundsMigrated(address indexed controller, uint256 indexed amount);

    /// @notice Emitted when the cooldown duration for future releases is updated.
    /// @param currentCooldown Current cooldown duration in seconds.
    /// @param newCooldown New cooldown duration in seconds.
    event CooldownUpdated(uint256 indexed currentCooldown, uint256 indexed newCooldown);

    /// @notice Emitted when a cross-tier fee is paid into the insurance fund.
    /// @dev Surfaces both the registration-time top-up (via `depositInsurance`) and the
    ///      transfer-time delta (via `chargeTransferFee`). `isRegistration` distinguishes
    ///      between the two; `recipient` is the NFT recipient (transfer-time `to` or the
    ///      registration `owner`).
    /// @param tokenId Token identifier the fee was recorded against.
    /// @param payer Original `msg.sender` whose value funded the fee.
    /// @param recipient NFT recipient associated with the fee event.
    /// @param amount Net amount credited to the insurance fund.
    /// @param isRegistration True when emitted from `depositInsurance`; false from `chargeTransferFee`.
    event CrossTierFeePaid(
        uint256 indexed tokenId,
        address indexed payer,
        address indexed recipient,
        uint256 amount,
        bool isRegistration
    );

    /// @notice Emitted when a withdrawal draws from the insurance fund to cover a shortfall in `tokenReserved`.
    /// @param tokenId Token identifier whose refund triggered the draw.
    /// @param amount Amount drawn from the insurance fund.
    event InsuranceDraw(uint256 indexed tokenId, uint256 amount);

    /// @notice Emitted when overpayment is refunded to the payer.
    /// @param payer Address receiving the refund.
    /// @param amount Refunded amount.
    event OverpaymentRefunded(address indexed payer, uint256 amount);

    /// @notice Thrown when the caller is not the configured registrar controller.
    /// @param caller Address that attempted the call.
    error NotController(address caller);

    /// @notice Thrown when the caller is not the configured registrar.
    /// @param caller Address that attempted the call.
    error NotRegistrar(address caller);

    /// @notice Thrown when the supplied refund recipient is invalid (e.g. zero address).
    error InvalidRecipient();

    /// @notice Thrown when the attached call value is insufficient to cover the computed charge.
    error InsufficientValue();

    /// @notice Thrown when neither `tokenReserved` nor the insurance fund can cover the refund.
    /// @param tokenId Token identifier of the refund position.
    /// @param owed Amount owed to the refund recipient.
    /// @param available Combined balance available across reserves and insurance.
    error InsufficientFunds(uint256 tokenId, uint256 owed, uint256 available);

    /// @notice Thrown when assets being deposited are not supported by the escrow.
    /// @param asset Address of the asset that was attempted to be deposited.
    error AssetNotSupported(address asset);

    /// @notice Thrown when the configured page size is invalid.
    /// @param limit Requested page size.
    error InvalidPageSize(uint256 limit);

    /// @notice Thrown when the configured cooldown is invalid.
    error InvalidCooldown();

    /// @notice Thrown when the supplied amount is invalid.
    error InvalidAmount();

    /// @notice Thrown when the supplied ERC20 asset is invalid.
    error InvalidAsset();

    /// @notice Thrown when a deposit position is already funded.
    /// @param tokenId Token identifier.
    error PositionAlreadyFunded(uint256 tokenId);

    /// @notice Thrown when no deposit is configured for the token.
    /// @param tokenId Token identifier.
    error DepositNotConfigured(uint256 tokenId);

    /// @notice Thrown when the token has already been released.
    /// @param tokenId Token identifier.
    error AlreadyReleased(uint256 tokenId);

    /// @notice Thrown when the token has not been released.
    /// @param tokenId Token identifier.
    error NotReleased(uint256 tokenId);

    /// @notice Thrown when the refund has already been claimed.
    /// @param tokenId Token identifier.
    error AlreadyClaimed(uint256 tokenId);

    /// @notice Thrown when a token is not in a reclaimable state (released + claimed).
    /// @param tokenId Token identifier.
    error NotReclaimable(uint256 tokenId);

    /// @notice Thrown when the caller is neither the token owner nor an approved operator.
    /// @param caller Address that attempted the call.
    /// @param tokenId Token identifier.
    error NotTokenOwnerOrApproved(address caller, uint256 tokenId);

    /// @notice Thrown when escrow is not approved to transfer the token.
    /// @param tokenId Token identifier.
    error EscrowNotApproved(uint256 tokenId);

    /// @notice Thrown when the caller is not the refund recipient.
    /// @param caller Address that attempted the call.
    /// @param tokenId Token identifier.
    error NotRefundRecipient(address caller, uint256 tokenId);

    /// @notice Thrown when withdrawal is attempted before cooldown has elapsed.
    /// @param tokenId Token identifier.
    /// @param availableAt Earliest withdrawal timestamp.
    /// @param currentTime Current block timestamp.
    error WithdrawalTooEarly(uint256 tokenId, uint256 availableAt, uint256 currentTime);

    /// @notice Thrown when a refund transfer fails.
    /// @param tokenId Token identifier. Set to zero when surfaced from `claimWithdrawal()`,
    ///                as the pulled balance may aggregate refunds across multiple positions.
    error RefundFailed(uint256 tokenId);

    /// @notice Thrown when `claimWithdrawal()` is called but the caller has no pending balance.
    error NoPendingWithdrawal();

    /// @notice Thrown when escrow receives an ERC721 transfer from a non-registrar source.
    /// @param caller Address that attempted the transfer.
    error NotAcceptedTransfer(address caller);

    /// @notice Returns total amount of assets liabilities reserved for withdrawals.
    /// @param asset Asset address. `address(0)` denotes native token.
    /// @return amount Total native amount reserved.
    function reserves(address asset) external view returns (uint256 amount);

    /// @notice Returns the escrow state for a token.
    /// @param tokenId Token identifier.
    /// @return position Canonical escrow position.
    function getReleasePosition(uint256 tokenId)
        external
        view
        returns (ReleasePosition memory position);

    /// @notice Returns the number of tokens currently held by escrow pending reclaim or withdrawal.
    /// @dev Intended to facilitate off-chain pagination of the released token set.
    /// @return count Number of released tokens not yet reclaimed.
    function releasedTokenCount() external view returns (uint256 count);

    /// @notice Returns a bounded paginated slice of released token identifiers.
    /// @dev Reverts if `limit` is zero or exceeds `MAX_RELEASED_PAGE_SIZE`.
    /// @param start Start index into the released-token set.
    /// @param limit Maximum number of token identifiers to return.
    /// @return tokenIds Released token identifiers in the requested slice.
    function releasedTokens(
        uint256 start,
        uint256 limit
    )
        external
        view
        returns (uint256[] memory tokenIds);

    /// @notice Records an asset deposit position for a token.
    /// @dev Callable only by the registrar controller. The call value must equal `amount`.
    ///      The `recipient` field on `params` is locked at deposit time and is the only address
    ///      eligible for the refund via `withdraw()`. The controller must pass the registrant's
    ///      refund address (typically the original `msg.sender` of `register`).
    /// @dev We trust that the controller passed amount since it handles refunds
    /// @param params see @custom: DepositParams struct definition.
    function deposit(DepositParams calldata params) external payable;

    /// @notice Records a cross-tier registration fee into the insurance fund.
    /// @dev Callable only by the registrar controller. Used when `msg.sender != registration.owner`
    ///      AND tier prices differ — the controller forwards the differential to the escrow so the
    ///      original payer is recorded for the event and the running max is bumped to keep
    ///      transfer-time fee accounting consistent.
    /// @param params see {InsuranceDepositParams} struct definition.
    function depositInsurance(InsuranceDepositParams calldata params) external payable;

    /// @notice Charges the cross-tier transfer-fee delta against the running max for a token.
    /// @dev Authorised only for the registrar resolved from the protocol registry.
    /// @custom:contract IDotnsProtocolRegistry.get
    ///      Atomic: reads runningMax, computes delta, updates state, deposits to insuranceFund,
    ///      refunds excess to payer.
    ///      If `priceForTo <= runningMax[tokenId]`, the recipient is already covered and
    ///      `msg.value` is fully refunded; the function returns 0.
    ///      Otherwise `delta = priceForTo - runningMax[tokenId]` is charged from `msg.value`;
    ///      the running max bumps to `priceForTo`; insurance increments by `delta`;
    ///      any overpayment is refunded.
    ///      Reverts {InsufficientValue} when `msg.value < delta` for a cross-tier downgrade.
    /// @param params Charge inputs (see {ChargeTransferFeeParams}).
    /// @return charged Amount actually credited to insurance (zero when recipient is covered).
    function chargeTransferFee(ChargeTransferFeeParams calldata params)
        external
        payable
        returns (uint256 charged);

    /// @notice Returns the cumulative cross-tier fee balance held against future shortfalls.
    /// @return balance Current insurance fund balance, in wei.
    function insuranceFund() external view returns (uint256 balance);

    /// @notice Returns the highest price ever charged for a token across registration and transfers.
    /// @dev Reset to zero on `reclaim()` so the next registrant starts with a fresh baseline.
    /// @param tokenId Token identifier.
    /// @return max The current running maximum, in wei.
    function runningMax(uint256 tokenId) external view returns (uint256 max);

    /// @notice Releases a token into escrow and starts the withdrawal cooldown.
    /// @dev The caller must be the current owner or an approved operator. Escrow itself must
    ///      also be approved to transfer the token into custody.
    /// @param tokenId Token identifier.
    function release(uint256 tokenId) external;

    /// @notice Credits the refundable deposit for a released token to the recipient's pending balance.
    /// @dev Pull-payment: this function does NOT send native value. It marks the position as
    ///      claimed, debits `tokenReserved` (and the insurance fund on shortfall), and credits
    ///      the recipient's `_pendingWithdrawals` entry. The recipient must subsequently call
    ///      `claimWithdrawal()` to pull the funds.
    /// @custom:emits RefundWithdrawn when the credit is recorded.
    /// @param tokenId Token identifier.
    function withdraw(uint256 tokenId) external;

    /// @notice Pulls the caller's accumulated pending refund balance.
    /// @dev Implements the second half of the pull-payment refund flow. The caller's pending
    ///      balance is zeroed before the external call to enforce checks-effects-interactions.
    ///      A single call drains the entire pending balance, which may aggregate multiple
    ///      `withdraw()` credits.
    /// @custom:reverts NoPendingWithdrawal if the caller has no balance to pull.
    /// @custom:reverts RefundFailed if the native transfer fails.
    /// @custom:emits WithdrawalClaimed with the pulled amount.
    /// @return amount Native amount transferred to the caller.
    function claimWithdrawal() external returns (uint256 amount);

    /// @notice Returns the pending refund balance owed to `recipient`.
    /// @param recipient Address to query.
    /// @return amount Native amount currently credited to `recipient` and pullable via `claimWithdrawal`.
    function pendingWithdrawal(address recipient) external view returns (uint256 amount);

    /// @notice Transfers a released-and-claimed token from escrow custody to a new owner.
    /// @dev Callable only by the registrar controller during a re-registration flow.
    ///      Requires the position to be released and the refund to have been withdrawn —
    ///      enforcing that the original depositor has been made whole before reuse.
    /// @param tokenId Token identifier.
    /// @param newOwner Address of the new registrant taking over the name.
    function reclaim(uint256 tokenId, address newOwner) external;

    /// @notice Receives native funds migrated out of the registrar controller.
    /// @dev This exists only for upgrade compatibility with controller-held native balances.
    /// @custom:security TODO On fresh deploy (not upgrade), remove this function.
    function receiveControllerFunds() external payable;

    /// @notice Updates the cooldown duration for future releases.
    /// @param newCooldown New cooldown duration in seconds.
    /// @dev Callable only by the contract owner.
    /// @custom:emits CooldownUpdated
    /// @custom:reverts InvalidCooldown if `newCooldown` is zero.
    function updateCooldown(uint256 newCooldown) external;
}
