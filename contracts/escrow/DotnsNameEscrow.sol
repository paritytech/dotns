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
/// @notice Holds refundable deposits for registered names and manages the release/reclaim
/// lifecycle. @custom:security-contact admin@parity.io
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
    /// @dev The cooldown gates only the release-to-withdraw delay, not the long-lived deposit lock
    ///      and not the reclaim boundary (see `redeemWindow`), so it is intentionally kept short.
    ///      Capping at one hour also keeps the cast to `uint64` well below the saturation point at
    ///      every plausible block timestamp.
    uint256 public constant MAX_COOLDOWN = 1 hours;

    /// @notice Upper bound on the configurable redeem window.
    /// @dev The redeem window is a different quantity from the cooldown: it is the period after
    ///      release in which only the previous holder may act, and it gates reclaim rather than
    ///      withdrawal. The bound limits how long policy can hold a released name out of
    ///      circulation, and keeps the cast to `uint64` in release well below saturation.
    uint256 public constant MAX_REDEEM_WINDOW = 30 days;

    /// @notice Lower bound on the configurable redeem window.
    /// @dev A window short enough to elapse before its holder can plausibly notice the release
    ///      offers no protection at all, and one of zero length turns every release into an
    ///      immediate hand-off to whoever is watching. The floor keeps the window long enough to
    ///      span a holder being asleep or away for a day, so the guarantee survives any setting
    ///      the owner is able to choose.
    uint256 public constant MIN_REDEEM_WINDOW = 1 days;

    /// @notice The protocol registry for resolving sibling contract addresses.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @notice Delay after release before the deposit withdrawal may be credited.
    /// @dev Forces a delay between `release` and `withdraw`. It does not bound reclaim: the
    ///      release-to-reclaim boundary is `redeemWindow`, a separate and longer quantity. Also
    ///      supplies the per-entry clock for time-locked refund credits, which is why raising it
    ///      would slow every refund path and not just the deposit one.
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

    /// @notice Cumulative balance of non-refundable protocol fees; only accumulates.
    /// @dev Credited by cross-paid registration fees and transfer fees. Never debited: protocol
    ///      fees do not back refunds, which draw solely on the per-asset reserve.
    uint256 public protocolFees;

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

    /// @notice Period after release during which only the previous holder may act.
    /// @dev Distinct from `cooldown`. Inside this window the holder may `redeem` the name back
    ///      and nobody else may take it (`available` reports false); once it elapses `reclaim`
    ///      becomes permissionless and any unwithdrawn deposit is credited to the recipient
    ///      rather than stranded.
    uint256 public redeemWindow;

    /// @dev Reserved storage space to allow for layout changes in future upgrades. A variable
    /// appended above must shrink this array by the same number of slots, so an upgrade never
    /// moves the slots of anything already stored.
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
    ///      initial cooldown. `redeemWindowSeconds` is forwarded to @custom:function
    ///      updateRedeemWindow, which rejects any value below @custom:constant MIN_REDEEM_WINDOW
    ///      (@custom:reverts RedeemWindowTooShort) or above @custom:constant MAX_REDEEM_WINDOW
    ///      (@custom:reverts RedeemWindowTooLong), and emits @custom:emits RedeemWindowUpdated.
    /// @param registry Protocol registry used to resolve registrar and controller addresses.
    /// @param cooldownSeconds Delay after release before the deposit withdrawal may be credited.
    /// @param redeemWindowSeconds Period after release in which only the previous holder may act.
    function initialize(
        IDotnsProtocolRegistry registry,
        uint256 cooldownSeconds,
        uint256 redeemWindowSeconds
    )
        external
        initializer
    {
        require(address(registry) != address(0), InvalidAsset());

        __Ownable_init(msg.sender);
        __ERC165_init();

        protocolRegistry = registry;
        updateCooldown(cooldownSeconds);
        updateRedeemWindow(redeemWindowSeconds);
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
    function updateRedeemWindow(uint256 newRedeemWindow) public override onlyOwner {
        require(
            newRedeemWindow >= MIN_REDEEM_WINDOW,
            RedeemWindowTooShort(newRedeemWindow, MIN_REDEEM_WINDOW)
        );
        require(
            newRedeemWindow <= MAX_REDEEM_WINDOW,
            RedeemWindowTooLong(newRedeemWindow, MAX_REDEEM_WINDOW)
        );

        uint256 currentRedeemWindow = redeemWindow;
        redeemWindow = newRedeemWindow;

        emit RedeemWindowUpdated(currentRedeemWindow, newRedeemWindow);
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
        // positions (seeded by cross-paid registrations, which pay a fee rather than a deposit)
        // still count as present and cannot be re-seeded with a different recipient.
        require(position.recipient == address(0), PositionAlreadyFunded(params.tokenId));
        require(!position.released, AlreadyReleased(params.tokenId));

        position.asset = params.asset;
        position.amount = params.amount;
        position.recipient = params.recipient;

        tokenReserved[position.asset] += params.amount;

        emit NativeDepositRecorded(params.tokenId, params.amount);
    }

    /// @inheritdoc IDotnsNameEscrow
    function creditOverpayment(address recipient) external payable override onlyController {
        require(recipient != address(0), InvalidRecipient());
        require(msg.value != 0, InvalidAmount());
        _pendingWithdrawals[recipient] += msg.value;
        emit OverpaymentRefunded(recipient, msg.value);
    }

    /// @inheritdoc IDotnsNameEscrow
    function depositProtocolFee(ProtocolFeeDepositParams calldata params)
        external
        payable
        override
        onlyController
    {
        require(msg.value > 0, InvalidAmount());

        protocolFees += msg.value;

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
        returns (uint256 charged)
    {
        ReleasePosition storage position = _positions[params.tokenId];
        // Released positions are mid-lifecycle in escrow custody and must not be rebound; the
        // recipient is the original releaser who will claim the refund. The canonical transfer
        // path never reaches here for released tokens (`_update` short-circuits on escrow-touching
        // transfers) but the guard hardens the contract against a divergent registrar.
        require(!position.released, AlreadyReleased(params.tokenId));

        address priorRecipient = position.recipient;

        uint256 fee = params.transferFee;
        require(msg.value >= fee, InsufficientValue());

        // Deposits follow the NFT, not the depositor. When the position is funded the locked
        // deposit travels with the name; when it is a zero-amount lifecycle marker the marker
        // travels with it. In both cases the position is rebound to the new holder so only
        // the current holder can later release into escrow and claim the refund.
        if (priorRecipient != address(0) && params.to != priorRecipient) {
            position.recipient = params.to;
        }

        charged = fee;

        if (fee > 0) {
            protocolFees += fee;
            emit CrossTierFeePaid(
                params.tokenId,
                params.payer,
                params.to,
                fee,
                /* isRegistration */
                false
            );
        }

        uint256 overpayment = msg.value - fee;
        if (overpayment > 0) {
            _creditRefund(params.payer, overpayment, params.tokenId);
        }
    }

    /// @inheritdoc IDotnsNameEscrow
    function release(uint256 tokenId) external override nonReentrant {
        IDotnsRegistrar registrar = _registrar();

        address currentOwner = registrar.ownerOf(tokenId);

        ReleasePosition storage position = _positions[tokenId];
        // Recipient is the canonical "is this position present?" sentinel; zero-amount positions
        // seeded for cross-paid registrations are still releasable so every minted name has a
        // reachable lifecycle.
        require(position.recipient != address(0), DepositNotConfigured(tokenId));
        require(!position.released, AlreadyReleased(tokenId));

        // Position recipient mirrors the current NFT holder (rebound on every transfer), so the
        // holder gate collapses to a single equality check. Approved operators cannot release on
        // behalf of the holder because the recipient field is keyed to the holder, not to any
        // approval set; this keeps the deposit refund flow tied to the on-chain owner.
        require(
            msg.sender == currentOwner && msg.sender == position.recipient,
            NotRefundRecipient(msg.sender, tokenId)
        );

        bool approvedForEscrow = registrar.getApproved(tokenId) == address(this)
            || registrar.isApprovedForAll(currentOwner, address(this));

        require(approvedForEscrow, EscrowNotApproved(tokenId));

        // Fail closed on an unseeded window rather than stamping `redeemableUntil` at the current
        // timestamp, which would collapse the holder's exclusive redeem phase to zero length and
        // open permissionless reclaim the instant the name is released. Only reachable on a proxy
        // upgraded without pairing the upgrade with `updateRedeemWindow`.
        uint256 currentRedeemWindow = redeemWindow;
        require(currentRedeemWindow != 0, RedeemWindowNotConfigured());

        // Snapshot the position fields once into stack locals so the trailing event emit reuses
        // them without three extra warm SLOADs after the state mutation. Both casts to `uint64` are
        // safe because `cooldown` and `redeemWindow` are bounded by @custom:constant MAX_COOLDOWN
        // and @custom:constant MAX_REDEEM_WINDOW respectively.
        address asset = position.asset;
        uint256 amount = position.amount;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 availableAt = uint64(block.timestamp + cooldown);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 redeemUntil = uint64(block.timestamp + currentRedeemWindow);

        position.withdrawAvailableAt = availableAt;
        position.redeemableUntil = redeemUntil;
        position.released = true;

        registrar.safeTransferFrom(currentOwner, address(this), tokenId);

        _addReleasedToken(tokenId);

        emit NameReleased(tokenId, msg.sender, asset, amount, availableAt, redeemUntil);
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

        _settleDeposit(position, tokenId, msg.sender);
    }

    /// @notice Moves a position's outstanding deposit onto the recipient's pull-payment balance.
    /// @dev Shared by @custom:function withdraw, where the recipient pulls the deposit themselves,
    ///      and by @custom:function reclaim, where a third party takes the name and the deposit is
    ///      settled on the departing holder's behalf. Both credit the same ledger and neither
    ///      transfers value, so the accounting is identical and lives here once. The per-asset
    ///      `tokenReserved` pool backs the refund in full, and @custom:reverts InsufficientFunds
    ///      when it cannot cover the amount owed. Emits @custom:emits RefundWithdrawn.
    ///      A zero-amount position is a no-op: it writes nothing and emits nothing, which keeps the
    ///      free-registration lifecycle free of meaningless ledger entries and events.
    /// @param position Storage pointer to the position being settled.
    /// @param recipient Address credited with the deposit. Always the position recipient.
    function _settleDeposit(
        ReleasePosition storage position,
        uint256 tokenId,
        address recipient
    )
        private
    {
        uint256 owed = position.amount;
        address asset = position.asset;

        // Nothing to settle: return before touching `claimed`. That flag is what `redeem` reads to
        // decide whether the holder has already been paid for the name, so setting it here would
        // make a zero-amount `withdraw`, which pays nothing and emits nothing, silently forfeit
        // the holder's right to recover their own name for no consideration at all. Free PopFull
        // and PopLite registrations seed exactly these positions, and `withdraw` is the step the
        // old contract required before a name could be recycled, so that is a path holders will
        // take.
        if (owed == 0) return;

        // Effects: from here the deposit really is being handed over, so the flag is set.
        position.claimed = true;

        // The per-asset reserve backs every refundable deposit; protocol fees are non-refundable
        // and never cover a refund.
        require(
            tokenReserved[asset] >= owed, InsufficientFunds(tokenId, owed, tokenReserved[asset])
        );

        position.amount = 0;
        tokenReserved[asset] -= owed;

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
        // Storage pointer over memory copy: only the fields we actually need are SLOAD-ed.
        RefundEntry storage entry = _refundEntries[entryId];
        amount = entry.amount;
        // Check existence first so a deleted (already-claimed or unknown) entry surfaces a clear
        // `NoSuchRefundEntry` rather than the recipient-mismatch revert that would otherwise fire
        // against the zero-address sentinel.
        require(amount > 0, NoSuchRefundEntry(entryId));
        uint256 entryTokenId = entry.tokenId;
        require(entry.recipient == msg.sender, NotRefundRecipient(msg.sender, entryTokenId));
        require(block.timestamp >= entry.availableAt, RefundLocked(entryId, entry.availableAt));

        _removeRefundEntry(entryId, msg.sender);

        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, RefundFailed(entryTokenId));

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
            RefundEntry storage entry = _refundEntries[entryId];
            uint256 amount = entry.amount;
            require(amount > 0, NoSuchRefundEntry(entryId));
            require(entry.recipient == msg.sender, NotRefundRecipient(msg.sender, entry.tokenId));
            require(block.timestamp >= entry.availableAt, RefundLocked(entryId, entry.availableAt));

            totalAmount += amount;
            _removeRefundEntry(entryId, msg.sender);

            emit RefundClaimed(msg.sender, entryId, amount);
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
    /// enumeration array, and emits @custom:emits RefundCredited. The cooldown is read from the
    /// configured `cooldown` storage value; @custom:constant MAX_COOLDOWN bounds it so the cast to
    /// `uint64` cannot truncate for any plausible block timestamp.
    function _creditRefund(
        address recipient,
        uint256 amount,
        uint256 tokenId
    )
        internal
        returns (uint256 entryId)
    {
        require(recipient != address(0), InvalidRecipient());
        require(amount > 0, InvalidAmount());

        entryId = ++_nextEntryId;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 availableAt = uint64(block.timestamp + cooldown);

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
        require(isReclaimable(tokenId), NotReclaimable(tokenId));

        ReleasePosition storage position = _positions[tokenId];
        address previousRecipient = position.recipient;

        // Settle before deleting: the departing holder keeps their claim on the deposit even though
        // they are losing the name. `_settleDeposit` is a no-op for a zero-amount position and for
        // one already withdrawn, so the common paths cost nothing extra.
        _settleDeposit(position, tokenId, previousRecipient);

        delete _positions[tokenId];
        _removeReleasedToken(tokenId);

        _registrar().safeTransferFrom(address(this), newOwner, tokenId);

        emit NameReclaimed(tokenId, previousRecipient, newOwner);
    }

    /// @inheritdoc IDotnsNameEscrow
    /// @dev `public` rather than `external` so `reclaim` can gate on it without a self-call, which
    ///      is what keeps the condition in one place instead of two.
    function isReclaimable(uint256 tokenId) public view override returns (bool reclaimable) {
        ReleasePosition storage position = _positions[tokenId];

        // The gate is the elapsed redeem window, not the `claimed` flag. Gating on `claimed` would
        // make recyclability depend on the previous holder choosing to withdraw, which strands the
        // name whenever they have no reason to: a zero-amount position has nothing to collect, so
        // "never withdraws" is the default rather than the exception. The window bounds the wait
        // instead, and reclaim settles any unwithdrawn value rather than holding it hostage.
        //
        // Lifecycle state only. `reclaim` also settles the deposit, which can in principle revert
        // `InsufficientFunds` when the reserved balance cannot cover the amount owed, so a true
        // answer here is a claim about the window rather than a guarantee
        // that the call is funded. The two coincide because `tokenReserved` is by construction the
        // exact sum of live position amounts: only `deposit` credits it, and only `_settleDeposit`
        // debits it, by exactly the amount it zeroes. `invariant_reserves_match_positions` holds
        // that construction, and `invariant_reclaimable_positions_are_fundable` asserts the
        // implication directly, so a change that broke the coincidence would fail the suite rather
        // than surface as a name advertised and then unregisterable.
        reclaimable = position.released && block.timestamp >= position.redeemableUntil;
    }

    /// @inheritdoc IDotnsNameEscrow
    function redeem(uint256 tokenId) external override nonReentrant {
        ReleasePosition storage position = _positions[tokenId];

        require(position.recipient == msg.sender, NotRefundRecipient(msg.sender, tokenId));
        // One error for the whole state predicate: unreleased, already withdrawn, or past the
        // window are all simply "not redeemable" from the caller's point of view, and collapsing
        // them avoids leaking a three-way state machine into the revert surface.
        require(
            position.released && !position.claimed && block.timestamp < position.redeemableUntil,
            NotRedeemable(tokenId)
        );

        // Restore the pre-release state and nothing more. Recipient, asset and amount are left
        // untouched so the deposit stays locked against the name; clearing the clocks means a later
        // release starts a fresh pair rather than inheriting stale deadlines.
        position.released = false;
        position.withdrawAvailableAt = 0;
        position.redeemableUntil = 0;

        _removeReleasedToken(tokenId);

        _registrar().safeTransferFrom(address(this), msg.sender, tokenId);

        emit NameRedeemed(tokenId, msg.sender);
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        address,
        uint256 tokenId,
        bytes calldata
    )
        external
        view
        override
        returns (bytes4 selector)
    {
        require(msg.sender == address(_registrar()), NotAcceptedTransfer(msg.sender));
        // Only accept transfers that this contract itself initiated via `release`. A holder calling
        // `registrar.safeTransferFrom(holder, escrow, tokenId)` directly would otherwise land the
        // NFT in custody with no `released` position, leaving the token (and any prior deposit)
        // permanently unreachable through `withdraw` / `reclaim`.
        require(_positions[tokenId].released, UnsolicitedDeposit(tokenId));
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
