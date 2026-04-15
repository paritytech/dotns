// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ERC165Upgradeable
} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";

import {IDotnsRegistrar} from "./IDotnsRegistrar.sol";
import {IDotnsRegistry} from "../registry/IDotnsRegistry.sol";
import {IDotnsReverseResolver} from "../resolvers/IDotnsReverseResolver.sol";
import {IPopRules} from "../pop/IPopRules.sol";
import {StringUtils} from "../utils/StringUtils.sol";
import {IDotnsRegistrarController} from "./IDotnsRegistrarController.sol";
import {Store} from "../store/Store.sol";
import {IStoreFactory} from "../store/IStoreFactory.sol";
import {IStore} from "../store/IStore.sol";
import {StoreUtils} from "../utils/StoreUtils.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {DotnsProtocolRegistry} from "../registry/DotnsProtocolRegistry.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";

/// @title Dotns Registrar Controller
/// @notice Allocates .dot labels using a commit–reveal scheme.
/// @dev Orchestrates allocation, PoP validation, pricing enforcement, forward registry wiring,
///      default reverse resolution, and immutable store writing.
///
/// @dev Tokenisation:
///      - The minted ERC721 tokenId is uint256(node), where node = namehash(DOT_NODE, labelhash).
///      - The registry stores a sentinel owner (address(0)) for tokenised nodes and derives ownership
///        from the ERC721 registrar for authorisation.
///
/// @custom:security-contact admin@parity.io
contract DotnsRegistrarController is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IDotnsRegistrarController
{
    using StringUtils for *;
    using StoreUtils for IStoreFactory;

    /// @notice Upper bound for commitment validity to cap storage griefing risk.
    uint256 public constant MAX_ALLOWED_COMMITMENT_AGE = 7 days;

    /// @notice DEPRECATED: Base registrar responsible for minting name ownership.
    /// @dev Retained for UUPS storage layout compatibility. Use protocolRegistry instead.
    /// TODO: Remove on fresh deploy (not upgrade). Restore __gap accordingly.
    IDotnsRegistrar public dotnsRegistrar;

    /// @notice DEPRECATED: Forward registry storing node ownership and resolver.
    /// @dev Retained for UUPS storage layout compatibility. Use protocolRegistry instead.
    /// TODO: Remove on fresh deploy (not upgrade). Restore __gap accordingly.
    IDotnsRegistry public dotnsRegistry;

    /// @notice DEPRECATED: Reverse resolver for address -> primary name mapping.
    /// @dev Retained for UUPS storage layout compatibility. Use protocolRegistry instead.
    /// TODO: Remove on fresh deploy (not upgrade). Restore __gap accordingly.
    IDotnsReverseResolver public reverseResolver;

    /// @notice DEPRECATED: Rules enforcing PoP rules and pricing.
    /// @dev Retained for UUPS storage layout compatibility. Use protocolRegistry instead.
    /// TODO: Remove on fresh deploy (not upgrade). Restore __gap accordingly.
    IPopRules public popRules;

    /// @notice DEPRECATED: Factory for per-user Store instances.
    /// @dev Retained for UUPS storage layout compatibility. Use protocolRegistry instead.
    /// TODO: Remove on fresh deploy (not upgrade). Restore __gap accordingly.
    IStoreFactory public storeFactory;

    /// @notice Minimum age a commitment must reach before reveal.
    uint256 public minCommitmentAge;

    /// @notice Maximum age after which a commitment expires.
    uint256 public maxCommitmentAge;

    /// @notice Stores Mapping of commitment hashes to timestamp committed.
    mapping(bytes32 hash => uint256 timestamp) public commitments;

    /// @notice Whitelist for addresses allowed to call `registerReserved`.
    mapping(address user => bool isWhiteListed) public whiteList;

    /// @notice Protocol-level address registry for all DotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @notice Upper bound for the number of simultaneously queued reservations per label.
    /// @dev Keeps `expireReservation` gas bounded.
    uint16 public constant MAX_RESERVATION_QUEUE = 64;

    /// @notice Reservation queue entry: a user and the timestamp they joined the queue.
    /// @dev Packs into a single storage slot (20 + 8 bytes).
    struct ReservationEntry {
        address owner;
        uint64 joinedAt;
    }

    /// @notice Metadata describing the occupied range of a reservation queue.
    /// @dev Uses monotonically increasing indices. Active entries occupy
    ///      `[head, tail)`; `length = tail - head`. Slots past `head` are deleted as the
    ///      head advances so garbage never accumulates.
    struct ReservationQueueMeta {
        uint64 head;
        uint64 tail;
    }

    /// @notice Per-label queue metadata (head/tail pointers).
    mapping(bytes32 labelhash => ReservationQueueMeta meta) internal _reservationMeta;

    /// @notice Per-label sparse entries keyed by monotonically-increasing index.
    mapping(bytes32 labelhash => mapping(uint64 index => ReservationEntry entry)) internal
        _reservationEntries;

    /// @notice Tracks which label each user currently holds a reservation for.
    /// @dev A non-zero labelhash means the user is somewhere in the queue for that label.
    ///      Enforces "one active reservation per account".
    mapping(address user => bytes32 labelhash) internal _userReservation;

    /// @notice Records the monotonic index at which a user's reservation lives within the
    ///         queue, so non-head relinquishment can find it in O(1).
    mapping(address user => uint64 index) internal _userReservationIndex;

    /// @notice Duration (in seconds) after which a reservation entry is considered expired.
    /// @dev Mirrors `pallet_resources::UsernameReservationDuration`. Configurable by governance
    ///      via `setReservationDuration`.
    uint64 public reservationDuration;

    /// @dev Reserved storage space to allow for layout changes in the future.
    ///      Shrunk from 48 by 5 slots added above (4 mappings + `reservationDuration`).
    uint256[43] private __gap;

    /// @notice Restricts calls to the forward registry contract.
    modifier onlyRegistry() {
        _onlyRegistry();
        _;
    }

    /// @notice Restricts calls to whitelisted addresses or the owner.
    /// @dev This is used to gate the `registerReserved` function, which allows registering reserved names
    ///      without PoP checks or payment. This is necessary to allow the owner to register reserved names
    ///      for users who are already known and verified and dont need Pop checks.
    modifier onlyWhiteListedOrOwner() {
        _onlyWhiteListedOrOwner();
        _;
    }

    /// @notice Restricts calls to the privileged PoP gateway address stored in the protocol
    ///         registry under `POP_GATEWAY`.
    modifier onlyGateway() {
        _onlyGateway();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the registrar controller.
    /// @dev Validates commitment window bounds and wires dependencies.
    /// @param registrar Base registrar used for ERC721 minting.
    /// @param registry Forward registry storing node ownership and resolver.
    /// @param reverse Reverse resolver for primary name mapping.
    /// @param rules PoP rules used for eligibility and pricing.
    /// @param factory Store factory used to resolve/deploy per-user stores.
    /// @param minAge Minimum commitment age in seconds.
    /// @param maxAge Maximum commitment age in seconds.
    // TODO: On fresh deploy (not upgrade), accept IDotnsProtocolRegistry and set protocolRegistry here.
    function initialize(
        IDotnsRegistrar registrar,
        IDotnsRegistry registry,
        IDotnsReverseResolver reverse,
        IPopRules rules,
        IStoreFactory factory,
        uint256 minAge,
        uint256 maxAge
    )
        external
        initializer
    {
        __Ownable_init(msg.sender);
        __ERC165_init();

        require(maxAge > minAge, MaxCommitmentAgeTooLow());
        require(maxAge <= MAX_ALLOWED_COMMITMENT_AGE, MaxCommitmentAgeTooHigh());

        dotnsRegistrar = registrar;
        dotnsRegistry = registry;
        reverseResolver = reverse;
        popRules = rules;
        storeFactory = factory;

        minCommitmentAge = minAge;
        maxCommitmentAge = maxAge;
    }

    /// @notice Initializer for the 1.5.0 upgrade.
    /// @dev Callable exactly once via `upgradeToAndCall` to atomically install the new
    ///      implementation and set the PoP reservation duration. Using a reinitializer avoids
    ///      a race window where reservations would instantly appear expired between the
    ///      upgrade and a follow-up `setReservationDuration` call.
    /// @param _reservationDuration Initial reservation duration in seconds.
    function initializeV2(uint64 _reservationDuration) external reinitializer(2) {
        reservationDuration = _reservationDuration;
        emit ReservationDurationSet(_reservationDuration);
    }

    /// @inheritdoc IDotnsRegistrarController
    function available(string calldata label) public view override returns (bool) {
        bytes32 node;
        (, node) = _validatedLabelNode(label);
        IDotnsRegistrar registrar = IDotnsRegistrar(
            protocolRegistry.get(DotnsProtocolRegistry(address(protocolRegistry)).REGISTRAR())
        );
        return registrar.available(uint256(node));
    }

    /// @inheritdoc IDotnsRegistrarController
    function makeCommitment(Registration calldata registration)
        public
        pure
        override
        returns (bytes32 commitment)
    {
        string calldata registrationLabel = registration.label;
        address registrationOwner = registration.owner;
        bytes32 registrationSecret = registration.secret;
        bool registrationReserved = registration.reserved;

        assembly ("memory-safe") {
            let freeMemoryPointer := mload(0x40)

            let labelByteLength := registrationLabel.length
            calldatacopy(freeMemoryPointer, registrationLabel.offset, labelByteLength)

            mstore(add(freeMemoryPointer, labelByteLength), registrationOwner)

            mstore(add(freeMemoryPointer, add(labelByteLength, 0x20)), registrationSecret)

            mstore8(
                add(freeMemoryPointer, add(labelByteLength, 0x40)),
                iszero(iszero(registrationReserved))
            )

            commitment := keccak256(freeMemoryPointer, add(labelByteLength, 0x41))
        }
    }

    /// @inheritdoc IDotnsRegistrarController
    function commit(bytes32 commitment) external override {
        require(
            commitments[commitment] == 0
                || commitments[commitment] + maxCommitmentAge < block.timestamp,
            UnexpiredCommitmentExists(commitment)
        );

        commitments[commitment] = block.timestamp;
        emit NameCommitted(commitment);
    }

    /// @inheritdoc IDotnsRegistrarController
    function register(Registration calldata registration) external payable override {
        (IDotnsRegistrar registrar, bytes32 labelhash, bytes32 node) =
            _requireAvailableLabel(registration.label);

        _requireNotReservedByOther(registration.label, labelhash, registration.owner);

        _consumeCommitment(registration);

        IPopRules rules = IPopRules(
            protocolRegistry.get(DotnsProtocolRegistry(address(protocolRegistry)).POP_RULES())
        );
        IPopRules.PriceWithMeta memory priced =
            rules.priceWithCheck(registration.label, registration.owner);

        require(msg.value >= priced.price, InsufficientValue());

        bool setReverseRecord = registration.reserved && msg.sender == registration.owner;
        _completeRegistration(
            registration, registrar, labelhash, node, priced.price, setReverseRecord
        );

        if (msg.value > priced.price) {
            (bool ok,) = payable(msg.sender).call{value: msg.value - priced.price}("");
            require(ok, RefundFailed());
        }
    }

    /// @inheritdoc IDotnsRegistrarController
    function isWhiteListed(address who) external view override returns (bool) {
        return whiteList[who];
    }

    /// @inheritdoc IDotnsRegistrarController
    function whiteListAddress(address who, bool whiteListStatus) external override onlyOwner {
        whiteList[who] = whiteListStatus;
        emit WhiteListed(who, whiteListStatus);
    }

    /// @inheritdoc IDotnsRegistrarController
    function registerReserved(Registration calldata registration)
        external
        override
        onlyWhiteListedOrOwner
    {
        (IDotnsRegistrar registrar, bytes32 labelhash, bytes32 node) =
            _requireAvailableLabel(registration.label);
        _consumeCommitment(registration);

        _completeRegistration(registration, registrar, labelhash, node, 0, true);
    }

    /// @inheritdoc IDotnsRegistrarController
    function reserveBaseName(
        string calldata label,
        address user,
        bytes calldata chatKey,
        string calldata reservedLabel
    )
        external
        override
        onlyGateway
    {
        (, bytes32 labelhash, bytes32 node) = _requireAvailableLabel(label);

        _advanceExpiredHead(labelhash);
        _requireNotReservedByOther(label, labelhash, user);

        _completeGatewayRegistration(user, label, labelhash, node, chatKey, bytes32(0));

        emit LiteNameReserved(labelhash, user, label);

        if (bytes(reservedLabel).length != 0) {
            bytes32 reservedHash = keccak256(bytes(reservedLabel));
            _advanceExpiredHead(reservedHash);

            if (_userReservation[user] != bytes32(0)) {
                _removeUserFromQueue(user);
            }
            _enqueueReservation(reservedHash, user);
        }
    }

    /// @inheritdoc IDotnsRegistrarController
    function registerBaseName(
        string calldata label,
        address user,
        Link calldata link
    )
        external
        override
        onlyGateway
    {
        (, bytes32 labelhash, bytes32 node) = _requireAvailableLabel(label);

        _advanceExpiredHead(labelhash);

        if (link.kind == LinkKind.LiteUsername) {
            // Path A: claim a previously reserved username.
            require(_userReservation[user] == labelhash, NoActiveReservation(user));
            ReservationQueueMeta memory meta = _reservationMeta[labelhash];
            require(
                meta.head < meta.tail && _reservationEntries[labelhash][meta.head].owner == user,
                NotHolder(user, labelhash)
            );

            bytes32 liteLabelhash = keccak256(bytes(link.liteLabel));

            _clearQueue(labelhash);

            _completeGatewayRegistration(user, label, labelhash, node, "", liteLabelhash);

            emit BaseNameClaimed(labelhash, user, label);
            emit LiteToFullLinked(labelhash, liteLabelhash);
        } else {
            // Path B: standalone registration. Refuse if someone else holds an active
            // reservation on this label. Otherwise wipe the user's own reservation (on
            // this label or any other) so they start clean.
            _requireNotReservedByOther(label, labelhash, user);

            bytes32 userReserved = _userReservation[user];
            if (userReserved == labelhash) {
                _clearQueue(labelhash);
            } else if (userReserved != bytes32(0)) {
                _removeUserFromQueue(user);
            }

            _completeGatewayRegistration(user, label, labelhash, node, link.chatKey, bytes32(0));

            emit StandaloneNameRegistered(labelhash, user, label);
        }
    }

    /// @inheritdoc IDotnsRegistrarController
    function expireReservation(string calldata label) external override {
        bytes32 labelhash = keccak256(bytes(label));
        _advanceExpiredHead(labelhash);
    }

    /// @inheritdoc IDotnsRegistrarController
    function relinquishReservation() external override {
        bytes32 labelhash = _userReservation[msg.sender];
        require(labelhash != bytes32(0), NoActiveReservation(msg.sender));
        _removeUserFromQueue(msg.sender);
        emit ReservationRelinquished(labelhash, msg.sender);
    }

    /// @inheritdoc IDotnsRegistrarController
    function isReservedForClaim(string calldata label)
        external
        view
        override
        returns (bool reserved, address holder)
    {
        bytes32 labelhash = keccak256(bytes(label));
        ReservationQueueMeta memory meta = _reservationMeta[labelhash];
        if (meta.head >= meta.tail) {
            return (false, address(0));
        }
        ReservationEntry memory head = _reservationEntries[labelhash][meta.head];
        if (head.owner == address(0)) {
            return (false, address(0));
        }
        if (_isExpired(head.joinedAt)) {
            return (false, address(0));
        }
        return (true, head.owner);
    }

    /// @inheritdoc IDotnsRegistrarController
    function setReservationDuration(uint64 duration) external override onlyOwner {
        reservationDuration = duration;
        emit ReservationDurationSet(duration);
    }

    /// @inheritdoc ERC165Upgradeable
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IDotnsRegistrarController).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice Computes keccak256(label).
    /// @param label Label string.
    /// @return hash keccak256(label).
    function _labelhash(string calldata label) internal pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            let len := label.length
            calldatacopy(pointer, label.offset, len)
            hash := keccak256(pointer, len)
        }
    }

    /// @notice Computes namehash(DOT_NODE, labelhash).
    /// @param labelhash keccak256(label).
    /// @return node namehash.
    function _namehash(bytes32 labelhash) internal pure returns (bytes32 node) {
        bytes32 dotNode = DotnsConstants.DOT_NODE;
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, dotNode)
            mstore(add(pointer, 0x20), labelhash)
            node := keccak256(pointer, 0x40)
        }
    }

    function _validatedLabelNode(string calldata label)
        internal
        pure
        returns (bytes32 labelhash, bytes32 node)
    {
        require(label.isSingleLabel(), InvalidLabel());
        require(bytes(label).length >= 3, NameNotAvailable(label));
        labelhash = _labelhash(label);
        node = _namehash(labelhash);
    }

    function _requireAvailableLabel(string calldata label)
        internal
        view
        returns (IDotnsRegistrar registrar, bytes32 labelhash, bytes32 node)
    {
        (labelhash, node) = _validatedLabelNode(label);
        registrar = IDotnsRegistrar(
            protocolRegistry.get(DotnsProtocolRegistry(address(protocolRegistry)).REGISTRAR())
        );
        require(registrar.available(uint256(node)), NameNotAvailable(label));
    }

    function _consumeCommitment(Registration calldata registration) internal {
        bytes32 commitment = makeCommitment(registration);
        uint256 committedAt = commitments[commitment];

        require(committedAt != 0, CommitmentNotFound(commitment));
        require(
            committedAt + minCommitmentAge <= block.timestamp,
            CommitmentTooNew(commitment, committedAt + minCommitmentAge, block.timestamp)
        );
        require(
            committedAt + maxCommitmentAge > block.timestamp,
            CommitmentTooOld(commitment, committedAt + maxCommitmentAge, block.timestamp)
        );

        delete commitments[commitment];
    }

    function _completeRegistration(
        Registration calldata registration,
        IDotnsRegistrar registrar,
        bytes32 labelhash,
        bytes32 node,
        uint256 baseCost,
        bool setReverseRecord
    )
        internal
    {
        IDotnsRegistry registry = IDotnsRegistry(
            protocolRegistry.get(DotnsProtocolRegistry(address(protocolRegistry)).REGISTRY())
        );
        IDotnsReverseResolver reverse = IDotnsReverseResolver(
            protocolRegistry.get(
                DotnsProtocolRegistry(address(protocolRegistry)).REVERSE_RESOLVER()
            )
        );

        registrar.register(uint256(node), registration.owner, registration.label);
        registry.setOwner(node, registration.owner, address(reverse));

        if (setReverseRecord) {
            reverse.setReverseName(
                registration.owner, string.concat(registration.label, DotnsConstants.TLD)
            );
        }

        IStoreFactory factory = IStoreFactory(
            protocolRegistry.get(DotnsProtocolRegistry(address(protocolRegistry)).STORE_FACTORY())
        );
        address[] memory controllers = new address[](3);
        controllers[0] = address(this);
        controllers[1] = address(registry);
        controllers[2] = address(registrar);

        string memory fullName = string.concat(registration.label, DotnsConstants.TLD);
        Store store = factory.writeToStore(controllers, registration.owner, labelhash, fullName);

        emit NameRegistered(
            registration.label, labelhash, registration.owner, baseCost, address(store)
        );
    }

    /// @notice Mints a label, wires forward registry, persists store entries, and writes
    ///         PoP-flow chat-key and (optional) lite-link entries.
    /// @dev Shared implementation for gateway-driven registration flows. Skips pricing,
    ///      commit-reveal, and reverse-record setting entirely. The caller must have already
    ///      validated the label via `_requireAvailableLabel` and checked reservation state.
    function _completeGatewayRegistration(
        address user,
        string calldata label,
        bytes32 labelhash,
        bytes32 node,
        bytes memory chatKey,
        bytes32 liteLabelhash
    )
        internal
    {
        IDotnsRegistrar registrar = IDotnsRegistrar(
            protocolRegistry.get(DotnsProtocolRegistry(address(protocolRegistry)).REGISTRAR())
        );
        IDotnsRegistry registry = IDotnsRegistry(
            protocolRegistry.get(DotnsProtocolRegistry(address(protocolRegistry)).REGISTRY())
        );
        IDotnsReverseResolver reverse = IDotnsReverseResolver(
            protocolRegistry.get(
                DotnsProtocolRegistry(address(protocolRegistry)).REVERSE_RESOLVER()
            )
        );

        registrar.register(uint256(node), user, label);
        registry.setOwner(node, user, address(reverse));

        IStoreFactory factory = IStoreFactory(
            protocolRegistry.get(DotnsProtocolRegistry(address(protocolRegistry)).STORE_FACTORY())
        );
        address[] memory controllers = new address[](3);
        controllers[0] = address(this);
        controllers[1] = address(registry);
        controllers[2] = address(registrar);

        string memory fullName = string.concat(label, DotnsConstants.TLD);
        Store store = factory.writeToStore(controllers, user, labelhash, fullName);

        if (chatKey.length != 0) {
            store.setValueFor(user, StoreUtils.chatKeyStoreKey(labelhash), string(chatKey));
        }
        if (liteLabelhash != bytes32(0)) {
            store.setValueFor(
                user,
                StoreUtils.liteLinkStoreKey(labelhash),
                string(abi.encodePacked(liteLabelhash))
            );
        }

        emit NameRegistered(label, labelhash, user, 0, address(store));
    }

    /// @notice Reverts when a label has a live (non-expired) reservation at the head of its
    ///         queue held by an address other than `user`.
    /// @dev Relinquished mid-queue slots (`owner == address(0)`) and expired heads are
    ///      treated as absent. Intended to be called AFTER `_advanceExpiredHead` so that
    ///      stale entries don't trigger false rejections.
    function _requireNotReservedByOther(
        string calldata label,
        bytes32 labelhash,
        address user
    )
        internal
        view
    {
        ReservationQueueMeta memory meta = _reservationMeta[labelhash];
        if (meta.head >= meta.tail) {
            return;
        }
        ReservationEntry memory head = _reservationEntries[labelhash][meta.head];
        if (head.owner == address(0)) {
            return;
        }
        if (_isExpired(head.joinedAt)) {
            return;
        }
        if (head.owner != user) {
            revert LabelReservedForPop(label);
        }
    }

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.5.0";
    }

    /// @notice Internal check enforcing whitelist-or-owner access.
    function _onlyWhiteListedOrOwner() internal view {
        require(whiteList[msg.sender] || msg.sender == owner(), NotWhiteListedOrOwner(msg.sender));
    }

    /// @notice Internal check enforcing PoP-gateway-only access.
    function _onlyGateway() internal view {
        address gateway =
            protocolRegistry.get(DotnsProtocolRegistry(address(protocolRegistry)).POP_GATEWAY());
        require(msg.sender == gateway, NotGateway(msg.sender));
    }

    /// @notice Returns the reservation entry at the head of the queue for `labelhash`.
    /// @return entry Head entry. `entry.owner == address(0)` when the queue is empty.
    function _queueHead(bytes32 labelhash) internal view returns (ReservationEntry memory entry) {
        ReservationQueueMeta memory meta = _reservationMeta[labelhash];
        if (meta.head >= meta.tail) {
            return entry;
        }
        entry = _reservationEntries[labelhash][meta.head];
    }

    /// @notice Returns whether a queue entry is expired relative to `block.timestamp`.
    function _isExpired(uint64 joinedAt) internal view returns (bool) {
        return joinedAt + reservationDuration <= block.timestamp;
    }

    /// @notice Appends a new reservation entry to the tail of the queue for `labelhash`.
    /// @dev Reverts if the queue is full or the user already holds a reservation.
    function _enqueueReservation(bytes32 labelhash, address user) internal {
        require(_userReservation[user] == bytes32(0), AlreadyReserved(user, labelhash));

        ReservationQueueMeta memory meta = _reservationMeta[labelhash];
        require(meta.tail - meta.head < MAX_RESERVATION_QUEUE, QueueFull(labelhash));

        uint64 index = meta.tail;
        _reservationEntries[labelhash][index] =
            ReservationEntry({owner: user, joinedAt: uint64(block.timestamp)});
        _reservationMeta[labelhash] = ReservationQueueMeta({head: meta.head, tail: index + 1});

        _userReservation[user] = labelhash;
        _userReservationIndex[user] = index;

        emit ReservationQueued(labelhash, user, index - meta.head);
    }

    /// @notice Wipes the entire reservation queue for `labelhash`.
    /// @dev Used when a holder claims their reservation: every waiter is evicted and their
    ///      per-user tracking state is cleared. Deletes entries as it walks so storage is
    ///      released.
    function _clearQueue(bytes32 labelhash) internal {
        ReservationQueueMeta memory meta = _reservationMeta[labelhash];
        for (uint64 i = meta.head; i < meta.tail; i++) {
            ReservationEntry memory entry = _reservationEntries[labelhash][i];
            if (entry.owner != address(0)) {
                delete _userReservation[entry.owner];
                delete _userReservationIndex[entry.owner];
            }
            delete _reservationEntries[labelhash][i];
        }
        delete _reservationMeta[labelhash];
    }

    /// @notice Advances the queue head past every expired entry at the head of the queue.
    /// @dev Bounded by queue length. Emits `ReservationExpired` per removed entry.
    function _advanceExpiredHead(bytes32 labelhash) internal {
        ReservationQueueMeta memory meta = _reservationMeta[labelhash];
        uint64 head = meta.head;
        uint64 tail = meta.tail;

        while (head < tail) {
            ReservationEntry memory entry = _reservationEntries[labelhash][head];
            // Skip already-relinquished slots.
            if (entry.owner == address(0)) {
                delete _reservationEntries[labelhash][head];
                head++;
                continue;
            }
            if (!_isExpired(entry.joinedAt)) {
                break;
            }

            delete _userReservation[entry.owner];
            delete _userReservationIndex[entry.owner];
            delete _reservationEntries[labelhash][head];
            emit ReservationExpired(labelhash, entry.owner);
            head++;
        }

        if (head == tail) {
            delete _reservationMeta[labelhash];
        } else if (head != meta.head) {
            _reservationMeta[labelhash] = ReservationQueueMeta({head: head, tail: tail});
        }
    }

    /// @notice Removes `user` from whichever reservation queue they currently occupy.
    /// @dev If the user is at the head the head is advanced and further expired entries are
    ///      compacted. Otherwise the entry is zeroed in place and the slot is left for the
    ///      next head advance to clean up.
    function _removeUserFromQueue(address user) internal {
        bytes32 labelhash = _userReservation[user];
        if (labelhash == bytes32(0)) {
            return;
        }
        uint64 index = _userReservationIndex[user];
        ReservationQueueMeta memory meta = _reservationMeta[labelhash];

        delete _userReservation[user];
        delete _userReservationIndex[user];

        if (index == meta.head) {
            delete _reservationEntries[labelhash][index];
            _reservationMeta[labelhash] = ReservationQueueMeta({head: index + 1, tail: meta.tail});
            _advanceExpiredHead(labelhash);
        } else {
            delete _reservationEntries[labelhash][index];
        }
    }

    /// @inheritdoc IDotnsRegistrarController
    // TODO: On fresh deploy (not upgrade), remove this function. Set protocolRegistry in initialize instead.
    function updateProtocolRegistry(IDotnsProtocolRegistry registry) external override onlyOwner {
        protocolRegistry = registry;
        emit ProtocolRegistryUpdated(registry);
    }

    /// @notice Internal check enforcing registry-only access.
    function _onlyRegistry() internal view {
        address registry =
            protocolRegistry.get(DotnsProtocolRegistry(address(protocolRegistry)).REGISTRY());
        require(msg.sender == registry, NotRegistry());
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
