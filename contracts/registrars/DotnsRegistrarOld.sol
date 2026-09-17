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

import {IDotnsRegistrarOld} from "./IDotnsRegistrarOld.sol";
import {IDotnsController} from "./IDotnsController.sol";
import {IDotnsProtocolRegistryOld} from "../registry/IDotnsProtocolRegistryOld.sol";

import {IStoreFactoryOld} from "../store/IStoreFactoryOld.sol";
import {ILabelStore} from "../store/ILabelStore.sol";
import {StoreUtilsOld} from "../utils/StoreUtilsOld.sol";
import {LabelUtils} from "../utils/LabelUtils.sol";
import {StringUtils} from "../utils/StringUtils.sol";
import {IDotnsNameEscrow} from "../escrow/IDotnsNameEscrow.sol";
import {IPopRules} from "../pop/IPopRules.sol";
import {DotnsConstantsOld} from "../utils/DotnsConstantsOld.sol";

/// @title Dotns Registrar
/// @notice ERC721-backed registrar implementing permanent name ownership.
/// @dev Deliberately policy-free on pricing, reservations, and PoP gating; those live in the
/// controllers and @custom:contract IPopRules. The registrar owns transferability itself: publicly
/// registered names transfer freely, while names minted through the PoP gateway are soulbound and
/// revert on transfer. The `_update` hook enforces both the soulbound gate and the fee-on-transfer
/// settlement that consults the escrow.
/// @custom:security-contact admin@parity.io
contract DotnsRegistrarOld is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC721Upgradeable,
    IDotnsRegistrarOld
{
    using StoreUtilsOld for IStoreFactoryOld;
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
    IDotnsProtocolRegistryOld public protocolRegistry;

    /// @notice Marks a token as soulbound: minted through the PoP gateway and non-transferable.
    /// @dev Set at mint by @custom:function register when the caller is the address registered
    /// under `DotnsConstantsOld.POP_CONTROLLER`. Write-once and never cleared: a name's soulbound
    /// state is fixed at registration. Read by the `_update` transfer gate and by
    /// @custom:function quoteTransferFee.
    mapping(uint256 tokenId => bool soulbound) private _soulbound;

    /// @dev Reserved storage space to allow for layout changes in the future. `_soulbound` occupies
    /// one reserved slot, so the gap holds 49 slots and the contract keeps a fixed 51-slot
    /// footprint.
    uint256[49] private __gap;

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
        IDotnsProtocolRegistryOld registry
    )
        external
        initializer
    {
        require(address(registry) != address(0), ProtocolRegistryRequired());
        __Ownable_init(msg.sender);
        __ERC721_init(name, symbol);
        protocolRegistry = registry;
    }

    /// @inheritdoc IDotnsRegistrarOld
    function addController(IDotnsController controller) external onlyOwner {
        controllers[controller] = true;
        emit ControllerAdded(controller);
    }

    /// @inheritdoc IDotnsRegistrarOld
    function removeController(IDotnsController controller) external onlyOwner {
        controllers[controller] = false;
        emit ControllerRemoved(controller);
    }

    /// @inheritdoc IDotnsRegistrarOld
    function available(uint256 id) public view override returns (bool isAvailable) {
        address holder = _ownerOf(id);
        if (holder == address(0)) return true;

        address escrow = protocolRegistry.get(DotnsConstantsOld.NAME_ESCROW);
        if (holder != escrow) return false;

        // Escrow custody on its own does not mean registrable: a released name inside its redeem
        // window still belongs to its previous holder. The escrow owns that lifecycle and is asked
        // directly, so availability here and reclaimability there cannot drift apart and start
        // advertising names whose registration would revert.
        return IDotnsNameEscrow(payable(escrow)).isReclaimable(id);
    }

    /// @inheritdoc IDotnsRegistrarOld
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
        require(owner != protocolRegistry.get(DotnsConstantsOld.NAME_ESCROW), InvalidOwner());
        // Empty labels are an intentional gateway-cold path (substrate Root cannot deploy a
        // `LabelStore` under `pallet-revive`, so the controller stashes a pending claim and the
        // user settles via @custom:function IDotnsPopController.claimLabelStore later). Non-empty
        // labels must still be canonical so the transfer-floor lookup in `_quoteTransferFee`
        // cannot brick the token by reverting on a malformed stem.
        require(bytes(label).length == 0 || label.isSingleLabel(), InvalidLabel());
        _mint(owner, id);
        // Provenance is verified here rather than trusted from a caller-supplied flag: only the
        // canonical PoP controller mints soulbound names, so a compromised or buggy peer controller
        // cannot lock a public name and the PoP controller cannot mint an unlocked one. Written
        // only on the true branch to leave the public path free of a redundant zero write.
        bool soulbound = msg.sender == protocolRegistry.get(DotnsConstantsOld.POP_CONTROLLER);
        if (soulbound) _soulbound[id] = true;
        if (bytes(label).length != 0) _writeOwnerLabel(owner, id, label);
        emit NameRegistered(id, owner, soulbound);
    }

    /// @inheritdoc IDotnsRegistrarOld
    function labelOf(uint256 tokenId) external view override returns (string memory) {
        address holder = _ownerOf(tokenId);
        if (holder == address(0)) return "";
        return LabelUtils.stripTld(protocolRegistry.tld(), _readLabel(tokenId, holder));
    }

    /// @inheritdoc IDotnsRegistrarOld
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
        // A soulbound name cannot be transferred, so it has no transfer price. Revert rather than
        // return zero: a zero here would read as "transferable, no fee" to integrators while any
        // real transfer reverts in `_update`.
        require(!_soulbound[tokenId], NameSoulbound(tokenId));

        address from = ownerOf(tokenId);
        (,, requiredFee) = _quoteTransferFee(from, to, tokenId);
    }

    /// @inheritdoc IDotnsRegistrarOld
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    )
        public
        payable
        override(ERC721Upgradeable, IDotnsRegistrarOld)
    {
        super.transferFrom(from, to, tokenId);
    }

    /// @inheritdoc IDotnsRegistrarOld
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    )
        public
        payable
        override(ERC721Upgradeable, IDotnsRegistrarOld)
    {
        super.safeTransferFrom(from, to, tokenId, "");
    }

    /// @inheritdoc IDotnsRegistrarOld
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    )
        public
        payable
        override(ERC721Upgradeable, IDotnsRegistrarOld)
    {
        super.safeTransferFrom(from, to, tokenId, data);
    }

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.0.0";
    }

    /// @inheritdoc IDotnsRegistrarOld
    function exists(uint256 tokenId) external view override returns (bool tokenExists) {
        tokenExists = _exists(tokenId);
    }

    /// @inheritdoc IDotnsRegistrarOld
    function isSoulbound(uint256 tokenId) external view override returns (bool soulbound) {
        soulbound = _soulbound[tokenId];
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

        // Mints carry no economic event and must not be blocked: the soulbound flag is written
        // after `_mint`, so a mint reaches here before the flag exists. Reject any attached value
        // because nothing forwards it onward (no `receive`, no rescue path).
        if (from == address(0)) {
            require(msg.value == 0, UnexpectedValue());
            return from;
        }

        // Soulbound names are non-transferable, including a move to the sender's own address, which
        // keeps this in step with @custom:function quoteTransferFee and the interface contract. It
        // reverts rather than returning, unwinding the ownership move `super._update` has already
        // made, and sits before any escrow or store lookup so a soulbound token is rejected even
        // when the escrow is unconfigured, blocking every custody move including release into
        // escrow.
        require(!_soulbound[tokenId], NameSoulbound(tokenId));

        // Self-transfers of a transferable name carry no economic event. Reject attached value for
        // the same trapped-funds reason as the mint path above.
        if (from == to) {
            require(msg.value == 0, UnexpectedValue());
            return from;
        }

        // Resolve every registry-sourced dependency once and thread it into the helpers so a
        // single transfer pays one external lookup per key rather than three.
        IDotnsProtocolRegistryOld registry = protocolRegistry;
        address escrow = registry.get(DotnsConstantsOld.NAME_ESCROW);
        require(escrow != address(0), EscrowNotConfigured());
        IStoreFactoryOld factory = IStoreFactoryOld(registry.get(DotnsConstantsOld.STORE_FACTORY));

        bool isEscrowTouching = to == escrow || from == escrow;
        // Skip mirroring on escrow-touching paths: release deposits the NFT into custody where
        // a `LabelStore` would be wasted and reclaim hands it back to a fresh-mint controller
        // that writes the label through its own flow.
        if (!isEscrowTouching) {
            _syncRecipientStore(factory, to, from, tokenId);
        }

        (uint256 transferFee, uint256 requiredFee) =
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
                tokenId: tokenId, transferFee: transferFee, payer: msg.sender, to: to
            })
        );

        return from;
    }

    /// @notice Mirrors the sender's label entry into the recipient's `LabelStore`.
    function _syncRecipientStore(
        IStoreFactoryOld factory,
        address to,
        address from,
        uint256 tokenId
    )
        internal
    {
        string memory fullName = _readLabelFor(factory, tokenId, from);
        if (bytes(fullName).length == 0) {
            // Defensive: the sender holds no label entry for the token. Gateway mints reach this
            // only at mint time, and a gateway name is soulbound so it never transfers; a public
            // name always carries a label. Nothing to mirror, so do not deploy a recipient store;
            // downstream writes are demand-deploy through `StoreUtilsOld.ensureLabelStore`.
            return;
        }
        factory.writeLabel(to, bytes32(tokenId), fullName);
    }

    /// @notice Reads the full name (`label.tld`) for `tokenId` from `holder`'s `LabelStore` using
    /// a caller-supplied factory.
    function _readLabelFor(
        IStoreFactoryOld factory,
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
        escrow = protocolRegistry.get(DotnsConstantsOld.NAME_ESCROW);
    }

    /// @notice Resolves the configured PoP rules contract from the protocol registry.
    function _popRules() private view returns (IPopRules rules) {
        rules = IPopRules(protocolRegistry.get(DotnsConstantsOld.POP_RULES));
    }

    /// @notice Resolves the configured store factory from the protocol registry.
    function _storeFactory() private view returns (IStoreFactoryOld factory) {
        factory = IStoreFactoryOld(protocolRegistry.get(DotnsConstantsOld.STORE_FACTORY));
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
    /// @dev Required fee is the name's own price returned by @custom:function
    /// PopRulesOld.transferFloor. It is paid by the sender on every downward or cross-reach transfer
    /// and settles to the
    /// protocol fee pot. Any prior deposit travels with the NFT: the escrow rebinds the position to
    /// the new holder rather than refunding the sender, so transferring a funded name forfeits the
    /// locked deposit to the recipient. Self-transfers and escrow-touching transfers return zero.
    function _quoteTransferFee(
        address from,
        address to,
        uint256 tokenId
    )
        private
        view
        returns (address escrow, uint256 transferFee, uint256 requiredFee)
    {
        if (from == to) return (address(0), 0, 0);

        IDotnsProtocolRegistryOld registry = protocolRegistry;
        escrow = registry.get(DotnsConstantsOld.NAME_ESCROW);
        require(escrow != address(0), EscrowNotConfigured());

        bool isEscrowTouching = to == escrow || from == escrow;
        IStoreFactoryOld factory = IStoreFactoryOld(registry.get(DotnsConstantsOld.STORE_FACTORY));
        (transferFee, requiredFee) =
            _quoteTransferFeeFor(registry, factory, isEscrowTouching, from, to, tokenId);
    }

    /// @notice Quotes the transfer floor reusing a caller-cached registry and store factory.
    /// @dev Hot-path variant used by @custom:function _update. Returns `(0, 0)` for any
    /// escrow-touching move or when the sender holds no label entry; otherwise reads the canonical
    /// label and delegates to @custom:function PopRulesOld.transferFloor.
    function _quoteTransferFeeFor(
        IDotnsProtocolRegistryOld registry,
        IStoreFactoryOld factory,
        bool isEscrowTouching,
        address from,
        address to,
        uint256 tokenId
    )
        private
        view
        returns (uint256 transferFee, uint256 requiredFee)
    {
        if (isEscrowTouching) return (0, 0);

        string memory fullName = _readLabelFor(factory, tokenId, from);
        // No label means there is no label-derived price to charge against; treat as a zero-fee
        // move. This is defensive: a gateway name is soulbound and reverts before reaching here,
        // and a public name always carries a label, so no reachable transfer hits this branch.
        if (bytes(fullName).length == 0) return (0, 0);
        // A stored full name always carries the registry TLD suffix, so an empty strip means the
        // name is malformed for this registry (a wrong or missing suffix); fail loudly rather than
        // mis-pricing the move as zero-fee.
        string memory label = LabelUtils.stripTld(registry.tld(), fullName);
        require(bytes(label).length != 0, InvalidLabel());

        transferFee =
            IPopRules(registry.get(DotnsConstantsOld.POP_RULES)).transferFloor(label, from, to);
        requiredFee = transferFee;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
