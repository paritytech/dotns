// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    ERC165Upgradeable
} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IDotnsNameEscrow} from "./IDotnsNameEscrow.sol";
import {IDotnsRegistrar} from "../registrars/IDotnsRegistrar.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";

/// @title Dotns Name Escrow
/// @notice Holds refundable deposits for .dot names and manages the release/reclaim lifecycle.
/// @custom:security-contact admin@parity.io
contract DotnsNameEscrow is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardTransient,
    ERC165Upgradeable,
    IERC721Receiver,
    IDotnsNameEscrow
{
    /// @notice Maximum page size for releasedTokens pagination.
    uint256 public constant MAX_RELEASED_PAGE_SIZE = 200;

    /// @notice Maximum page size for pendingRefunds pagination and batch claims.
    uint256 public constant MAX_REFUND_PAGE_SIZE = 200;

    /// @notice Upper bound on the configurable release-cooldown.
    /// @dev The cooldown gates only the release-to-reclaim window, not the long-lived deposit lock,
    ///      so it is intentionally kept short. Capping at one hour also keeps the cast to `uint64`
    ///      well below the saturation point at every plausible block timestamp.
    uint256 public constant MAX_COOLDOWN = 1 hours;

    /// @notice The protocol registry for resolving sibling contract addresses.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @notice Cooldown period after release during which refunds can be
    ///         claimed but not yet reclaimed.
    /// @dev Forces a delay between `release` and `reclaim` so the original payer has an
    ///      uncontested window to pull their refund before the controller hands the name out again.
    uint256 public cooldown;

    /// @notice Total amount of a specific asset reserved across all positions.
    /// @dev Keyed by asset so future ERC20 support can track per-token liabilities independently;
    ///      `address(0)` represents the native token and is the only asset currently accepted.
    mapping(address asset => uint256 amount) public tokenReserved;

    /// @notice Per-token escrow position storing recipient, amount, lifecycle flags and cooldown.
    mapping(uint256 tokenId => ReleasePosition position) private _positions;

    /// @notice Ordered set of tokens currently in escrow custody, used for paginated enumeration.
    uint256[] private _releasedTokens;

    /// @notice Reverse lookup into `_releasedTokens` (one-based) for O(1) remove-by-swap.
    mapping(uint256 tokenId => uint256 indexPlusOne) private _releasedIndexPlusOne;

    /// @notice Cumulative balance of cross-tier fees held against unreleased shortfalls.
    /// @dev Credited by cross-tier registration deposits, reach-floor friction, and transfer-fee
    ///      deltas; debited only when `withdraw` needs to top up a refund that exceeds the
    ///      asset's reserved balance.
    uint256 public insuranceFund;

    /// @notice Pull-payment ledger storing each recipient's claimable refund balance.
    /// @dev Per-recipient isolation ensures a failing or reentrant receiver cannot block other
    ///      users' withdrawals. Used as the fallback path for registration overpayments whose
    ///      direct push back to `msg.sender` failed (because the caller is a contract that
    ///      rejects incoming value).
    mapping(address recipient => uint256 amount) private _pendingWithdrawals;

    /// @notice Time-locked refund ledger keyed by entryId.
    /// @dev Every credit allocates a fresh entryId so per-entry cooldowns are independent and
    ///      drip-feed credits cannot reset an existing entry's clock.
    mapping(uint256 entryId => RefundEntry entry) private _refundEntries;

    /// @notice Per-recipient list of pending entryIds for paginated enumeration and batch claim.
    mapping(address recipient => uint256[] entryIds) private _entriesByRecipient;

    /// @notice Reverse lookup into `_entriesByRecipient` (one-based) for O(1) remove-by-swap.
    mapping(uint256 entryId => uint256 indexPlusOne) private _entryIndexPlusOne;

    /// @notice Monotonic counter assigning entryIds to new refund credits.
    uint256 private _nextEntryId;

    /// @dev Reserved storage space to allow for layout changes in the future.
    uint256[50] private __gap;

    /// @notice Restricts calls to the configured registrar controller.
    modifier onlyController() {
        _onlyController();
        _;
    }

    /// @notice Restricts calls to the configured registrar from the protocol registry.
    modifier onlyRegistrar() {
        _onlyRegistrar();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the name escrow.
    /// @dev Runs once behind the proxy; subsequent calls trigger @custom:reverts
    ///      InvalidInitialization via the `initializer` modifier. `registry` must be non-zero,
    ///      otherwise @custom:reverts InvalidAsset; `cooldownSeconds` is forwarded to
    ///      @custom:function updateCooldown, which rejects a zero value (@custom:reverts
    ///      InvalidCooldown) and any value above @custom:constant MAX_COOLDOWN (@custom:reverts
    ///      CooldownTooLong), and emits @custom:emits CooldownUpdated as part of seeding the
    ///      initial cooldown.
    /// @param registry Protocol registry used to resolve registrar and controller addresses.
    /// @param cooldownSeconds Refund cooldown after release.
    function initialize(
        IDotnsProtocolRegistry registry,
        uint256 cooldownSeconds
    )
        external
        initializer
    {
        require(address(registry) != address(0), InvalidAsset());

        __Ownable_init(msg.sender);
        __ERC165_init();

        protocolRegistry = registry;
        updateCooldown(cooldownSeconds);
    }

    /// @inheritdoc IDotnsNameEscrow
    function updateCooldown(uint256 newCooldown) public override onlyOwner {
        require(newCooldown != 0, InvalidCooldown());
        require(newCooldown <= MAX_COOLDOWN, CooldownTooLong(newCooldown, MAX_COOLDOWN));

        uint256 currentCooldown = cooldown;
        cooldown = newCooldown;

        emit CooldownUpdated(currentCooldown, newCooldown);
    }

    /// @inheritdoc IDotnsNameEscrow
    function getReleasePosition(uint256 tokenId)
        external
        view
        override
        returns (ReleasePosition memory position)
    {
        position = _positions[tokenId];
    }

    /// @inheritdoc IDotnsNameEscrow
    function releasedTokenCount() external view override returns (uint256 count) {
        count = _releasedTokens.length;
    }

    /// @inheritdoc IDotnsNameEscrow
    function reserves(address asset) external view returns (uint256 amount) {
        amount = tokenReserved[asset];
    }

    /// @inheritdoc IDotnsNameEscrow
    function releasedTokens(
        uint256 start,
        uint256 limit
    )
        external
        view
        override
        returns (uint256[] memory tokenIds)
    {
        require(limit != 0 && limit <= MAX_RELEASED_PAGE_SIZE, InvalidPageSize(limit));

        uint256 length = _releasedTokens.length;
        if (start >= length) return new uint256[](0);

        uint256 end = start + limit;
        if (end > length) end = length;

        tokenIds = new uint256[](end - start);
        uint256 outIndex = 0;
        for (uint256 i = start; i < end; ++i) {
            tokenIds[outIndex] = _releasedTokens[i];
            ++outIndex;
        }
    }

    /// @inheritdoc IDotnsNameEscrow
    function deposit(DepositParams calldata params) external payable override onlyController {
        // Reject mismatched amount/msg.value so callers cannot under-fund a position.
        require(msg.value == params.amount, InvalidAmount());
        // Only native deposits are currently supported; ERC20 support can be added in a
        // future upgrade by relaxing this check and routing transfers via SafeERC20.
        require(params.asset == address(0), AssetNotSupported(params.asset));
        require(params.recipient != address(0), InvalidRecipient());

        ReleasePosition storage position = _positions[params.tokenId];

        // Use `recipient` as the "is this slot funded?" sentinel so zero-amount
        // positions (seeded by free PopFull / PopLite registrations) still count
        // as funded and cannot be re-seeded with a different recipient.
        require(position.recipient == address(0), PositionAlreadyFunded(params.tokenId));
        require(!position.released, AlreadyReleased(params.tokenId));

        position.asset = params.asset;
        position.amount = params.amount;
        position.recipient = params.recipient;

        tokenReserved[position.asset] += params.amount;

        emit NativeDepositRecorded(params.tokenId, params.amount);
    }

    /// @inheritdoc IDotnsNameEscrow
    function creditOverpayment(address recipient)
        external
        payable
        override
        onlyController
        nonReentrant
    {
        require(recipient != address(0), InvalidRecipient());
        require(msg.value != 0, InvalidAmount());
        _pendingWithdrawals[recipient] += msg.value;
        emit OverpaymentRefunded(recipient, msg.value);
    }

    /// @inheritdoc IDotnsNameEscrow
    function depositInsurance(InsuranceDepositParams calldata params)
        external
        payable
        override
        onlyController
        nonReentrant
    {
        require(msg.value > 0, InvalidAmount());

        insuranceFund += msg.value;

        emit CrossTierFeePaid(
            params.tokenId,
            params.payer,
            params.recipient,
            msg.value,
            /* isRegistration */
            true
        );
    }

    /// @inheritdoc IDotnsNameEscrow
    function chargeTransferFee(ChargeTransferFeeParams calldata params)
        external
        payable
        override
        onlyRegistrar
        nonReentrant
        returns (uint256 charged)
    {
        ReleasePosition storage position = _positions[params.tokenId];
        address priorRecipient = position.recipient;

        uint256 fee = params.reachFloor;
        require(msg.value >= fee, InsufficientValue());

        // Deposits follow the NFT, not the depositor. When the position is funded the locked
        // deposit travels with the name; when it is a zero-amount lifecycle marker the marker
        // travels with it. In both cases the position is rebound to the new holder so only
        // the current holder can later release into escrow and claim the refund.
        if (priorRecipient != address(0) && params.to != priorRecipient) {
            position.recipient = params.to;
        }

        if (fee > 0) {
            insuranceFund += fee;
        }

        charged = fee;

        emit CrossTierFeePaid(
            params.tokenId,
            params.payer,
            params.to,
            fee,
            /* isRegistration */
            false
        );

        uint256 overpayment = msg.value - fee;
        if (overpayment > 0) {
            // `cooldown` is capped at @custom:constant MAX_COOLDOWN (one hour), so the cast to
            // `uint64` cannot truncate for any plausible block timestamp.
            // forge-lint: disable-next-line(unsafe-typecast)
            _creditRefund(params.payer, overpayment, params.tokenId, uint64(cooldown));
        }
    }

    /// @inheritdoc IDotnsNameEscrow
    function release(uint256 tokenId) external override nonReentrant {
        IDotnsRegistrar registrar = _registrar();

        address currentOwner = registrar.ownerOf(tokenId);
        bool callerAuthorised = msg.sender == currentOwner
            || registrar.getApproved(tokenId) == msg.sender
            || registrar.isApprovedForAll(currentOwner, msg.sender);

        require(callerAuthorised, NotTokenOwnerOrApproved(msg.sender, tokenId));

        ReleasePosition storage position = _positions[tokenId];
        // Recipient is the canonical "is this position present?" sentinel; zero-
        // amount positions seeded for free PopFull / PopLite registrations are
        // still releasable so every minted name has a reachable lifecycle.
        require(position.recipient != address(0), DepositNotConfigured(tokenId));
        require(!position.released, AlreadyReleased(tokenId));

        // Position recipient mirrors the current NFT holder (rebound on every transfer), so this
        // gate is the holder-only check. Belt-and-braces with the approval check below: the
        // holder must both initiate the release and approve escrow to move the NFT.
        require(msg.sender == position.recipient, NotRefundRecipient(msg.sender, tokenId));

        bool approvedForEscrow = registrar.getApproved(tokenId) == address(this)
            || registrar.isApprovedForAll(currentOwner, address(this));

        require(approvedForEscrow, EscrowNotApproved(tokenId));

        // Position recipient already mirrors the caller (the current holder) thanks to the
        // transfer rebind, so release does not need to touch it. The cast to `uint64` is safe
        // because `cooldown` is bounded by @custom:constant MAX_COOLDOWN.
        // forge-lint: disable-next-line(unsafe-typecast)
        position.withdrawAvailableAt = uint64(block.timestamp + cooldown);
        position.released = true;

        registrar.safeTransferFrom(currentOwner, address(this), tokenId);

        _addReleasedToken(tokenId);

        emit NameReleased(
            tokenId,
            position.recipient,
            position.asset,
            position.amount,
            position.withdrawAvailableAt
        );
    }

    /// @inheritdoc IDotnsNameEscrow
    function withdraw(uint256 tokenId) external override nonReentrant {
        ReleasePosition storage position = _positions[tokenId];

        require(position.released, NotReleased(tokenId));
        require(!position.claimed, AlreadyClaimed(tokenId));
        require(position.recipient == msg.sender, NotRefundRecipient(msg.sender, tokenId));
        require(
            block.timestamp >= position.withdrawAvailableAt,
            WithdrawalTooEarly(tokenId, position.withdrawAvailableAt, block.timestamp)
        );

        uint256 owed = position.amount;
        address asset = position.asset;
        address recipient = position.recipient;
        uint256 reserved = tokenReserved[asset];

        uint256 fromRefundable;
        uint256 fromInsurance;
        if (reserved >= owed) {
            fromRefundable = owed;
            // fromInsurance is already 0 from default initialization.
        } else {
            fromRefundable = reserved;
            fromInsurance = owed - reserved;
            require(
                insuranceFund >= fromInsurance,
                InsufficientFunds(tokenId, owed, reserved + insuranceFund)
            );
        }

        // Effects: mutate state only after all checks have passed.
        position.claimed = true;
        position.amount = 0;
        tokenReserved[asset] -= fromRefundable;
        if (fromInsurance > 0) {
            insuranceFund -= fromInsurance;
            emit InsuranceDraw(tokenId, fromInsurance);
        }

        _pendingWithdrawals[recipient] += owed;

        emit RefundWithdrawn(tokenId, recipient, asset, owed);
    }

    /// @inheritdoc IDotnsNameEscrow
    function claimWithdrawal() external override nonReentrant returns (uint256 amount) {
        amount = _pendingWithdrawals[msg.sender];
        require(amount > 0, NoPendingWithdrawal());

        // Effects before interaction.
        _pendingWithdrawals[msg.sender] = 0;

        (bool ok,) = payable(msg.sender).call{value: amount}("");
        // tokenId is not meaningful here since a single pending balance can aggregate
        // multiple positions; surface 0 to keep the existing error shape.
        require(ok, RefundFailed(0));

        emit WithdrawalClaimed(msg.sender, amount);
    }

    /// @inheritdoc IDotnsNameEscrow
    function pendingWithdrawal(address recipient) external view override returns (uint256 amount) {
        amount = _pendingWithdrawals[recipient];
    }

    /// @inheritdoc IDotnsNameEscrow
    function claimRefund(uint256 entryId) external override nonReentrant returns (uint256 amount) {
        RefundEntry memory entry = _refundEntries[entryId];
        require(entry.recipient == msg.sender, NotRefundRecipient(msg.sender, entry.tokenId));
        require(entry.amount > 0, NoSuchRefundEntry(entryId));
        require(block.timestamp >= entry.availableAt, RefundLocked(entryId, entry.availableAt));

        amount = entry.amount;
        _removeRefundEntry(entryId, msg.sender);

        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, RefundFailed(entry.tokenId));

        emit RefundClaimed(msg.sender, entryId, amount);
    }

    /// @inheritdoc IDotnsNameEscrow
    function claimRefundsBatch(uint256[] calldata entryIds)
        external
        override
        nonReentrant
        returns (uint256 totalAmount)
    {
        uint256 length = entryIds.length;
        require(length > 0 && length <= MAX_REFUND_PAGE_SIZE, InvalidPageSize(length));

        for (uint256 i; i < length; ++i) {
            uint256 entryId = entryIds[i];
            RefundEntry memory entry = _refundEntries[entryId];
            require(entry.recipient == msg.sender, NotRefundRecipient(msg.sender, entry.tokenId));
            require(entry.amount > 0, NoSuchRefundEntry(entryId));
            require(block.timestamp >= entry.availableAt, RefundLocked(entryId, entry.availableAt));

            totalAmount += entry.amount;
            _removeRefundEntry(entryId, msg.sender);

            emit RefundClaimed(msg.sender, entryId, entry.amount);
        }

        (bool ok,) = payable(msg.sender).call{value: totalAmount}("");
        require(ok, RefundFailed(0));
    }

    /// @inheritdoc IDotnsNameEscrow
    function pendingRefundCount(address recipient) external view override returns (uint256 count) {
        count = _entriesByRecipient[recipient].length;
    }

    /// @inheritdoc IDotnsNameEscrow
    function pendingRefundIds(
        address recipient,
        uint256 offset,
        uint256 limit
    )
        external
        view
        override
        returns (uint256[] memory entryIds)
    {
        require(limit > 0 && limit <= MAX_REFUND_PAGE_SIZE, InvalidPageSize(limit));

        uint256[] storage all = _entriesByRecipient[recipient];
        uint256 total = all.length;
        if (offset >= total) return new uint256[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        entryIds = new uint256[](end - offset);
        for (uint256 i = 0; i < entryIds.length; ++i) {
            entryIds[i] = all[offset + i];
        }
    }

    /// @inheritdoc IDotnsNameEscrow
    function pendingRefunds(
        address recipient,
        uint256 offset,
        uint256 limit
    )
        external
        view
        override
        returns (uint256[] memory entryIds, RefundEntry[] memory entries)
    {
        require(limit > 0 && limit <= MAX_REFUND_PAGE_SIZE, InvalidPageSize(limit));

        uint256[] storage all = _entriesByRecipient[recipient];
        uint256 total = all.length;
        if (offset >= total) {
            return (new uint256[](0), new RefundEntry[](0));
        }

        uint256 end = offset + limit;
        if (end > total) end = total;

        uint256 count = end - offset;
        entryIds = new uint256[](count);
        entries = new RefundEntry[](count);
        for (uint256 i = 0; i < count; ++i) {
            uint256 entryId = all[offset + i];
            entryIds[i] = entryId;
            entries[i] = _refundEntries[entryId];
        }
    }

    /// @inheritdoc IDotnsNameEscrow
    function refundEntry(uint256 entryId)
        external
        view
        override
        returns (RefundEntry memory entry)
    {
        entry = _refundEntries[entryId];
    }

    /// @notice Internal helper: allocate a new entryId and credit a refund to `recipient`.
    /// @dev Assigns the next monotonic entryId, stores the entry, appends to the recipient's
    ///      enumeration array, and emits @custom:emits RefundCredited. `cooldownSeconds` may be
    ///      zero when the cooldown has already been served by another mechanism (for example, the
    ///      release-and-withdraw path enforces the cooldown on the position before crediting).
    function _creditRefund(
        address recipient,
        uint256 amount,
        uint256 tokenId,
        uint64 cooldownSeconds
    )
        internal
        returns (uint256 entryId)
    {
        require(recipient != address(0), InvalidRecipient());
        require(amount > 0, InvalidAmount());

        entryId = ++_nextEntryId;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 availableAt = uint64(block.timestamp + cooldownSeconds);

        _refundEntries[entryId] = RefundEntry({
            recipient: recipient, amount: amount, availableAt: availableAt, tokenId: tokenId
        });

        uint256[] storage list = _entriesByRecipient[recipient];
        list.push(entryId);
        _entryIndexPlusOne[entryId] = list.length;

        emit RefundCredited(recipient, entryId, amount, availableAt, tokenId);
    }

    /// @notice Internal helper: delete a refund entry and swap-pop its slot in the recipient's
    ///         enumeration array.
    function _removeRefundEntry(uint256 entryId, address recipient) internal {
        uint256 indexPlusOne = _entryIndexPlusOne[entryId];
        // Caller is expected to have validated existence already; defensive check kept cheap.
        if (indexPlusOne == 0) return;

        uint256 index = indexPlusOne - 1;
        uint256[] storage list = _entriesByRecipient[recipient];
        uint256 lastIndex = list.length - 1;

        if (index != lastIndex) {
            uint256 movedEntryId = list[lastIndex];
            list[index] = movedEntryId;
            _entryIndexPlusOne[movedEntryId] = indexPlusOne;
        }
        list.pop();

        delete _entryIndexPlusOne[entryId];
        delete _refundEntries[entryId];
    }

    /// @inheritdoc IDotnsNameEscrow
    function reclaim(
        uint256 tokenId,
        address newOwner
    )
        external
        override
        onlyController
        nonReentrant
    {
        ReleasePosition storage position = _positions[tokenId];

        require(position.released && position.claimed, NotReclaimable(tokenId));

        address previousRecipient = position.recipient;

        delete _positions[tokenId];
        _removeReleasedToken(tokenId);

        _registrar().safeTransferFrom(address(this), newOwner, tokenId);

        emit NameReclaimed(tokenId, previousRecipient, newOwner);
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    )
        external
        view
        override
        returns (bytes4 selector)
    {
        require(msg.sender == address(_registrar()), NotAcceptedTransfer(msg.sender));
        selector = IERC721Receiver.onERC721Received.selector;
    }

    /// @inheritdoc ERC165Upgradeable
    function supportsInterface(bytes4 interfaceId) public view override returns (bool supported) {
        supported = interfaceId == type(IDotnsNameEscrow).interfaceId
            || interfaceId == type(IERC721Receiver).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.0.0";
    }

    /// @notice Returns the configured registrar from the protocol registry.
    function _registrar() internal view returns (IDotnsRegistrar registrar) {
        registrar = IDotnsRegistrar(protocolRegistry.get(DotnsConstants.REGISTRAR));
    }

    /// @notice Restricts calls to the configured controller from the protocol registry.
    function _onlyController() internal view {
        address controller = protocolRegistry.get(DotnsConstants.CONTROLLER);
        require(msg.sender == controller, NotController(msg.sender));
    }

    /// @notice Restricts calls to the configured registrar from the protocol registry.
    function _onlyRegistrar() internal view {
        address registrar = protocolRegistry.get(DotnsConstants.REGISTRAR);
        require(msg.sender == registrar, NotRegistrar(msg.sender));
    }

    /// @notice Adds a token to the released-token set if absent.
    function _addReleasedToken(uint256 tokenId) internal {
        if (_releasedIndexPlusOne[tokenId] != 0) return;

        _releasedTokens.push(tokenId);
        _releasedIndexPlusOne[tokenId] = _releasedTokens.length;
    }

    /// @notice Removes a token from the released-token set if present.
    function _removeReleasedToken(uint256 tokenId) internal {
        uint256 indexPlusOne = _releasedIndexPlusOne[tokenId];
        if (indexPlusOne == 0) return;

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _releasedTokens.length - 1;

        if (index != lastIndex) {
            uint256 lastTokenId = _releasedTokens[lastIndex];
            _releasedTokens[index] = lastTokenId;
            _releasedIndexPlusOne[lastTokenId] = index + 1;
        }

        _releasedTokens.pop();
        delete _releasedIndexPlusOne[tokenId];
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
