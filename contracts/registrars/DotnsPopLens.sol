// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IDotnsPopLens} from "./IDotnsPopLens.sol";
import {IDotnsPopController} from "./IDotnsPopController.sol";
import {IDotnsRegistrar} from "./IDotnsRegistrar.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {IDotnsRegistry} from "../registry/IDotnsRegistry.sol";
import {IDotnsPopResolver} from "../resolvers/IDotnsPopResolver.sol";
import {IPopRules} from "../pop/IPopRules.sol";
import {IStoreFactory} from "../store/IStoreFactory.sol";
import {ILabelStore} from "../store/ILabelStore.sol";
import {LabelUtils} from "../utils/LabelUtils.sol";
import {SubnodeUtils} from "../utils/SubnodeUtils.sol";
import {StringUtils} from "../utils/StringUtils.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";

/// @title DotnsPopLens
/// @notice Read-only view over PoP identity data.
/// @dev Stateless beyond the protocol registry it holds, and never mints or settles. It composes
/// each field from the contract that owns it: names from the owner's `LabelStore` and the
/// controller's pending queue, ownership from the registry, chat keys and links from the PoP
/// resolver, and label classification from PopRules. The registry is the single ownership
/// authority: it delegates a tokenised name to the registrar and owns a subname directly, so a
/// lite username, which is a subname, resolves the same way as a full-person name. Living outside
/// the controller keeps the controller within the contract-size limit. Deployed as a plain
/// contract through the CREATE3 factory, so its address is deterministic and it can be redeployed
/// on a read change without touching stored state.
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
        NameDetail memory detail = _detail(_nodeOf(name));
        // The caller holds the label, so supply it when the name exists but the node alone could
        // not recover it (a subname). An unknown name keeps its empty label.
        if (detail.exists && bytes(detail.label).length == 0) detail.label = name;
        // Holding the label means holding its labelhash, so the lite-to-full link resolves here.
        detail.fullClaim = _popResolver().fullClaim(LabelUtils.labelhash(name));
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
    /// @dev Two questions and one guard the caller already applied. Whether a name is an identity
    /// at all is provenance, so each listing is gated on
    /// @custom:function IDotnsPopController.isPopIssued: characters alone would admit a public
    /// registration spelled `joseph42`, which reads as a full-person name and is not one. Which
    /// kind of identity it is, lite or full, is spelling: a lite name carries its separator and a
    /// full-person name does not, and provenance covers both. A lite name is a subname and a
    /// full-person name is a tokenised second-level name, and the callers resolve ownership through
    /// the registry, which covers both, so both listings reach their names. Provenance is keyed by
    /// text, so a subname a `user` created under a name they own does not enter a listing unless
    /// the controller issued it. The two listings together cover the names the gateway issued and
    /// `user` holds, one kind each, rather than everything the account holds.
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
        string memory tld = _protocolRegistry.tld();
        address store = _storeFactory().getLabelStore(user);

        if (store != address(0)) {
            ILabelStore labelStore = ILabelStore(store);
            uint256 stored = labelStore.getLabelCount();
            for (uint256 i; i < stored; ++i) {
                bytes32 node = labelStore.getLabelhashAt(i);
                if (!_ownedBy(node, user)) continue;
                if (_belongsToListing(LabelUtils.stripTld(tld, labelStore.getLabelAt(i)), wantLite))
                {
                    ++count;
                }
            }
        }

        IDotnsPopController.PendingClaim[] memory queue = _pendingClaims(user);
        uint256 pending = queue.length;
        for (uint256 j; j < pending; ++j) {
            string memory label = queue[j].label;
            if (!_belongsToListing(label, wantLite)) continue;
            bytes32 node = _nodeOf(label);
            if (store != address(0) && ILabelStore(store).isLocked(node)) continue;
            if (_ownedBy(node, user)) ++count;
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

        string memory tld = _protocolRegistry.tld();
        address store = _storeFactory().getLabelStore(user);

        uint256 filled;
        uint256 seen;

        if (store != address(0)) {
            ILabelStore labelStore = ILabelStore(store);
            uint256 stored = labelStore.getLabelCount();
            for (uint256 i; i < stored && filled < limit; ++i) {
                bytes32 node = labelStore.getLabelhashAt(i);
                if (!_ownedBy(node, user)) continue;
                string memory label = LabelUtils.stripTld(tld, labelStore.getLabelAt(i));
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
            bytes32 node = _nodeOf(label);
            if (store != address(0) && ILabelStore(store).isLocked(node)) continue;
            if (!_ownedBy(node, user)) continue;
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

    /// @notice Whether `node` is a name currently owned by `user`.
    /// @dev Reads the registry, which is the single ownership authority for both a tokenised name
    /// (it delegates to the registrar) and a subname (an explicit record owner). A node with no
    /// record returns the zero address, so a missing name yields false and the read stays total.
    function _ownedBy(bytes32 node, address user) internal view returns (bool) {
        return _registry().owner(node) == user;
    }

    /// @notice Gathers a name's record from the registrar, PoP resolver, and PopRules.
    /// @dev Reads defensively so an unminted or unsettled name yields zeroed fields instead of
    /// reverting. `fullClaim` is left for the caller because it needs the labelhash, which is
    /// recoverable from the label string but not from the node alone. `tier` classifies the
    /// label shape and is skipped for an empty label.
    function _detail(bytes32 node) internal view returns (NameDetail memory detail) {
        detail.node = node;
        address owner = _registry().owner(node);
        if (owner != address(0)) {
            detail.exists = true;
            detail.owner = owner;
            address store = _storeFactory().getLabelStore(owner);
            bool settled = store != address(0) && ILabelStore(store).isLocked(node);
            detail.settled = settled;
            // A tokenised name carries its label on the registrar; a subname does not, so its
            // label is read back from the owner's store once settled. A pending subname has no
            // recoverable label from the node alone.
            if (_registrar().exists(uint256(node))) {
                detail.label = _registrar().labelOf(uint256(node));
            } else if (settled) {
                detail.label =
                    LabelUtils.stripTld(_protocolRegistry.tld(), ILabelStore(store).getLabel(node));
            }
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

    /// @notice Resolves the registry via the protocol registry.
    function _registry() internal view returns (IDotnsRegistry) {
        return IDotnsRegistry(_protocolRegistry.get(DotnsConstants.REGISTRY));
    }

    /// @notice Derives the node a name resolves to, whether tokenised or a lite subname.
    /// @dev A lite name is `stem` beneath its numeric container, so it hashes as a subnode; any
    /// other name hashes as a second-level label under the TLD.
    /// @param label Bare label without the TLD, e.g. `alice` or `alice.01`.
    /// @return node The node the name resolves to.
    function _nodeOf(string memory label) internal view returns (bytes32 node) {
        bytes32 tldNode = _protocolRegistry.tldNode();
        if (label.isLitePersonLabelMemory()) {
            (string memory stem, string memory suffix) = label.splitLiteLabel();
            return SubnodeUtils.subnodeOf(tldNode, suffix, stem);
        }
        node = LabelUtils.namehashUnder(tldNode, LabelUtils.labelhashMemory(label));
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
