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

    /// @notice Wei price for names with 9 characters and up
    uint256 public startingPrice;

    /// @notice Tracks PoP status per user/profile
    mapping(address => PopStatus) public userPopStatus;

    /// @notice Active reservations for base names
    mapping(string baseName => Reservation reservation) public reservations;

    /// @notice Maximum time a base name can be reserved
    uint256 public constant MAX_RESERVATION_TIME = 12 weeks;

    /// @notice Namehash of .dot TLD
    bytes32 private constant DOT_NODE =
        0x3fce7d1364a893e213bc4212792b517ffc88f5b13b86c8ef9c8d390c3a1370ce;

    /// @notice DEPRECATED: Authorized registry controller address.
    /// @dev Retained for UUPS storage layout compatibility. Use protocolRegistry instead.
    /// TODO: Remove on fresh deploy (not upgrade). Restore __gap accordingly.
    address public dotRegistryController;

    /// @notice Protocol-level address registry for all DotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @notice Well-known protocol registry key for the registrar controller.
    /// casting to 'bytes32' is safe because the string fits in 32 bytes.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant KEY_CONTROLLER = bytes32("controller");

    /// @dev Reserved storage space to allow for layout changes in the future.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[49] private __gap;

    /// @notice Restricts function to registry controller
    modifier onlyRegistry() {
        _onlyRegistry();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the oracle with pricing parameters
    /// @param _startingPrice Base price in wei for No pop status users
    function _popRulesInit(uint256 _startingPrice) internal onlyInitializing {
        __Ownable_init(msg.sender);
        __ERC165_init();
        startingPrice = _startingPrice;
    }

    /// @notice Initializes the oracle (public entry point)
    /// @param _startingPrice Base price in wei for No pop status users
    function initialize(uint256 _startingPrice) public initializer {
        _popRulesInit(_startingPrice);
    }

    /// @inheritdoc IPopRules
    function setUserPopStatus(PopStatus status) external override {
        userPopStatus[msg.sender] = status;
        emit UserPopStatusSet(msg.sender, status);
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
        if (
            existingReservation.owner == address(0)
                || existingReservation.expires <= block.timestamp
        ) {
            // casting to 'uint64' is safe because MAX_RESERVATION_TIME will never be large enough to cause a revert
            // forge-lint: disable-next-line(unsafe-typecast)
            uint64 expiryTime = uint64(block.timestamp + MAX_RESERVATION_TIME);
            reservations[strippedBase] = Reservation({owner: userAddress, expires: expiryTime});
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
        if (reservation.owner != address(0) && reservation.expires > block.timestamp) {
            return (true, reservation.owner, reservation.expires);
        }
        return (false, reservation.owner, reservation.expires);
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
        } else {
            uint256 trailingDigits = _countTrailingDigits(name);
            require(
                trailingDigits != 0 && userStatus != PopStatus.PopLite,
                PopError("Personhood Lite cannot register base names")
            );
        }

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

        if (
            reservation.owner != address(0) && reservation.expires > block.timestamp
                && reservation.owner != userAddress
        ) {
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

    function _priceValidatedName(uint256 namelength) internal view returns (uint256 priceValue) {
        if (namelength < 9) {
            return 0;
        }

        if (namelength >= 15) {
            return startingPrice / 2;
        }

        return startingPrice * (15 - namelength);
    }

    /// @notice Enforces base name reservation rules
    /// @param name Domain label
    /// @param userAddress Registering user
    function _enforceReservationRules(string calldata name, address userAddress) internal view {
        string memory baseName = _stripDigits(name);
        Reservation memory reservation = reservations[baseName];

        if (reservation.owner != address(0) && reservation.expires > block.timestamp) {
            require(
                reservation.owner == userAddress,
                PopError("Base name reserved for original Lite registrant")
            );
        }
    }

    /// @notice Counts trailing digits in a string
    /// @param label String to analyze
    /// @return digitCount Number of trailing digits
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

    /// @notice Strips trailing digits from a name
    /// @param name Domain label
    /// @return baseName Name without trailing digits
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
    function updateProtocolRegistry(IDotnsProtocolRegistry registry) external override onlyOwner {
        protocolRegistry = registry;
        emit ProtocolRegistryUpdated(registry);
    }

    /// @notice Returns implementation version
    /// @return versionString Current version string
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.1.0";
    }

    /// @notice Ensures the caller is the authorized registry controller
    function _onlyRegistry() internal view {
        address controller = protocolRegistry.get(KEY_CONTROLLER);
        require(msg.sender == controller, NotRegistry());
    }
}
