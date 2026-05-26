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
import {IPopRules} from "./IPopRules.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {IDotnsController} from "../registrars/IDotnsController.sol";
import {DotnsRegistrar} from "../registrars/DotnsRegistrar.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";
import {IPersonhood} from "../external/personhood/IPersonhood.sol";

/// @title PopRules
/// @notice Implements DotNS classification, flat NoStatus pricing, and base-name reservations.
/// @dev Tier shape: lengths <= 5 are governance-reserved, lengths 6-8 require PopFull (or
///      PopLite when carrying exactly two trailing digits, for gateway-issued lite names),
///      lengths >= 9 are open to any caller as NoStatus when they carry zero or exactly two
///      trailing digits. A one-digit suffix and more than two trailing digits are invalid.
///      NoStatus users pay a single flat deposit (`startingPrice`) per name; verified users pay
/// zero. @custom:security-contact admin@parity.io
contract PopRules is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IPopRules
{
    using StringUtils for *;

    /// @notice Wei price for names with 9 characters and up.
    uint256 public startingPrice;

    /// @notice Active reservations keyed by digit-stripped base name.
    mapping(string baseName => Reservation reservation) public reservations;

    /// @notice Maximum time a base name can be reserved.
    uint256 public constant MAX_RESERVATION_TIME = 12 weeks;

    /// @notice Protocol-level address registry for all DotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

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

    /// @notice Initialises the oracle with pricing parameters.
    /// @param _startingPrice Base price in wei for NoStatus users.
    /// @param registry Protocol-level address registry used to resolve sibling contracts.
    function _popRulesInit(
        uint256 _startingPrice,
        IDotnsProtocolRegistry registry
    )
        internal
        onlyInitializing
    {
        __Ownable_init(msg.sender);
        __ERC165_init();
        updateStartingPrice(_startingPrice);
        protocolRegistry = registry;
    }

    /// @notice Initialises the oracle (public entry point).
    /// @dev Runs once behind the proxy; subsequent calls trigger @custom:reverts
    ///      InvalidInitialization via the `initializer` modifier. Forwards to
    ///      @custom:function _popRulesInit, which seeds `startingPrice` through
    ///      @custom:function updateStartingPrice.
    /// @param _startingPrice Base price in wei for NoStatus users.
    /// @param registry Protocol-level address registry used to resolve sibling contracts.
    function initialize(
        uint256 _startingPrice,
        IDotnsProtocolRegistry registry
    )
        public
        initializer
    {
        _popRulesInit(_startingPrice, registry);
    }

    /// @inheritdoc IPopRules
    function updateStartingPrice(uint256 newStartingPrice) public override onlyOwner {
        require(newStartingPrice > 0, PopError("Price must be greater than 0"));
        emit StartingPriceUpdated(startingPrice, newStartingPrice);
        startingPrice = newStartingPrice;
    }

    /// @inheritdoc IPopRules
    function classifyName(string calldata name)
        public
        pure
        override
        returns (PopStatus requirement, string memory message)
    {
        _requireCanonicalLabel(name);
        return _classifyValidatedName(name);
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
        _requireCanonicalLabel(stem);
        uint256 stemLength = bytes(stem).length;
        require(
            stemLength >= 6 && stemLength <= 8 && _countTrailingDigits(stem) == 0,
            PopError("Reservation stem must be 6-8 chars with no trailing digits")
        );
        _writeReservation(stem, userAddress);
    }

    /// @inheritdoc IPopRules
    function isBaseName(string calldata baseName) public pure override returns (bool isBase) {
        _requireCanonicalLabel(baseName);
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
        _requireCanonicalLabel(baseName);
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
        _requireCanonicalLabel(baseName);
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
        _requireCanonicalLabel(name);
        _enforceReservationRules(name, userAddress);

        (PopStatus requiredStatus, string memory classification) = _classifyValidatedName(name);
        PopStatus userStatus = _personhoodTier(userAddress);

        metadata.price =
            userStatus == PopStatus.NoStatus ? _priceValidatedName(bytes(name).length) : 0;
        metadata.status = requiredStatus;
        metadata.userStatus = userStatus;
        metadata.message = classification;

        require(requiredStatus != PopStatus.Reserved, PopError(classification));

        if (requiredStatus == PopStatus.PopFull) {
            require(
                userStatus == PopStatus.PopFull, PopError("Requires Full Personhood verification")
            );
        } else if (requiredStatus == PopStatus.PopLite) {
            require(
                userStatus == PopStatus.PopLite || userStatus == PopStatus.PopFull,
                PopError("Requires Personhood Lite verification")
            );
        }
        // requiredStatus == PopStatus.NoStatus falls through: any user tier may register.

        return metadata;
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
        _requireCanonicalLabel(name);

        (PopStatus requiredStatus, string memory classification) = _classifyValidatedName(name);
        PopStatus userStatus = _personhoodTier(userAddress);

        metadata.price =
            userStatus == PopStatus.NoStatus ? _priceValidatedName(bytes(name).length) : 0;
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
    function price(string calldata name) public view override returns (uint256) {
        _requireCanonicalLabel(name);
        return _priceValidatedName(bytes(name).length);
    }

    /// @inheritdoc IPopRules
    function reachFee(
        string calldata name,
        address account
    )
        external
        view
        override
        returns (uint256 fee)
    {
        _requireCanonicalLabel(name);
        (PopStatus required,) = _classifyValidatedName(name);
        if (_meetsReach(required, _personhoodTier(account))) {
            return 0;
        }
        return startingPrice;
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
        _requireCanonicalLabel(name);
        (PopStatus required,) = _classifyValidatedName(name);

        PopStatus toTier = _personhoodTier(to);
        uint256 reachComponent = _meetsReach(required, toTier) ? 0 : startingPrice;

        PopStatus fromTier = _personhoodTier(from);
        // `_personhoodTier` never returns Reserved, so users are NoStatus(0)/PopLite(1)/PopFull(2)
        // and uint8 ordering matches tier ordering.
        uint256 downgradeComponent = uint8(toTier) < uint8(fromTier) ? startingPrice : 0;

        return reachComponent > downgradeComponent ? reachComponent : downgradeComponent;
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
    /// @dev Both `reachFee` and `priceWithCheck` build on this so the tier-eligibility rule lives
    /// in exactly one place and the two callers cannot disagree about who clears a given label.
    function _meetsReach(PopStatus required, PopStatus userStatus) private pure returns (bool) {
        if (required == PopStatus.PopFull) {
            return userStatus == PopStatus.PopFull;
        }
        if (required == PopStatus.PopLite) {
            return userStatus == PopStatus.PopLite || userStatus == PopStatus.PopFull;
        }
        return true;
    }

    function _priceValidatedName(uint256 namelength) internal view returns (uint256 priceValue) {
        if (namelength < 9) {
            return 0;
        }
        return startingPrice;
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
        uint256 stringlength = bytesLabel.length;

        for (uint256 i = stringlength; i > 0; i--) {
            if (bytesLabel[i - 1] >= 0x30 && bytesLabel[i - 1] <= 0x39) {
                digitCount++;
            } else {
                break;
            }
        }
    }

    /// @notice Strips trailing digits from a name.
    /// @param name Domain label.
    function _stripDigits(string calldata name) internal pure returns (string memory baseName) {
        bytes calldata bytesName = bytes(name);
        uint256 endPosition = bytesName.length;

        while (
            endPosition > 0 && bytesName[endPosition - 1] >= 0x30
                && bytesName[endPosition - 1] <= 0x39
        ) {
            endPosition--;
        }

        bytes memory output = new bytes(endPosition);
        for (uint256 i = 0; i < endPosition; i++) {
            output[i] = bytesName[i];
        }

        return string(output);
    }

    function _classifyValidatedName(string calldata name)
        internal
        pure
        returns (PopStatus requirement, string memory message)
    {
        uint256 totallength = bytes(name).length;
        uint256 trailingDigits = _countTrailingDigits(name);

        require(
            trailingDigits == 0 || trailingDigits == 2,
            PopError("Name must have no digit suffix or exactly 2 digit suffix")
        );

        uint256 baselength = totallength - trailingDigits;

        if (baselength <= 5) {
            return (PopStatus.Reserved, "Reserved for Governance");
        }

        if (baselength >= 6 && baselength <= 8) {
            if (trailingDigits == 2) {
                return (PopStatus.PopLite, "Requires Light personhood verification");
            }
            return (PopStatus.PopFull, "Requires Full personhood verification");
        }

        // Baselength >= 9 is open to any caller with no suffix or the two-digit lite suffix shape.
        return (PopStatus.NoStatus, "Available to all");
    }

    function _requireCanonicalLabel(string calldata name) internal pure {
        require(name.isSingleLabel(), PopError("Name must be lowercase ASCII DNS label"));
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
        _requireCanonicalLabel(stem);
        require(
            _countTrailingDigits(stem) == 0,
            PopError("Reservation stem must have no trailing digits")
        );
        _writeReservation(stem, userAddress);
    }

    /// @inheritdoc IPopRules
    function stripDigits(string calldata name) external pure override returns (string memory stem) {
        _requireCanonicalLabel(name);
        return _stripDigits(name);
    }

    /// @inheritdoc IPopRules
    function releaseBaseName(string calldata stem) external override onlyRegistry {
        _requireCanonicalLabel(stem);
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
        _requireCanonicalLabel(stem);
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
    function _writeReservation(string memory stem, address userAddress) internal {
        Reservation memory existing = reservations[stem];
        if (_isLive(existing)) {
            require(existing.owner == userAddress, PopError("Base name held by another user"));
        }

        // `block.timestamp + MAX_RESERVATION_TIME` cannot overflow `uint64`: `MAX_RESERVATION_TIME`
        // is bounded (one year, ~3.15e7) and `uint64` saturates at ~5.84e11, a horizon that does
        // not arrive until year 2554.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 expiryTime = uint64(block.timestamp + MAX_RESERVATION_TIME);
        reservations[stem] =
            Reservation({owner: userAddress, expires: expiryTime, controller: msg.sender});
        emit BaseNameReserved(stem, userAddress, expiryTime);
    }
}
