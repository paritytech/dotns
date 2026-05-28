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
/// governance-reserved labels (@custom:reverts InvalidBaseLabel), and the lite leg's
/// `isSingleDotLiteLabel` format guard guarantees the stripped lite label cannot classify
/// as `Reserved`. Native-token pricing is bypassed entirely; the gateway pays no rent.
///
/// Decoupling:
/// This contract does not import or call `IDotnsRegistrarController`. The public
/// commit-reveal controller is equally unaware of this one. Cross-flow collision handling
/// relies on two distinct properties, neither of which requires the two controllers to know
/// about each other:
/// (1) Lite-person labels (`NAMEXX`) share the public namespace: they are just DNS labels
/// with exactly two trailing digits. First-to-mint wins at the ERC721 layer, so a lite-user
/// and a public registrant cannot hold the same flat label simultaneously. Keeping one
/// namespace removes the ambiguity downstream tooling (dotli, dweb) would see with a
/// separate separator form.
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

    /// @notice Selector for the typed @custom:function reserveLiteName overload.
    /// @dev Hard-coded to disambiguate from the `(bytes)` overload at compile time. Must stay
    /// in sync with the @custom:struct LiteRegistration field layout.
    bytes4 private constant SELECTOR_RESERVE_LITE =
        bytes4(keccak256("reserveLiteName((string,address,bytes))"));

    /// @notice Selector for the typed @custom:function reserveBaseName overload.
    /// @dev `BaseReservation` is `(LiteRegistration, string)` and `LiteRegistration` is
    /// `(string,address,bytes)`, hence the nested tuple in the canonical signature.
    bytes4 private constant SELECTOR_RESERVE_BASE =
        bytes4(keccak256("reserveBaseName(((string,address,bytes),string))"));

    /// @notice Selector for the typed @custom:function registerBaseName overload.
    /// @dev `Link` is `(uint8,string,bytes)` because `LinkKind` is an enum.
    bytes4 private constant SELECTOR_REGISTER_BASE =
        bytes4(keccak256("registerBaseName((string,address,(uint8,string,bytes)))"));

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
    uint64 public reservationDuration;

    /// @notice Per-user record of a freshly minted name whose `LabelStore` write was
    /// deferred because the user had no store at mint time.
    /// @dev Set when the gateway path mints for a user with no `LabelStore`. Cleared
    /// on settlement via @custom:function claimLabelStore or on expiry via
    /// @custom:function expirePendingClaim. At most one entry per address; expiry is
    /// measured from `mintedAt` against `reservationDuration`.
    mapping(address user => PendingClaim claim) internal _pendingClaims;

    /// @notice Enumeration set of users holding a live pending claim.
    /// @dev Membership equals the live key set of `_pendingClaims`. Used by
    /// `pendingClaimUserCount` and `pendingClaimUsers` for paginated enumeration.
    EnumerableSet.AddressSet private _pendingClaimUsers;

    /// @dev Reserved storage space to allow for layout changes in the future.
    uint256[50] private __gap;

    /// @notice Restricts calls to the address registered as the PoP gateway
    ///         on the protocol registry.
    /// @dev Authority is delegated wholly to the registered gateway, which is
    ///      the Root gateway dispatcher. Any caller other than the registered
    ///      gateway is rejected with NotGateway. The Root-authority check
    ///      itself lives in the dispatcher because the revive System
    ///      precompile is only meaningful in the frame that is the direct
    ///      callee of Root, which is the dispatcher and never this UUPS
    ///      implementation.
    modifier onlyGateway() {
        _onlyGateway();
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
        uint64 reservationDuration_,
        address initialOwner
    )
        external
        initializer
    {
        require(
            reservationDuration_ >= MIN_RESERVATION_DURATION,
            ReservationDurationTooLow(reservationDuration_)
        );
        __Ownable_init(initialOwner);
        __ERC165_init();
        protocolRegistry = registry;
        reservationDuration = reservationDuration_;
        emit ReservationDurationSet(reservationDuration_);
    }

    /// @inheritdoc IDotnsPopController
    function reserveLiteName(LiteRegistration calldata params) external override onlyGateway {
        _reserveLite(params);
    }

    /// @inheritdoc IDotnsPopController
    function reserveLiteName(bytes calldata payload) external override onlyGateway {
        _dispatchTyped(SELECTOR_RESERVE_LITE, payload);
    }

    /// @inheritdoc IDotnsPopController
    function reserveBaseName(BaseReservation calldata params) external override onlyGateway {
        _reserveLite(params.lite);

        if (bytes(params.reservedBaseLabel).length != 0) {
            // Governance-reserved labels can never be enqueued through the gateway. Runs
            // before any queue mutation so a Reserved label never touches the queue.
            (IPopRules.PopStatus required,) = _popRules().classifyName(params.reservedBaseLabel);
            require(
                required != IPopRules.PopStatus.Reserved
                    && _popRules().isBaseName(params.reservedBaseLabel),
                InvalidBaseLabel()
            );

            bytes32 reservedHash = _validateBaseLabelHash(params.reservedBaseLabel);
            _advanceExpiredHead(reservedHash);

            // `_removeUserFromQueue` early-returns when the user has no active
            // reservation, so no outer guard is needed.
            _removeUserFromQueue(params.lite.user);
            _enqueueReservation(reservedHash, params.reservedBaseLabel, params.lite.user);
        }
    }

    /// @inheritdoc IDotnsPopController
    function reserveBaseName(bytes calldata payload) external override onlyGateway {
        _dispatchTyped(SELECTOR_RESERVE_BASE, payload);
    }

    /// @notice Lite-only mint shared by @custom:function reserveLiteName and the lite leg
    /// of @custom:function reserveBaseName.
    /// @dev Gateway attestation is the authority for personhood on this path; the on-chain
    /// precompile is not consulted. The dotted-format check accepts only `stem.NN`, then
    /// PopRules classification must identify the flattened label as `PopLite` before minting.
    /// Takes the @custom:struct LiteRegistration struct directly so both call sites pass the
    /// same payload shape: the typed entrypoint forwards its own `params`, the `reserveBaseName`
    /// entrypoint forwards `params.lite`.
    function _reserveLite(LiteRegistration calldata params) internal {
        require(params.liteLabel.isSingleDotLiteLabel(), InvalidLiteLabel());

        string memory liteLabel = params.liteLabel.stripDots();
        (IPopRules.PopStatus required,) = _popRules().classifyName(liteLabel);
        require(required == IPopRules.PopStatus.PopLite, InvalidLiteLabel());
        (bytes32 labelhash, bytes32 node) = _validateLiteLabel(liteLabel);

        _advanceExpiredHead(labelhash);

        _completeGatewayRegistration(
            params.user, liteLabel, labelhash, node, params.chatKey, bytes32(0)
        );

        emit LiteNameReserved(labelhash, params.user, liteLabel);
    }

    /// @inheritdoc IDotnsPopController
    function registerBaseName(bytes calldata payload) external override onlyGateway {
        _dispatchTyped(SELECTOR_REGISTER_BASE, payload);
    }

    /// @inheritdoc IDotnsPopController
    function registerBaseName(FullRegistration calldata params) external override onlyGateway {
        Link calldata link = params.link;
        address user = params.user;
        string calldata label = params.label;

        // Governance-reserved labels can never be minted through the gateway. Runs ahead of
        // the reservation-axis detection so a Reserved label never touches the queue.
        (IPopRules.PopStatus required,) = _popRules().classifyName(label);
        require(required != IPopRules.PopStatus.Reserved, InvalidBaseLabel());

        (bytes32 labelhash, bytes32 node) = _validateBaseLabel(label);

        _advanceExpiredHead(labelhash);

        // Reservation axis: `user` is claiming iff they hold the live head-of-queue
        // reservation on `label`. Orthogonal to `link.kind`.
        ReservationQueueMeta memory meta = _reservationMeta[labelhash];
        bool isClaim = _userReservations[user].labelhash == labelhash && meta.head < meta.tail
            && _reservationEntries[labelhash][meta.head].owner == user;

        // Standalone-mint holder guard: when the caller is not claiming their
        // own live head, a live reservation held by another user blocks the
        // mint. Expired or tombstoned heads do not block; those are handled by
        // the queue garbage-collection paths.
        if (!isClaim && meta.head < meta.tail) {
            address head = _reservationEntries[labelhash][meta.head].owner;
            if (
                head != address(0) && head != user
                    && !_isExpired(_reservationEntries[labelhash][meta.head].joinedAt)
            ) {
                revert NotHolder(user, labelhash);
            }
        }

        if (isClaim) {
            _clearQueue(labelhash);
        } else {
            // Silent relinquish: any pending queue entry the user holds is removed.
            // `_removeUserFromQueue` early-returns when there is nothing to remove.
            _removeUserFromQueue(user);
        }

        // Chat-key axis: `link.kind` selects whether a fresh key is persisted on the
        // resolver or the entry is linked back to (and inherits the key from) a prior
        // lite-person username.
        bytes32 liteLabelhash;
        bytes memory chatKeyToPersist;
        if (link.kind == LinkKind.LiteUsername) {
            string memory liteLabel = link.liteLabel.stripDots();
            require(link.liteLabel.isSingleDotLiteLabel(), InvalidLiteLabel());
            liteLabelhash = _validateLiteLabelHash(liteLabel);
            bytes32 liteNode = LabelUtils.namehash(liteLabelhash);
            // Bind chat-key inheritance to lite-token ownership: the registrant must
            // currently hold the lite identity whose chat key they inherit, so a
            // graduating user's full name copies their own key rather than any
            // attestor's. The registrar mints tokenId = `uint256(node)`, so the
            // ownership check goes through the node (namehash), not the bare labelhash.
            require(
                _registrar().ownerOf(uint256(liteNode)) == user,
                LiteLabelNotOwnedByUser(user, liteLabelhash)
            );
            chatKeyToPersist = _popResolver().chatKey(liteNode);
        } else {
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
        bytes32 labelhash = _validateBaseLabelHash(reservedBaseLabel);
        _advanceExpiredHead(labelhash);
    }

    /// @inheritdoc IDotnsPopController
    function relinquishReservation() external override {
        bytes32 labelhash = _userReservations[msg.sender].labelhash;
        require(labelhash != bytes32(0), NoActiveReservation(msg.sender));
        _removeUserFromQueue(msg.sender);
        emit ReservationRelinquished(labelhash, msg.sender);
    }

    /// @inheritdoc IDotnsPopController
    function claimLabelStore() external override {
        PendingClaim memory claim_ = _pendingClaims[msg.sender];
        require(claim_.mintedAt != 0 && !_isExpired(claim_.mintedAt), NoPendingClaim(msg.sender));

        bytes32 labelhash = LabelUtils.labelhashMemory(claim_.label);
        bytes32 node = LabelUtils.namehash(labelhash);

        // Stores are historical, not ownership-bound: if the caller already has a
        // `LabelStore` from any path (this controller's prior settlement, or the
        // public registrar controller's mint flow), reuse it. Only deploy when no
        // store exists, which keeps the settle step idempotent across controllers.
        IStoreFactory factory = _storeFactory();
        address store = factory.getLabelStore(msg.sender);
        if (store == address(0)) {
            store = factory.deployLabelStoreFor(msg.sender);
        }

        _writeRecord(store, node, claim_.label);

        _clearPendingClaim(msg.sender);

        emit PendingClaimSettled(msg.sender, labelhash, store);
        emit NameRegistered(claim_.label, labelhash, msg.sender, store);
    }

    /// @inheritdoc IDotnsPopController
    function expirePendingClaim(address user) external override {
        PendingClaim memory claim_ = _pendingClaims[user];
        require(claim_.mintedAt != 0, NoPendingClaim(user));
        require(_isExpired(claim_.mintedAt), PendingClaimNotExpired(user));

        bytes32 labelhash = LabelUtils.labelhashMemory(claim_.label);

        _clearPendingClaim(user);

        emit PendingClaimExpired(user, labelhash);
    }

    /// @inheritdoc IDotnsPopController
    function isReservedForClaim(string calldata reservedBaseLabel)
        external
        view
        override
        returns (bool reserved, address holder)
    {
        bytes32 labelhash = _validateBaseLabelHash(reservedBaseLabel);
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
    function pendingClaim(address user)
        external
        view
        override
        returns (PendingClaim memory claim_)
    {
        return _pendingClaims[user];
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

        users = new address[](count);
        for (uint256 i; i < count; ++i) {
            users[i] = _pendingClaimUsers.at(offset + i);
        }
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

    /// @notice Mints a name, wires forward registry, and persists PoP-flow records (chat
    /// key, lite link) on the PoP resolver. The owner's Store write is handled by
    /// `_persistLabel`, which writes directly when the owner already has a `LabelStore`
    /// and stashes a pending claim otherwise.
    /// @dev The mint + forward-registry pair is delegated to
    /// @custom:function RegistrationUtils.registerAndStore so this flow and the public
    /// commit-reveal flow share exactly one implementation of that sequence. The label is passed
    /// empty so
    /// the registrar does not deploy a `LabelStore`; substrate Root cannot run the
    /// `LabelStore` constructor under `pallet-revive`. PoP-flow per-name records (chat key,
    /// lite link) are persisted eagerly on @custom:contract IDotnsPopResolver here, before
    /// the label is written, so the resolver carries the full identity record from mint time
    /// regardless of whether the owner already has a `LabelStore`. The Store stays
    /// labels-only. Emits @custom:emits NameRegistered on the warm path; the cold path
    /// emits @custom:emits PendingClaimStashed and graduates to NameRegistered when the
    /// user settles.
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
        RegistrationUtils.registerAndStore(
            RegistrationUtils.RegistrationContext({
                protocolRegistry: protocolRegistry,
                user: user,
                label: "",
                labelhash: labelhash,
                node: node
            })
        );

        if (chatKeyBytes.length != 0) {
            _popResolver().setChatKey(node, chatKeyBytes);
        }
        if (liteLabelhash != bytes32(0)) {
            _popResolver().setLiteLink(node, liteLabelhash);
        }

        address store = _persistLabel(user, label, labelhash, node);

        if (store != address(0)) {
            emit NameRegistered(label, labelhash, user, store);
        }
    }

    /// @notice Writes a freshly minted name's label, deferring to a pending claim when
    /// the user has no `LabelStore` yet.
    /// @dev Warm path: when `factory.getLabelStore(user)` is non-zero the label is written
    /// directly into the existing store under `node` (matching the registrar's
    /// `_writeOwnerLabel` key convention). Cold path: the label is stashed and the call
    /// returns `address(0)`. Chat-key persistence on the PoP resolver happens eagerly in
    /// @custom:function _completeGatewayRegistration before this function runs, so the
    /// resolver record is independent of whether the owner already has a `LabelStore`.
    /// @param user Owner of the new name.
    /// @param label Bare DNS label (no TLD) being recorded.
    /// @param labelhash `keccak256(bytes(label))`.
    /// @param node `namehash(labelhash)`; the canonical `LabelStore` key for the entry.
    /// @return store The user's `LabelStore` address on the warm path, zero on the cold
    /// path.
    function _persistLabel(
        address user,
        string memory label,
        bytes32 labelhash,
        bytes32 node
    )
        internal
        returns (address store)
    {
        store = _storeFactory().getLabelStore(user);

        if (store == address(0)) {
            _stashPendingClaim(user, label, labelhash);
            return store;
        }

        _writeRecord(store, node, label);
    }

    /// @notice Writes a name's label into `store`.
    /// @dev Single canonical persistence step shared by the warm gateway path and the
    /// user-signed @custom:function claimLabelStore. The store key is `node`, matching
    /// the registrar's `_writeOwnerLabel` convention.
    /// @param store Owner's `LabelStore` proxy.
    /// @param node `namehash(labelhash)` for the entry.
    /// @param label Bare DNS label (no TLD); the TLD is appended on write.
    function _writeRecord(address store, bytes32 node, string memory label) internal {
        ILabelStore(store).storeLabel(node, string.concat(label, DotnsConstants.TLD));
    }

    /// @notice Records a deferred binding for `user` and adds them to the enumeration set.
    /// @dev Reverts with `PendingClaimExists` when the user already holds an entry. Emits
    /// @custom:emits PendingClaimStashed.
    function _stashPendingClaim(address user, string memory label, bytes32 labelhash) internal {
        require(_pendingClaims[user].mintedAt == 0, PendingClaimExists(user));

        _pendingClaims[user] = PendingClaim({label: label, mintedAt: uint64(block.timestamp)});
        _pendingClaimUsers.add(user);

        emit PendingClaimStashed(user, labelhash, label);
    }

    /// @notice Clears a user's pending claim and removes them from the enumeration set.
    function _clearPendingClaim(address user) internal {
        delete _pendingClaims[user];
        _pendingClaimUsers.remove(user);
    }

    /// @notice Returns whether a queue entry is expired relative to `block.timestamp`.
    function _isExpired(uint64 joinedAt) internal view returns (bool) {
        return joinedAt + reservationDuration <= block.timestamp;
    }

    /// @notice Appends a new reservation entry to the tail of the queue for `labelhash`.
    /// @dev Reverts if the queue is full or the user already holds a reservation. When the
    /// enqueued entry is the new head of an empty queue, the controller also reserves the
    /// base name on PopRules so the public commit-reveal flow sees the reservation through
    /// its existing `priceWithCheck` guard. Subsequent waiters only live in the local queue
    /// until they are promoted.
    function _enqueueReservation(
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
            // PopRules keys reservations by the digit-stripped stem; normalise here so
            // the slot the public commit-reveal flow reads through `priceWithCheck`
            // and the slot this controller writes are addressed by the same key.
            IPopRules rules = _popRules();
            string memory stem = rules.stripDigits(baseLabel);
            _reservedBaseLabel[labelhash] = stem;
            rules.reserveBaseNameForPop(stem, user);
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
                delete _reservationEntries[labelhash][head];
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
        bytes32 labelhash = _userReservations[user].labelhash;
        if (labelhash == bytes32(0)) return;

        uint64 entryIndex = _userReservations[user].index;
        ReservationQueueMeta memory queueMeta = _reservationMeta[labelhash];

        delete _userReservations[user];
        delete _reservationEntries[labelhash][entryIndex];

        if (entryIndex == queueMeta.head) {
            _advanceExpiredHead(labelhash);
        }
    }

    /// @notice Validates a lite-person `NAMEXX` label and derives `(labelhash, node)`.
    function _validateLiteLabel(string memory liteLabel)
        internal
        pure
        returns (bytes32 labelhash, bytes32 node)
    {
        require(liteLabel.isLitePersonLabelMemory(), InvalidLiteLabel());
        labelhash = LabelUtils.labelhashMemory(liteLabel);
        node = LabelUtils.namehash(labelhash);
    }

    /// @notice Validates a lite-person `NAMEXX` label and returns its labelhash.
    /// @dev Node is not needed for every call site; this overload avoids the extra keccak
    /// when only the labelhash is used.
    function _validateLiteLabelHash(string memory liteLabel)
        internal
        pure
        returns (bytes32 labelhash)
    {
        require(liteLabel.isLitePersonLabelMemory(), InvalidLiteLabel());
        labelhash = LabelUtils.labelhashMemory(liteLabel);
    }

    /// @notice Validates a base (full-person) DNS label and derives `(labelhash, node)`.
    function _validateBaseLabel(string calldata baseLabel)
        internal
        pure
        returns (bytes32 labelhash, bytes32 node)
    {
        require(baseLabel.isSingleLabel(), InvalidBaseLabel());
        (labelhash, node) = LabelUtils.deriveNode(baseLabel);
    }

    /// @notice Validates a base (full-person) DNS label and returns its labelhash.
    function _validateBaseLabelHash(string calldata baseLabel)
        internal
        pure
        returns (bytes32 labelhash)
    {
        require(baseLabel.isSingleLabel(), InvalidBaseLabel());
        labelhash = LabelUtils.labelhash(baseLabel);
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
    function _syncPopRulesToHead(bytes32 labelhash, address newHead) internal {
        string memory baseLabel = _reservedBaseLabel[labelhash];
        if (bytes(baseLabel).length == 0 || newHead == address(0)) return;
        // Release the slot held by the prior head before writing the new one,
        // because PopRules rejects `reserveBaseNameForPop` when the live slot
        // belongs to someone other than the caller-supplied user.
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

    /// @notice Internal check enforcing PoP-gateway-only access.
    /// @dev Authorises a call when the caller matches the address registered
    ///      as the PoP gateway on the protocol registry. The dispatcher
    ///      registered there is responsible for proving substrate Root
    ///      authority via the revive System precompile; this contract trusts
    ///      that forwarded calls already carry that authority. Reverts with
    ///      NotGateway on failure, including when the registry key is unset.
    function _onlyGateway() internal view {
        address gw = protocolRegistry.get(DotnsConstants.POP_GATEWAY);
        require(gw != address(0) && msg.sender == gw, NotGateway(msg.sender));
    }

    /// @notice Routes a raw cross-chain payload to the typed entrypoint identified by `selector`.
    /// @dev Prepends `selector` to `payload` and `delegatecall`s `address(this)` so the typed
    /// overload runs in the original call context, making the typed path the single source of
    /// truth. The `bytes` payload from the cross-chain caller is already
    /// `abi.encode(StructTuple)`, so concatenating `selector` with `payload` is exactly the
    /// calldata the typed overload expects. Reverts bubble up byte-for-byte so the caller sees
    /// the same error it would have seen on a direct typed call. The delegatecall target is
    /// hard-coded to `address(this)` and `selector` is one of three module-private constants
    /// pointing at this contract's own typed entrypoints, so storage context is preserved and
    /// no external code can run in this contract's frame. @custom:function _onlyGateway runs
    /// on both the outer bytes overload and the inner typed overload; both checks read the
    /// same registry slot.
    /// @custom:oz-upgrades-unsafe-allow delegatecall
    function _dispatchTyped(bytes4 selector, bytes calldata payload) private {
        (bool ok, bytes memory ret) = address(this).delegatecall(bytes.concat(selector, payload));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
