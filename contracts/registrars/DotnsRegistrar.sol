// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ERC721Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

import {IDotnsRegistrar} from "./IDotnsRegistrar.sol";
import {IDotnsController} from "./IDotnsController.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";

import {IStoreFactory} from "../store/IStoreFactory.sol";
import {ILabelStore} from "../store/ILabelStore.sol";
import {StoreUtils} from "../utils/StoreUtils.sol";
import {LabelUtils} from "../utils/LabelUtils.sol";
import {IDotnsReverseResolver} from "../resolvers/IDotnsReverseResolver.sol";
import {IDotnsNameEscrow} from "../escrow/IDotnsNameEscrow.sol";
import {IPopRules} from "../pop/IPopRules.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";

/// @title Dotns Registrar
/// @notice ERC721-backed registrar implementing permanent name ownership.
/// @dev Deliberately policy-free. Transfers are supported to allow ownership changes without
/// registry hooks, and the registrar itself does not encode pricing, reservations, or PoP
/// gating; those live in the controllers and @custom:contract IPopRules. The fee-on-transfer hook
/// in `_update` is a thin enforcement layer that consults the escrow.
/// @custom:security-contact admin@parity.io
contract DotnsRegistrar is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC721Upgradeable,
    IDotnsRegistrar
{
    using StoreUtils for IStoreFactory;

    /// @notice Mapping of authorised controllers.
    /// @dev Controllers may call `register`. Keyed by the shared baseline @custom:contract
    /// IDotnsController interface so the registrar doesn't depend on any specific controller shape.
    /// Commit-reveal, PoP, and future controllers coexist here so long as they implement the
    /// baseline interface.
    /// @custom:oz-retyped-from mapping(IDotnsRegistrarController => bool)
    mapping(IDotnsController controller => bool exists) public controllers;

    /// @notice Protocol-level address registry for all DotNS contracts.
    /// @dev Used to resolve sibling contract addresses (store factory, controller, registry)
    /// without storing individual references.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @dev Reserved storage space to allow for layout changes in the future.
    uint256[50] private __gap;

    /// @notice Restricts function access to authorised controllers.
    modifier onlyController() {
        _onlyController();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the registrar.
    /// @dev Uses OpenZeppelin upgradeable initialisers and is callable once through the UUPS
    /// proxy; direct calls on the implementation revert with @custom:reverts InvalidInitialization
    /// because `_disableInitializers` runs in the constructor, and any nested call outside an
    /// active initialiser scope reverts with @custom:reverts NotInitializing.
    function initialize(
        string calldata name,
        string calldata symbol,
        IDotnsProtocolRegistry registry
    )
        external
        initializer
    {
        __Ownable_init(msg.sender);
        __ERC721_init(name, symbol);
        protocolRegistry = registry;
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
        address escrow = address(protocolRegistry) == address(0)
            ? address(0)
            : protocolRegistry.get(DotnsConstants.NAME_ESCROW);
        return escrow != address(0) && _ownerOf(id) == escrow;
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
        _mint(owner, id);
        _writeOwnerLabel(owner, id, label);
        emit NameRegistered(id, owner);
    }

    /// @inheritdoc IDotnsRegistrar
    function labelOf(uint256 tokenId) external view override returns (string memory) {
        address holder = _ownerOf(tokenId);
        if (holder == address(0)) return "";
        return LabelUtils.stripDotTld(_readLabel(tokenId, holder));
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
        (,, requiredFee) = _quoteTransferFee(from, to, tokenId);
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
    {
        super.transferFrom(from, to, tokenId);
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
    {
        super.safeTransferFrom(from, to, tokenId, data);
    }

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.0.0";
    }

    /// @inheritdoc IDotnsRegistrar
    function exists(uint256 tokenId) external view override returns (bool tokenExists) {
        tokenExists = _exists(tokenId);
    }

    /// @notice Checks whether a token ID exists.
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
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
            _syncRecipientStore(to, from, tokenId);
        }

        // Fee-on-transfer path. Skip mints (controller already priced), burns (defensive),
        // and self-transfers (no economic event).
        if (from == address(0)) return from;
        if (to == address(0)) return from;
        if (from == to) return from;

        (address escrow, uint256 reachFloor, uint256 requiredFee) =
            _quoteTransferFee(from, to, tokenId);
        require(requiredFee == 0 || msg.value != 0, TransferFeeRequired(tokenId, to, requiredFee));

        // Deposits follow the NFT, not the depositor: every transfer that moves a name off the
        // prior position recipient rebinds the escrow position to the new holder, so the locked
        // deposit (when funded) and the lifecycle marker (when zero-amount) both travel with the
        // name. Escrow-touching transfers (release into escrow, reclaim out of it) are excluded
        // because the escrow is mid-call and its non-reentrancy guard would reject a re-entry;
        // the release/reclaim paths manage the position directly.
        bool isEscrowTouching = to == escrow || from == escrow;
        bool positionSyncNeeded;
        if (!isEscrowTouching) {
            IDotnsNameEscrow.ReleasePosition memory position =
                IDotnsNameEscrow(payable(escrow)).getReleasePosition(tokenId);
            positionSyncNeeded = position.recipient != address(0) && to != position.recipient;
        }

        if (requiredFee == 0 && msg.value == 0 && !positionSyncNeeded) return from;

        IDotnsNameEscrow(payable(escrow)).chargeTransferFee{value: msg.value}(
            IDotnsNameEscrow.ChargeTransferFeeParams({
                tokenId: tokenId, reachFloor: reachFloor, payer: msg.sender, to: to
            })
        );

        return from;
    }

    function _clearFormerPrimaryName(address from, uint256 tokenId) internal {
        string memory fullName = _readLabel(tokenId, from);
        if (bytes(fullName).length == 0) return;

        IDotnsReverseResolver reverse =
            IDotnsReverseResolver(protocolRegistry.get(DotnsConstants.REVERSE_RESOLVER));
        string memory currentReverse = reverse.nameOf(from);

        if (LabelUtils.labelhashMemory(currentReverse) == LabelUtils.labelhashMemory(fullName)) {
            reverse.setReverseName(from, "");
        }
    }

    /// @notice Mirrors the sender's label entry into the recipient's `LabelStore`.
    function _syncRecipientStore(address to, address from, uint256 tokenId) internal {
        IStoreFactory factory = _storeFactory();
        if (address(factory) == address(0)) return;

        string memory fullName = _readLabel(tokenId, from);
        if (bytes(fullName).length == 0) {
            factory.ensureLabelStore(to);
            return;
        }

        factory.writeLabel(to, bytes32(tokenId), fullName);
    }

    /// @notice Reads the full name (`label.tld`) for `tokenId` from `holder`'s `LabelStore`.
    function _readLabel(
        uint256 tokenId,
        address holder
    )
        private
        view
        returns (string memory fullName)
    {
        IStoreFactory factory = _storeFactory();
        if (address(factory) == address(0)) return "";
        address store = factory.getLabelStore(holder);
        if (store == address(0)) return "";
        return ILabelStore(store).getLabel(bytes32(tokenId));
    }

    /// @notice Resolves the configured name escrow address from the protocol registry.
    function _escrow() private view returns (address escrow) {
        escrow = protocolRegistry.get(DotnsConstants.NAME_ESCROW);
    }

    /// @notice Resolves the configured PoP rules contract from the protocol registry.
    function _popRules() private view returns (IPopRules rules) {
        rules = IPopRules(protocolRegistry.get(DotnsConstants.POP_RULES));
    }

    /// @notice Resolves the configured store factory from the protocol registry.
    function _storeFactory() private view returns (IStoreFactory factory) {
        factory = IStoreFactory(protocolRegistry.get(DotnsConstants.STORE_FACTORY));
    }

    /// @notice Writes the canonical full name into `owner`'s `LabelStore` keyed by
    /// `bytes32(tokenId)`.
    function _writeOwnerLabel(address owner, uint256 tokenId, string calldata label) private {
        if (bytes(label).length == 0) return;
        IStoreFactory factory = _storeFactory();
        if (address(factory) == address(0)) return;
        factory.writeLabel(owner, bytes32(tokenId), string.concat(label, DotnsConstants.TLD));
    }

    /// @notice Quotes the friction fee required for a transfer.
    /// @dev Required fee is the reach floor returned by @custom:function PopRules.transferFloor.
    /// It is paid by the sender on every downward or cross-reach transfer and settles to the
    /// insurance fund. Any prior deposit travels with the NFT: the escrow rebinds the position to
    /// the new holder rather than refunding the sender, so transferring a funded name forfeits the
    /// locked deposit to the recipient. Self-transfers and escrow-touching transfers return zero.
    function _quoteTransferFee(
        address from,
        address to,
        uint256 tokenId
    )
        private
        view
        returns (address escrow, uint256 reachFloor, uint256 requiredFee)
    {
        escrow = _escrow();
        require(escrow != address(0), EscrowNotConfigured());

        if (from == to) return (escrow, 0, 0);
        if (to == escrow || from == escrow) return (escrow, 0, 0);

        string memory fullName = _readLabel(tokenId, from);
        // No label means there is no label-derived price to charge against; treat as
        // a zero-fee move.
        if (bytes(fullName).length == 0) return (escrow, 0, 0);
        string memory label = LabelUtils.stripDotTld(fullName);
        if (bytes(label).length == 0) return (escrow, 0, 0);

        reachFloor = _popRules().transferFloor(label, from, to);
        requiredFee = reachFloor;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
