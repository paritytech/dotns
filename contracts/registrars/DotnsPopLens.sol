// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IDotnsPopLens} from "./IDotnsPopLens.sol";
import {IDotnsPopController} from "./IDotnsPopController.sol";
import {IDotnsRegistrar} from "./IDotnsRegistrar.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {IDotnsPopResolver} from "../resolvers/IDotnsPopResolver.sol";
import {IPopRules} from "../pop/IPopRules.sol";
import {IStoreFactory} from "../store/IStoreFactory.sol";
import {ILabelStore} from "../store/ILabelStore.sol";
import {LabelUtils} from "../utils/LabelUtils.sol";
import {StringUtils} from "../utils/StringUtils.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";

/// @title DotnsPopLens
/// @notice Read-only view over PoP identity data.
/// @dev Stateless beyond the protocol registry it holds, and never mints or settles. It composes
/// each field from the contract that owns it: names from the owner's `LabelStore` and the
/// controller's pending queue, ownership from the registrar, chat keys and links from the PoP
/// resolver, and label classification from PopRules. Living outside the controller keeps the
/// controller within the contract-size limit and keeps the registrar the single source of
/// ownership truth. Deployed as a plain contract through the CREATE3 factory, so its address is
/// deterministic and it can be redeployed on a read change without touching stored state.
/// @custom:security-contact admin@parity.io
contract DotnsPopLens is IDotnsPopLens {
    using StringUtils for *;

    /// @notice Protocol-level address registry used to resolve every sibling contract.
    IDotnsProtocolRegistry internal immutable _protocolRegistry;

    /// @notice Binds the lens to the protocol registry it reads through.
    /// @param registry Protocol registry resolving the controller, registrar, store factory,
    /// PoP resolver, and PopRules.
    constructor(IDotnsProtocolRegistry registry) {
        _protocolRegistry = registry;
    }

    /// @inheritdoc IDotnsPopLens
    function protocolRegistry() external view override returns (address registry) {
        return address(_protocolRegistry);
    }

    /// @inheritdoc IDotnsPopLens
    function liteNamesOf(
        address user,
        uint256 offset,
        uint256 limit
    )
        external
        view
        override
        returns (Name[] memory names)
    {
        return _pageNames(user, offset, limit, true);
    }

    /// @inheritdoc IDotnsPopLens
    function fullNamesOf(
        address user,
        uint256 offset,
        uint256 limit
    )
        external
        view
        override
        returns (Name[] memory names)
    {
        return _pageNames(user, offset, limit, false);
    }

    /// @inheritdoc IDotnsPopLens
    function liteNameCountOf(address user) external view override returns (uint256 count) {
        return _countNames(user, true);
    }

    /// @inheritdoc IDotnsPopLens
    function fullNameCountOf(address user) external view override returns (uint256 count) {
        return _countNames(user, false);
    }

    /// @inheritdoc IDotnsPopLens
    function nameDetail(string calldata name) external view override returns (NameDetail memory) {
        (bytes32 labelhash, bytes32 node) = LabelUtils.deriveNode(_protocolRegistry.tldNode(), name);
        NameDetail memory detail = _detail(node);
        // Holding the label means holding its labelhash, so the lite-to-full link resolves here.
        detail.fullClaim = _popResolver().fullClaim(labelhash);
        return detail;
    }

    /// @inheritdoc IDotnsPopLens
    function nameDetailByNode(bytes32 node) external view override returns (NameDetail memory) {
        NameDetail memory detail = _detail(node);
        // The node cannot be inverted to a labelhash, so `fullClaim` resolves only when the label
        // is independently recoverable (a settled name whose label the registrar returns).
        if (bytes(detail.label).length != 0) {
            detail.fullClaim = _popResolver().fullClaim(LabelUtils.labelhashMemory(detail.label));
        }
        return detail;
    }

    /// @inheritdoc IDotnsPopLens
    function profileOf(address user) external view override returns (PopProfile memory profile) {
        IDotnsPopController controller = _controller();
        profile.hasLabelStore = _storeFactory().getLabelStore(user) != address(0);
        profile.pendingClaimCount = controller.pendingClaimCountOf(user);
        profile.reservationLabelhash = controller.userReservation(user).labelhash;
    }

    /// @notice Whether `label` belongs in the lite listing (`wantLite`) or the full listing.
    /// @dev Two questions, two signals, and a third guard the caller already applied. Whether a
    /// name is an identity at all is provenance, so each listing is gated on
    /// @custom:function IDotnsPopController.isPopIssued: characters alone would admit a public
    /// registration spelled `joseph42`, which reads as a full-person name and is not one. Which
    /// kind of identity it is, lite or full, is spelling: the gateway issues a lite name with
    /// its separator and a full-person name without one, and provenance cannot tell them apart
    /// because it covers both. A subname is excluded before either signal is read: the callers
    /// keep only nodes the registrar says `user` owns, and a subname lives in the registry with
    /// no token behind it. That matters because provenance is keyed by text, so a subname
    /// rendering as `joseph.42` would otherwise borrow the answer belonging to the whole label.
    /// So the two listings together cover the names the gateway issued and `user` holds, one
    /// kind each, rather than everything the account holds.
    function _belongsToListing(string memory label, bool wantLite) internal view returns (bool) {
        if (!_controller().isPopIssued(label)) return false;
        return wantLite ? label.isLitePersonLabelMemory() : label.isSingleLabelMemory();
    }

    /// @notice Counts the names currently owned by `user` that belong to the requested listing.
    /// @dev Walks the user's `LabelStore` (settled names) then their pending claims, keeping only
    /// entries that belong to the listing and are still owned by `user` on the registrar. A pending
    /// entry already written into the store by a sibling flow is skipped so it is not counted
    /// twice.
    function _countNames(address user, bool wantLite) internal view returns (uint256 count) {
        IDotnsRegistrar registrar = _registrar();
        bytes32 tldNode = _protocolRegistry.tldNode();
        address store = _storeFactory().getLabelStore(user);

        if (store != address(0)) {
            ILabelStore labelStore = ILabelStore(store);
            uint256 stored = labelStore.getLabelCount();
            for (uint256 i; i < stored; ++i) {
                bytes32 node = labelStore.getLabelhashAt(i);
                if (!_ownedBy(registrar, node, user)) continue;
                if (_belongsToListing(registrar.labelOf(uint256(node)), wantLite)) ++count;
            }
        }

        IDotnsPopController.PendingClaim[] memory queue = _pendingClaims(user);
        uint256 pending = queue.length;
        for (uint256 j; j < pending; ++j) {
            string memory label = queue[j].label;
            if (!_belongsToListing(label, wantLite)) continue;
            bytes32 node = LabelUtils.namehashUnder(tldNode, LabelUtils.labelhashMemory(label));
            if (store != address(0) && ILabelStore(store).isLocked(node)) continue;
            if (_ownedBy(registrar, node, user)) ++count;
        }
    }

    /// @notice Returns a page of `user`'s owned names belonging to the requested listing.
    /// @dev Same ownership-verified walk as @custom:function _countNames, in the same order
    /// (store then pending), skipping the first `offset` matches and returning up to `limit`
    /// entries. `limit` is clamped to `DotnsConstants.MAX_PAGE_SIZE` to bound the memory and the
    /// scan.
    function _pageNames(
        address user,
        uint256 offset,
        uint256 limit,
        bool wantLite
    )
        internal
        view
        returns (Name[] memory names)
    {
        if (limit > DotnsConstants.MAX_PAGE_SIZE) limit = DotnsConstants.MAX_PAGE_SIZE;
        Name[] memory page = new Name[](limit);
        if (limit == 0) return page;

        IDotnsRegistrar registrar = _registrar();
        bytes32 tldNode = _protocolRegistry.tldNode();
        address store = _storeFactory().getLabelStore(user);

        uint256 filled;
        uint256 seen;

        if (store != address(0)) {
            ILabelStore labelStore = ILabelStore(store);
            uint256 stored = labelStore.getLabelCount();
            for (uint256 i; i < stored && filled < limit; ++i) {
                bytes32 node = labelStore.getLabelhashAt(i);
                if (!_ownedBy(registrar, node, user)) continue;
                string memory label = registrar.labelOf(uint256(node));
                if (!_belongsToListing(label, wantLite)) continue;
                if (seen++ < offset) continue;
                page[filled++] = Name({node: node, label: label, settled: true, deadline: 0});
            }
        }

        IDotnsPopController.PendingClaim[] memory queue = _pendingClaims(user);
        uint256 pending = queue.length;
        uint64 duration = _controller().reservationDuration();
        for (uint256 j; j < pending && filled < limit; ++j) {
            string memory label = queue[j].label;
            if (!_belongsToListing(label, wantLite)) continue;
            bytes32 node = LabelUtils.namehashUnder(tldNode, LabelUtils.labelhashMemory(label));
            if (store != address(0) && ILabelStore(store).isLocked(node)) continue;
            if (!_ownedBy(registrar, node, user)) continue;
            if (seen++ < offset) continue;
            page[filled++] = Name({
                node: node, label: label, settled: false, deadline: queue[j].mintedAt + duration
            });
        }

        if (filled == limit) return page;
        names = new Name[](filled);
        for (uint256 k; k < filled; ++k) {
            names[k] = page[k];
        }
    }

    /// @notice Whether `node` is a minted name currently owned by `user`.
    /// @dev Guards the `ownerOf` call with `exists` so a missing token returns false rather than
    /// reverting, keeping the listing reads total.
    function _ownedBy(
        IDotnsRegistrar registrar,
        bytes32 node,
        address user
    )
        internal
        view
        returns (bool)
    {
        return registrar.exists(uint256(node)) && registrar.ownerOf(uint256(node)) == user;
    }

    /// @notice Gathers a name's record from the registrar, PoP resolver, and PopRules.
    /// @dev Reads defensively so an unminted or unsettled name yields zeroed fields instead of
    /// reverting. `fullClaim` is left for the caller because it needs the labelhash, which is
    /// recoverable from the label string but not from the node alone. `tier` classifies the
    /// label shape and is skipped for an empty label.
    function _detail(bytes32 node) internal view returns (NameDetail memory detail) {
        detail.node = node;
        IDotnsRegistrar registrar = _registrar();
        if (registrar.exists(uint256(node))) {
            address owner = registrar.ownerOf(uint256(node));
            detail.exists = true;
            detail.owner = owner;
            detail.label = registrar.labelOf(uint256(node));
            address store = _storeFactory().getLabelStore(owner);
            detail.settled = store != address(0) && ILabelStore(store).isLocked(node);
        }
        if (bytes(detail.label).length != 0) {
            // Every mint path validates the label, so a stored label always classifies; the try
            // keeps this read total even if a future path ever stores a non-canonical label.
            try _popRules().classifyName(detail.label) returns (
                IPopRules.PopStatus tier, string memory
            ) {
                detail.tier = tier;
            } catch {}
        }
        IDotnsPopResolver resolver = _popResolver();
        detail.chatKey = resolver.chatKey(node);
        detail.liteLink = resolver.liteLink(node);
    }

    /// @notice Reads a bounded page of `user`'s pending claims from the controller.
    /// @dev The listings scan this page in memory; it holds up to `DotnsConstants.MAX_PAGE_SIZE`
    /// staged claims, which the reads document as their pending-portion bound.
    function _pendingClaims(address user)
        internal
        view
        returns (IDotnsPopController.PendingClaim[] memory claims)
    {
        return _controller().pendingClaims(user, 0, DotnsConstants.MAX_PAGE_SIZE);
    }

    /// @notice Resolves the PoP controller via the protocol registry.
    function _controller() internal view returns (IDotnsPopController) {
        return IDotnsPopController(_protocolRegistry.get(DotnsConstants.POP_CONTROLLER));
    }

    /// @notice Resolves the registrar via the protocol registry.
    function _registrar() internal view returns (IDotnsRegistrar) {
        return IDotnsRegistrar(_protocolRegistry.get(DotnsConstants.REGISTRAR));
    }

    /// @notice Resolves the store factory via the protocol registry.
    function _storeFactory() internal view returns (IStoreFactory) {
        return IStoreFactory(_protocolRegistry.get(DotnsConstants.STORE_FACTORY));
    }

    /// @notice Resolves the PoP resolver via the protocol registry.
    function _popResolver() internal view returns (IDotnsPopResolver) {
        return IDotnsPopResolver(_protocolRegistry.get(DotnsConstants.POP_RESOLVER));
    }

    /// @notice Resolves the PopRules contract via the protocol registry.
    function _popRules() internal view returns (IPopRules) {
        return IPopRules(_protocolRegistry.get(DotnsConstants.POP_RULES));
    }
}
