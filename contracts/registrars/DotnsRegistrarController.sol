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
import {StoreUtils} from "../utils/StoreUtils.sol";

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

    /// @notice Namehash of the .dot TLD.
    bytes32 private constant DOT_NODE =
        0x3fce7d1364a893e213bc4212792b517ffc88f5b13b86c8ef9c8d390c3a1370ce;

    /// @notice Upper bound for commitment validity to cap storage griefing risk.
    uint256 public constant MAX_ALLOWED_COMMITMENT_AGE = 7 days;

    /// @notice Base registrar responsible for minting name ownership.
    IDotnsRegistrar public dotnsRegistrar;

    /// @notice Forward registry storing node ownership and resolver.
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

    /// @notice Stores Mapping of commitment hashes to timestamp committed.
    mapping(bytes32 hash => uint256 timestamp) public commitments;

    /// @notice Key prefix for Dotns-written Store immutable entries ("dotns.registered").
    /// casting to 'bytes32' is safe because this is safe
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant DOTNS_REGISTERED_KEY = bytes32("dotns.registered");

    /// @notice Whitelist for addresses allowed to call `registerReserved`.
    mapping(address user => bool isWhiteListed) public whiteList;

    /// @dev Reserved storage space to allow for layout changes in the future.
    uint256[49] private __gap;

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
        bytes32 node = _namehash(labelhash);
        return dotnsRegistrar.available(uint256(node));
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

        IPopRules.PriceWithMeta memory priced =
            popRules.priceWithCheck(registration.label, registration.owner);

        require(msg.value >= priced.price, InsufficientValue());

        dotnsRegistrar.register(uint256(node), registration.owner);

        dotnsRegistry.setOwner(node, registration.owner, address(reverseResolver));

        if (registration.reserved) {
            reverseResolver.setReverseName(
                registration.owner, string.concat(registration.label, ".dot")
            );
        }

        address[] memory controllers = new address[](2);
        controllers[0] = address(this);
        controllers[1] = address(dotnsRegistry);
        Store store = storeFactory.getOrCreateStore(controllers, registration.owner);

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

        dotnsRegistrar.register(uint256(node), registration.owner);
        dotnsRegistry.setOwner(node, registration.owner, address(reverseResolver));

        reverseResolver.setReverseName(
            registration.owner, string.concat(registration.label, ".dot")
        );

        address[] memory controllers = new address[](2);
        controllers[0] = address(this);
        controllers[1] = address(dotnsRegistry);
        Store store = storeFactory.getOrCreateStore(controllers, registration.owner);

        bytes32 storeKey = _storeKey(labelhash);
        store.setValueFor(registration.owner, storeKey, string.concat(registration.label, ".dot"));

        emit NameRegistered(registration.label, labelhash, registration.owner, 0, address(store));
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
        assembly {
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
        assembly {
            let pointer := mload(0x40)
            mstore(pointer, DOT_NODE)
            mstore(add(pointer, 0x20), labelhash)
            node := keccak256(pointer, 0x40)
        }
    }

    /// @notice Computes keccak256("dotns.registered", labelhash).
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

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.2.0";
    }

    /// @notice Internal check enforcing whitelist-or-owner access.
    function _onlyWhiteListedOrOwner() internal view {
        require(whiteList[msg.sender] || msg.sender == owner(), NotWhiteListedOrOwner(msg.sender));
    }

    /// @notice Internal check enforcing registry-only access.
    function _onlyRegistry() internal view {
        require(msg.sender == address(dotnsRegistry), NotRegistry());
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
