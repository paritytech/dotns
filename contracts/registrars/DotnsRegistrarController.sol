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
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IDotnsRegistrar} from "./IDotnsRegistrar.sol";
import {IDotnsRegistry} from "../registry/IDotnsRegistry.sol";
import {IDotnsReverseResolver} from "../resolvers/IDotnsReverseResolver.sol";
import {IPopRules} from "../pop/IPopRules.sol";
import {StringUtils} from "../utils/StringUtils.sol";
import {IDotnsRegistrarController} from "./IDotnsRegistrarController.sol";
import {IDotnsNameEscrow} from "../escrow/IDotnsNameEscrow.sol";
import {Store} from "../store/Store.sol";
import {IStoreFactory} from "../store/IStoreFactory.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";
import {LabelUtils} from "../utils/LabelUtils.sol";
import {RegistrationUtils} from "../utils/RegistrationUtils.sol";
import {StoreUtils} from "../utils/StoreUtils.sol";

/// @title Dotns Registrar Controller
/// @notice Allocates .dot labels using a commit–reveal scheme.
/// @dev Orchestrates allocation, PoP validation, pricing enforcement, forward registry wiring,
///      default reverse resolution, and immutable store writing.
///
/// @dev Tokenisation:
///      - The minted ERC721 tokenId is uint256(node), where node = namehash(DOT_NODE, labelhash).
///      - The registry stores a sentinel owner (address(0)) for tokenised nodes and derives
/// ownership from the ERC721 registrar for authorisation.
///
/// @custom:security-contact admin@parity.io
contract DotnsRegistrarController is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    ReentrancyGuardTransient,
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

    /// @notice DEPRECATED: Reverse resolver for address => primary name mapping.
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
    /// @dev This is used to gate the `registerReserved` function, which allows registering reserved
    /// names without PoP checks or payment. This is necessary to allow the owner to register
    /// reserved names
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
        bytes32 node;
        (, node) = _validatedLabelNode(label);
        IDotnsRegistrar registrar = IDotnsRegistrar(protocolRegistry.get(DotnsConstants.REGISTRAR));
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
        // `== 0` distinguishes an unset commitment from an expired one. The value 0 is the
        // mapping's default, not a manipulable timestamp, so the equality check is safe.
        // slither-disable-next-line incorrect-equality
        require(
            commitments[commitment] == 0
                || commitments[commitment] + maxCommitmentAge < block.timestamp,
            UnexpiredCommitmentExists(commitment)
        );

        commitments[commitment] = block.timestamp;
        emit NameCommitted(commitment);
    }

    /// @inheritdoc IDotnsRegistrarController
    function register(Registration calldata registration) external payable override nonReentrant {
        address escrow = _escrow();

        (IDotnsRegistrar registrar, bytes32 labelhash, bytes32 node) =
            _requireAvailableLabel(registration.label);
        _consumeCommitment(registration);

        IPopRules rules = IPopRules(protocolRegistry.get(DotnsConstants.POP_RULES));

        bool isDirect = msg.sender == registration.owner;
        IPopRules.PriceWithMeta memory priced;
        if (isDirect) {
            // Direct path: enforce personhood + reservation gate.
            priced = rules.priceWithCheck(registration.label, registration.owner);
        } else {
            // Cross-payer path: the personhood gate is skipped here, but base-name
            // reservations are still enforced so a third party cannot pay around a
            // reservation held by another user.
            priced = rules.priceWithoutCheck(registration.label, registration.owner);
            require(priced.status != IPopRules.PopStatus.Reserved, NameReserved(registration.label));
        }

        // Cross-payer friction: when the sender is registering on behalf of a verified
        // owner (priced.price == 0) but the sender's own reach is below the label's
        // required tier, the personhood gate has been skipped and PopRules.reachFee
        // re-applies it as a length-scaled charge that credits the insurance fund.
        uint256 friction = 0;
        if (!isDirect && priced.price == 0) {
            friction = rules.reachFee(registration.label, msg.sender);
        }
        uint256 totalCharged = priced.price + friction;
        require(msg.value >= totalCharged, InsufficientValue());

        bool setReverseRecord = registration.reserved && isDirect;

        uint256 tokenId = uint256(node);
        // Custody handoff: if the token already exists, escrow is holding it from a prior
        // release (verified by `_requireAvailableLabel` which only returns true for fresh
        // tokenIds or escrow-custody tokenIds). Transfer custody instead of minting.
        bool isReclaim = registrar.exists(tokenId);
        if (isReclaim) {
            IDotnsNameEscrow(payable(escrow)).reclaim(tokenId, registration.owner);
        }

        _completeRegistration(
            registration, registrar, labelhash, node, priced.price, setReverseRecord, isReclaim
        );

        if (priced.price != 0) {
            if (isDirect) {
                // Direct path: refundable deposit with owner as refund recipient.
                IDotnsNameEscrow(payable(escrow)).deposit{value: priced.price}(
                    IDotnsNameEscrow.DepositParams({
                        tokenId: tokenId,
                        asset: address(0),
                        amount: priced.price,
                        recipient: registration.owner
                    })
                );
            } else {
                // Cross-payer path: compare payer's tier price for the same label to
                // distinguish "same-tier-different-address" (refundable to owner)
                // from a genuine cross-tier payment (insurance fund).
                uint256 senderPrice = rules.priceWithoutCheck(registration.label, msg.sender).price;
                if (senderPrice == priced.price) {
                    IDotnsNameEscrow(payable(escrow)).deposit{value: priced.price}(
                        IDotnsNameEscrow.DepositParams({
                            tokenId: tokenId,
                            asset: address(0),
                            amount: priced.price,
                            recipient: registration.owner
                        })
                    );
                } else {
                    IDotnsNameEscrow(payable(escrow)).depositInsurance{value: priced.price}(
                        IDotnsNameEscrow.InsuranceDepositParams({
                            tokenId: tokenId, payer: msg.sender, recipient: registration.owner
                        })
                    );
                }
            }
        }

        if (friction != 0) {
            IDotnsNameEscrow(payable(escrow)).depositInsurance{value: friction}(
                IDotnsNameEscrow.InsuranceDepositParams({
                    tokenId: tokenId, payer: msg.sender, recipient: registration.owner
                })
            );
        }

        if (
            priced.status == IPopRules.PopStatus.PopLite
                && priced.userStatus == IPopRules.PopStatus.PopLite
        ) {
            rules.reserveBaseName(registration.label, registration.owner);
        }

        if (msg.value > totalCharged) {
            uint256 refund = msg.value - totalCharged;
            (bool ok,) = payable(msg.sender).call{value: refund}("");
            require(ok, RefundFailed());
            emit OverpaymentRefunded(msg.sender, refund);
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
        nonReentrant
    {
        (IDotnsRegistrar registrar, bytes32 labelhash, bytes32 node) =
            _requireAvailableLabel(registration.label);
        _consumeCommitment(registration);

        _completeRegistration(registration, registrar, labelhash, node, 0, true, false);
    }

    /// @inheritdoc ERC165Upgradeable
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165Upgradeable, IERC165)
        returns (bool)
    {
        return interfaceId == type(IDotnsRegistrarController).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice Validates label shape and derives `(labelhash, node)`.
    /// @dev Delegates hashing to {LabelUtils} so the assembly sequence lives in exactly
    ///      one place across the codebase. Error ownership stays on this interface:
    ///      short labels revert with `NameNotAvailable(label)` (pre-existing semantics),
    ///      shape violations revert with `InvalidLabel()`.
    function _validatedLabelNode(string calldata label)
        internal
        pure
        returns (bytes32 labelhash, bytes32 node)
    {
        require(label.isSingleLabel(), InvalidLabel());
        require(bytes(label).length >= 3, NameNotAvailable(label));
        (labelhash, node) = LabelUtils.deriveNode(label);
    }

    function _requireAvailableLabel(string calldata label)
        internal
        view
        returns (IDotnsRegistrar registrar, bytes32 labelhash, bytes32 node)
    {
        (labelhash, node) = _validatedLabelNode(label);
        registrar = IDotnsRegistrar(protocolRegistry.get(DotnsConstants.REGISTRAR));
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

    /// @notice Completes a commit-reveal registration: mints (or skips when reclaiming),
    ///         wires forward registry, optionally sets the reverse record, and writes
    ///         the owner's Store.
    /// @dev On the standard (non-reclaim) path the mint + forward-registry + store-write
    ///      triad is delegated to {RegistrationUtils-registerAndStore}, which is the
    ///      single canonical implementation shared across every DotNS registration flow.
    ///      On the reclaim path the escrow has already transferred custody to the new
    ///      owner, so we skip the mint and inline the registry-update + store-write
    ///      sequence using the same canonical Store-controller set, keeping the
    ///      authorised-caller invariant identical across both paths. Reverse-record
    ///      setting and the priced-registration event stay here because they are
    ///      commit-reveal-specific policy.
    function _completeRegistration(
        Registration calldata registration,
        IDotnsRegistrar registrar,
        bytes32 labelhash,
        bytes32 node,
        uint256 baseCost,
        bool setReverseRecord,
        bool isReclaim
    )
        internal
    {
        Store store;
        if (!isReclaim) {
            store = RegistrationUtils.registerAndStore(
                RegistrationUtils.RegistrationContext({
                    protocolRegistry: protocolRegistry,
                    user: registration.owner,
                    label: registration.label,
                    labelhash: labelhash,
                    node: node
                })
            );
        } else {
            // Reclaim path: custody has already been transferred by the escrow, so we
            // skip the mint but still update the forward registry and write the Store
            // entry using the canonical controller set.
            IDotnsRegistry registry = IDotnsRegistry(protocolRegistry.get(DotnsConstants.REGISTRY));
            IDotnsReverseResolver reverse =
                IDotnsReverseResolver(protocolRegistry.get(DotnsConstants.REVERSE_RESOLVER));
            registry.setOwner(node, registration.owner, address(reverse));

            IStoreFactory factory =
                IStoreFactory(protocolRegistry.get(DotnsConstants.STORE_FACTORY));
            address[] memory controllers = RegistrationUtils.storeControllers(protocolRegistry);
            string memory fullName = string.concat(registration.label, DotnsConstants.TLD);
            store = factory.writeToStore(controllers, registration.owner, labelhash, fullName);
        }

        if (setReverseRecord) {
            IDotnsReverseResolver reverse =
                IDotnsReverseResolver(protocolRegistry.get(DotnsConstants.REVERSE_RESOLVER));
            reverse.setReverseName(
                registration.owner, string.concat(registration.label, DotnsConstants.TLD)
            );
        }

        emit NameRegistered(
            registration.label, labelhash, registration.owner, baseCost, address(store)
        );
    }

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.7.0";
    }

    /// @inheritdoc IDotnsRegistrarController
    function migrateNativeFundsToEscrow(uint256 amount) external override onlyOwner {
        address escrow = _escrow();
        (bool ok,) = payable(escrow).call{value: amount}(
            abi.encodeCall(IDotnsNameEscrow.receiveControllerFunds, ())
        );
        require(ok, NativeFundsMigrationFailed());
        emit NativeFundsMigrated(escrow, amount);
    }

    /// @notice Returns the configured name escrow from the protocol registry.
    /// @return escrow Escrow address.
    function _escrow() internal view returns (address escrow) {
        escrow = protocolRegistry.get(DotnsConstants.NAME_ESCROW);
        require(escrow != address(0), EscrowNotConfigured());
    }

    /// @notice Internal check enforcing whitelist-or-owner access.
    function _onlyWhiteListedOrOwner() internal view {
        require(whiteList[msg.sender] || msg.sender == owner(), NotWhiteListedOrOwner(msg.sender));
    }

    /// @inheritdoc IDotnsRegistrarController
    // TODO: On fresh deploy (not upgrade), remove this function. Set protocolRegistry in initialize instead.
    function updateProtocolRegistry(IDotnsProtocolRegistry registry) external override onlyOwner {
        protocolRegistry = registry;
        emit ProtocolRegistryUpdated(registry);
    }

    /// @notice Internal check enforcing registry-only access.
    function _onlyRegistry() internal view {
        address registry = protocolRegistry.get(DotnsConstants.REGISTRY);
        require(msg.sender == registry, NotRegistry());
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
