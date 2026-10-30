// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
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
import {IDotnsPopControllerLegacy} from "./IDotnsPopControllerLegacy.sol";
import {IDotnsPopGovernance} from "./IDotnsPopGovernance.sol";
import {IDotnsRegistrar} from "./IDotnsRegistrar.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {IDotnsPopResolver} from "../resolvers/IDotnsPopResolver.sol";
import {IDotnsPopResolverClearing} from "../resolvers/IDotnsPopResolverClearing.sol";
import {IPopRules} from "../pop/IPopRules.sol";
import {PopClassification} from "../pop/PopClassification.sol";
import {IStoreFactory} from "../store/IStoreFactory.sol";
import {ILabelStore} from "../store/ILabelStore.sol";
import {LabelUtils} from "../utils/LabelUtils.sol";
import {SubnodeUtils} from "../utils/SubnodeUtils.sol";
import {RegistrationUtils} from "../utils/RegistrationUtils.sol";
import {IDotnsRegistry} from "../registry/IDotnsRegistry.sol";
import {IDotnsNameWhitelist} from "../whitelist/IDotnsNameWhitelist.sol";
import {StringUtils} from "../utils/StringUtils.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";
import {SystemUtils} from "../utils/SystemUtils.sol";

/// @title DotnsPopController
/// @notice Dedicated PoP controller that issues device names and personhood names on behalf of
/// the dotNS gateway pallet.
/// @dev Lives behind its own UUPS proxy with its own storage. Registered on `DotnsRegistrar`
/// via `addController`, which is how multiple controllers coexist on the same registrar
/// without interfering with each other.
///
/// Enforcement:
/// Devicehood and personhood are attested off-chain by the gateway before the call reaches this
/// contract, so the on-chain personhood precompile is not re-queried on the gateway path.
/// Every issuance path applies PopRules' naming rules (@custom:contract PopClassification) to
/// reject governance-reserved labels (@custom:reverts InvalidPersonhoodLabel for personhood names,
/// @custom:reverts InvalidDeviceLabel for device names). A device name is accepted with any
/// two-digit suffix whose stem is not governance-reserved, regardless of stem length. Native-token
/// pricing is bypassed entirely; the gateway pays no rent.
///
/// Decoupling:
/// This contract does not import or call `IDotnsRegistrarController`. The public
/// commit-reveal controller is equally unaware of this one. Cross-flow collision handling
/// relies on two distinct properties, neither of which requires the two controllers to know
/// about each other:
/// (1) Device names (`stem.NN`) occupy a namespace the public path cannot reach: the
/// separator is legal only on a device name, and the public path rejects it, so no public
/// registration can spell one. A digit suffix is not exclusive, but an ordinary label carrying
/// one is measured as written and so is simply a different name. The two flows therefore cannot
/// contend for the same label. This holds of labels the contracts minted, not of an arbitrary
/// string: a subname stored under a digit-only parent reads the same way, which is why
/// provenance is published through @custom:function isPopIssued rather than inferred.
/// (2) Personhood-name reservations are synchronised into `IPopRules` by base name. The head of
/// this controller's reservation queue is written through `IPopRules.reserveBaseNameForPop` on
/// every head transition; the slot is cleared through `IPopRules.releaseBaseName` when the
/// queue empties (claim, final relinquish, final expiry). The public commit-reveal
/// controller routes through `IPopRules.priceWithCheck`, which rejects any registration
/// targeting a base name reserved for another user, so the public flow respects
/// gateway reservations without ever importing this contract. PopRules is the single
/// cross-flow authority; the queue here is the intra-PoP ordering layer on top of it.
///
/// Shared primitives: labelhash / namehash via @custom:contract LabelUtils; classification via
/// @custom:contract PopClassification; chat-key and device-link persistence via
/// @custom:contract IDotnsPopResolver. Keeping per-name records on the resolver preserves the
/// "Store = labels only" invariant.
/// @custom:security-contact admin@parity.io
contract DotnsPopController is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IDotnsPopController,
    IDotnsPopControllerLegacy,
    IDotnsPopGovernance
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

    /// @notice Maximum value accepted by @custom:function setReservationDuration.
    /// @dev PopRules holds the name for the user at the front of a queue for
    /// @custom:constant PopRules.MAX_RESERVATION_TIME (12 weeks) from each change of front, and a
    /// PopRules reservation lapses at its last second while a queue entry is still active at
    /// its own. One second less keeps the front user's entry from outlasting the PopRules
    /// reservation written when they reached the front. Users behind them keep their own join
    /// time, so their entries can outlast it; a call that clears the queue re-stamps or releases
    /// the PopRules reservation, which is why apps clear a queue before using it.
    uint64 public constant MAX_RESERVATION_DURATION = 12 weeks - 1;

    /// @notice Required byte length for a non-empty chat key.
    /// @dev Mirrors @custom:contract IDotnsPopResolver `InvalidChatKeyLength` so the controller
    /// can fail closed before the mint instead of bubbling the resolver's revert after partial
    /// state has been committed.
    uint256 private constant CHAT_KEY_LENGTH = 65;

    /// @notice Most expired or emptied entries one gateway call clears from the front of a
    /// reservation queue.
    /// @dev A gateway call runs under a fixed weight limit, and each entry visited costs a
    /// storage read. A longer run is cleared over several calls, each keeping its progress, or at
    /// once by @custom:function expireReservation.
    uint256 public constant MAX_QUEUE_STEPS_PER_CALL = 4;

    /// @notice Protocol-level address registry for all dotNS contracts.
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

    /// @notice Remembers the personhood name for each reserved labelhash so the PopRules
    /// sync path can address the reservation by its original string form (PopRules keys its
    /// `reservations` mapping by string).
    /// @dev Populated on first enqueue for a label, cleared when the queue empties. Exists
    /// only to bridge the queue's `bytes32` key space to PopRules' `string` key space;
    /// nothing else reads it.
    mapping(bytes32 labelhash => string reservedLabel) internal _reservedBaseLabel;

    /// @notice Duration (in seconds) after which a reservation entry is considered expired.
    /// @dev Sets the reservation duration, configurable by
    /// governance via `setReservationDuration`.
    uint64 public override reservationDuration;

    /// @notice Enumeration set of users holding at least one pending claim.
    /// @dev Membership equals the set of users with a non-empty queue. Used by
    /// `pendingClaimUserCount` and `pendingClaimUsers` for paginated enumeration.
    EnumerableSet.AddressSet private _pendingClaimUsers;

    /// @notice Per-user pile of deferred names awaiting a `LabelStore`.
    /// @dev The mint origin cannot deploy a `LabelStore`, so deferred names accumulate here until a
    /// signed-origin @custom:function settlePendingClaims deploys the store and writes the stashed
    /// labels. Entries never lapse and can be settled at any time.
    mapping(address user => PendingClaim[] queue) internal _pendingClaimQueue;

    /// @notice Labels this controller minted, keyed by the bare label without the TLD.
    /// @dev Provenance, not a transfer rule: written at mint and cleared only when the name is
    ///      revoked (@custom:function revokeName), so it stays true if a name later becomes
    ///      transferable and turns false once governance takes the name back. Keyed by the label
    ///      text rather than the node because a reader holding only `joseph.42` cannot derive the
    ///      node without first deciding whether the separator is part of the label or a subname
    ///      boundary, which is the question it is asking.
    mapping(string label => bool issued) internal _popIssued;

    /// @notice Numeric containers this contract has minted or verified as its own.
    /// @dev Lets device-name issuance skip the registrar and registry checks on every later
    /// issuance in the same container. See @custom:function _registerDeviceSubname. An entry is
    /// never cleared, because a recorded container cannot change hands: the registrar marks a
    /// name minted by this contract soulbound and rejects every transfer of it, release to the
    /// escrow included. Nor can it be revoked: the registrar's Root revocation refuses a soulbound
    /// name, and @custom:function revokeName takes only labels this contract issued, which a
    /// container is not. If a container ever did change hands, the registry's
    /// own parent check in @custom:function IDotnsRegistry.setSubnodeOwner would still reject
    /// issuance under it.
    mapping(bytes32 parentNode => bool ready) internal _deviceContainers;

    /// @dev Reserved storage space to allow for layout changes in future upgrades.
    uint256[49] private __gap;

    /// @notice Contract addresses one call reads from the protocol registry, each at most once.
    /// @dev Filled on first use by the `_...Of` getters and passed by reference through the call.
    /// A gateway call runs under a fixed weight limit and every registry lookup is a proxied
    /// external call, so each address is read once per call and reused.
    struct Deps {
        IPopRules rules;
        IDotnsRegistrar registrar;
        IDotnsRegistry registry;
        IDotnsPopResolver popResolver;
        IStoreFactory storeFactory;
        bytes32 tldNode;
    }

    /// @notice Restricts calls to a Root origin.
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
    /// @param initialOwner Address that owns the contract once initialised.
    function initialize(
        address initialOwner,
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
        require(
            reservationDuration_ <= MAX_RESERVATION_DURATION,
            ReservationDurationTooHigh(reservationDuration_)
        );
        __Ownable_init(initialOwner);
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
    function issueDeviceName(DeviceNameIssuance calldata params) external override onlyRoot {
        Deps memory deps;
        _issueDeviceName(deps, params, false);
    }

    /// @inheritdoc IDotnsPopControllerLegacy
    function reserveLiteName(DeviceNameIssuance calldata params) external override onlyRoot {
        Deps memory deps;
        _issueDeviceName(deps, params, true);
    }

    /// @inheritdoc IDotnsPopController
    function issueDeviceNameWithReservation(DeviceNameIssuanceWithReservation calldata params)
        external
        override
        onlyRoot
    {
        _issueDeviceNameWithReservation(params, false);
    }

    /// @inheritdoc IDotnsPopControllerLegacy
    function reserveBaseName(DeviceNameIssuanceWithReservation calldata params)
        external
        override
        onlyRoot
    {
        _issueDeviceNameWithReservation(params, true);
    }

    /// @inheritdoc IDotnsPopController
    function reservePersonhoodName(PersonhoodNameReservation calldata params)
        external
        override
        onlyRoot
    {
        Deps memory deps;
        (bytes32 reservedHash,) = _validateReservablePersonhoodLabel(deps, params.label, false);
        bool slotKept =
            _advanceExpiredHead(deps, reservedHash, MAX_QUEUE_STEPS_PER_CALL, true, address(0));
        if (_keepOrDropReservation(deps, reservedHash, params.user)) return;
        _enqueueReservation(deps, reservedHash, params.label, params.user, slotKept);
    }

    /// @inheritdoc IDotnsPopController
    function issuePersonhoodName(PersonhoodNameIssuance calldata params)
        external
        override
        onlyRoot
    {
        _issuePersonhoodName(params, false);
    }

    /// @inheritdoc IDotnsPopControllerLegacy
    function registerBaseName(PersonhoodNameIssuance calldata params) external override onlyRoot {
        _issuePersonhoodName(params, true);
    }

    /// @notice Body shared by @custom:function issueDeviceNameWithReservation and its legacy
    /// entrypoint.
    /// @dev The reservation is validated before the issuance so an unreservable label aborts the
    /// whole call. `legacy` selects the label errors, as in @custom:function _issueDeviceName.
    function _issueDeviceNameWithReservation(
        DeviceNameIssuanceWithReservation calldata params,
        bool legacy
    )
        internal
    {
        Deps memory deps;
        bytes32 reservedHash;
        bool hasReservation = bytes(params.reservedLabel).length != 0;
        if (hasReservation) {
            (reservedHash,) = _validateReservablePersonhoodLabel(deps, params.reservedLabel, legacy);
        }

        _issueDeviceName(deps, params.issuance, legacy);

        if (hasReservation) {
            bool slotKept =
                _advanceExpiredHead(deps, reservedHash, MAX_QUEUE_STEPS_PER_CALL, true, address(0));
            if (_keepOrDropReservation(deps, reservedHash, params.issuance.user)) return;
            _enqueueReservation(
                deps, reservedHash, params.reservedLabel, params.issuance.user, slotKept
            );
        }
    }

    /// @notice Device-name issuance shared by @custom:function issueDeviceName, the issuance of
    /// @custom:function issueDeviceNameWithReservation, and their legacy entrypoints.
    /// @dev Gateway attestation is the authority for devicehood on this path; the on-chain
    /// precompile is not consulted. The label is stored in the `stem.NN` form the gateway sends,
    /// which is the canonical form of the name, so no normalisation happens here. The shape check
    /// runs before classification so a malformed label reverts with a controller error, which the
    /// gateway decodes by selector; letting `classifyName` catch it instead would surface an
    /// undecodable PopRules string. `legacy` selects @custom:reverts InvalidLiteLabel over
    /// @custom:reverts InvalidDeviceLabel for the callers that decode the legacy error.
    function _issueDeviceName(
        Deps memory deps,
        DeviceNameIssuance calldata params,
        bool legacy
    )
        internal
    {
        _requireDeviceLabel(params.label.isDeviceLabel(), legacy);
        _requireValidChatKey(params.chatKey);

        (IPopRules.PopStatus required,,) = PopClassification.classify(params.label);
        // The shape check fixes the suffix, so classification lands on Devicehood (stem 6-8),
        // NoStatus (stem 9 or more), or Reserved (stem 5 or fewer). Accept the first two; a
        // stem short enough to be governance-reserved is not issued from this path.
        _requireDeviceLabel(required != IPopRules.PopStatus.Reserved, legacy);
        (bytes32 labelhash, bytes32 node) = _validateDeviceLabel(deps, params.label, legacy);

        _completeGatewayRegistration(
            deps, params.user, params.label, labelhash, node, params.chatKey, bytes32(0)
        );

        emit DeviceNameIssued(labelhash, params.user, params.label);
    }

    /// @notice Personhood-name issuance shared by @custom:function issuePersonhoodName and its
    /// legacy entrypoint.
    /// @dev `legacy` selects @custom:reverts InvalidLiteLabel / @custom:reverts InvalidBaseLabel
    /// over the new label errors for the callers that decode the legacy ones.
    function _issuePersonhoodName(PersonhoodNameIssuance calldata params, bool legacy) internal {
        Link calldata link = params.link;
        address user = params.user;
        string calldata label = params.label;

        Deps memory deps;
        (bytes32 labelhash, bytes32 node) = _validatePersonhoodLabel(deps, label, legacy);

        (IPopRules.PopStatus required,,) = PopClassification.classify(label);
        _requirePersonhoodLabel(
            required != IPopRules.PopStatus.Reserved && required != IPopRules.PopStatus.Devicehood,
            legacy
        );
        _requireNotGranted(node);

        _advanceExpiredHead(deps, labelhash, MAX_QUEUE_STEPS_PER_CALL, false, user);

        ReservationQueueMeta memory meta = _reservationMeta[labelhash];
        bool isClaim;
        if (meta.head < meta.tail) {
            // The queue holds this label's PopRules slot, so the queue alone decides: only the
            // user at the front with an active reservation may take the name. A front still
            // expired after this call's clearing lets nobody.
            ReservationEntry memory headEntry = _reservationEntries[labelhash][meta.head];
            isClaim = headEntry.owner == user && !_isExpired(headEntry.joinedAt);
            require(isClaim, NotHolder(user, labelhash));
        } else {
            // Cross-flow guard: with no queue here, a live slot was written by a sibling
            // controller. Reject when held by another user so PopRules stays the single
            // cross-flow authority in both directions; the public flow reads this slot through
            // `priceWithCheck` and writes none of its own.
            (bool slotLive, address slotOwner,) = _rulesOf(deps).isBaseNameReserved(label);
            require(!slotLive || slotOwner == user, NotHolder(user, labelhash));
        }

        if (isClaim) {
            _clearQueue(deps, labelhash);
        } else {
            // Leaving another queue only empties the user's entry there, as in
            // @custom:function _keepOrDropReservation.
            _dropUserReservation(deps, user, 0);
        }

        bytes32 deviceLabelhash;
        bytes32 deviceNode;
        bytes memory chatKeyToPersist;
        if (link.kind == LinkKind.DeviceName) {
            _requireDeviceLabel(link.deviceLabel.isDeviceLabel(), legacy);
            (deviceLabelhash, deviceNode) = _validateDeviceLabel(deps, link.deviceLabel, legacy);
            // A device name is a subnode, so its owner lives in the registry record rather than
            // the registrar's ERC-721 ledger.
            require(
                _registryOf(deps).owner(deviceNode) == user,
                DeviceNameNotOwned(user, deviceLabelhash)
            );
            chatKeyToPersist = _popResolverOf(deps).chatKey(deviceNode);
        } else {
            _requireValidChatKey(link.chatKey);
            chatKeyToPersist = link.chatKey;
        }

        _completeGatewayRegistration(
            deps, user, label, labelhash, node, chatKeyToPersist, deviceLabelhash
        );

        emit PersonhoodNameIssued(labelhash, user, label);
        if (isClaim) {
            emit ReservationClaimed(labelhash, user);
        }
        if (link.kind == LinkKind.DeviceName) {
            emit DeviceNameLinked(labelhash, deviceLabelhash);
        }
    }

    /// @inheritdoc IDotnsPopGovernance
    function revokeName(string calldata label) external override onlyRoot {
        bytes32 labelhash = LabelUtils.labelhash(label);
        require(_popIssued[label], NotPopIssued(labelhash));
        delete _popIssued[label];

        Deps memory deps;
        // A device name is the subname `stem` of the container `suffix`; a personhood name is a
        // second-level name under the TLD.
        bool isDevice = label.isDeviceLabel();
        bytes32 parentNode = _tldNodeOf(deps);
        bytes32 childhash = labelhash;
        if (isDevice) {
            (string memory stem, string memory suffix) = StringUtils.splitDeviceLabel(label);
            parentNode = LabelUtils.namehashUnder(parentNode, LabelUtils.labelhashMemory(suffix));
            childhash = LabelUtils.labelhashMemory(stem);
        }
        bytes32 node = LabelUtils.namehashUnder(parentNode, childhash);
        address holder = _registryOf(deps).owner(node);

        IDotnsPopResolverClearing(address(_popResolverOf(deps)))
            .clearRecords(node, isDevice ? labelhash : bytes32(0));
        if (isDevice) {
            // This contract holds the container, so it deletes the subname as the parent's owner.
            _registryOf(deps).deleteSubname(parentNode, childhash);
        } else {
            _registrarOf(deps).revokeIssued(uint256(node));
        }

        emit IssuedNameRevoked(labelhash, holder, label);
    }

    /// @inheritdoc IDotnsPopGovernance
    function evictReservations(string calldata label) external override onlyRoot {
        Deps memory deps;
        (bytes32 labelhash,) = _validatePersonhoodLabel(deps, label, false);

        ReservationQueueMeta memory meta = _reservationMeta[labelhash];
        if (meta.head == meta.tail) return;

        _clearQueue(deps, labelhash);
        emit ReservationsEvicted(labelhash);
    }

    /// @inheritdoc IDotnsPopGovernance
    function evictReservation(address user) external override onlyRoot {
        UserReservation memory reservation = _userReservations[user];
        if (reservation.labelhash == bytes32(0) || _isEvicted(reservation)) return;

        Deps memory deps;
        // Governance runs outside the gateway's weight limit, so it can clear the whole queue.
        _dropReservation(deps, user, reservation, MAX_RESERVATION_QUEUE);
    }

    /// @inheritdoc IDotnsPopController
    function expireReservation(string calldata label) external override {
        Deps memory deps;
        (bytes32 labelhash,) = _validatePersonhoodLabel(deps, label, false);
        // A signed call outside the gateway's limit: it always has room to clear the whole queue.
        _advanceExpiredHead(deps, labelhash, MAX_RESERVATION_QUEUE, false, address(0));
    }

    /// @inheritdoc IDotnsPopController
    function prepareDeviceContainer(string calldata suffix) external override {
        bytes memory raw = bytes(suffix);
        require(raw.length == StringUtils.DEVICE_SUFFIX_DIGITS, InvalidDeviceLabel());
        for (uint256 i; i < raw.length; ++i) {
            require(raw[i] >= 0x30 && raw[i] <= 0x39, InvalidDeviceLabel());
        }
        Deps memory deps;
        bytes32 parentNode =
            LabelUtils.namehashUnder(_tldNodeOf(deps), LabelUtils.labelhashMemory(suffix));
        if (!_deviceContainers[parentNode]) _ensureDeviceContainer(deps, parentNode);
    }

    /// @inheritdoc IDotnsPopController
    function relinquishReservation() external override {
        UserReservation memory reservation = _userReservations[msg.sender];
        require(
            reservation.labelhash != bytes32(0) && !_isEvicted(reservation),
            NoActiveReservation(msg.sender)
        );
        Deps memory deps;
        // A signed call outside the gateway's limit: it has room to clear the whole queue.
        _dropUserReservation(deps, msg.sender, MAX_RESERVATION_QUEUE);
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
        Deps memory deps;
        IStoreFactory factory = _storeFactoryOf(deps);
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
            store = _settlePendingLabel(deps, factory, store, user, label);
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
        Deps memory deps,
        IStoreFactory factory,
        address store,
        address user,
        string memory label
    )
        internal
        returns (address)
    {
        bytes32 labelhash = LabelUtils.labelhashMemory(label);
        // A device name settled its ownership as a subnode, so its store entry keys the same
        // hierarchical node; a personhood name keys the second-level node under the TLD.
        bytes32 node = label.isDeviceLabelMemory()
            ? _deviceSubnode(deps, label)
            : LabelUtils.namehashUnder(_tldNodeOf(deps), labelhash);
        // A name revoked since the claim was stashed may already belong to someone else, and a
        // name revoked and issued to the same user again leaves two entries for one row. Either
        // entry is dropped without a write or an event, so the log never reports a registration
        // that did not happen.
        if (_registryOf(deps).owner(node) != user) return store;
        if (store == address(0)) {
            store = factory.deployLabelStoreFor(user);
        }
        if (!_writeRecord(store, node, label)) return store;
        emit PendingClaimSettled(user, labelhash, store, msg.sender);
        emit NameRegistered(label, labelhash, user, store);
        return store;
    }

    /// @inheritdoc IDotnsPopController
    function isReservedForClaim(string calldata label)
        external
        view
        override
        returns (bool reserved, address holder)
    {
        Deps memory deps;
        (bytes32 labelhash,) = _validatePersonhoodLabel(deps, label, false);
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
        require(duration <= MAX_RESERVATION_DURATION, ReservationDurationTooHigh(duration));
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
        ReservationQueueMeta memory meta = _reservationMeta[labelhash];
        if (index < meta.head || index >= meta.tail) return (address(0), 0);
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
        reservation = _userReservations[user];
        if (_isEvicted(reservation)) delete reservation;
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
    function reservedLabelOf(bytes32 labelhash)
        external
        view
        override
        returns (string memory label)
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
            || interfaceId == type(IDotnsPopControllerLegacy).interfaceId
            || interfaceId == type(IDotnsPopGovernance).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice Returns the release this network declares it runs, read live from the protocol
    ///         registry so every dotNS contract reports one synchronised value.
    /// @dev Mirror of `IDotnsProtocolRegistry.protocolVersion`, kept under the historical
    ///      `version()` selector for ABI compatibility. It reports the network's declaration,
    ///      not this contract's build; per-contract identity is the codehash declared on the
    ///      registry.
    /// @return versionString Declared release as bare semver, empty when never declared.
    function version() external view virtual returns (string memory versionString) {
        versionString = protocolRegistry.protocolVersion();
    }

    /// @notice Mints a name, wires forward registry, persists PoP-flow records (chat key,
    /// device link) on the PoP resolver, and either writes the label into the owner's
    /// existing `LabelStore` or stashes a pending claim when the owner has none yet.
    /// @dev The mint + forward-registry pair runs against the registrar and registry this call
    /// already resolved, so the gateway's call reads each address once. The label is passed
    /// empty so the registrar does not deploy a `LabelStore`; the mint origin cannot run the
    /// `LabelStore` constructor. PoP-flow per-name records
    /// (chat key, device link) are persisted eagerly on @custom:contract IDotnsPopResolver
    /// here, before the label is written, so the resolver carries the full identity record
    /// from mint time regardless of whether the owner already has a `LabelStore`. The Store
    /// stays labels-only. Warm path emits @custom:emits NameRegistered immediately; the
    /// cold path emits @custom:emits PendingClaimStashed at mint and defers
    /// @custom:emits NameRegistered to @custom:function settlePendingClaims when the claim
    /// settles.
    function _completeGatewayRegistration(
        Deps memory deps,
        address user,
        string memory label,
        bytes32 labelhash,
        bytes32 node,
        bytes memory chatKeyBytes,
        bytes32 deviceLabelhash
    )
        internal
    {
        _popIssued[label] = true;

        // A device name is a subname under its numeric container, so it takes the subnode path
        // and never mints a token. A personhood name is a tokenised second-level registration and
        // keeps the shared token triad untouched. `persist` is false because the store write is
        // deferred to the pending-claim queue below and the user syncs it later.
        if (label.isDeviceLabelMemory()) {
            // A device name is issued once. Its subnode already existing means a duplicate
            // issuance, which would rehome the identity and overwrite its records, so it is
            // rejected.
            require(!_registryOf(deps).recordExists(node), DeviceNameAlreadyIssued());
            (string memory stem, string memory suffix) = label.splitDeviceLabel();
            // Take the node from the registry write itself, so the chat-key and store writes below
            // land on exactly the node the record was created at rather than a separately derived
            // one that could drift from it.
            node = _registerDeviceSubname(deps, suffix, stem, user);
        } else {
            // The empty label keeps the registrar from writing a `LabelStore`; the store write
            // happens below, or is deferred to the pending-claim queue.
            RegistrationUtils.registerName(_registrarOf(deps), _registryOf(deps), node, user, "");
        }

        if (chatKeyBytes.length != 0 || deviceLabelhash != bytes32(0)) {
            IDotnsPopResolver resolver = _popResolverOf(deps);
            if (chatKeyBytes.length != 0) {
                resolver.setChatKey(node, chatKeyBytes);
            }
            if (deviceLabelhash != bytes32(0)) {
                resolver.setDeviceLink(node, deviceLabelhash);
            }
        }

        address store = _storeFactoryOf(deps).getLabelStore(user);
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
    /// @param node The name's node. A device name resolves to its stem beneath its numeric
    /// container, so this is not always `namehash(tldNode, keccak(label))` for the whole label.
    /// @param label Bare label without the TLD, which is appended on write. A device name
    /// carries its separator, so this is not always a single DNS label.
    /// @return written False when the slot was already locked and nothing was written.
    function _writeRecord(
        address store,
        bytes32 node,
        string memory label
    )
        internal
        returns (bool written)
    {
        if (ILabelStore(store).isLocked(node)) return false;
        ILabelStore(store).storeLabel(node, string.concat(label, protocolRegistry.tld()));
        return true;
    }

    /// @notice Appends a deferred binding for `user` and adds them to the enumeration set.
    /// @dev The mint origin cannot deploy the user's `LabelStore`, so deferred names pile
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
        Deps memory deps,
        bytes32 labelhash,
        string memory reservedLabel,
        address user,
        bool slotKept
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
            if (slotKept) {
                // The queue was emptied in this call with its PopRules slot and label kept, so
                // the slot moves straight to the new head.
                _rulesOf(deps).reassignBaseNameForPop(reservedLabel, user);
            } else {
                _reservedBaseLabel[labelhash] = reservedLabel;
                _rulesOf(deps).reserveBaseNameForPop(reservedLabel, user);
            }
        }

        emit ReservationQueued(labelhash, user, index - meta.head);
    }

    /// @notice Ends the reservation queue for `labelhash` when its head claims the name or
    /// governance evicts the queue, and releases the corresponding PopRules reservation.
    /// @dev After a claim the name is minted, and after an eviction nobody is waiting for it, so
    /// either way nothing is left to reserve and PopRules is told the slot is free. Every entry,
    /// the claimant's and each waiter's, is evicted lazily, so the call costs the same whatever
    /// the queue holds: the head moves to the tail, which ends the queue, and entries and pointers
    /// stay where they are, below the new head.
    /// @custom:function _isEvicted reads such a pointer as no reservation, and the user's next
    /// reservation clears it. The event the caller emits, @custom:emits ReservationClaimed or
    /// @custom:emits ReservationsEvicted, therefore ends the reservation of every waiter in the
    /// queue.
    function _clearQueue(Deps memory deps, bytes32 labelhash) internal {
        uint64 tail = _reservationMeta[labelhash].tail;
        _reservationMeta[labelhash] = ReservationQueueMeta({head: tail, tail: tail});
        _releasePopRulesSlot(deps, labelhash);
    }

    /// @notice Returns whether `reservation` points at an entry the queue's head has moved past.
    /// @dev Expiry and claims leave entries and pointers in place and move the head past them
    /// (see @custom:function _advanceExpiredHead and @custom:function _clearQueue), so a pointer
    /// below its queue's head is no reservation. Queue indices only ever grow, so such a pointer
    /// never matches an entry queued later under the same label.
    function _isEvicted(UserReservation memory reservation) internal view returns (bool) {
        return reservation.labelhash != bytes32(0)
            && reservation.index < _reservationMeta[reservation.labelhash].head;
    }

    /// @notice Prepares a gateway reservation of `labelhash` for `user`: keeps the user's
    /// reservation when it is an active one for the same name, and otherwise drops whatever
    /// reservation they hold so a fresh one can be queued.
    /// @dev A repeated reservation of the same name, such as one made again after the user recovers
    /// their account onto a new device, keeps the user's place and expiry. The expiry is not
    /// refreshed, so repeating a reservation never extends how long a user holds a name. Reads the
    /// user's reservation once and hands it to @custom:function _dropReservation.
    /// Dropping a reservation for another name only empties the user's entry in that queue: the
    /// next call on that name clears it like an expired one. A gateway call then does queue work
    /// in one queue only, the name being reserved, so its cost stays within the weight limit.
    /// @return kept Whether the existing reservation was kept, so nothing is to be queued.
    function _keepOrDropReservation(
        Deps memory deps,
        bytes32 labelhash,
        address user
    )
        internal
        returns (bool kept)
    {
        UserReservation memory reservation = _userReservations[user];
        if (
            reservation.labelhash == labelhash && !_isEvicted(reservation)
                && !_isExpired(_reservationEntries[labelhash][reservation.index].joinedAt)
        ) {
            return true;
        }
        _dropReservation(deps, user, reservation, 0);
    }

    /// @notice Clears up to `maxSteps` expired or emptied entries from the front of the queue.
    /// @dev Every entry visited costs a storage read, and a gateway call runs under a fixed weight
    /// limit, so a call clears at most `maxSteps` entries and keeps that progress; a later call
    /// carries on. Clearing writes nothing per entry: entries and pointers stay below the new
    /// front, where they read as gone (@custom:function _isEvicted), and queue indices only ever
    /// grow.
    /// When clearing reaches an active reservation, PopRules moves to that user, unless it is
    /// `claimant`, whose claim in the same call releases the slot. When it empties the queue, the
    /// PopRules slot is released, unless the caller is `refilling` it in the same call: then the
    /// slot and its label are kept and `slotKept` is returned, so the slot moves to the new user
    /// in one PopRules call. When it stops before either, PopRules is left as it is, naming a user
    /// the queue may have moved past. That user gains nothing: the public flow rejects a reserved
    /// name for everyone, and while a name has a queue, @custom:function issuePersonhoodName
    /// decides from the queue alone. @custom:emits ReservationExpired once per expired entry
    /// cleared.
    function _advanceExpiredHead(
        Deps memory deps,
        bytes32 labelhash,
        uint256 maxSteps,
        bool refilling,
        address claimant
    )
        internal
        returns (bool slotKept)
    {
        ReservationQueueMeta memory meta = _reservationMeta[labelhash];
        uint64 head = meta.head;
        uint64 tail = meta.tail;
        // An empty queue holds no PopRules slot and no label, so there is nothing to clear.
        if (head == tail) return false;
        address activeHead;
        // Read once: every entry visited compares against it.
        uint64 duration = reservationDuration;

        for (uint256 steps; head < tail; ++head) {
            ReservationEntry memory entry = _reservationEntries[labelhash][head];
            if (entry.owner != address(0) && entry.joinedAt + duration >= block.timestamp) {
                activeHead = entry.owner;
                break;
            }
            if (steps == maxSteps) break;
            ++steps;
            // An empty entry is one its owner already left.
            if (entry.owner != address(0)) emit ReservationExpired(labelhash, entry.owner);
        }
        if (head == meta.head) return false;

        _reservationMeta[labelhash] = ReservationQueueMeta({head: head, tail: tail});
        if (head == tail) {
            if (refilling) return true;
            _releasePopRulesSlot(deps, labelhash);
        } else if (activeHead != address(0) && activeHead != claimant) {
            _syncPopRulesToHead(deps, labelhash, activeHead);
        }
    }

    /// @notice Drops `user`'s own reservation entry, if any, and records that it happened.
    /// @dev The single path by which a user's entry leaves a queue other than by expiry or by a
    /// claim: an explicit relinquish, a standalone personhood-name issuance, and a re-reservation
    /// that moves the user to another queue. @custom:emits ReservationRelinquished only when the
    /// user held an entry, so an indexer can rebuild every queue from events alone. `maxSteps`
    /// bounds the clearing that follows when the user was at the front of their queue: a gateway
    /// call passes 0, leaving the emptied entry for the next call on that name, and a signed
    /// relinquish clears the whole queue.
    function _dropUserReservation(Deps memory deps, address user, uint256 maxSteps) internal {
        _dropReservation(deps, user, _userReservations[user], maxSteps);
    }

    /// @notice Body of @custom:function _dropUserReservation for a caller that has already read
    /// `user`'s reservation.
    function _dropReservation(
        Deps memory deps,
        address user,
        UserReservation memory reservation,
        uint256 maxSteps
    )
        internal
    {
        bytes32 labelhash = reservation.labelhash;
        if (labelhash == bytes32(0)) return;
        if (_isEvicted(reservation)) {
            // A claim already ended this reservation; only the pointer is left to clear.
            delete _userReservations[user];
            return;
        }
        _removeUserFromQueue(deps, user, reservation, maxSteps);
        emit ReservationRelinquished(labelhash, user);
    }

    /// @notice Removes `user` from whichever reservation queue they currently occupy.
    /// @dev The user's entry is deleted in place. When it was the front of the queue and
    /// `maxSteps` is not zero, @custom:function _advanceExpiredHead clears up to `maxSteps`
    /// entries from there, the emptied entry among them, and moves PopRules to the next user with
    /// an active reservation or releases it when none is left. Otherwise the front and PopRules
    /// stay unchanged. Emits nothing itself; callers go through
    /// @custom:function _dropUserReservation. `reservation` is the user's live reservation,
    /// already read by the caller.
    function _removeUserFromQueue(
        Deps memory deps,
        address user,
        UserReservation memory reservation,
        uint256 maxSteps
    )
        internal
    {
        bytes32 labelhash = reservation.labelhash;
        uint64 entryIndex = reservation.index;

        delete _userReservations[user];
        delete _reservationEntries[labelhash][entryIndex];

        if (maxSteps != 0 && entryIndex == _reservationMeta[labelhash].head) {
            _advanceExpiredHead(deps, labelhash, maxSteps, false, address(0));
        }
    }

    /// @notice Validates a device name `stem.NN` and derives `(labelhash, node)`.
    /// @dev The stem is lowercase letters only, so this rejects a stem carrying a digit or a
    /// hyphen before any node is derived. `node` is the hierarchical subnode `stem` under the
    /// numeric container `NN`, the node a resolver reaches by walking the dotted name, and
    /// `labelhash` stays the keccak of the whole label so it is a stable text identifier for events
    /// and the reservation queue. `legacy` selects the label error, as in
    /// @custom:function _requireDeviceLabel.
    function _validateDeviceLabel(
        Deps memory deps,
        string memory deviceLabel,
        bool legacy
    )
        internal
        view
        returns (bytes32 labelhash, bytes32 node)
    {
        _requireDeviceLabel(deviceLabel.isDeviceLabelMemory(), legacy);
        labelhash = LabelUtils.labelhashMemory(deviceLabel);
        node = _deviceSubnode(deps, deviceLabel);
    }

    /// @notice Derives the hierarchical subnode for a device name `<stem>.<suffix>`.
    /// @dev Splits at the separator and walks `suffix.tld` then `stem` under it, so a device name
    /// resolves as `stem` beneath its numeric container rather than as a hash of the whole label.
    /// Shared by @custom:function _validateDeviceLabel and pending-claim settlement so every
    /// consumer agrees on one node.
    /// @param deviceLabel Device name held in memory, e.g. `alice.01`.
    /// @return subnode Namehash of `stem` under `suffix.tld`.
    function _deviceSubnode(
        Deps memory deps,
        string memory deviceLabel
    )
        internal
        view
        returns (bytes32 subnode)
    {
        subnode = SubnodeUtils.deviceSubnodeOf(_tldNodeOf(deps), deviceLabel);
    }

    /// @notice Validates a personhood name and derives `(labelhash, node)`.
    /// @dev Letters only, so this is stricter than a DNS label: a hyphen or an interior digit
    /// is rejected here even though @custom:function StringUtils.isSingleLabel would admit it.
    /// `legacy` selects the label error, as in @custom:function _requirePersonhoodLabel.
    function _validatePersonhoodLabel(
        Deps memory deps,
        string calldata label,
        bool legacy
    )
        internal
        view
        returns (bytes32 labelhash, bytes32 node)
    {
        // Letters only, matching the gateway's personhood-name rule: a personhood name is a name
        // a person chose, so it admits no digits and no hyphens. Classification does not cover
        // this on its own: a label carrying a digit or a hyphen is measured as written, so one of
        // six or more characters classifies as Personhood or NoStatus and would otherwise pass.
        _requirePersonhoodLabel(label.isPersonhoodLabel(), legacy);
        (labelhash, node) = LabelUtils.deriveNode(_tldNodeOf(deps), label);
    }

    /// @notice Validates a personhood name as reservable and returns its hashes.
    /// @dev Shared by both reservation paths so the guard cannot drift between them. Runs four
    /// checks and reverts on the first failure, before any reservation state is mutated: the label
    /// must be a letters-only personhood label, which makes it its own base name, classify outside
    /// the governance-reserved tier, have no owner on the registrar, and hold no live grant on the
    /// name whitelist, which only its grantee may register. The owner check is the fix
    /// for a reservation queued over an already-registered name: the queue keys by base name, so
    /// such a reservation could never be redeemed yet would hold the base name, and so every device
    /// name with that stem, for the full reservation window. `exists` (owner set) mirrors exactly
    /// what makes the eventual claim's mint revert, so a label that passes here is one a claim can
    /// still register.
    function _validateReservablePersonhoodLabel(
        Deps memory deps,
        string calldata label,
        bool legacy
    )
        internal
        view
        returns (bytes32 labelhash, bytes32 node)
    {
        (labelhash, node) = _validatePersonhoodLabel(deps, label, legacy);

        (IPopRules.PopStatus required,,) = PopClassification.classify(label);
        _requirePersonhoodLabel(required != IPopRules.PopStatus.Reserved, legacy);
        require(!_registrarOf(deps).exists(uint256(node)), PersonhoodNameUnavailable());
        _requireNotGranted(node);
    }

    /// @notice Reverts when the name at `node` holds a live grant on the name whitelist.
    /// @dev A granted name is registered only through the public controller's
    /// `registerReserved`, which spends the grant, so the gateway neither issues nor reserves it,
    /// for any user. Reverts @custom:reverts PersonhoodNameUnavailable, an error the gateway
    /// already decodes. A network with no whitelist configured has no grants to honour. Reads by
    /// node, so the whitelist makes no TLD lookup of its own inside the gateway's weight limit.
    function _requireNotGranted(bytes32 node) internal view {
        address whitelist = protocolRegistry.get(DotnsConstants.NAME_WHITELIST);
        if (whitelist == address(0)) return;
        require(
            IDotnsNameWhitelist(whitelist).granteeOfNode(node) == address(0),
            PersonhoodNameUnavailable()
        );
    }

    /// @notice Reverts with the device-label error the caller decodes when `ok` is false.
    /// @dev `legacy` is set only on the @custom:contract IDotnsPopControllerLegacy entrypoints,
    /// whose callers decode @custom:reverts InvalidLiteLabel; every other path reverts
    /// @custom:reverts InvalidDeviceLabel.
    function _requireDeviceLabel(bool ok, bool legacy) internal pure {
        if (ok) return;
        if (legacy) revert InvalidLiteLabel();
        revert InvalidDeviceLabel();
    }

    /// @notice Reverts with the personhood-label error the caller decodes when `ok` is false.
    /// @dev `legacy` is set only on the @custom:contract IDotnsPopControllerLegacy entrypoints,
    /// whose callers decode @custom:reverts InvalidBaseLabel; every other path reverts
    /// @custom:reverts InvalidPersonhoodLabel.
    function _requirePersonhoodLabel(bool ok, bool legacy) internal pure {
        if (ok) return;
        if (legacy) revert InvalidBaseLabel();
        revert InvalidPersonhoodLabel();
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

    /// @notice Resolves the registry via the protocol registry.
    function _registry() internal view returns (IDotnsRegistry) {
        return IDotnsRegistry(protocolRegistry.get(DotnsConstants.REGISTRY));
    }

    /// @notice Returns PopRules, reading it from the protocol registry on first use in `deps`.
    function _rulesOf(Deps memory deps) internal view returns (IPopRules rules) {
        rules = deps.rules;
        if (address(rules) == address(0)) deps.rules = rules = _popRules();
    }

    /// @notice Returns the registrar, reading it from the protocol registry on first use in
    /// `deps`.
    function _registrarOf(Deps memory deps) internal view returns (IDotnsRegistrar registrar) {
        registrar = deps.registrar;
        if (address(registrar) == address(0)) deps.registrar = registrar = _registrar();
    }

    /// @notice Returns the registry, reading it from the protocol registry on first use in
    /// `deps`.
    function _registryOf(Deps memory deps) internal view returns (IDotnsRegistry registry) {
        registry = deps.registry;
        if (address(registry) == address(0)) deps.registry = registry = _registry();
    }

    /// @notice Returns the PoP resolver, reading it from the protocol registry on first use in
    /// `deps`.
    function _popResolverOf(Deps memory deps) internal view returns (IDotnsPopResolver resolver) {
        resolver = deps.popResolver;
        if (address(resolver) == address(0)) deps.popResolver = resolver = _popResolver();
    }

    /// @notice Returns the store factory, reading it from the protocol registry on first use in
    /// `deps`.
    function _storeFactoryOf(Deps memory deps) internal view returns (IStoreFactory factory) {
        factory = deps.storeFactory;
        if (address(factory) == address(0)) deps.storeFactory = factory = _storeFactory();
    }

    /// @notice Returns the TLD node, reading it from the protocol registry on first use in
    /// `deps`.
    /// @dev The TLD node is a namehash, so zero never names a real TLD and serves as "not read
    /// yet".
    function _tldNodeOf(Deps memory deps) internal view returns (bytes32 tldNode) {
        tldNode = deps.tldNode;
        if (tldNode == bytes32(0)) deps.tldNode = tldNode = protocolRegistry.tldNode();
    }

    /// @notice Registers the device name `stem.suffix` for `owner` beneath its numeric container.
    /// @dev The container is checked, and minted on first use, only until this contract has seen
    /// it once; after that the registry's own parent authorisation in
    /// @custom:function IDotnsRegistry.setSubnodeOwner is the guard. A container this contract
    /// minted is soulbound to it, so it never changes hands afterwards.
    function _registerDeviceSubname(
        Deps memory deps,
        string memory suffix,
        string memory stem,
        address owner
    )
        internal
        returns (bytes32 subnode)
    {
        bytes32 parentNode =
            LabelUtils.namehashUnder(_tldNodeOf(deps), LabelUtils.labelhashMemory(suffix));
        if (!_deviceContainers[parentNode]) _ensureDeviceContainer(deps, parentNode);

        subnode = _registryOf(deps)
            .setSubnodeOwner(
                IDotnsRegistry.SubnodeRecord({
                parentNode: parentNode,
                subLabel: stem,
                parentLabel: suffix,
                owner: owner,
                persist: false
            })
            );
    }

    /// @notice Mints the numeric container `parentNode` for this contract when it does not exist
    /// yet, or checks that this contract owns it, and records that it is ready.
    /// @dev Reverts with @custom:reverts IDotnsRegistry.NotAuthorised when someone else holds the
    /// container, so a name registered elsewhere is never used as a device container.
    function _ensureDeviceContainer(Deps memory deps, bytes32 parentNode) internal {
        SubnodeUtils.ensureParent(_registrarOf(deps), _registryOf(deps), parentNode);
        _deviceContainers[parentNode] = true;
    }

    /// @notice Writes the new head of the queue into PopRules so the public commit-reveal flow
    /// rejects registrations of this base name for anyone other than `newHead`.
    /// @dev Callers guarantee `newHead` is non-zero (the queue holds a live entry) and that
    /// `_reservedBaseLabel[labelhash]` is non-empty (any non-empty queue had its first head
    /// write the slot). @custom:function IPopRules.reassignBaseNameForPop moves the slot in one
    /// call; this contract stamped it, so PopRules' ownership gate admits the move.
    function _syncPopRulesToHead(Deps memory deps, bytes32 labelhash, address newHead) internal {
        _rulesOf(deps).reassignBaseNameForPop(_reservedBaseLabel[labelhash], newHead);
        emit ReservationHeadAdvanced(labelhash, newHead);
    }

    /// @notice Clears the PopRules slot and the local label bookkeeping when the queue empties
    /// (claim, last-relinquish, last-expire).
    function _releasePopRulesSlot(Deps memory deps, bytes32 labelhash) internal {
        string memory reservedLabel = _reservedBaseLabel[labelhash];
        if (bytes(reservedLabel).length == 0) return;
        _rulesOf(deps).releaseBaseName(reservedLabel);
        delete _reservedBaseLabel[labelhash];
    }

    /// @notice Internal check enforcing a Root origin.
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
