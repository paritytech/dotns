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

import {IDotnsRegistrarOld} from "./IDotnsRegistrarOld.sol";
import {IDotnsRegistry} from "../registry/IDotnsRegistry.sol";
import {IDotnsReverseResolver} from "../resolvers/IDotnsReverseResolver.sol";
import {IPopRules} from "../pop/IPopRules.sol";
import {StringUtils} from "../utils/StringUtils.sol";
import {IDotnsRegistrarControllerOld} from "./IDotnsRegistrarControllerOld.sol";
import {Store} from "../store/Store.sol";
import {IStoreFactory} from "../store/IStoreFactory.sol";
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
contract DotnsRegistrarControllerOld is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IDotnsRegistrarControllerOld
{
    using StringUtils for *;
    using StoreUtils for IStoreFactory;

    /// @notice Upper bound for commitment validity to cap storage griefing risk.
    uint256 public constant MAX_ALLOWED_COMMITMENT_AGE = 7 days;

    /// @notice DEPRECATED: Base registrar responsible for minting name ownership.
    /// @dev Retained for UUPS storage layout compatibility. Use protocolRegistry instead.
    /// TODO: Remove on fresh deploy (not upgrade). Restore __gap accordingly.
    IDotnsRegistrarOld public dotnsRegistrar;

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

    /// @dev Reserved storage space to allow for layout changes in the future.
    uint256[48] private __gap;

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
    // TODO: On fresh deploy (not upgrade), accept IDotnsProtocolRegistry and set protocolRegistry here.
    function initialize(
        IDotnsRegistrarOld registrar,
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

    /// @inheritdoc IDotnsRegistrarControllerOld
    function available(string calldata label) public view override returns (bool) {
        bytes32 node;
        (, node) = _validatedLabelNode(label);
        IDotnsRegistrarOld registrar = IDotnsRegistrarOld(
            protocolRegistry.get(DotnsProtocolRegistry(address(protocolRegistry)).REGISTRAR())
        );
        return registrar.available(uint256(node));
    }

    /// @inheritdoc IDotnsRegistrarControllerOld
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

    /// @inheritdoc IDotnsRegistrarControllerOld
    function commit(bytes32 commitment) external override {
        require(
            commitments[commitment] == 0
                || commitments[commitment] + maxCommitmentAge < block.timestamp,
            UnexpiredCommitmentExists(commitment)
        );

        commitments[commitment] = block.timestamp;
        emit NameCommitted(commitment);
    }

    /// @inheritdoc IDotnsRegistrarControllerOld
    function register(Registration calldata registration) external payable override {
        (IDotnsRegistrarOld registrar, bytes32 labelhash, bytes32 node) =
            _requireAvailableLabel(registration.label);
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

        if (
            priced.status == IPopRules.PopStatus.PopLite
                && priced.userStatus == IPopRules.PopStatus.PopLite
        ) {
            rules.reserveBaseName(registration.label, registration.owner);
        }

        if (msg.value > priced.price) {
            (bool ok,) = payable(msg.sender).call{value: msg.value - priced.price}("");
            require(ok, RefundFailed());
        }
    }

    /// @inheritdoc IDotnsRegistrarControllerOld
    function isWhiteListed(address who) external view override returns (bool) {
        return whiteList[who];
    }

    /// @inheritdoc IDotnsRegistrarControllerOld
    function whiteListAddress(address who, bool whiteListStatus) external override onlyOwner {
        whiteList[who] = whiteListStatus;
        emit WhiteListed(who, whiteListStatus);
    }

    /// @inheritdoc IDotnsRegistrarControllerOld
    function registerReserved(Registration calldata registration)
        external
        override
        onlyWhiteListedOrOwner
    {
        (IDotnsRegistrarOld registrar, bytes32 labelhash, bytes32 node) =
            _requireAvailableLabel(registration.label);
        _consumeCommitment(registration);

        _completeRegistration(registration, registrar, labelhash, node, 0, true);
    }

    /// @inheritdoc ERC165Upgradeable
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IDotnsRegistrarControllerOld).interfaceId
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
        returns (IDotnsRegistrarOld registrar, bytes32 labelhash, bytes32 node)
    {
        (labelhash, node) = _validatedLabelNode(label);
        registrar = IDotnsRegistrarOld(
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
        IDotnsRegistrarOld registrar,
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

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.4.0";
    }

    /// @notice Internal check enforcing whitelist-or-owner access.
    function _onlyWhiteListedOrOwner() internal view {
        require(whiteList[msg.sender] || msg.sender == owner(), NotWhiteListedOrOwner(msg.sender));
    }

    /// @inheritdoc IDotnsRegistrarControllerOld
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
