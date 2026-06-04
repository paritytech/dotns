// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {DotnsRoleManager} from "../access/DotnsRoleManager.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IDotnsRegistrar} from "./IDotnsRegistrar.sol";
import {IDotnsReverseResolver} from "../resolvers/IDotnsReverseResolver.sol";
import {IPopRules} from "../pop/IPopRules.sol";
import {StringUtils} from "../utils/StringUtils.sol";
import {IDotnsRegistrarController} from "./IDotnsRegistrarController.sol";
import {IDotnsNameEscrow} from "../escrow/IDotnsNameEscrow.sol";
import {IStoreFactory} from "../store/IStoreFactory.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {IDotnsRegistry} from "../registry/IDotnsRegistry.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";
import {LabelUtils} from "../utils/LabelUtils.sol";
import {RegistrationUtils} from "../utils/RegistrationUtils.sol";
import {StoreUtils} from "../utils/StoreUtils.sol";

/// @title Dotns Registrar Controller
/// @notice Allocates .dot labels using a commit reveal scheme.
/// @dev Orchestrates allocation, PoP validation, pricing enforcement, forward registry
/// wiring, default reverse resolution, and immutable store writing.
///
/// Tokenisation: the minted ERC721 tokenId is `uint256(node)`, where
/// `node = namehash(DOT_NODE, labelhash)`. The registry stores a sentinel owner
/// (`address(0)`) for tokenised nodes and derives ownership from the ERC721 registrar for
/// authorisation.
/// @custom:security-contact admin@parity.io
contract DotnsRegistrarController is
    Initializable,
    UUPSUpgradeable,
    DotnsRoleManager,
    ReentrancyGuardTransient,
    IDotnsRegistrarController
{
    using StringUtils for *;
    using StoreUtils for IStoreFactory;

    /// @notice Upper bound for commitment validity to cap storage griefing risk.
    uint256 public constant MAX_ALLOWED_COMMITMENT_AGE = 7 days;

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
    uint256[50] private __gap;

    /// @notice Restricts calls to whitelisted addresses or the owner.
    /// @dev Used to gate `registerReserved`, which allows registering reserved names without
    /// PoP checks or payment. Necessary so the owner (or a whitelisted operator) can seed
    /// reserved names on behalf of users who are already known and verified and do not need
    /// PoP checks.
    modifier onlyWhiteListedOrOwner() {
        _onlyWhiteListedOrOwner();
        _;
    }

    modifier onlyWhitelistOperatorOrOwner() {
        _checkRoleOrOwner(DotnsConstants.WHITELIST_OPERATOR_ROLE);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the registrar controller.
    /// @dev Callable once through the UUPS proxy; direct calls on the implementation revert
    /// with @custom:reverts InvalidInitialization, and any nested call outside an active
    /// initialiser scope reverts with @custom:reverts NotInitializing. Validates the
    /// commitment window bounds: `minAge` must be strictly positive (otherwise
    /// @custom:reverts MinCommitmentAgeZero) so a reveal cannot land in the same block as
    /// its commit; `maxAge` must exceed `minAge` (otherwise
    /// @custom:reverts MaxCommitmentAgeTooLow) and must stay within
    /// `MAX_ALLOWED_COMMITMENT_AGE` (otherwise @custom:reverts MaxCommitmentAgeTooHigh) before
    /// wiring the protocol registry.
    function initialize(
        IDotnsProtocolRegistry registry,
        uint256 minAge,
        uint256 maxAge
    )
        external
        initializer
    {
        __Ownable_init(msg.sender);
        _dotnsRoleManagerInit();

        require(minAge > 0, MinCommitmentAgeZero());
        require(maxAge > minAge, MaxCommitmentAgeTooLow());
        require(maxAge <= MAX_ALLOWED_COMMITMENT_AGE, MaxCommitmentAgeTooHigh());

        protocolRegistry = registry;

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
        commitment = keccak256(
            abi.encode(
                registration.label, registration.owner, registration.secret, registration.reserved
            )
        );
    }

    /// @inheritdoc IDotnsRegistrarController
    function commit(bytes32 commitment) external override {
        uint256 prior = commitments[commitment];
        require(
            prior == 0 || prior + maxCommitmentAge <= block.timestamp,
            UnexpiredCommitmentExists(commitment)
        );

        commitments[commitment] = block.timestamp;
        emit NameCommitted(commitment);
    }

    /// @inheritdoc IDotnsRegistrarController
    function register(Registration calldata registration) external payable override nonReentrant {
        (IDotnsRegistrar registrar, bytes32 labelhash, bytes32 node) =
            _requireAvailableLabel(registration.label);
        _consumeCommitment(registration);

        address escrow = _escrow();
        IPopRules rules = IPopRules(protocolRegistry.get(DotnsConstants.POP_RULES));

        uint256 tokenId = uint256(node);
        bool isReclaim = registrar.exists(tokenId);

        string memory stem = rules.stripDigits(registration.label);
        bool stemCanonical = stem.isSingleLabelMemory();
        // Reclaim hands the name back from a prior occupant who may hold a sibling-controller's
        // stem reservation; clear it so the new registrant's stem reserve at line 218 starts fresh.
        // Non-reclaim paths intentionally leave an existing same-owner reservation in place so a
        // sibling controller (e.g. the PoP queue head stamp) retains the slot's `controller` field
        // through the refresh in `_writeReservation`. Replacing the slot from this controller
        // would brick the sibling's release/advance paths.
        if (stemCanonical && isReclaim) {
            (address reservationOwner,) = rules.getBaseNameReservation(stem);
            address expectedOwner =
                IDotnsNameEscrow(payable(escrow)).getReleasePosition(tokenId).recipient;
            if (reservationOwner != address(0) && reservationOwner == expectedOwner) {
                rules.releaseReservationForReclaim(stem, expectedOwner);
            }
        }

        bool isDirect = msg.sender == registration.owner;
        IPopRules.PriceWithMeta memory priced;
        if (isDirect) {
            priced = rules.priceWithCheck(registration.label, registration.owner);
        } else {
            priced = rules.priceWithoutCheck(registration.label, registration.owner);
            if (priced.status == IPopRules.PopStatus.Reserved) {
                (IPopRules.PopStatus required,) = rules.classifyName(registration.label);
                if (required == IPopRules.PopStatus.Reserved) {
                    revert GovernanceReserved(registration.label);
                }
                revert NameReserved(registration.label);
            }
            require(
                priced.userStatus >= priced.status,
                OwnerStatusInsufficient(registration.label, priced.userStatus, priced.status)
            );
        }

        uint256 friction =
            !isDirect ? rules.transferFloor(registration.label, msg.sender, registration.owner) : 0;
        uint256 totalCharged = priced.price > friction ? priced.price : friction;
        require(msg.value >= totalCharged, InsufficientValue());

        IDotnsReverseResolver reverse;
        bool setReverseRecord;
        if (registration.reserved && isDirect) {
            reverse = IDotnsReverseResolver(protocolRegistry.get(DotnsConstants.REVERSE_RESOLVER));
            setReverseRecord = bytes(reverse.nameOf(registration.owner)).length == 0;
        }

        _completeRegistration(
            registration, labelhash, node, priced.price, setReverseRecord, reverse, isReclaim
        );

        if (isReclaim) {
            IDotnsNameEscrow(payable(escrow)).reclaim(tokenId, registration.owner);
            // Reclaim hands the NFT to the new holder; rewrite the registry record so the prior
            // owner's resolver pointer cannot follow the name. Must run after `escrow.reclaim`
            // so the registry's `ownerOf` check sees the new holder, not the escrow.
            IDotnsRegistry(protocolRegistry.get(DotnsConstants.REGISTRY))
                .setOwner(node, registration.owner);
        }

        _settleEscrow(escrow, tokenId, registration.owner, isDirect, totalCharged);

        if (
            priced.status == IPopRules.PopStatus.PopLite
                && priced.userStatus == IPopRules.PopStatus.PopLite && stemCanonical
        ) {
            rules.reserveBaseName(stem, registration.owner);
        }

        if (msg.value > totalCharged) {
            uint256 refund = msg.value - totalCharged;
            (bool ok,) = payable(msg.sender).call{value: refund}("");
            if (ok) {
                emit OverpaymentRefunded(msg.sender, refund);
            } else {
                IDotnsNameEscrow(payable(escrow)).creditOverpayment{value: refund}(msg.sender);
            }
        }
    }

    /// @notice Settles every escrow side-effect of a successful registration.
    /// @dev Extracted to keep `register` under the stack-depth ceiling. On a direct
    ///      registration the full `chargeAmount` lands in the refundable deposit position
    ///      keyed to `nameOwner`. On a cross-payer registration the deposit position is
    ///      seeded with a zero amount so the release lifecycle stays reachable, and the same
    ///      `chargeAmount` routes to the insurance fund via `depositInsurance` keyed to
    ///      `msg.sender` as the payer.
    function _settleEscrow(
        address escrow,
        uint256 tokenId,
        address nameOwner,
        bool isDirect,
        uint256 chargeAmount
    )
        internal
    {
        uint256 depositAmount = isDirect ? chargeAmount : 0;
        IDotnsNameEscrow(payable(escrow)).deposit{value: depositAmount}(
            IDotnsNameEscrow.DepositParams({
                tokenId: tokenId, asset: address(0), amount: depositAmount, recipient: nameOwner
            })
        );

        if (!isDirect && chargeAmount > 0) {
            IDotnsNameEscrow(payable(escrow)).depositInsurance{value: chargeAmount}(
                IDotnsNameEscrow.InsuranceDepositParams({
                    tokenId: tokenId, payer: msg.sender, recipient: nameOwner
                })
            );
        }
    }

    /// @inheritdoc IDotnsRegistrarController
    function isWhiteListed(address who) external view override returns (bool) {
        return whiteList[who];
    }

    /// @inheritdoc IDotnsRegistrarController
    function whiteListAddress(
        address who,
        bool whiteListStatus
    )
        external
        override
        onlyWhitelistOperatorOrOwner
    {
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
        (, bytes32 labelhash, bytes32 node) = _requireAvailableLabel(registration.label);
        _consumeCommitment(registration);

        IDotnsReverseResolver reverse =
            IDotnsReverseResolver(protocolRegistry.get(DotnsConstants.REVERSE_RESOLVER));
        _completeRegistration(registration, labelhash, node, 0, true, reverse, false);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(DotnsRoleManager, IERC165)
        returns (bool)
    {
        return interfaceId == type(IDotnsRegistrarController).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice Validates label shape and derives `(labelhash, node)`.
    /// @dev Delegates hashing to @custom:contract LabelUtils so the assembly sequence lives in
    /// exactly one place across the codebase. Error ownership stays on this interface: shape
    /// violations revert with `InvalidLabel()`; labels below the minimum length revert with
    /// `LabelTooShort(label)` so off-chain consumers can distinguish "shape-valid but below
    /// the policy minimum" from "shape-valid but already minted".
    function _validatedLabelNode(string calldata label)
        internal
        pure
        returns (bytes32 labelhash, bytes32 node)
    {
        require(label.isSingleLabel(), InvalidLabel());
        require(bytes(label).length >= 3, LabelTooShort(label));
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
    /// wires forward registry, optionally sets the reverse record, and writes the owner's
    /// Store.
    /// @dev On a fresh mint the triad of mint + forward-registry + store-write is delegated
    /// to @custom:function RegistrationUtils.registerAndStore, the single canonical implementation
    /// shared across every DotNS registration flow. On a reclaim the mint step is skipped (the
    /// escrow has already moved custody) and only the registry wiring and store write run.
    /// Reverse-record setting and the priced-registration event stay here because they are
    /// commit-reveal-specific policy.
    function _completeRegistration(
        Registration calldata registration,
        bytes32 labelhash,
        bytes32 node,
        uint256 baseCost,
        bool setReverseRecord,
        IDotnsReverseResolver reverse,
        bool isReclaim
    )
        internal
    {
        address labelStore;
        if (!isReclaim) {
            labelStore = RegistrationUtils.registerAndStore(
                RegistrationUtils.RegistrationContext({
                    protocolRegistry: protocolRegistry,
                    user: registration.owner,
                    label: registration.label,
                    labelhash: labelhash,
                    node: node
                })
            );
        } else {
            // Registry reset on reclaim is deferred until after `escrow.reclaim` runs (see
            // @custom:function register) so the registry's `ownerOf` check sees the new holder.
            IStoreFactory factory =
                IStoreFactory(protocolRegistry.get(DotnsConstants.STORE_FACTORY));
            string memory fullName = string.concat(registration.label, DotnsConstants.TLD);
            labelStore = factory.writeLabel(registration.owner, node, fullName);
        }

        if (setReverseRecord) {
            reverse.setReverseName(
                registration.owner, string.concat(registration.label, DotnsConstants.TLD)
            );
        }

        emit NameRegistered(registration.label, labelhash, registration.owner, baseCost, labelStore);
    }

    /// @notice Returns the configured name escrow from the protocol registry.
    function _escrow() internal view returns (address escrow) {
        escrow = protocolRegistry.get(DotnsConstants.NAME_ESCROW);
        require(escrow != address(0), EscrowNotConfigured());
    }

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.0.0";
    }

    /// @notice Internal check enforcing whitelist-or-owner access.
    function _onlyWhiteListedOrOwner() internal view {
        require(whiteList[msg.sender] || msg.sender == owner(), NotWhiteListedOrOwner(msg.sender));
    }

    function _isSupportedRole(bytes32 role) internal view override returns (bool supported) {
        return role == DotnsConstants.WHITELIST_OPERATOR_ROLE;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
