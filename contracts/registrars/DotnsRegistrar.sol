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
import {StringUtils} from "../utils/StringUtils.sol";
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
    using StringUtils for *;

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
        require(address(registry) != address(0), ProtocolRegistryRequired());
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
        address holder = _ownerOf(id);
        if (holder == address(0)) return true;

        address escrow = protocolRegistry.get(DotnsConstants.NAME_ESCROW);
        if (holder != escrow) return false;

        // Escrow custody on its own no longer means registrable. While a released position is
        // inside its redeem window the name still belongs to its previous holder, and reclaim
        // would revert with NotReclaimable. Reporting it available there would advertise the name
        // as free and send registrants through an entire commit-reveal cycle that cannot succeed,
        // so availability tracks the window rather than custody.
        IDotnsNameEscrow.ReleasePosition memory position =
            IDotnsNameEscrow(payable(escrow)).getReleasePosition(id);

        return block.timestamp >= position.redeemableUntil;
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
        // `available` returns true both for unminted ids and for ids currently held by escrow
        // (so the controller can route through `escrow.reclaim`). `register` only handles the
        // fresh-mint branch; the escrow-held branch must use the reclaim path and is rejected
        // here with the typed error so callers do not see OZ's `ERC721InvalidSender(0)`.
        require(!_exists(id), NameNotAvailable(id));
        require(owner != protocolRegistry.get(DotnsConstants.NAME_ESCROW), InvalidOwner());
        // Empty labels are an intentional gateway-cold path (substrate Root cannot deploy a
        // `LabelStore` under `pallet-revive`, so the controller stashes a pending claim and the
        // user settles via @custom:function IDotnsPopController.claimLabelStore later). Non-empty
        // labels must still be canonical so the transfer-floor lookup in `_quoteTransferFee`
        // cannot brick the token by reverting on a malformed stem.
        require(bytes(label).length == 0 || label.isSingleLabel(), InvalidLabel());
        _mint(owner, id);
        if (bytes(label).length != 0) _writeOwnerLabel(owner, id, label);
        emit NameRegistered(id, owner);
    }

    /// @inheritdoc IDotnsRegistrar
    function labelOf(uint256 tokenId) external view override returns (string memory) {
        address holder = _ownerOf(tokenId);
        if (holder == address(0)) return "";
        return LabelUtils.stripTld(protocolRegistry.tld(), _readLabel(tokenId, holder));
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
        super.safeTransferFrom(from, to, tokenId, "");
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

        // Mints and self-transfers carry no economic event. Reject any attached value on those
        // paths because nothing forwards it onward, which would otherwise trap the funds in this
        // contract permanently (no `receive`, no rescue path).
        if (from == address(0) || from == to) {
            require(msg.value == 0, UnexpectedValue());
            return from;
        }

        // Resolve every registry-sourced dependency once and thread it into the helpers so a
        // single transfer pays one external lookup per key rather than three.
        IDotnsProtocolRegistry registry = protocolRegistry;
        address escrow = registry.get(DotnsConstants.NAME_ESCROW);
        require(escrow != address(0), EscrowNotConfigured());
        IStoreFactory factory = IStoreFactory(registry.get(DotnsConstants.STORE_FACTORY));

        bool isEscrowTouching = to == escrow || from == escrow;
        // Skip mirroring on escrow-touching paths: release deposits the NFT into custody where
        // a `LabelStore` would be wasted and reclaim hands it back to a fresh-mint controller
        // that writes the label through its own flow.
        if (!isEscrowTouching) {
            _syncRecipientStore(factory, to, from, tokenId);
        }

        (uint256 reachFloor, uint256 requiredFee) =
            _quoteTransferFeeFor(registry, factory, isEscrowTouching, from, to, tokenId);
        if (requiredFee != 0) {
            require(msg.value >= requiredFee, TransferFeeRequired(tokenId, to, requiredFee));
        }

        // Deposits follow the NFT, not the depositor: every transfer that moves a name off the
        // prior position recipient rebinds the escrow position to the new holder so the locked
        // deposit (when funded) and the lifecycle marker (when zero-amount) both travel with the
        // name. Escrow-touching transfers are excluded because the escrow is mid-call and its
        // non-reentrancy guard would reject a re-entry; release/reclaim manage the position
        // directly.
        bool positionSyncNeeded;
        if (!isEscrowTouching) {
            IDotnsNameEscrow.ReleasePosition memory position =
                IDotnsNameEscrow(payable(escrow)).getReleasePosition(tokenId);
            positionSyncNeeded = position.recipient != address(0) && to != position.recipient;
        }

        if (requiredFee == 0 && msg.value == 0 && !positionSyncNeeded) {
            return from;
        }

        IDotnsNameEscrow(payable(escrow)).chargeTransferFee{value: msg.value}(
            IDotnsNameEscrow.ChargeTransferFeeParams({
                tokenId: tokenId, reachFloor: reachFloor, payer: msg.sender, to: to
            })
        );

        return from;
    }

    /// @notice Mirrors the sender's label entry into the recipient's `LabelStore`.
    function _syncRecipientStore(
        IStoreFactory factory,
        address to,
        address from,
        uint256 tokenId
    )
        internal
    {
        string memory fullName = _readLabelFor(factory, tokenId, from);
        if (bytes(fullName).length == 0) {
            // Sender has no label entry for the token (typical of gateway-cold PoP mints).
            // Nothing to mirror, so do not deploy a recipient store; downstream writes are
            // demand-deploy through `StoreUtils.ensureLabelStore`.
            return;
        }
        factory.writeLabel(to, bytes32(tokenId), fullName);
    }

    /// @notice Reads the full name (`label.tld`) for `tokenId` from `holder`'s `LabelStore` using
    /// a caller-supplied factory.
    function _readLabelFor(
        IStoreFactory factory,
        uint256 tokenId,
        address holder
    )
        private
        view
        returns (string memory fullName)
    {
        address store = factory.getLabelStore(holder);
        if (store == address(0)) return "";
        return ILabelStore(store).getLabel(bytes32(tokenId));
    }

    /// @notice Reads the full name for `tokenId` from `holder`'s `LabelStore` via fresh lookups.
    /// @dev Used by external view functions where caching the factory is not yet established;
    /// the hot transfer path uses @custom:function _readLabelFor with a cached factory.
    function _readLabel(
        uint256 tokenId,
        address holder
    )
        private
        view
        returns (string memory fullName)
    {
        return _readLabelFor(_storeFactory(), tokenId, holder);
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
    /// @dev Caller (@custom:function register) is responsible for short-circuiting on empty label;
    /// the factory is a protocol-critical dependency and is assumed non-zero (a zero return from
    /// the registry would have already broken every other call site).
    function _writeOwnerLabel(address owner, uint256 tokenId, string calldata label) private {
        _storeFactory()
            .writeLabel(owner, bytes32(tokenId), string.concat(label, protocolRegistry.tld()));
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
        if (from == to) return (address(0), 0, 0);

        IDotnsProtocolRegistry registry = protocolRegistry;
        escrow = registry.get(DotnsConstants.NAME_ESCROW);
        require(escrow != address(0), EscrowNotConfigured());

        bool isEscrowTouching = to == escrow || from == escrow;
        IStoreFactory factory = IStoreFactory(registry.get(DotnsConstants.STORE_FACTORY));
        (reachFloor, requiredFee) =
            _quoteTransferFeeFor(registry, factory, isEscrowTouching, from, to, tokenId);
    }

    /// @notice Quotes the transfer floor reusing a caller-cached registry and store factory.
    /// @dev Hot-path variant used by @custom:function _update. Returns `(0, 0)` for any
    /// escrow-touching move or when the sender holds no label entry; otherwise reads the canonical
    /// label and delegates to @custom:function PopRules.transferFloor.
    function _quoteTransferFeeFor(
        IDotnsProtocolRegistry registry,
        IStoreFactory factory,
        bool isEscrowTouching,
        address from,
        address to,
        uint256 tokenId
    )
        private
        view
        returns (uint256 reachFloor, uint256 requiredFee)
    {
        if (isEscrowTouching) return (0, 0);

        string memory fullName = _readLabelFor(factory, tokenId, from);
        // No label means there is no label-derived price to charge against; treat as a zero-fee
        // move (typical of gateway-cold PoP mints that have not yet claimed a `LabelStore`).
        if (bytes(fullName).length == 0) return (0, 0);
        // A stored full name always carries the registry TLD suffix, so an empty strip means the
        // name is malformed for this registry (a wrong or missing suffix); fail loudly rather than
        // mis-pricing the move as zero-fee.
        string memory label = LabelUtils.stripTld(registry.tld(), fullName);
        require(bytes(label).length != 0, InvalidLabel());

        reachFloor =
            IPopRules(registry.get(DotnsConstants.POP_RULES)).transferFloor(label, from, to);
        requiredFee = reachFloor;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
