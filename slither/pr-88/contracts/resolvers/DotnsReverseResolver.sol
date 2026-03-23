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
import {IDotnsReverseResolver} from "./IDotnsReverseResolver.sol";
import {IDotnsRegistrarController} from "../registrars/IDotnsRegistrarController.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";

/// @title Dotns Reverse Resolver
/// @notice Resolves an address to its associated .dot name.
/// @dev Maintains an on-chain mapping from addresses to name strings.
///      Writes are restricted to an authorised registrar.
/// @custom:security-contact admin@parity.io
contract DotnsReverseResolver is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IDotnsReverseResolver
{
    /// @dev Mapping from address to its reverse name.
    ///      An empty string indicates that no reverse name is set.
    mapping(address owner => string name) private reverseNames;

    /// @notice DEPRECATED: Address authorised to modify reverse name records.
    /// @dev Retained for UUPS storage layout compatibility. Use protocolRegistry instead.
    /// TODO: Remove on fresh deploy (not upgrade). Restore __gap accordingly.
    IDotnsRegistrarController public registrarController;

    /// @notice Protocol-level address registry for all DotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @notice Well-known protocol registry key for the registrar controller.
    /// casting to 'bytes32' is safe because the string fits in 32 bytes.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant KEY_CONTROLLER = bytes32("controller");

    /// @notice Well-known protocol registry key for the ERC721 registrar.
    /// casting to 'bytes32' is safe because the string fits in 32 bytes.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant KEY_REGISTRAR = bytes32("registrar");

    /// @dev Reserved storage space to allow for layout changes in the future.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[49] private __gap;

    /// @notice Restricts access to the configured registrar.
    modifier onlyRegistrar() {
        _onlyRegistrar();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the reverse resolver.
    /// @dev This function may only be called once.
    function initialize() external initializer {
        __Ownable_init(msg.sender);
        __ERC165_init();
    }

    /// @inheritdoc IDotnsReverseResolver
    function setReverseName(address addr, string calldata name) external override onlyRegistrar {
        reverseNames[addr] = name;
        emit ReverseNameSet(addr, name);
    }

    /// @inheritdoc IDotnsReverseResolver
    function nameOf(address addr) external view override returns (string memory name) {
        return reverseNames[addr];
    }

    /// @inheritdoc ERC165Upgradeable
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165Upgradeable)
        returns (bool supported)
    {
        return interfaceId == type(IDotnsReverseResolver).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IDotnsReverseResolver
    function updateProtocolRegistry(IDotnsProtocolRegistry registry) external override onlyOwner {
        protocolRegistry = registry;
        emit ProtocolRegistryUpdated(registry);
    }

    /// @notice Internal check enforcing registrar-only access.
    function _onlyRegistrar() internal view {
        address controller = protocolRegistry.get(KEY_CONTROLLER);
        address registrar = protocolRegistry.get(KEY_REGISTRAR);
        require(
            msg.sender == controller || msg.sender == registrar, NotRegistrarController(msg.sender)
        );
    }

    /// @notice Returns implementation version
    /// @return versionString Current version string
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.1.0";
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
