// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

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
/// @dev Canonical state is keyed by tokenId. A token:
///      - is funded with a refundable deposit during registration;
///      - may later be released into escrow by its holder;
///      - may be withdrawn by the snapshotted refund recipient after cooldown;
///      - may be reclaimed by a new registrant via the controller, transferring custody out.
///
/// @dev CRITICAL INVARIANT: only names registered by NoStatus users (which require a deposit)
///      can be released and reclaimed through this escrow. PopLite/PopFull registrations are
///      free, create no deposit position, and therefore `release()` reverts with
///      `DepositNotConfigured`. This is enforced by the price-gated deposit in
///      `DotnsRegistrarController.register()` and the `position.amount != 0` check in release().
///
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

    /// @notice The protocol registry for resolving sibling contract addresses.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @notice Cooldown period after release during which refunds can be
    ///         claimed but not yet reclaimed.
    uint256 public cooldown;

    /// @notice Total amount of a specific asset reserved across all positions. Keyed by asset
    /// address. @dev address(0) is used for native token reservations
    mapping(address asset => uint256 amount) public tokenReserved;
    /// @dev Canonical release and refund state keyed by tokenId.
    mapping(uint256 tokenId => ReleasePosition position) private _positions;

    /// @dev Enumerable set of currently released tokens not yet reclaimed.
    uint256[] private _releasedTokens;

    /// @dev Index + 1 into `_releasedTokens`.
    mapping(uint256 tokenId => uint256 indexPlusOne) private _releasedIndexPlusOne;

    /// @notice Cumulative balance of cross-tier fees and registration excess held against
    /// unreleased shortfalls. @dev Only debited via `withdraw()` shortfall draw; never refundable
    /// directly to any caller.
    ///      Increments via `depositInsurance` and `chargeTransferFee`.
    uint256 public insuranceFund;

    /// @notice Highest price ever charged for the name identified by tokenId, across registration
    /// and any transfers. @dev Monotonic non-decreasing within a token's lifecycle, EXCEPT cleared
    /// on `reclaim()` (fresh slate for next registrant).
    ///      Used to compute transfer-time fee deltas: `fee = max(0, priceForTo -
    /// runningMax[tokenId])`.
    mapping(uint256 tokenId => uint256 max) public runningMax;

    /// @notice Pending native refund balances credited by `withdraw()` and pulled via
    /// `claimWithdrawal()`. @dev Pull-payment pattern: `withdraw()` only credits this mapping; the
    /// recipient must call
    ///      `claimWithdrawal()` to actually receive the funds. This isolates the external call
    ///      from the position-state mutation and avoids griefing via reverting fallback handlers.
    mapping(address recipient => uint256 amount) private _pendingWithdrawals;

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

    /// @notice Initializes the name escrow.
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
        require(params.amount != 0, InvalidAmount());
        // We do this incase the user decides to pass differing amounts
        require(msg.value == params.amount, InvalidAmount());
        // Only native deposits are currently supported; ERC20 support can be added in a
        // future upgrade by relaxing this check and routing transfers via SafeERC20.
        require(params.asset == address(0), AssetNotSupported(params.asset));
        require(params.recipient != address(0), InvalidRecipient());

        ReleasePosition storage position = _positions[params.tokenId];

        require(position.amount == 0, PositionAlreadyFunded(params.tokenId));
        require(!position.released, AlreadyReleased(params.tokenId));

        position.asset = params.asset;
        position.amount = params.amount;
        position.recipient = params.recipient;

        tokenReserved[position.asset] += params.amount;

        if (params.amount > runningMax[params.tokenId]) {
            runningMax[params.tokenId] = params.amount;
        }

        emit NativeDepositRecorded(params.tokenId, params.amount);
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
        if (msg.value > runningMax[params.tokenId]) {
            runningMax[params.tokenId] = msg.value;
        }

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
        uint256 prior = runningMax[params.tokenId];

        uint256 deltaFee = params.priceForTo > prior ? params.priceForTo - prior : 0;
        uint256 fee = deltaFee > params.reachFloor ? deltaFee : params.reachFloor;

        // Recipient already covered and not gated by reach: no fee owed.
        if (fee == 0) {
            if (msg.value > 0) {
                (bool ok,) = payable(params.payer).call{value: msg.value}("");
                require(ok, RefundFailed(params.tokenId));
                emit OverpaymentRefunded(params.payer, msg.value);
            }
            return 0;
        }

        require(msg.value >= fee, InsufficientValue());

        // Bump the running max to the highest payment ever recorded for this token.
        // Mirrors the rule in `deposit` and `depositInsurance` so the same invariant
        // ("`runningMax` is the largest amount ever paid through escrow for this token")
        // holds across every payment path: refundable deposit, registration insurance,
        // delta-driven transfer fee, and pure reach-floor friction.
        uint256 highest =
            params.priceForTo > params.reachFloor ? params.priceForTo : params.reachFloor;
        if (highest > prior) {
            runningMax[params.tokenId] = highest;
        }
        insuranceFund += fee;
        charged = fee;

        emit CrossTierFeePaid(
            params.tokenId,
            params.payer,
            params.to,
            fee,
            /* isRegistration */
            false
        );

        uint256 refund = msg.value - fee;

        if (refund > 0) {
            (bool ok,) = payable(params.payer).call{value: refund}("");
            require(ok, RefundFailed(params.tokenId));
            emit OverpaymentRefunded(params.payer, refund);
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
        require(position.amount != 0, DepositNotConfigured(tokenId));
        require(!position.released, AlreadyReleased(tokenId));

        // Only the locked refund recipient (= original deposit payer) can pull the release
        // trigger. Combined with the approval check below, this enforces a two-party
        // cooperation model: the current NFT holder must approve escrow, and the original
        // payer initiates the release. Closes the secondary-market grief vector where a
        // buyer of a NoStatus NFT could release someone else's deposit.
        require(msg.sender == position.recipient, NotRefundRecipient(msg.sender, tokenId));

        bool approvedForEscrow = registrar.getApproved(tokenId) == address(this)
            || registrar.isApprovedForAll(currentOwner, address(this));

        require(approvedForEscrow, EscrowNotApproved(tokenId));

        // recipient is locked at deposit time; release does not mutate it
        // casting to 'uint64' is safe because we bound cooldown to only minutes
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
        delete runningMax[tokenId];
        _removeReleasedToken(tokenId);

        _registrar().safeTransferFrom(address(this), newOwner, tokenId);

        emit NameReclaimed(tokenId, previousRecipient, newOwner);
    }

    /// @inheritdoc IDotnsNameEscrow
    function receiveControllerFunds() external payable override onlyController {
        emit ControllerFundsMigrated(msg.sender, msg.value);
    }

    /// @inheritdoc IERC721Receiver
    /// @notice Accepts safe ERC721 transfers into escrow only from the configured registrar.
    /// @dev Refusing arbitrary ERC721 transfers prevents foreign tokens (or registrar tokens
    ///      transferred outside the release flow) from getting permanently stuck in escrow.
    /// @return selector IERC721Receiver selector.
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
        versionString = "1.1.0";
    }

    /// @notice Returns the configured registrar from the protocol registry.
    /// @return registrar Registrar contract.
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
    /// @param tokenId Token identifier.
    function _addReleasedToken(uint256 tokenId) internal {
        if (_releasedIndexPlusOne[tokenId] != 0) return;

        _releasedTokens.push(tokenId);
        _releasedIndexPlusOne[tokenId] = _releasedTokens.length;
    }

    /// @notice Removes a token from the released-token set if present.
    /// @param tokenId Token identifier.
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
