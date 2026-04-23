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
    /// @param tokenId Token identifier.
    /// @param asset Deposit asset. `address(0)` denotes native token.
    /// @param amount Deposit amount.
    struct DepositParams {
        uint256 tokenId;
        address asset;
        uint256 amount;
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

    /// @notice Emitted when a refund is withdrawn.
    /// @param tokenId Token identifier.
    /// @param recipient Refund recipient.
    /// @param asset Refund asset. `address(0)` denotes native token.
    /// @param amount Refunded amount.
    event RefundWithdrawn(
        uint256 indexed tokenId, address indexed recipient, address indexed asset, uint256 amount
    );

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

    /// @notice Thrown when the caller is not the configured registrar controller.
    /// @param caller Address that attempted the call.
    error NotController(address caller);

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
    /// @param tokenId Token identifier.
    error RefundFailed(uint256 tokenId);

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
    /// @dev We trust that the controller passed amount since it handles refunds
    /// @param params see @custom: DepositParams struct definition.
    function deposit(DepositParams calldata params) external payable;

    /// @notice Releases a token into escrow and starts the withdrawal cooldown.
    /// @dev The caller must be the current owner or an approved operator. Escrow itself must
    ///      also be approved to transfer the token into custody.
    /// @param tokenId Token identifier.
    function release(uint256 tokenId) external;

    /// @notice Withdraws the refundable deposit for a released token after cooldown.
    /// @param tokenId Token identifier.
    function withdraw(uint256 tokenId) external;

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
