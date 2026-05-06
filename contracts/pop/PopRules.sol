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
import {StringUtils} from "../utils/StringUtils.sol";
import {IPopRules} from "./IPopRules.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {IDotnsController} from "../registrars/IDotnsController.sol";
import {DotnsRegistrar} from "../registrars/DotnsRegistrar.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";

/// @title PopRules
/// @notice Implements DotNS pricing with PoP-tier validation and base-name reservations
/// @custom:security-contact admin@parity.io
contract PopRules is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IPopRules
{
    using StringUtils for *;

    /// @notice Base unit for the length-scaled name price.
    /// @dev Scales down inside `_priceValidatedName` according to label length;
    ///      charged to NoStatus users as a spam deterrent and to below-tier reach
    ///      paths as protocol friction.
    uint256 public startingPrice;

    /// @notice Tracks PoP status per user profile.
    /// @dev Temporary until a precompile exposes PoP status directly from the
    ///      pallet; every registration read goes through this map.
    mapping(address => PopStatus) public userPopStatus;

    /// @notice Active reservations keyed by digit-stripped base name.
    /// @dev Single cross-flow reservation table. Both the commit-reveal
    ///      controller (via `priceWithCheck`) and the PoP controller (via
    ///      `reserveBaseNameForPop` / `releaseBaseName`) read and write this
    ///      map, so the live-window predicate `_isLive` stays the one place
    ///      freshness is computed.
    mapping(string baseName => Reservation reservation) public reservations;

    /// @notice Maximum time a base name can be reserved.
    /// @dev Every reservation write (`reserveBaseName`, `reserveBaseNameForPop`)
    ///      stamps `block.timestamp + MAX_RESERVATION_TIME` as the expiry; the
    ///      reservation predicate `_isLive` tests this bound.
    uint256 public constant MAX_RESERVATION_TIME = 12 weeks;

    /// @notice DEPRECATED: Authorised registry controller address.
    /// @dev Retained for UUPS storage layout compatibility. Use protocolRegistry instead.
    /// TODO: Remove on fresh deploy (not upgrade). Restore __gap accordingly.
    address public dotRegistryController;

    /// @notice Protocol-level address registry for all DotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @dev Reserved storage space to allow for layout changes in the future.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[49] private __gap;

    /// @notice Restricts function to any registry-authorised controller
    /// @dev The registrar's `controllers` mapping is the canonical ACL for "who may
    ///      drive DotNS name state". Every controller lives behind owner-gated
    ///      `addController` / `removeController`, so trusting that set directly
    ///      keeps PopRules open to current and future controllers without
    ///      requiring a new modifier per controller type.
    modifier onlyRegistry() {
        _onlyRegistry();
        _;
    }

    /// @notice Restricts function to the single PoP controller resolved through
    ///         the protocol registry under `POP_CONTROLLER`.
    /// @dev Used by the pop-flow paths (`reserveBaseNameForPop`, `releaseBaseName`)
    ///      which are only ever called by the dedicated `DotnsPopController`. The
    ///      tighter gate replaces the broader `onlyRegistry` check on these paths,
    ///      keeping pop-flow access aligned with the single-controller architecture.
    ///      The commit-reveal `reserveBaseName` keeps `onlyRegistry` because that
    ///      path is shared by every registrar-authorised controller.
    modifier onlyPopController() {
        _onlyPopController();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the oracle with pricing parameters.
    /// @dev Shared initialiser body; called from `initialize` so future upgrade
    ///      variants can reuse the same setup without duplicating the Ownable
    ///      and ERC165 wiring.
    /// @param _startingPrice Base price in wei for NoStatus users.
    function _popRulesInit(uint256 _startingPrice) internal onlyInitializing {
        __Ownable_init(msg.sender);
        __ERC165_init();
        startingPrice = _startingPrice;
    }

    /// @notice Initialises the oracle (public entry point).
    /// @dev One-shot initialiser invoked through the UUPS proxy. Delegates to
    ///      `_popRulesInit` so an upgraded initialiser can add new wiring
    ///      without rewriting the base setup.
    /// @param _startingPrice Base price in wei for NoStatus users.
    // TODO: On fresh deploy (not upgrade), accept IDotnsProtocolRegistry and set protocolRegistry here.
    function initialize(uint256 _startingPrice) public initializer {
        _popRulesInit(_startingPrice);
    }

    /// @inheritdoc IPopRules
    function setUserPopStatus(PopStatus status) external override {
        userPopStatus[msg.sender] = status;
        emit UserPopStatusSet(msg.sender, status);
    }

    /// @inheritdoc IPopRules
    function updateStartingPrice(uint256 newStartingPrice) external override onlyOwner {
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
        string calldata name,
        address userAddress
    )
        external
        override
        onlyRegistry
    {
        _requireCanonicalLabel(name);

        (PopStatus requiredStatus,) = _classifyValidatedName(name);
        require(
            requiredStatus == PopStatus.PopLite,
            PopError("Base reservation requires a lite-eligible name")
        );

        string memory strippedBase = _stripDigits(name);

        Reservation memory existingReservation = reservations[strippedBase];
        if (!_isLive(existingReservation)) {
            // casting to 'uint64' is safe because MAX_RESERVATION_TIME will never be large enough to cause a revert
            // forge-lint: disable-next-line(unsafe-typecast)
            uint64 expiryTime = uint64(block.timestamp + MAX_RESERVATION_TIME);
            reservations[strippedBase] =
                Reservation({owner: userAddress, expires: expiryTime, controller: msg.sender});
            emit BaseNameReserved(strippedBase, userAddress, expiryTime);
        }
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
        PopStatus userStatus = userPopStatus[userAddress];

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
        PopStatus userStatus = userPopStatus[userAddress];

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
        if (_meetsReach(required, userPopStatus[account])) {
            return 0;
        }
        return _priceValidatedName(bytes(name).length);
    }

    /// @notice Single canonical "is `userStatus` at reach for `required`?" predicate.
    /// @dev Mirrors the personhood gate enforced in `priceWithCheck` so the cross-payer
    ///      and transfer paths that bypass that gate compute the same answer when
    ///      pricing the bypass.
    function _meetsReach(PopStatus required, PopStatus userStatus) internal pure returns (bool) {
        if (required == PopStatus.PopFull) {
            return userStatus == PopStatus.PopFull;
        }
        if (required == PopStatus.PopLite) {
            return userStatus == PopStatus.PopLite || userStatus == PopStatus.PopFull;
        }
        return true;
    }

    function _priceValidatedName(uint256 namelength) internal view returns (uint256 priceValue) {
        if (namelength >= 15) {
            return startingPrice / 2;
        }

        return startingPrice * (15 - namelength);
    }

    /// @notice Enforces base-name reservation rules.
    /// @dev Invoked from `priceWithCheck`. A live reservation owned by a
    ///      different user blocks the registration; a matching owner passes
    ///      through; an expired or empty slot is a no-op.
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
    /// @dev Single canonical live-reservation predicate so every reservation
    ///      read path (`priceWithCheck`, `priceWithoutCheck`, `isBaseNameReserved`,
    ///      `reserveBaseName`, `reserveBaseNameForPop`) agrees on the edge
    ///      condition and cannot drift.
    function _isLive(Reservation memory reservation) internal view returns (bool) {
        return reservation.owner != address(0) && reservation.expires > block.timestamp;
    }

    /// @notice Counts trailing digits in a string.
    /// @dev Walks the label right-to-left until a non-digit byte; used by
    ///      classification and `_stripDigits` to separate the base stem from
    ///      the lite-suffix.
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
    /// @dev Returns the stem used as the reservation-table key so `alice42`
    ///      and `alice` share one reservation slot.
    /// @param name Domain label.
    /// @return baseName Name without trailing digits.
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

        require(trailingDigits <= 2, PopError("Name can have maximum 2 digit suffix"));

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

        if (trailingDigits == 2) {
            return (PopStatus.NoStatus, "Available to all");
        }

        return (PopStatus.PopFull, "Requires Full personhood verification");
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

    /// @inheritdoc IPopRules
    // TODO: On fresh deploy (not upgrade), remove this function. Set protocolRegistry in initialize instead.
    function updateProtocolRegistry(IDotnsProtocolRegistry registry) external override onlyOwner {
        protocolRegistry = registry;
        emit ProtocolRegistryUpdated(registry);
    }

    /// @notice Returns implementation version.
    /// @dev Bumped on every upgrade. Used by deployment scripts as a
    ///      post-upgrade assertion target.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.5.0";
    }

    /// @notice Ensures the caller is any controller authorised on the registrar.
    /// @dev Trusts `DotnsRegistrar.controllers[msg.sender]` as the single source of
    ///      truth for "is this address an authorised DotNS controller". Lets the
    ///      commit-reveal controller and the PoP controller both write reservations
    ///      without PopRules knowing their specific interfaces.
    function _onlyRegistry() internal view {
        DotnsRegistrar registrar = DotnsRegistrar(protocolRegistry.get(DotnsConstants.REGISTRAR));
        require(registrar.controllers(IDotnsController(msg.sender)), NotRegistry());
    }

    /// @notice Ensures the caller is the configured PoP controller.
    /// @dev Resolves `POP_CONTROLLER` from the protocol registry on every call so a
    ///      controller upgrade (a new proxy address registered under the same key)
    ///      takes effect without PopRules needing its own setter or storage slot.
    ///      Tighter than `_onlyRegistry` for pop-flow paths because there is exactly
    ///      one valid pop-flow caller.
    function _onlyPopController() internal view {
        address popController = protocolRegistry.get(DotnsConstants.POP_CONTROLLER);
        require(msg.sender == popController, NotRegistry());
    }

    /// @inheritdoc IPopRules
    function reserveBaseNameForPop(
        string calldata baseName,
        address userAddress
    )
        external
        override
        onlyPopController
    {
        _requireCanonicalLabel(baseName);

        Reservation memory existing = reservations[baseName];
        if (_isLive(existing)) {
            // An earlier reserver still holds the live slot. A silent no-op here
            // would let the PoP controller's local queue state diverge from
            // PopRules (controller writes head-bookkeeping assuming the write
            // landed). Reverting propagates the collision back to the caller so
            // both sides stay consistent. Refresh-own-expiry still goes through.
            require(existing.owner == userAddress, PopError("Base name held by another user"));
        }

        // casting to 'uint64' is safe because MAX_RESERVATION_TIME will never be
        // large enough to cause a revert.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 expiryTime = uint64(block.timestamp + MAX_RESERVATION_TIME);
        reservations[baseName] =
            Reservation({owner: userAddress, expires: expiryTime, controller: msg.sender});
        emit BaseNameReserved(baseName, userAddress, expiryTime);
    }

    /// @inheritdoc IPopRules
    function releaseBaseName(string calldata baseName) external override onlyPopController {
        _requireCanonicalLabel(baseName);
        Reservation memory reservation = reservations[baseName];
        // Live reservations can only be cleared by the controller that wrote
        // them, so one registrar-authorised controller cannot wipe another's
        // active slot. Expired reservations are dead weight and may be cleared
        // by any authorised controller as garbage collection. Reservations
        // with a zero controller predate this field and also fall through to
        // the GC path for backwards compatibility.
        if (_isLive(reservation) && reservation.controller != address(0)) {
            require(
                msg.sender == reservation.controller,
                PopError("Only reserving controller can release")
            );
        }
        delete reservations[baseName];
        emit BaseNameReleased(baseName);
    }
}
