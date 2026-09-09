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
import {StringUtils} from "../utils/StringUtils.sol";
import {SystemUtils} from "../utils/SystemUtils.sol";
import {IPopRules} from "./IPopRules.sol";
import {IDotnsCostModelRegistry} from "./IDotnsCostModelRegistry.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {IDotnsController} from "../registrars/IDotnsController.sol";
import {DotnsRegistrar} from "../registrars/DotnsRegistrar.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";
import {IPersonhood} from "../external/personhood/IPersonhood.sol";

/// @title PopRules
/// @notice Implements DotNS classification, cost-model-driven pricing, and base-name reservations.
/// @dev Tiers are set by base length. Every label is measured as written, except a lite label,
///      whose separator and allocated digits are not part of the name the candidate chose, so
///      `joseph.42` measures six and `joseph42` measures eight.
///      Base lengths <= 5 are governance-reserved, base lengths 6-8 require PopFull, and base
///      lengths >= 9 are open to any caller as NoStatus. PopLite is the separated form alone: a
///      digit suffix on an ordinary label says nothing about personhood.
///      Every caller pays the same amount for a given base length. The amount comes from the cost
///      model registered under `DotnsConstants.COST_MODEL`, which owns the curve; this contract
///      passes it only the base length and keeps the classification, reservation, and tier rules.
///      Personhood only unlocks the premium band. Base lengths below nine are closed to the public
///      paid path until Root sets `shortNamesEnabled`; the gateway and registerReserved do
///      not consult it.
/// @custom:security-contact admin@parity.io
contract PopRules is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IPopRules
{
    using StringUtils for *;

    /// @notice Active reservations keyed by stem.
    mapping(string baseName => Reservation reservation) public reservations;

    /// @notice Maximum time a base name can be reserved.
    uint256 public constant MAX_RESERVATION_TIME = 12 weeks;

    /// @notice Protocol-level address registry for all DotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @notice Whether the public paid path may register names shorter than nine characters.
    ///         Closed by default; only governance opens it.
    bool public shortNamesEnabled;

    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[50] private __gap;

    /// @notice Restricts function to any registry-authorised controller.
    modifier onlyRegistry() {
        _onlyRegistry();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the oracle (public entry point).
    /// @dev Runs once behind the proxy; subsequent calls trigger @custom:reverts
    ///      InvalidInitialization via the `initializer` modifier. Amounts come from the cost model
    ///      registered under `DotnsConstants.COST_MODEL`, so no price is seeded here.
    /// @param registry Protocol-level address registry used to resolve sibling contracts.
    function initialize(IDotnsProtocolRegistry registry) public initializer {
        __Ownable_init(msg.sender);
        __ERC165_init();
        protocolRegistry = registry;
    }

    /// @inheritdoc IPopRules
    function setShortNamesEnabled(bool enabled) external override {
        // Opening the short-name band to the public path is a governance decision, so it is gated
        // on a substrate Root origin rather than the owner. `msg.sender` is deliberately not read:
        // a Root origin has no account behind it, so reading it would trap.
        require(SystemUtils.originIsRoot(), NotRoot());
        shortNamesEnabled = enabled;
        emit ShortNamesEnabledUpdated(enabled);
    }

    /// @inheritdoc IPopRules
    function classifyName(string calldata name)
        external
        pure
        override
        returns (PopStatus requirement, string memory message)
    {
        _requireLabel(name);
        (requirement, message,) = _classifyValidatedName(name);
    }

    /// @inheritdoc IPopRules
    function reserveBaseName(
        string calldata stem,
        address userAddress
    )
        external
        override
        onlyRegistry
    {
        _requireStem(stem);
        uint256 stemLength = bytes(stem).length;
        require(
            stemLength >= 6 && stemLength <= 8 && _countTrailingDigits(stem) == 0,
            PopError("Reservation stem must be 6-8 chars with no trailing digits")
        );
        _writeReservation(stem, userAddress);
    }

    /// @inheritdoc IPopRules
    function isBaseName(string calldata baseName) external pure override returns (bool isBase) {
        _requireLabel(baseName);
        uint256 digits = _countTrailingDigits(baseName);
        return digits == 0;
    }

    /// @inheritdoc IPopRules
    function getBaseNameReservation(string calldata baseName)
        external
        view
        override
        returns (address reservationOwner, uint64 expiryTimestamp)
    {
        _requireStem(baseName);
        Reservation memory reserved = reservations[baseName];
        return (reserved.owner, reserved.expires);
    }

    /// @inheritdoc IPopRules
    function isBaseNameReserved(string calldata baseName)
        external
        view
        override
        returns (bool isReserved, address reservationOwner, uint64 expiryTimestamp)
    {
        _requireStem(baseName);
        Reservation memory reservation = reservations[baseName];
        return (_isLive(reservation), reservation.owner, reservation.expires);
    }

    /// @inheritdoc IPopRules
    function priceWithCheck(
        string calldata name,
        address userAddress
    )
        external
        view
        override
        returns (PriceWithMeta memory metadata)
    {
        return _priceWithCheck(name, userAddress, false, 0);
    }

    /// @inheritdoc IPopRules
    function priceWithCheckAtVersion(
        string calldata name,
        address userAddress,
        uint256 pricingVersionValue
    )
        external
        view
        override
        returns (PriceWithMeta memory metadata)
    {
        return _priceWithCheck(name, userAddress, true, pricingVersionValue);
    }

    /// @inheritdoc IPopRules
    function priceWithoutCheck(
        string calldata name,
        address userAddress
    )
        external
        view
        override
        returns (PriceWithMeta memory metadata)
    {
        return _priceWithoutCheck(name, userAddress, false, 0);
    }

    /// @inheritdoc IPopRules
    function priceWithoutCheckAtVersion(
        string calldata name,
        address userAddress,
        uint256 pricingVersionValue
    )
        external
        view
        override
        returns (PriceWithMeta memory metadata)
    {
        return _priceWithoutCheck(name, userAddress, true, pricingVersionValue);
    }

    /// @notice Shared body for the reservation-enforcing pricing reads.
    /// @dev `atVersion` selects the amount source: the current model when false, the model for
    ///      `pricingVersionValue` when true. Classification, tier gating, and reservation rules are
    ///      the same on both paths, so they live here once.
    function _priceWithCheck(
        string calldata name,
        address userAddress,
        bool atVersion,
        uint256 pricingVersionValue
    )
        internal
        view
        returns (PriceWithMeta memory metadata)
    {
        _requireLabel(name);
        _enforceReservationRules(name, userAddress);

        (PopStatus requiredStatus, string memory classification, uint256 baseLength) =
            _classifyValidatedName(name);
        _requireShortNamesOpen(baseLength);
        PopStatus userStatus = _personhoodTier(userAddress);

        metadata.price = atVersion
            ? _priceValidatedNameAtVersion(pricingVersionValue, baseLength)
            : _priceValidatedName(baseLength);
        metadata.status = requiredStatus;
        metadata.userStatus = userStatus;
        metadata.message = classification;

        require(requiredStatus != PopStatus.Reserved, PopError(classification));
        require(_meetsReach(requiredStatus, userStatus), PopError(classification));

        return metadata;
    }

    /// @notice Shared body for the non-reverting pricing reads.
    /// @dev Mirror of @custom:function _priceWithCheck for the front-end preview path: reports a
    ///      contested reservation through `metadata` rather than reverting. `atVersion` selects the
    ///      amount source in the same way.
    function _priceWithoutCheck(
        string calldata name,
        address userAddress,
        bool atVersion,
        uint256 pricingVersionValue
    )
        internal
        view
        returns (PriceWithMeta memory metadata)
    {
        _requireLabel(name);

        (PopStatus requiredStatus, string memory classification, uint256 baseLength) =
            _classifyValidatedName(name);
        _requireShortNamesOpen(baseLength);
        PopStatus userStatus = _personhoodTier(userAddress);

        metadata.price = atVersion
            ? _priceValidatedNameAtVersion(pricingVersionValue, baseLength)
            : _priceValidatedName(baseLength);
        metadata.status = requiredStatus;
        metadata.userStatus = userStatus;
        metadata.message = classification;

        string memory baseName = _stripDigits(name);
        Reservation memory reservation = reservations[baseName];

        if (_isLive(reservation) && reservation.owner != userAddress) {
            metadata.message = "Base name reserved for original Lite registrant";
            metadata.status = IPopRules.PopStatus.Reserved;
        }

        return metadata;
    }

    /// @inheritdoc IPopRules
    function price(string calldata name) external view override returns (uint256) {
        _requireLabel(name);
        return _priceValidatedName(_validatedBaseLength(name));
    }

    /// @inheritdoc IPopRules
    function pricingVersion() external view override returns (uint256 modelVersion) {
        return _costModelRegistry().currentVersion();
    }

    /// @inheritdoc IPopRules
    function transferFloor(
        string calldata name,
        address from,
        address to
    )
        external
        view
        override
        returns (uint256 floor)
    {
        _requireLabel(name);
        if (from == to) return 0;
        (PopStatus required,, uint256 baseLength) = _classifyValidatedName(name);
        uint256 ownPrice = _priceValidatedName(baseLength);

        PopStatus toTier = _personhoodTier(to);
        uint256 reachComponent = _meetsReach(required, toTier) ? 0 : ownPrice;

        PopStatus fromTier = _personhoodTier(from);
        // `_personhoodTier` never returns Reserved, so users are in {NoStatus, PopLite, PopFull}
        // and enum comparison reflects tier ordering directly.
        uint256 downgradeComponent = toTier < fromTier ? ownPrice : 0;

        return reachComponent > downgradeComponent ? reachComponent : downgradeComponent;
    }

    /// @inheritdoc IPopRules
    function personhoodOf(address account) external view override returns (PopStatus tier) {
        return _personhoodTier(account);
    }

    /// @notice Reads `account`'s dotns-scoped personhood tier from the alias-accounts
    ///         precompile and translates it into a `PopStatus`.
    /// @dev Single source of truth so callers cannot read the precompile directly and
    ///      drift on the status mapping. Tiers are defined incrementally on the
    ///      precompile side: 0=None, 1=Lite, 2=Full. Anything outside that range
    ///      collapses to `NoStatus` so a future tier addition fails closed instead of
    ///      silently being treated as a higher level than it actually is.
    function _personhoodTier(address account) private view returns (PopStatus) {
        IPersonhood.PersonhoodInfo memory info = IPersonhood(DotnsConstants.PERSONHOOD)
            .personhoodStatus(account, DotnsConstants.PERSONHOOD_CONTEXT);
        if (info.status == 2) return PopStatus.PopFull;
        if (info.status == 1) return PopStatus.PopLite;
        return PopStatus.NoStatus;
    }

    /// @notice Single canonical "is `userStatus` at reach for `required`?" predicate.
    /// @dev Both `priceWithCheck` and `transferFloor` build on this so the tier-eligibility rule
    /// lives in exactly one place and the callers cannot disagree about who clears a given label.
    /// `_personhoodTier` never returns `Reserved`, so `userStatus` is in `{NoStatus, PopLite,
    /// PopFull}` and the enum comparison reflects tier ordering directly. A `Reserved` `required`
    /// (governance label) is unreachable by any verified user, so the comparison returns false and
    /// the caller charges the friction fee, providing defence-in-depth if a Reserved label ever
    /// enters circulation.
    function _meetsReach(PopStatus required, PopStatus userStatus) private pure returns (bool) {
        return userStatus >= required;
    }

    /// @notice Amount for a base length at the current cost-model version.
    /// @dev The cost-model registry owns the curve; this contract passes it only the base length.
    ///      The call is a view because it runs on the ERC721 transfer floor read through
    ///      @custom:function transferFloor.
    function _priceValidatedName(uint256 baseLength) internal view returns (uint256 priceValue) {
        return _costModelRegistry().priceForBaseLength(baseLength);
    }

    /// @notice Amount for a base length at a specific cost-model version.
    /// @dev Prices an in-flight registration at the version it committed to, so a model change
    ///      between commit and reveal does not move its cost. @custom:reverts UnknownVersion (from
    ///      the registry) when the version was never registered.
    function _priceValidatedNameAtVersion(
        uint256 pricingVersionValue,
        uint256 baseLength
    )
        internal
        view
        returns (uint256 priceValue)
    {
        return _costModelRegistry().priceForBaseLengthAtVersion(pricingVersionValue, baseLength);
    }

    /// @notice Resolves the cost-model registry registered under `DotnsConstants.COST_MODEL`.
    /// @dev @custom:reverts PopError when no registry is configured, so a pricing read fails closed
    ///      rather than resolving through the zero address.
    function _costModelRegistry() private view returns (IDotnsCostModelRegistry registry) {
        address configured = protocolRegistry.get(DotnsConstants.COST_MODEL);
        require(configured != address(0), PopError("Cost model not configured"));
        return IDotnsCostModelRegistry(configured);
    }

    /// @notice Reverts a public paid registration of a base length below nine while the short-name
    ///         market is closed.
    /// @dev The one gate both public price reads share. Base lengths of nine and above are always
    ///      open. @custom:reverts PopError when a base length below nine is priced while
    ///      `shortNamesEnabled` is false. The gateway and @custom:function registerReserved never
    ///      reach this, so neither is gated.
    function _requireShortNamesOpen(uint256 baseLength) private view {
        require(shortNamesEnabled || baseLength >= 9, PopError("Short names are not for sale"));
    }

    /// @notice Index one past `name`'s stem: a lite label without its suffix, or the whole of
    ///         any other label.
    /// @dev Only a lite label has a suffix to remove. The gateway allocates those two digits to
    ///      tell apart people who chose the same stem, so removing them recovers what the
    ///      candidate actually picked. No such allocation stands behind the digits in an
    ///      ordinary label, where they are part of the name: `web3` is a four-character word,
    ///      not `web` with a counter.
    function _stemEnd(string calldata name) private pure returns (uint256 stemEnd) {
        stemEnd = bytes(name).length;
        if (!name.isLitePersonLabel()) return stemEnd;
        return stemEnd - StringUtils.LITE_SUFFIX_DIGITS - 1;
    }

    /// @notice The base length that pricing and classification both use to place a name in its
    ///         band, which is the length of the name's stem.
    /// @dev Every label is measured as written, except a lite label, whose allocated suffix is
    ///      not part of the name the candidate chose. So `web3` and `blink182` are measured
    ///      whole and no digit count is privileged or rejected.
    function _validatedBaseLength(string calldata name) internal pure returns (uint256 baseLength) {
        return _stemEnd(name);
    }

    /// @notice Enforces base-name reservation rules.
    /// @param name Domain label.
    /// @param userAddress Registering user.
    function _enforceReservationRules(string calldata name, address userAddress) internal view {
        string memory baseName = _stripDigits(name);
        Reservation memory reservation = reservations[baseName];

        if (_isLive(reservation)) {
            require(
                reservation.owner == userAddress,
                PopError("Base name reserved for original Lite registrant")
            );
        }
    }

    /// @notice Returns whether `reservation` is live at `block.timestamp`.
    function _isLive(Reservation memory reservation) internal view returns (bool) {
        return reservation.owner != address(0) && reservation.expires > block.timestamp;
    }

    /// @notice Counts trailing digits in a string.
    /// @param label String to analyse.
    /// @return digitCount Number of trailing digits.
    function _countTrailingDigits(string calldata label)
        internal
        pure
        returns (uint256 digitCount)
    {
        bytes calldata bytesLabel = bytes(label);
        for (uint256 i = bytesLabel.length; i > 0; i--) {
            if (bytesLabel[i - 1] >= 0x30 && bytesLabel[i - 1] <= 0x39) {
                digitCount++;
            } else {
                break;
            }
        }
    }

    /// @notice Returns `name`'s stem: a lite label without its allocated suffix, or any other
    ///         label verbatim.
    /// @dev The reservation key. Because only a lite label is shortened, `joseph.42` contends
    ///      with `joseph` while `joseph42` is an unrelated name and contends with nothing.
    /// @param name Domain label.
    function _stripDigits(string calldata name) internal pure returns (string memory baseName) {
        bytes calldata bytesName = bytes(name);
        uint256 endPosition = _stemEnd(name);

        // No suffix to strip: return the input verbatim and skip the manual copy.
        if (endPosition == bytesName.length) return name;

        bytes memory output = new bytes(endPosition);
        for (uint256 i = 0; i < endPosition; i++) {
            output[i] = bytesName[i];
        }

        return string(output);
    }

    function _classifyValidatedName(string calldata name)
        internal
        pure
        returns (PopStatus requirement, string memory message, uint256 baseLength)
    {
        baseLength = _validatedBaseLength(name);

        if (baseLength <= 5) {
            return (PopStatus.Reserved, "Reserved for Governance", baseLength);
        }

        if (baseLength >= 6 && baseLength <= 8) {
            // PopLite is the gateway's separated form. Digits in an ordinary label say nothing
            // about personhood, so such a label sits in the band its length earns.
            if (name.isLitePersonLabel()) {
                return (PopStatus.PopLite, "Requires Lite personhood verification", baseLength);
            }
            return (PopStatus.PopFull, "Requires Full personhood verification", baseLength);
        }

        // Base length >= 9 is open to any caller, and is reached by a lite label whose stem is
        // nine or more through the gateway.
        return (PopStatus.NoStatus, "Available to all", baseLength);
    }

    /// @notice Requires `stem` to be a canonical DNS label, carrying no separator.
    /// @dev Reservation keys are stems, so a separator here is a caller error rather than a lite
    ///      name. A digit suffix passes this check, because a DNS label admits digits; the entry
    ///      points that write a reservation reject one themselves.
    ///      @custom:function _requireLabel is the guard for full labels.
    function _requireStem(string calldata stem) internal pure {
        require(stem.isSingleLabel(), PopError("Name must be lowercase ASCII DNS label"));
    }

    /// @notice Requires `name` to be a label DotNS can issue: a canonical DNS label, or a lite
    ///         label carrying its separator.
    /// @dev The union is the full set of issuable labels, so a near miss such as `alice.4` or
    ///      `a.b.42` still reverts. @custom:function _requireStem is the stricter guard for
    ///      reservation keys, which never carry a separator.
    function _requireLabel(string calldata name) internal pure {
        require(
            name.isSingleLabel() || name.isLitePersonLabel(),
            PopError("Name must be a lowercase ASCII DNS label or a lite label")
        );
    }

    /// @inheritdoc ERC165Upgradeable
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override
        returns (bool supported)
    {
        return interfaceId == type(IPopRules).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Returns implementation version.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.0.0";
    }

    /// @notice Ensures the caller is any controller authorised on the registrar.
    function _onlyRegistry() internal view {
        DotnsRegistrar registrar = DotnsRegistrar(protocolRegistry.get(DotnsConstants.REGISTRAR));
        require(registrar.controllers(IDotnsController(msg.sender)), NotRegistry());
    }

    /// @inheritdoc IPopRules
    function reserveBaseNameForPop(
        string calldata stem,
        address userAddress
    )
        external
        override
        onlyRegistry
    {
        _requireStem(stem);
        require(
            _countTrailingDigits(stem) == 0,
            PopError("Reservation stem must have no trailing digits")
        );
        _writeReservation(stem, userAddress);
    }

    /// @inheritdoc IPopRules
    function stripDigits(string calldata name) external pure override returns (string memory stem) {
        _requireLabel(name);
        return _stripDigits(name);
    }

    /// @inheritdoc IPopRules
    function releaseBaseName(string calldata stem) external override onlyRegistry {
        _requireStem(stem);
        require(
            _countTrailingDigits(stem) == 0,
            PopError("Reservation stem must have no trailing digits")
        );
        Reservation memory reservation = reservations[stem];
        // Live reservations can only be cleared by the controller that wrote
        // them, so one registrar-authorised controller cannot wipe another's
        // active slot. Expired reservations are dead weight and may be cleared
        // by any authorised controller as garbage collection.
        if (_isLive(reservation)) {
            require(
                msg.sender == reservation.controller,
                PopError("Only reserving controller can release")
            );
        }
        delete reservations[stem];
        emit BaseNameReleased(stem);
    }

    /// @inheritdoc IPopRules
    function releaseReservationForReclaim(
        string calldata stem,
        address expectedOwner
    )
        external
        override
        onlyRegistry
    {
        _requireStem(stem);
        require(
            _countTrailingDigits(stem) == 0,
            PopError("Reservation stem must have no trailing digits")
        );
        Reservation memory reservation = reservations[stem];
        // Cross-controller release is gated on owner match rather than controller match,
        // so the public registrar controller can clear a PoP-stamped slot during reclaim
        // when the prior occupant is the reservation owner.
        if (_isLive(reservation)) {
            require(reservation.owner == expectedOwner, PopError("Reservation owner mismatch"));
        }
        delete reservations[stem];
        emit BaseNameReleased(stem);
    }

    /// @notice Internal single-source-of-truth writer for stem reservations.
    /// @dev Routes both @custom:function reserveBaseName and @custom:function reserveBaseNameForPop
    ///      through one path so the cross-user collision semantics stay identical: a live slot held
    ///      by a different user @custom:reverts PopError, and any other case writes a fresh expiry
    ///      and emits @custom:emits BaseNameReserved. Same-owner re-reservations refresh the expiry
    ///      to `block.timestamp + MAX_RESERVATION_TIME`. Callers are responsible for validating
    ///      `stem` is canonical and stem-shaped (no trailing digits); this helper does no input
    ///      validation of its own so each public entry can layer additional eligibility checks.
    function _writeReservation(string calldata stem, address userAddress) internal {
        Reservation memory existing = reservations[stem];
        bool liveSlot = _isLive(existing);
        if (liveSlot) {
            require(existing.owner == userAddress, PopError("Base name held by another user"));
        }

        // `block.timestamp + MAX_RESERVATION_TIME` cannot overflow `uint64`: `MAX_RESERVATION_TIME`
        // is bounded (12 weeks, ~7.26e6) and `uint64` saturates at ~5.84e11, a horizon that does
        // not arrive until year 2554.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 expiryTime = uint64(block.timestamp + MAX_RESERVATION_TIME);
        // Preserve the original stamping `controller` on same-owner refresh so a sibling controller
        // tracking the same stem (e.g. the PoP queue head) retains the right to release. Without
        // this, a same-user re-reservation through a different controller silently steals the slot
        // and bricks the original controller's release/advance/claim paths.
        address stampingController = liveSlot ? existing.controller : msg.sender;
        reservations[stem] =
            Reservation({owner: userAddress, expires: expiryTime, controller: stampingController});
        emit BaseNameReserved(stem, userAddress, expiryTime);
    }
}
