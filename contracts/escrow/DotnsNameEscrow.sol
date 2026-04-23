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
import {DotnsProtocolRegistry} from "../registry/DotnsProtocolRegistry.sol";

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

    /// @notice Total amount of a specific asset reserved across all positions. Keyed by asset address.
    /// @dev address(0) is used for native token reservations
    mapping(address asset => uint256 amount) public tokenReserved;
    /// @dev Canonical release and refund state keyed by tokenId.
    mapping(uint256 tokenId => ReleasePosition position) private _positions;

    /// @dev Enumerable set of currently released tokens not yet reclaimed.
    uint256[] private _releasedTokens;

    /// @dev Index + 1 into `_releasedTokens`.
    mapping(uint256 tokenId => uint256 indexPlusOne) private _releasedIndexPlusOne;

    /// @dev Reserved storage space to allow for layout changes in the future.
    uint256[50] private __gap;

    /// @notice Restricts calls to the configured registrar controller.
    modifier onlyController() {
        _onlyController();
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
            unchecked {
                ++outIndex;
            }
        }
    }

    /// @inheritdoc IDotnsNameEscrow
    function deposit(DepositParams calldata params) external payable override onlyController {
        require(params.amount != 0, InvalidAmount());
        // We do this incase the user decides to pass differing amounts
        require(msg.value == params.amount, InvalidAmount());
        // TODO: Remove this check or add check to ensure its against the supported asset
        require(params.asset == address(0), AssetNotSupported(params.asset));

        ReleasePosition storage position = _positions[params.tokenId];

        require(position.amount == 0, PositionAlreadyFunded(params.tokenId));
        require(!position.released, AlreadyReleased(params.tokenId));
        // TODO: Change this to params.asset
        position.asset = address(0);
        position.amount = params.amount;

        tokenReserved[position.asset] += params.amount;

        emit NativeDepositRecorded(params.tokenId, params.amount);
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

        bool approvedForEscrow = registrar.getApproved(tokenId) == address(this)
            || registrar.isApprovedForAll(currentOwner, address(this));

        require(approvedForEscrow, EscrowNotApproved(tokenId));

        position.recipient = currentOwner;
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

        uint256 amount = position.amount;
        address asset = position.asset;
        address recipient = position.recipient;

        position.claimed = true;
        position.amount = 0;
        // We not going to check for asset
        // as the current implementation only supports native
        // payments later on we can add logic for assets e.g. PUSD and and
        tokenReserved[asset] -= amount;
        (bool ok,) = payable(recipient).call{value: amount}("");
        require(ok, RefundFailed(tokenId));

        emit RefundWithdrawn(tokenId, recipient, asset, amount);
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
        versionString = "1.0.0";
    }

    /// @notice Returns the configured registrar from the protocol registry.
    /// @return registrar Registrar contract.
    function _registrar() internal view returns (IDotnsRegistrar registrar) {
        registrar = IDotnsRegistrar(
            protocolRegistry.get(DotnsProtocolRegistry(address(protocolRegistry)).REGISTRAR())
        );
    }

    /// @notice Restricts calls to the configured controller from the protocol registry.
    function _onlyController() internal view {
        address controller =
            protocolRegistry.get(DotnsProtocolRegistry(address(protocolRegistry)).CONTROLLER());
        require(msg.sender == controller, NotController(msg.sender));
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
