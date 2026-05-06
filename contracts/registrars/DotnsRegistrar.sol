// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ERC721Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721Utils} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Utils.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IDotnsRegistrar} from "./IDotnsRegistrar.sol";
import {IDotnsController} from "./IDotnsController.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";

import {IStoreFactory} from "../store/IStoreFactory.sol";
import {StoreUtils} from "../utils/StoreUtils.sol";
import {RegistrationUtils} from "../utils/RegistrationUtils.sol";
import {LabelUtils} from "../utils/LabelUtils.sol";
import {StringUtils} from "../utils/StringUtils.sol";
import {IDotnsReverseResolver} from "../resolvers/IDotnsReverseResolver.sol";
import {IDotnsNameEscrow} from "../escrow/IDotnsNameEscrow.sol";
import {IPopRules} from "../pop/IPopRules.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";

/// @title Dotns Registrar
/// @notice ERC721-backed registrar implementing permanent name ownership.
/// @dev This contract is deliberately policy-free.
///      Transfers are supported to allow ownership changes without registry hooks.
///
/// @dev Store writes on transfer:
///      When an ERC721 name token is transferred between non-zero addresses (i.e. not mint or
/// burn), the registrar writes the label to the recipient's Store using the label stored in
/// `_labels`.
///      This ensures the recipient's Store contains a record of every name they have received.
///      Stores are immutable (locked by DotNS controllers), so the sender's entry is not removed.
///
/// @custom:security-contact admin@parity.io
contract DotnsRegistrar is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC721Upgradeable,
    ReentrancyGuardTransient,
    IDotnsRegistrar
{
    using StoreUtils for IStoreFactory;
    using StringUtils for *;

    /// @notice Mapping of authorised controllers.
    /// @dev Controllers may call `register`. Keyed by the shared baseline
    ///      {IDotnsController} interface so the registrar doesn't depend on any
    ///      specific controller shape. Commit-reveal, PoP, and future controllers
    ///      coexist here so long as they implement the baseline interface.
    /// @custom:oz-retyped-from mapping(IDotnsRegistrarController => bool)
    mapping(IDotnsController controller => bool exists) public controllers;

    /// @notice Protocol-level address registry for all DotNS contracts.
    /// @dev Used to resolve sibling contract addresses (store factory, controller, registry)
    ///      without storing individual references.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @notice DEPRECATED as of v1.2.0: Previously stored labelhashes per token ID.
    /// @dev Retained for UUPS storage layout compatibility. No longer written to.
    ///      The labelhash is now derived on-the-fly from `_labels[tokenId]` via
    /// `keccak256(bytes(label))`. REMOVE this mapping when deploying to a new environment (fresh
    /// deploy, not upgrade).
    /// @custom:oz-retyped-from mapping(uint256 => bytes32)
    mapping(uint256 tokenId => bytes32 labelhash) private _labelhashes;

    /// @notice Human-readable label per token ID. Single source of truth for name data.
    /// @dev Stored at registration time. Used during transfers to write the label directly
    ///      to the recipient's Store without needing to read from the sender's Store.
    ///      The labelhash can always be derived as `keccak256(bytes(label))`.
    mapping(uint256 tokenId => string label) private _labels;

    /// @dev Reserved storage space to allow for layout changes in the future.
    uint256[47] private __gap;

    /// @notice Restricts function access to authorised controllers.
    modifier onlyController() {
        _onlyController();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the registrar.
    /// @dev Uses OpenZeppelin upgradeable initializers.
    /// @param name ERC721 token name.
    /// @param symbol ERC721 token symbol.
    // TODO: On fresh deploy (not upgrade), accept IDotnsProtocolRegistry and set protocolRegistry here.
    function initialize(string calldata name, string calldata symbol) external initializer {
        __Ownable_init(msg.sender);
        __ERC721_init(name, symbol);
    }

    /// @inheritdoc IDotnsRegistrar
    // TODO: On fresh deploy (not upgrade), remove this function. Set protocolRegistry in initialize instead.
    function updateProtocolRegistry(IDotnsProtocolRegistry registry) external override onlyOwner {
        protocolRegistry = registry;
        emit ProtocolRegistryUpdated(registry);
    }

    /// @inheritdoc IDotnsRegistrar
    function addController(IDotnsController controller) external onlyOwner {
        controllers[controller] = true;
        emit ControllerAdded(controller);
    }

    /// @inheritdoc IDotnsRegistrar
    function removeController(IDotnsController controller) external onlyOwner {
        controllers[controller] = false;
        emit ControllerRemoved(controller);
    }

    /// @inheritdoc IDotnsRegistrar
    function available(uint256 id) public view override returns (bool isAvailable) {
        if (!_exists(id)) return true;
        address escrow = protocolRegistry.get(DotnsConstants.NAME_ESCROW);
        if (escrow == address(0) || _ownerOf(id) != escrow) return false;

        IDotnsNameEscrow.ReleasePosition memory position =
            IDotnsNameEscrow(payable(escrow)).getReleasePosition(id);
        isAvailable = position.released && position.claimed;
    }

    /// @inheritdoc IDotnsRegistrar
    function exists(uint256 tokenId) external view override returns (bool tokenExists) {
        tokenExists = _exists(tokenId);
    }

    /// @inheritdoc IDotnsRegistrar
    function register(
        uint256 id,
        address owner,
        string calldata label
    )
        external
        override
        onlyController
    {
        require(available(id), NameNotAvailable(id));
        _labels[id] = label;
        _mint(owner, id);
        emit NameRegistered(id, owner);
    }

    /// @inheritdoc IDotnsRegistrar
    function syncLabel(uint256 tokenId, string calldata label) external override {
        require(_exists(tokenId), NameNotAvailable(tokenId));
        require(ownerOf(tokenId) == msg.sender, NotTokenOwner(msg.sender, tokenId));
        require(bytes(_labels[tokenId]).length == 0, LabelAlreadySet(tokenId));
        require(label.isSingleLabel(), InvalidLabel());

        (, bytes32 node) = LabelUtils.deriveNode(label);
        require(uint256(node) == tokenId, LabelMismatch(tokenId));

        _labels[tokenId] = label;
        emit LabelSynced(tokenId, label);
    }

    /// @inheritdoc IDotnsRegistrar
    function labelOf(uint256 tokenId) external view override returns (string memory) {
        return _labels[tokenId];
    }

    /// @inheritdoc IDotnsRegistrar
    function quoteTransferFee(
        uint256 tokenId,
        address to
    )
        external
        view
        override
        returns (uint256 requiredFee)
    {
        require(to != address(0), ERC721InvalidReceiver(address(0)));

        address from = ownerOf(tokenId);
        (,,, requiredFee) = _quoteTransferFee(from, to, tokenId);
    }

    /// @inheritdoc IDotnsRegistrar
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    )
        public
        payable
        override(ERC721Upgradeable, IDotnsRegistrar)
        nonReentrant
    {
        _transferToken(from, to, tokenId);
    }

    /// @inheritdoc IDotnsRegistrar
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    )
        public
        payable
        override(ERC721Upgradeable, IDotnsRegistrar)
    {
        safeTransferFrom(from, to, tokenId, "");
    }

    /// @inheritdoc IDotnsRegistrar
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    )
        public
        payable
        override(ERC721Upgradeable, IDotnsRegistrar)
        nonReentrant
    {
        _transferToken(from, to, tokenId);
        ERC721Utils.checkOnERC721Received(_msgSender(), from, to, tokenId, data);
    }

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.6.0";
    }

    /// @notice Checks whether a token ID exists.
    /// @param tokenId Token identifier.
    /// @return True if the token exists.
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /// @notice Shared body for the payable ERC721 transfer entrypoints.
    /// @dev Mirrors OZ's `transferFrom` body while preserving `msg.value` on the
    ///      call frame so the fee logic in `_update` can charge or refund as needed.
    /// @param from Current owner of the token.
    /// @param to Recipient address.
    /// @param tokenId Token identifier.
    function _transferToken(address from, address to, uint256 tokenId) private {
        require(to != address(0), ERC721InvalidReceiver(address(0)));
        address previousOwner = _update(to, tokenId, _msgSender());
        require(previousOwner == from, ERC721IncorrectOwner(from, tokenId, previousOwner));
    }

    /// @notice Internal function to check for controller access.
    function _onlyController() internal view {
        require(controllers[IDotnsController(msg.sender)], NotController(msg.sender));
    }

    /// @inheritdoc ERC721Upgradeable
    function _update(
        address to,
        uint256 tokenId,
        address auth
    )
        internal
        override
        returns (address from)
    {
        from = super._update(to, tokenId, auth);

        if (from != address(0) && from != to && address(protocolRegistry) != address(0)) {
            _clearFormerPrimaryName(from, tokenId);
        }

        if (from != address(0) && to != address(0) && address(protocolRegistry) != address(0)) {
            _syncRecipientStore(to, tokenId);
        }

        // Fee-on-transfer path. The skip conditions below mirror the legitimate non-fee
        // flows: mints (controller already priced), burns (defensive), self-transfers
        // (no economic event), and escrow release/reclaim (escrow itself is the
        // counterparty and pricing happens in the escrow/controller).
        if (from == address(0)) return from;
        if (to == address(0)) return from;
        if (from == to) return from;

        (address escrow, uint256 priceForTo, uint256 reachFloor, uint256 requiredFee) =
            _quoteTransferFee(from, to, tokenId);
        require(requiredFee == 0 || msg.value != 0, TransferFeeRequired(tokenId, to, requiredFee));

        // Preserve refund semantics on already-covered moves: when callers attach value to a
        // zero-fee transfer, route the call through escrow so the full amount is refunded
        // instead of remaining stranded on the registrar.
        if (requiredFee == 0 && msg.value == 0) return from;

        IDotnsNameEscrow(payable(escrow)).chargeTransferFee{value: msg.value}(
            IDotnsNameEscrow.ChargeTransferFeeParams({
                tokenId: tokenId,
                priceForTo: priceForTo,
                reachFloor: reachFloor,
                payer: msg.sender,
                to: to
            })
        );

        return from;
    }

    function _clearFormerPrimaryName(address from, uint256 tokenId) internal {
        string memory label = _labels[tokenId];
        if (bytes(label).length == 0) return;

        IDotnsReverseResolver reverse =
            IDotnsReverseResolver(protocolRegistry.get(DotnsConstants.REVERSE_RESOLVER));
        string memory currentReverse = reverse.nameOf(from);
        string memory fullName = string.concat(label, DotnsConstants.TLD);

        if (LabelUtils.labelhashMemory(currentReverse) == LabelUtils.labelhashMemory(fullName)) {
            reverse.setReverseName(from, "");
        }
    }

    /// @notice Ensures the recipient has a Store and writes the label to it if available.
    /// @dev Deploys a Store for the recipient via `getOrCreateStore` when one does not exist,
    ///      then writes the label entry if `_labels[tokenId]` is populated and the key
    ///      does not already have a value (locked entries are skipped).
    ///      Silently returns if the store factory is not set.
    /// @param to Address of the transfer recipient.
    /// @param tokenId The transferred token identifier.
    function _syncRecipientStore(address to, uint256 tokenId) internal {
        IStoreFactory factory = IStoreFactory(protocolRegistry.get(DotnsConstants.STORE_FACTORY));
        if (address(factory) == address(0)) return;

        address[] memory controllers_ = RegistrationUtils.storeControllers(protocolRegistry);

        string memory label = _labels[tokenId];
        if (bytes(label).length == 0) {
            // Side effect is deploying/updating the recipient's Store; returned instance is unused.
            // slither-disable-next-line unused-return
            factory.getOrCreateStore(controllers_, to);
            return;
        }

        bytes32 labelhash = LabelUtils.labelhashMemory(label);

        // Side effect is writing the label into the recipient's Store; returned instance is unused.
        // slither-disable-next-line unused-return
        factory.writeToStore(controllers_, to, labelhash, string.concat(label, DotnsConstants.TLD));
    }

    /// @notice Resolves the configured name escrow address from the protocol registry.
    /// @dev Resolved per call rather than cached so a registry update propagates atomically.
    /// @return escrow Current name escrow address; may be `address(0)` when unconfigured.
    function _escrow() private view returns (address escrow) {
        escrow = protocolRegistry.get(DotnsConstants.NAME_ESCROW);
    }

    /// @notice Resolves the configured PoP rules contract from the protocol registry.
    /// @dev Resolved per call rather than cached so a registry update propagates atomically.
    /// @return rules Current PoP rules interface.
    function _popRules() private view returns (IPopRules rules) {
        rules = IPopRules(protocolRegistry.get(DotnsConstants.POP_RULES));
    }

    /// @notice Quotes the recipient-tier price and required delta for a transfer.
    /// @dev Returns zero for same-tier, upward, self, and escrow-custody moves.
    ///      Reverts when the escrow is unconfigured or the token's legacy label has not
    ///      been synced, matching the runtime requirements of fee-aware user transfers.
    /// @param from Current owner of the token.
    /// @param to Intended recipient.
    /// @param tokenId Token identifier.
    /// @return escrow The configured name escrow address.
    /// @return priceForTo Full recipient-tier price quoted by PopRules.
    /// @return reachFloor Friction floor when the recipient cannot meet the label's required tier.
    /// @return requiredFee Final fee owed for the transfer: `max(priceForTo - runningMax,
    /// reachFloor)`.
    function _quoteTransferFee(
        address from,
        address to,
        uint256 tokenId
    )
        private
        view
        returns (address escrow, uint256 priceForTo, uint256 reachFloor, uint256 requiredFee)
    {
        escrow = _escrow();
        require(escrow != address(0), EscrowNotConfigured());

        if (from == to) return (escrow, 0, 0, 0);
        if (to == escrow || from == escrow) return (escrow, 0, 0, 0);

        string memory label = _labels[tokenId];
        require(bytes(label).length > 0, LabelNotSynced(tokenId));

        IPopRules popRules = _popRules();
        priceForTo = popRules.priceWithoutCheck(label, to).price;

        uint256 prior = IDotnsNameEscrow(payable(escrow)).runningMax(tokenId);
        uint256 deltaFee = priceForTo > prior ? priceForTo - prior : 0;

        // Reach floor: if the recipient cannot meet the label's required tier, charge the
        // length-scaled `NoStatus` rate even when the running max would otherwise cover the
        // move. Catches verified-but-below recipients (lite holding a base name, etc.) so
        // PopFull stays the only tier that receives every name without friction.
        reachFloor = popRules.reachFee(label, to);

        requiredFee = deltaFee > reachFloor ? deltaFee : reachFloor;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
