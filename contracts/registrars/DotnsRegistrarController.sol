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
import {IStore} from "../store/IStore.sol";
import {IStoreFactory} from "../store/IStoreFactory.sol";

/// @title DotNS Registrar Controller
/// @notice Allocates .dot labels using a commit–reveal scheme.
/// @dev Orchestrates allocation, PoP validation, pricing enforcement, forward registry wiring,
///      default reverse resolution, and immutable store writing.
///
/// @dev Commit–reveal:
///      - Commitments are stored as timestamps.
///      - A reveal is valid only if `minCommitmentAge <= now - committedAt < maxCommitmentAge`.
///
/// @dev Store writing:
///      - On successful registration, the controller writes the full name `<label>.dot` to the user's Store.
///      - The Store is expected to permanently lock DotNS-written entries, preventing deletion or overwrite.
/// @custom:security-contact admin@parity.io
contract DotnsRegistrarController is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IDotnsRegistrarController
{
    using StringUtils for *;

    /// @notice Namehash of the .dot TLD.
    bytes32 private constant DOT_NODE =
        0x3fce7d1364a893e213bc4212792b517ffc88f5b13b86c8ef9c8d390c3a1370ce;

    /// @notice Upper bound for commitment validity to cap storage griefing risk.
    uint256 public constant MAX_ALLOWED_COMMITMENT_AGE = 7 days;

    /// @notice Base registrar responsible for minting name ownership.
    IDotnsRegistrar public dotnsRegistrar;

    /// @notice Forward registry storing node ownership.
    IDotnsRegistry public dotnsRegistry;

    /// @notice Reverse resolver for address → primary name mapping.
    IDotnsReverseResolver public reverseResolver;

    /// @notice Rules enforcing PoP rules and pricing.
    IPopRules public popRules;

    /// @notice Factory for per-user Store instances.
    IStoreFactory public storeFactory;

    /// @notice Minimum age a commitment must reach before reveal.
    uint256 public minCommitmentAge;

    /// @notice Maximum age after which a commitment expires.
    uint256 public maxCommitmentAge;

    /// @notice Commitment hash => timestamp when committed.
    mapping(bytes32 hash => uint256 timestamp) public commitments;

    /// @notice Key prefix for DotNS-written Store entries ("dotns.registered")
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant DOTNS_REGISTERED_KEY = bytes32("dotns.registered");

    /// @dev Reserved storage space to allow for layout changes in the future.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[50] private __gap;

    /// @notice Restricts calls to the forward registry contract.
    modifier onlyRegistry() {
        _onlyRegistry();
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

    /// @inheritdoc IDotnsRegistrarController
    function available(string calldata label) public view override returns (bool) {
        require(label.strlen() >= 3, NameNotAvailable(label));
        bytes32 labelhash = _labelhash(label);
        return dotnsRegistrar.available(uint256(labelhash));
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

        assembly {
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
        require(available(registration.label), NameNotAvailable(registration.label));

        bytes32 labelhash = _labelhash(registration.label);
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

        IPopRules.PriceWithMeta memory priced =
            popRules.priceWithCheck(registration.label, registration.owner);

        require(msg.value >= priced.price, InsufficientValue());

        dotnsRegistrar.register(uint256(labelhash), registration.owner);

        bytes32 node = _namehash(labelhash);
        dotnsRegistry.setOwner(node, registration.owner, address(reverseResolver));

        if (registration.reserved) {
            reverseResolver.setReverseName(
                registration.owner, string.concat(registration.label, ".dot")
            );
        }

        Store store = _getOrCreateStore(registration.owner);

        bytes32 storeKey = _storeKey(labelhash);
        store.setValueFor(registration.owner, storeKey, string.concat(registration.label, ".dot"));

        emit NameRegistered(
            registration.label, labelhash, registration.owner, priced.price, address(store)
        );

        if (
            priced.status == IPopRules.PopStatus.PopLite
                && priced.userStatus == IPopRules.PopStatus.PopLite
        ) {
            popRules.reserveBaseName(registration.label, registration.owner);
        }

        if (msg.value > priced.price) {
            (bool ok,) = payable(msg.sender).call{value: msg.value - priced.price}("");
            require(ok, RefundFailed());
        }
    }

    /// @inheritdoc IDotnsRegistrarController
    function registerReserved(Registration calldata registration) external override {
        require(available(registration.label), NameNotAvailable(registration.label));

        bytes32 labelhash = _labelhash(registration.label);
        bytes32 node = _namehash(labelhash);
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

        dotnsRegistrar.register(uint256(labelhash), registration.owner);
        dotnsRegistry.setOwner(node, registration.owner, address(reverseResolver));

        reverseResolver.setReverseName(
            registration.owner, string.concat(registration.label, ".dot")
        );

        Store store = _getOrCreateStore(registration.owner);

        bytes32 storeKey = _storeKey(labelhash);
        store.setValueFor(registration.owner, storeKey, string.concat(registration.label, ".dot"));

        emit NameRegistered(registration.label, labelhash, registration.owner, 0, address(store));
    }

    /// @inheritdoc IDotnsRegistrarController
    function writeSubnodeToStore(IDotnsRegistry.SubnodeRecord calldata record)
        public
        override
        onlyRegistry
    {
        Store store = _getOrCreateStore(record.owner);

        bytes32 labelhash = _labelhash(record.subLabel);
        bytes32 storeKey = _storeKey(labelhash);

        store.setValueFor(
            record.owner,
            storeKey,
            string.concat(
                string.concat(record.subLabel, string.concat(".", record.parentLabel)), ".dot"
            )
        );
    }

    /// @inheritdoc ERC165Upgradeable
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IDotnsRegistrarController).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice Returns the Store for `owner`, deploying/mapping one if needed.
    /// @dev Unifies Store acquisition across `register`, `registerReserved`, and `writeSubnodeToStore`.
    ///      Handles three cases:
    ///      1) Store already mapped to `owner` in the factory.
    ///      2) Store mapped to this controller in the factory (migrate mapping to `owner`).
    ///      3) No store exists (deploy under controller, authorize controller, transfer store ownership,
    ///         then move factory mapping to `owner`).
    ///.     There should be a non-rentrant modifer here but we dont see a scenario where the resulting
    ///      Store can call this function again
    /// @param owner Target Store owner address.
    /// @return store The resolved Store instance.
    function _getOrCreateStore(address owner) internal returns (Store store) {
        IStore existing = storeFactory.getDeployedStore(owner);
        if (address(existing) != address(0)) return Store(address(existing));

        IStore controllerMapped = storeFactory.getDeployedStore(address(this));
        if (address(controllerMapped) != address(0)) {
            storeFactory.transferOwnership(owner);
            IStore moved = storeFactory.getDeployedStore(owner);
            require(address(moved) != address(0), IStoreFactory.InvalidTransfer(owner));
            return Store(address(moved));
        }

        store = Store(address(storeFactory.deploy()));
        store.authorizeDotnsController(address(this));
        store.transferOwnership(owner);
        storeFactory.transferOwnership(owner);
    }

    /// @notice Computes keccak256(label)
    /// @param label Label string.
    /// @return hash keccak256(label).
    function _labelhash(string calldata label) internal pure returns (bytes32 hash) {
        assembly {
            let pointer := mload(0x40)
            let len := label.length
            calldatacopy(pointer, label.offset, len)
            hash := keccak256(pointer, len)
        }
    }

    /// @notice Computes namehash(DOT_NODE, labelhash)
    /// @param labelhash keccak256(label).
    /// @return node namehash.
    function _namehash(bytes32 labelhash) internal pure returns (bytes32 node) {
        assembly {
            let pointer := mload(0x40)
            mstore(pointer, DOT_NODE)
            mstore(add(pointer, 0x20), labelhash)
            node := keccak256(pointer, 0x40)
        }
    }

    /// @notice Computes keccak256("dotns.registered", labelhash)
    /// @param labelhash keccak256(label).
    /// @return key Store key used for DotNS-written registration entry.
    function _storeKey(bytes32 labelhash) internal pure returns (bytes32 key) {
        bytes32 prefix = DOTNS_REGISTERED_KEY;
        assembly {
            let pointer := mload(0x40)
            mstore(pointer, prefix)
            mstore(add(pointer, 0x20), labelhash)
            key := keccak256(pointer, 0x40)
        }
    }

    /// @notice Returns implementation version
    /// @return versionString Current version string
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.0.0";
    }

    /// @notice Internal check enforcing registry-only access.
    function _onlyRegistry() internal view {
        require(msg.sender == address(dotnsRegistry), NotRegistry());
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
