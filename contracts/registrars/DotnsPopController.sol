// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ERC165Upgradeable
} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IDotnsPopController} from "./IDotnsPopController.sol";
import {IDotnsRegistrar} from "./IDotnsRegistrar.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {IDotnsPopResolver} from "../resolvers/IDotnsPopResolver.sol";
import {IPopRules} from "../pop/IPopRules.sol";
import {IStoreFactory} from "../store/IStoreFactory.sol";
import {ILabelStore} from "../store/ILabelStore.sol";
import {LabelUtils} from "../utils/LabelUtils.sol";
import {RegistrationUtils} from "../utils/RegistrationUtils.sol";
import {StringUtils} from "../utils/StringUtils.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";
import {SystemUtils} from "../utils/SystemUtils.sol";

/// @title DotnsPopController
/// @notice Dedicated PoP controller orchestrating lite-person and full-person username
/// issuance on behalf of the PoP gateway pallet.
/// @dev Lives behind its own UUPS proxy with its own storage. Registered on `DotnsRegistrar`
/// via `addController`, which is how multiple controllers coexist on the same registrar
/// without interfering with each other.
///
/// Enforcement:
/// Personhood is attested off-chain by the gateway pallet before the call reaches this
/// contract, so the on-chain personhood precompile is not re-queried on the gateway path.
/// Every base-label mint path still calls @custom:function IPopRules.classifyName to reject
/// governance-reserved labels (@custom:reverts InvalidBaseLabel on the base path,
/// @custom:reverts InvalidLiteLabel on the lite path). The lite leg accepts any two-digit lite
/// label whose stem is not governance-reserved, regardless of stem length. Native-token pricing
/// is bypassed entirely; the gateway pays no rent.
///
/// Decoupling:
/// This contract does not import or call `IDotnsRegistrarController`. The public
/// commit-reveal controller is equally unaware of this one. Cross-flow collision handling
/// relies on two distinct properties, neither of which requires the two controllers to know
/// about each other:
/// (1) Lite-person labels (`stem.NN`) occupy a namespace the public path cannot reach: the
/// separator is legal only on a lite label, and the public path rejects it, so no public
/// registration can spell one. A digit suffix is not exclusive, but an ordinary label carrying
/// one is measured as written and so is simply a different name. The two flows therefore cannot
/// contend for the same label. This holds of labels the contracts minted, not of an arbitrary
/// string: a subname stored under a digit-only parent reads the same way, which is why
/// provenance is published through @custom:function isPopIssued rather than inferred.
/// (2) Base-name reservations are synchronised into `IPopRules`. The head of this
/// controller's reservation queue is written through `IPopRules.reserveBaseNameForPop` on
/// every head transition; the slot is cleared through `IPopRules.releaseBaseName` when the
/// queue empties (claim, final relinquish, final expiry). The public commit-reveal
/// controller routes through `IPopRules.priceWithCheck`, which rejects any registration
/// targeting a base-name stem reserved for another user, so the public flow respects
/// gateway reservations without ever importing this contract. PopRules is the single
/// cross-flow authority; the queue here is the intra-PoP ordering layer on top of it.
///
/// Shared primitives: labelhash / namehash via @custom:contract LabelUtils; the mint +
/// forward-registry + store-write triad via @custom:contract RegistrationUtils; chat-key and
/// lite-to-full link persistence via
/// @custom:contract IDotnsPopResolver. Keeping per-name records on the resolver preserves the
/// "Store = labels only" invariant.
/// @custom:security-contact admin@parity.io
contract DotnsPopController is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IDotnsPopController
{
    using StringUtils for *;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Upper bound for the number of simultaneously queued reservations per label.
    /// @dev Keeps `expireReservation` gas bounded.
    uint16 public constant MAX_RESERVATION_QUEUE = 64;

    /// @notice Minimum value accepted by @custom:function setReservationDuration.
    /// @dev Prevents owner misconfiguration from instantly expiring every live queue and
    /// pending-claim entry. The actual production duration is governance-tuned higher.
    uint64 public constant MIN_RESERVATION_DURATION = 1 hours;

    /// @notice Required byte length for a non-empty chat key.
    /// @dev Mirrors @custom:contract IDotnsPopResolver `InvalidChatKeyLength` so the controller
    /// can fail closed before the mint instead of bubbling the resolver's revert after partial
    /// state has been committed.
    uint256 private constant CHAT_KEY_LENGTH = 65;

    /// @notice Protocol-level address registry for all DotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @notice Per-label queue metadata (head/tail pointers).
    mapping(bytes32 labelhash => ReservationQueueMeta meta) internal _reservationMeta;

    /// @notice Per-label sparse entries keyed by monotonically-increasing index.
    mapping(bytes32 labelhash => mapping(uint64 index => ReservationEntry entry)) internal
        _reservationEntries;

    /// @notice Single per-user pointer into the reservation queues.
    /// @dev Keeps per-user reservation data behind one key and one struct value so callers
    /// read both fields in one call instead of two.
    mapping(address user => UserReservation reservation) internal _userReservations;

    /// @notice Remembers the base-label string for each reserved labelhash so the PopRules
    /// sync path can address the reservation by its original string form (PopRules keys its
    /// `reservations` mapping by string).
    /// @dev Populated on first enqueue for a label, cleared when the queue empties. Exists
    /// only to bridge the queue's `bytes32` key space to PopRules' `string` key space;
    /// nothing else reads it.
    mapping(bytes32 labelhash => string baseLabel) internal _reservedBaseLabel;

    /// @notice Duration (in seconds) after which a reservation entry is considered expired.
    /// @dev Mirrors `pallet_resources::UsernameReservationDuration`. Configurable by
    /// governance via `setReservationDuration`.
    uint64 public override reservationDuration;

    /// @notice Enumeration set of users holding at least one pending claim.
    /// @dev Membership equals the set of users with a non-empty queue. Used by
    /// `pendingClaimUserCount` and `pendingClaimUsers` for paginated enumeration.
    EnumerableSet.AddressSet private _pendingClaimUsers;

    /// @notice Per-user pile of deferred names awaiting a `LabelStore`.
    /// @dev The Root gateway origin cannot deploy a `LabelStore` (contract creation is forbidden
    /// from Root), so deferred names accumulate here until a signed-origin
    /// @custom:function settlePendingClaims deploys the store and writes the stashed labels. Each
    /// entry's deadline is measured from its own `mintedAt` against `reservationDuration`.
    mapping(address user => PendingClaim[] queue) internal _pendingClaimQueue;

    /// @notice Labels this controller minted, keyed by the bare label without the TLD.
    /// @dev Provenance, not a transfer rule: written once at mint and never cleared, so it
    ///      stays true if a name later becomes transferable. Keyed by the label text rather
    ///      than the node because a reader holding only `joseph.42` cannot derive the node
    ///      without first deciding whether the separator is part of the label or a subname
    ///      boundary, which is the question it is asking.
    mapping(string label => bool issued) internal _popIssued;

    /// @dev Reserved storage space to allow for layout changes in future upgrades.
    uint256[50] private __gap;

    /// @notice Restricts calls to a substrate Root origin.
    modifier onlyRoot() {
        _onlyRoot();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the PoP controller.
    /// @dev Called once through the UUPS proxy; `_disableInitializers` on the implementation
    /// makes direct calls revert with @custom:reverts InvalidInitialization, and any nested
    /// call outside an active initialiser scope reverts with @custom:reverts NotInitializing.
    /// Emits @custom:emits ReservationDurationSet so indexers observe the initial value
    /// through the same event the setter uses later.
    function initialize(
        IDotnsProtocolRegistry registry,
        uint64 reservationDuration_
    )
        external
        initializer
    {
        require(
            reservationDuration_ >= MIN_RESERVATION_DURATION,
            ReservationDurationTooLow(reservationDuration_)
        );
        __Ownable_init(msg.sender);
        __ERC165_init();
        protocolRegistry = registry;
        reservationDuration = reservationDuration_;
        emit ReservationDurationSet(reservationDuration_);
    }

    /// @inheritdoc IDotnsPopController
    function isPopIssued(string calldata label) external view override returns (bool issued) {
        return _popIssued[label];
    }

    /// @inheritdoc IDotnsPopController
    function reserveLiteName(LiteRegistration calldata params) external override onlyRoot {
        _reserveLite(_popRules(), params);
    }

    /// @inheritdoc IDotnsPopController
    function reserveBaseName(BaseReservation calldata params) external override onlyRoot {
        IPopRules rules = _popRules();
        bytes32 reservedHash;
        bool hasReservation = bytes(params.reservedBaseLabel).length != 0;
        if (hasReservation) {
            (reservedHash,) = _validateReservableBaseLabel(rules, params.reservedBaseLabel);
        }

        _reserveLite(rules, params.lite);

        if (hasReservation) {
            _advanceExpiredHead(reservedHash);
            _removeUserFromQueue(params.lite.user);
            _enqueueReservation(rules, reservedHash, params.reservedBaseLabel, params.lite.user);
        }
    }

    /// @inheritdoc IDotnsPopController
    function reserveBaseNameOnly(BaseNameReservation calldata params) external override onlyRoot {
        IPopRules rules = _popRules();
        (bytes32 reservedHash,) = _validateReservableBaseLabel(rules, params.reservedBaseLabel);
        _advanceExpiredHead(reservedHash);
        _removeUserFromQueue(params.user);
        _enqueueReservation(rules, reservedHash, params.reservedBaseLabel, params.user);
    }

    /// @notice Lite-only mint shared by @custom:function reserveLiteName and the lite leg
    /// of @custom:function reserveBaseName.
    /// @dev Gateway attestation is the authority for personhood on this path; the on-chain
    /// precompile is not consulted. The label is stored in the `stem.NN` form the gateway sends,
    /// which is the form People Chain holds, so no normalisation happens here. The shape check
    /// runs before classification so a malformed label reverts
    /// @custom:reverts InvalidLiteLabel, which the gateway pallet decodes by selector; letting
    /// `classifyName` catch it instead would surface an undecodable PopRules string.
    /// Takes the @custom:struct LiteRegistration struct directly so both call sites pass the same
    /// payload shape: the typed entrypoint forwards its own `params`, the `reserveBaseName`
    /// entrypoint forwards `params.lite`.
    function _reserveLite(IPopRules rules, LiteRegistration calldata params) internal {
        require(params.liteLabel.isLitePersonLabel(), InvalidLiteLabel());
        _requireValidChatKey(params.chatKey);

        (IPopRules.PopStatus required,) = rules.classifyName(params.liteLabel);
        // The shape check fixes the suffix, so classification lands on PopLite (stem 6-8),
        // NoStatus (stem 9 or more), or Reserved (stem 5 or fewer). Accept the first two; a
        // stem short enough to be governance-reserved is not issued from this path.
        require(required != IPopRules.PopStatus.Reserved, InvalidLiteLabel());
        (bytes32 labelhash, bytes32 node) = _validateLiteLabel(params.liteLabel);

        _completeGatewayRegistration(
            params.user, params.liteLabel, labelhash, node, params.chatKey, bytes32(0)
        );

        emit LiteNameReserved(labelhash, params.user, params.liteLabel);
    }

    /// @inheritdoc IDotnsPopController
    function registerBaseName(FullRegistration calldata params) external override onlyRoot {
        Link calldata link = params.link;
        address user = params.user;
        string calldata label = params.label;

        (bytes32 labelhash, bytes32 node) = _validateBaseLabel(label);

        IPopRules rules = _popRules();
        (IPopRules.PopStatus required,) = rules.classifyName(label);
        require(
            required != IPopRules.PopStatus.Reserved && required != IPopRules.PopStatus.PopLite,
            InvalidBaseLabel()
        );

        _advanceExpiredHead(labelhash);

        // Cross-flow guard: after the local queue has had a chance to release its own
        // PopRules slot via head-advance, any remaining live slot was written by a sibling
        // controller. Reject when held by another user so PopRules stays the single
        // cross-flow authority in both directions; the public flow reads this slot through
        // `priceWithCheck` and writes none of its own.
        (bool slotLive, address slotOwner,) = rules.isBaseNameReserved(label);
        require(!slotLive || slotOwner == user, NotHolder(user, labelhash));

        ReservationQueueMeta memory meta = _reservationMeta[labelhash];
        ReservationEntry memory headEntry = meta.head < meta.tail
            ? _reservationEntries[labelhash][meta.head]
            : ReservationEntry({owner: address(0), joinedAt: 0});
        bool isClaim = _userReservations[user].labelhash == labelhash && meta.head < meta.tail
            && headEntry.owner == user;

        if (!isClaim && meta.head < meta.tail) {
            if (
                headEntry.owner != address(0) && headEntry.owner != user
                    && !_isExpired(headEntry.joinedAt)
            ) {
                revert NotHolder(user, labelhash);
            }
        }

        if (isClaim) {
            _clearQueue(labelhash);
        } else {
            _removeUserFromQueue(user);
        }

        bytes32 liteLabelhash;
        bytes32 liteNode;
        bytes memory chatKeyToPersist;
        if (link.kind == LinkKind.LiteUsername) {
            require(link.liteLabel.isLitePersonLabel(), InvalidLiteLabel());
            (liteLabelhash, liteNode) = _validateLiteLabel(link.liteLabel);
            IDotnsRegistrar registrar = _registrar();
            require(
                registrar.exists(uint256(liteNode)) && registrar.ownerOf(uint256(liteNode)) == user,
                LiteLabelNotOwnedByUser(user, liteLabelhash)
            );
            chatKeyToPersist = _popResolver().chatKey(liteNode);
        } else {
            _requireValidChatKey(link.chatKey);
            chatKeyToPersist = link.chatKey;
        }

        _completeGatewayRegistration(user, label, labelhash, node, chatKeyToPersist, liteLabelhash);

        if (isClaim) {
            emit BaseNameClaimed(labelhash, user, label);
        } else {
            emit StandaloneNameRegistered(labelhash, user, label);
        }
        if (link.kind == LinkKind.LiteUsername) {
            emit LiteToFullLinked(labelhash, liteLabelhash);
        }
    }

    /// @inheritdoc IDotnsPopController
    function expireReservation(string calldata reservedBaseLabel) external override {
        (bytes32 labelhash,) = _validateBaseLabel(reservedBaseLabel);
        _advanceExpiredHead(labelhash);
    }

    /// @inheritdoc IDotnsPopController
    function relinquishReservation() external override {
        UserReservation memory userRes = _userReservations[msg.sender];
        require(userRes.labelhash != bytes32(0), NoActiveReservation(msg.sender));
        _removeUserFromQueue(msg.sender);
        emit ReservationRelinquished(userRes.labelhash, msg.sender);
    }

    /// @inheritdoc IDotnsPopController
    function claimLabelStore() external override returns (bool moreRemaining) {
        (, moreRemaining) = _settlePending(msg.sender, DotnsConstants.MAX_PAGE_SIZE);
    }

    /// @inheritdoc IDotnsPopController
    function settlePendingClaims(
        address user,
        uint256 limit
    )
        external
        override
        returns (uint256 settledCount, bool moreRemaining)
    {
        return _settlePending(user, limit);
    }

    /// @notice Shared settlement loop behind @custom:function claimLabelStore and
    /// @custom:function settlePendingClaims.
    /// @dev Settles up to `limit` of the user's pending claims, deploying the store on the first
    /// write, and removes the user from the enumeration set once their queue empties.
    function _settlePending(
        address user,
        uint256 limit
    )
        internal
        returns (uint256 settledCount, bool moreRemaining)
    {
        IStoreFactory factory = _storeFactory();
        address store = factory.getLabelStore(user);

        PendingClaim[] storage queue = _pendingClaimQueue[user];
        uint256 remaining = queue.length;
        settledCount = limit < remaining ? limit : remaining;

        // Settle from the tail: read the last entry, pop it, then write. Popping the tail removes
        // an entry with no storage copy, unlike a swap-from-front. Settlement order does not
        // matter to the reads. The pop runs before the external write (deploy + store label), so a
        // store or factory that ever gained a callback could not re-enter onto an un-popped queue.
        for (uint256 i; i < settledCount; ++i) {
            --remaining;
            string memory label = queue[remaining].label;
            queue.pop();
            store = _settlePendingLabel(factory, store, user, label);
        }

        moreRemaining = remaining != 0;
        if (!moreRemaining) {
            _pendingClaimUsers.remove(user);
        }
    }

    /// @notice Writes a single pending label into the user's store, deploying the store lazily.
    /// @dev The store is created only when there is a label to write, so a caller who settles an
    /// empty queue never leaves a fresh store behind with nothing in it. Returns the (possibly
    /// newly deployed) store so the caller threads it through the remaining entries.
    function _settlePendingLabel(
        IStoreFactory factory,
        address store,
        address user,
        string memory label
    )
        internal
        returns (address)
    {
        bytes32 labelhash = LabelUtils.labelhashMemory(label);
        bytes32 node = LabelUtils.namehashUnder(protocolRegistry.tldNode(), labelhash);
        if (store == address(0)) {
            store = factory.deployLabelStoreFor(user);
        }
        _writeRecord(store, node, label);
        emit PendingClaimSettled(user, labelhash, store, msg.sender);
        emit NameRegistered(label, labelhash, user, store);
        return store;
    }

    /// @inheritdoc IDotnsPopController
    function isReservedForClaim(string calldata reservedBaseLabel)
        external
        view
        override
        returns (bool reserved, address holder)
    {
        (bytes32 labelhash,) = _validateBaseLabel(reservedBaseLabel);
        ReservationQueueMeta memory meta = _reservationMeta[labelhash];
        if (meta.head >= meta.tail) return (false, address(0));

        ReservationEntry memory head = _reservationEntries[labelhash][meta.head];
        if (head.owner == address(0)) return (false, address(0));
        if (_isExpired(head.joinedAt)) return (false, address(0));

        return (true, head.owner);
    }

    /// @inheritdoc IDotnsPopController
    function setReservationDuration(uint64 duration) external override onlyOwner {
        require(duration >= MIN_RESERVATION_DURATION, ReservationDurationTooLow(duration));
        reservationDuration = duration;
        emit ReservationDurationSet(duration);
    }

    /// @inheritdoc IDotnsPopController
    function reservationMeta(bytes32 labelhash)
        external
        view
        override
        returns (uint64 head, uint64 tail)
    {
        ReservationQueueMeta memory meta = _reservationMeta[labelhash];
        return (meta.head, meta.tail);
    }

    /// @inheritdoc IDotnsPopController
    function reservationEntry(
        bytes32 labelhash,
        uint64 index
    )
        external
        view
        override
        returns (address entryOwner, uint64 joinedAt)
    {
        ReservationEntry memory entry = _reservationEntries[labelhash][index];
        return (entry.owner, entry.joinedAt);
    }

    /// @inheritdoc IDotnsPopController
    function userReservation(address user)
        external
        view
        override
        returns (UserReservation memory reservation)
    {
        return _userReservations[user];
    }

    /// @inheritdoc IDotnsPopController
    function pendingClaims(
        address user,
        uint256 offset,
        uint256 limit
    )
        external
        view
        override
        returns (PendingClaim[] memory claims)
    {
        PendingClaim[] storage queue = _pendingClaimQueue[user];
        uint256 total = queue.length;
        if (offset >= total) return new PendingClaim[](0);

        uint256 available = total - offset;
        uint256 count = limit < available ? limit : available;
        if (count > DotnsConstants.MAX_PAGE_SIZE) count = DotnsConstants.MAX_PAGE_SIZE;

        claims = new PendingClaim[](count);
        for (uint256 i; i < count; ++i) {
            claims[i] = queue[offset + i];
        }
    }

    /// @inheritdoc IDotnsPopController
    function pendingClaimCountOf(address user) external view override returns (uint256 count) {
        return _pendingClaimQueue[user].length;
    }

    /// @inheritdoc IDotnsPopController
    function pendingClaimUserCount() external view override returns (uint256 count) {
        return _pendingClaimUsers.length();
    }

    /// @inheritdoc IDotnsPopController
    function pendingClaimUsers(
        uint256 offset,
        uint256 limit
    )
        external
        view
        override
        returns (address[] memory users)
    {
        uint256 total = _pendingClaimUsers.length();
        if (offset >= total) return new address[](0);

        uint256 available = total - offset;
        uint256 count = limit < available ? limit : available;
        if (count > DotnsConstants.MAX_PAGE_SIZE) count = DotnsConstants.MAX_PAGE_SIZE;

        users = new address[](count);
        for (uint256 i; i < count; ++i) {
            users[i] = _pendingClaimUsers.at(offset + i);
        }
    }

    /// @inheritdoc IDotnsPopController
    function reservedBaseLabelOf(bytes32 labelhash)
        external
        view
        override
        returns (string memory baseLabel)
    {
        return _reservedBaseLabel[labelhash];
    }

    /// @inheritdoc ERC165Upgradeable
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165Upgradeable, IERC165)
        returns (bool)
    {
        return interfaceId == type(IDotnsPopController).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.0.0";
    }

    /// @notice Mints a name, wires forward registry, persists PoP-flow records (chat key,
    /// lite link) on the PoP resolver, and either writes the label into the owner's
    /// existing `LabelStore` or stashes a pending claim when the owner has none yet.
    /// @dev The mint + forward-registry pair is delegated to
    /// @custom:function RegistrationUtils.registerAndStore so this flow and the public
    /// commit-reveal flow share exactly one implementation of that sequence. The label is
    /// passed empty so the registrar does not deploy a `LabelStore`; substrate Root cannot
    /// run the `LabelStore` constructor under `pallet-revive`. PoP-flow per-name records
    /// (chat key, lite link) are persisted eagerly on @custom:contract IDotnsPopResolver
    /// here, before the label is written, so the resolver carries the full identity record
    /// from mint time regardless of whether the owner already has a `LabelStore`. The Store
    /// stays labels-only. Warm path emits @custom:emits NameRegistered immediately; the
    /// cold path emits @custom:emits PendingClaimStashed at mint and defers
    /// @custom:emits NameRegistered to @custom:function settlePendingClaims when the claim
    /// settles.
    function _completeGatewayRegistration(
        address user,
        string memory label,
        bytes32 labelhash,
        bytes32 node,
        bytes memory chatKeyBytes,
        bytes32 liteLabelhash
    )
        internal
    {
        _popIssued[label] = true;

        RegistrationUtils.registerAndStore(
            RegistrationUtils.RegistrationContext({
                protocolRegistry: protocolRegistry,
                user: user,
                label: "",
                labelhash: labelhash,
                node: node
            })
        );

        if (chatKeyBytes.length != 0 || liteLabelhash != bytes32(0)) {
            IDotnsPopResolver resolver = _popResolver();
            if (chatKeyBytes.length != 0) {
                resolver.setChatKey(node, chatKeyBytes);
            }
            if (liteLabelhash != bytes32(0)) {
                resolver.setLiteLink(node, liteLabelhash);
            }
        }

        address store = _storeFactory().getLabelStore(user);
        if (store == address(0)) {
            _stashPendingClaim(user, label, labelhash);
        } else {
            _writeRecord(store, node, label);
            emit NameRegistered(label, labelhash, user, store);
        }
    }

    /// @notice Writes a name's label into `store`.
    /// @dev Single canonical persistence step shared by the warm gateway path and
    /// @custom:function settlePendingClaims. The store key is `node`, matching
    /// the registrar's `_writeOwnerLabel` convention. Idempotent on already-locked slots so a
    /// user whose store was pre-populated under the same `node` (e.g. by a sibling protocol
    /// flow) can still settle their pending claim without bricking on `LabelAlreadyExists`.
    /// @param store Owner's `LabelStore` proxy.
    /// @param node `namehash(labelhash)` for the entry.
    /// @param label Bare label without the TLD, which is appended on write. A lite label
    /// carries its separator, so this is not always a single DNS label.
    function _writeRecord(address store, bytes32 node, string memory label) internal {
        if (ILabelStore(store).isLocked(node)) return;
        ILabelStore(store).storeLabel(node, string.concat(label, protocolRegistry.tld()));
    }

    /// @notice Appends a deferred binding for `user` and adds them to the enumeration set.
    /// @dev The Root gateway origin cannot deploy the user's `LabelStore`, so deferred names pile
    /// up in `_pendingClaimQueue` until a signed-origin @custom:function settlePendingClaims
    /// writes them. Adding the user to the set is idempotent, so repeat stashes keep a single
    /// enumeration entry. Emits @custom:emits PendingClaimStashed.
    function _stashPendingClaim(address user, string memory label, bytes32 labelhash) internal {
        _pendingClaimQueue[user].push(
            PendingClaim({label: label, mintedAt: uint64(block.timestamp)})
        );
        _pendingClaimUsers.add(user);

        emit PendingClaimStashed(user, labelhash, label);
    }

    /// @notice Returns whether a queue entry is expired relative to `block.timestamp`.
    function _isExpired(uint64 joinedAt) internal view returns (bool) {
        return joinedAt + reservationDuration < block.timestamp;
    }

    /// @notice Appends a new reservation entry to the tail of the queue for `labelhash`.
    /// @dev Reverts if the queue is full or the user already holds a reservation. When the
    /// enqueued entry is the new head of an empty queue, the controller also reserves the
    /// base name on PopRules so the public commit-reveal flow sees the reservation through
    /// its existing `priceWithCheck` guard. Subsequent waiters only live in the local queue
    /// until they are promoted.
    function _enqueueReservation(
        IPopRules rules,
        bytes32 labelhash,
        string memory baseLabel,
        address user
    )
        internal
    {
        require(_userReservations[user].labelhash == bytes32(0), AlreadyReserved(user, labelhash));

        ReservationQueueMeta memory meta = _reservationMeta[labelhash];
        require(meta.tail - meta.head < MAX_RESERVATION_QUEUE, QueueFull(labelhash));

        uint64 index = meta.tail;
        bool becomesHead = index == meta.head;

        _reservationEntries[labelhash][index] =
            ReservationEntry({owner: user, joinedAt: uint64(block.timestamp)});
        _reservationMeta[labelhash] = ReservationQueueMeta({head: meta.head, tail: index + 1});

        _userReservations[user] = UserReservation({labelhash: labelhash, index: index});

        if (becomesHead) {
            _reservedBaseLabel[labelhash] = baseLabel;
            rules.reserveBaseNameForPop(baseLabel, user);
        }

        emit ReservationQueued(labelhash, user, index - meta.head);
    }

    /// @notice Wipes the entire reservation queue for `labelhash` and releases the
    /// corresponding PopRules reservation.
    /// @dev Used when a holder claims their reservation: every waiter is evicted and their
    /// per-user tracking state is cleared, and PopRules is told the slot is free so future
    /// public registrations are unblocked (the claim itself just minted the name, so there
    /// is nothing left to reserve).
    function _clearQueue(bytes32 labelhash) internal {
        ReservationQueueMeta memory meta = _reservationMeta[labelhash];
        for (uint64 i = meta.head; i < meta.tail; i++) {
            ReservationEntry memory entry = _reservationEntries[labelhash][i];
            if (entry.owner != address(0)) {
                delete _userReservations[entry.owner];
            }
            delete _reservationEntries[labelhash][i];
        }
        delete _reservationMeta[labelhash];
        _releasePopRulesSlot(labelhash);
    }

    /// @notice Advances the queue head past every expired entry at the head of the queue.
    /// @dev Reset semantics matter: when the queue empties (head catches tail), the meta slot
    /// is deleted AND the PopRules base-name slot is released, so the public commit-reveal
    /// flow can register the label again. When a new live head emerges, PopRules is re-synced
    /// to that head so reservations cannot be paid around by another address. Emits
    /// @custom:emits ReservationExpired once per expired entry reaped from the head.
    function _advanceExpiredHead(bytes32 labelhash) internal {
        ReservationQueueMeta memory meta = _reservationMeta[labelhash];
        uint64 head = meta.head;
        uint64 tail = meta.tail;

        while (head < tail) {
            ReservationEntry memory entry = _reservationEntries[labelhash][head];
            if (entry.owner == address(0)) {
                // `owner == 0` implies the slot is fully zero (it can only have arrived here
                // via a prior full-slot `delete`), so skip the no-op SSTORE.
                head++;
                continue;
            }
            if (!_isExpired(entry.joinedAt)) break;

            delete _userReservations[entry.owner];
            delete _reservationEntries[labelhash][head];
            emit ReservationExpired(labelhash, entry.owner);
            head++;
        }

        if (head == tail) {
            delete _reservationMeta[labelhash];
            _releasePopRulesSlot(labelhash);
        } else if (head != meta.head) {
            _reservationMeta[labelhash] = ReservationQueueMeta({head: head, tail: tail});
            address newHead = _reservationEntries[labelhash][head].owner;
            _syncPopRulesToHead(labelhash, newHead);
        }
    }

    /// @notice Removes `user` from whichever reservation queue they currently occupy.
    /// @dev For a head removal, we delete the entry without bumping `meta.head` and delegate
    /// the advance to `_advanceExpiredHead`. Its existing zero-owner skip walks past the
    /// freshly-deleted slot, and its `head != meta.head` branch fires the PopRules resync
    /// in the one place head promotion is actually handled. Non-head removals leave the
    /// queue shape intact, so no advance or resync is needed.
    function _removeUserFromQueue(address user) internal {
        UserReservation memory userRes = _userReservations[user];
        bytes32 labelhash = userRes.labelhash;
        if (labelhash == bytes32(0)) return;

        uint64 entryIndex = userRes.index;
        ReservationQueueMeta memory queueMeta = _reservationMeta[labelhash];

        delete _userReservations[user];
        delete _reservationEntries[labelhash][entryIndex];

        if (entryIndex == queueMeta.head) {
            _advanceExpiredHead(labelhash);
        }
    }

    /// @notice Validates a lite-person `stem.NN` label and derives `(labelhash, node)`.
    /// @dev The stem is lowercase letters only, so this rejects a stem carrying a digit or a
    /// hyphen before any node is derived.
    function _validateLiteLabel(string memory liteLabel)
        internal
        view
        returns (bytes32 labelhash, bytes32 node)
    {
        require(liteLabel.isLitePersonLabelMemory(), InvalidLiteLabel());
        labelhash = LabelUtils.labelhashMemory(liteLabel);
        node = LabelUtils.namehashUnder(protocolRegistry.tldNode(), labelhash);
    }

    /// @notice Validates a base (full-person) label and derives `(labelhash, node)`.
    /// @dev Letters only, so this is stricter than a DNS label: a hyphen or an interior digit
    /// is rejected here even though @custom:function StringUtils.isSingleLabel would admit it.
    function _validateBaseLabel(string calldata baseLabel)
        internal
        view
        returns (bytes32 labelhash, bytes32 node)
    {
        // Letters only, matching `BaseLabel::is_valid_person` in the gateway pallet: a
        // full-person label is a name a person chose, so it admits no digits and no hyphens.
        // Classification does not cover this on its own, since a suffixed label with nine or
        // more characters lands on NoStatus and would otherwise pass.
        require(baseLabel.isPersonLabel(), InvalidBaseLabel());
        (labelhash, node) = LabelUtils.deriveNode(protocolRegistry.tldNode(), baseLabel);
    }

    /// @notice Validates a base label as reservable and returns its hashes.
    /// @dev Shared by both reservation entrypoints so the guard cannot drift between them. Runs
    /// three checks and reverts on the first failure, before any reservation state is mutated: the
    /// label must classify outside the governance-reserved tier and be a base name, be a
    /// letters-only person label, and have no owner on the registrar. The last check is the fix for
    /// a reservation queued over an already-registered name: the queue keys by stem, so such a
    /// reservation could never be redeemed yet would hold the stem, and so every lite name built
    /// on it, for the full reservation window. `exists` (owner set) mirrors exactly what makes the
    /// eventual claim's mint revert, so a label that passes here is one a claim can still register.
    function _validateReservableBaseLabel(
        IPopRules rules,
        string calldata baseLabel
    )
        internal
        view
        returns (bytes32 labelhash, bytes32 node)
    {
        (labelhash, node) = _validateBaseLabel(baseLabel);

        (IPopRules.PopStatus required,) = rules.classifyName(baseLabel);
        require(
            required != IPopRules.PopStatus.Reserved && rules.isBaseName(baseLabel),
            InvalidBaseLabel()
        );
        require(!_registrar().exists(uint256(node)), BaseNameAlreadyRegistered());
    }

    /// @notice Reverts when a non-empty chat key is not exactly `CHAT_KEY_LENGTH` bytes.
    /// @dev Mirrors the resolver's own length gate so the gateway sees a controller-local
    /// `InvalidChatKey` revert before any mint state is written.
    function _requireValidChatKey(bytes memory chatKey) internal pure {
        require(
            chatKey.length == 0 || chatKey.length == CHAT_KEY_LENGTH, InvalidChatKey(chatKey.length)
        );
    }

    /// @notice Resolves the PoP resolver via the protocol registry.
    function _popResolver() internal view returns (IDotnsPopResolver) {
        return IDotnsPopResolver(protocolRegistry.get(DotnsConstants.POP_RESOLVER));
    }

    /// @notice Resolves the PopRules contract via the protocol registry.
    function _popRules() internal view returns (IPopRules) {
        return IPopRules(protocolRegistry.get(DotnsConstants.POP_RULES));
    }

    /// @notice Resolves the Store factory via the protocol registry.
    function _storeFactory() internal view returns (IStoreFactory) {
        return IStoreFactory(protocolRegistry.get(DotnsConstants.STORE_FACTORY));
    }

    /// @notice Resolves the registrar via the protocol registry.
    function _registrar() internal view returns (IDotnsRegistrar) {
        return IDotnsRegistrar(protocolRegistry.get(DotnsConstants.REGISTRAR));
    }

    /// @notice Writes the new head of the queue into PopRules so the public commit-reveal flow
    /// rejects registrations of this base name for anyone other than `newHead`.
    /// @dev Callers guarantee `newHead` is non-zero (the queue holds a live entry) and that
    /// `_reservedBaseLabel[labelhash]` is non-empty (any non-empty queue had its first head
    /// write the slot). The release-then-reserve pair satisfies PopRules' ownership gate on
    /// `reserveBaseNameForPop`.
    function _syncPopRulesToHead(bytes32 labelhash, address newHead) internal {
        string memory baseLabel = _reservedBaseLabel[labelhash];
        IPopRules rules = _popRules();
        rules.releaseBaseName(baseLabel);
        rules.reserveBaseNameForPop(baseLabel, newHead);
        emit ReservationHeadAdvanced(labelhash, newHead);
    }

    /// @notice Clears the PopRules slot and the local label bookkeeping when the queue empties
    /// (claim, last-relinquish, last-expire).
    function _releasePopRulesSlot(bytes32 labelhash) internal {
        string memory baseLabel = _reservedBaseLabel[labelhash];
        if (bytes(baseLabel).length == 0) return;
        _popRules().releaseBaseName(baseLabel);
        delete _reservedBaseLabel[labelhash];
    }

    /// @notice Internal check enforcing a substrate Root origin.
    /// @dev Authorises a call when @custom:function SystemUtils.originIsRoot is true, and
    ///      reverts with NotRoot otherwise. `msg.sender` is deliberately not consulted: a
    ///      Root origin has no account behind it, so reading `msg.sender` traps. That holds
    ///      for this frame and any delegatecall sharing it; a nested call sees the calling
    ///      contract as its sender and reads normally.
    ///
    ///      The check also holds for the whole Root transaction rather than the entry frame
    ///      alone, so nothing reachable from an onlyRoot entrypoint may call a
    ///      user-controlled address: such a callee could re-enter a gated function and still
    ///      pass. Every call out of this contract goes to a protocol contract resolved
    ///      through the registry.
    function _onlyRoot() internal view {
        require(SystemUtils.originIsRoot(), NotRoot());
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
