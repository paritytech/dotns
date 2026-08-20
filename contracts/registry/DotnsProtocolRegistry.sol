// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IDotnsProtocolRegistry} from "./IDotnsProtocolRegistry.sol";
import {LabelUtils} from "../utils/LabelUtils.sol";
import {StringUtils} from "../utils/StringUtils.sol";

/// @title Dotns Protocol Registry
/// @author Parity
/// @notice Upgradeable address registry for all DotNS protocol contracts, and the authority for
///         the network's top-level domain.
/// @dev Single source of truth for sibling-contract lookups. All siblings resolve each other via
///      well-known `bytes32` constants in `DotnsConstants` rather than holding direct addresses,
///      so an upgrade or rewire only mutates this contract. The TLD node and suffix are set once
///      at initialisation and read live by every consumer, so a network runs one TLD without
///      recompiling its contracts.
/// @custom:security-contact admin@parity.io
contract DotnsProtocolRegistry is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    IDotnsProtocolRegistry
{
    using StringUtils for string;

    /// @notice Address stored for each well-known protocol key.
    mapping(bytes32 key => address addr) private _addresses;

    /// @notice Reference count per address, incremented for every key it is registered under.
    /// @dev Lets `isRegisteredAddress` answer in O(1) and survive a contract being mapped to
    ///      multiple keys without being treated as deregistered when only one key is rewired.
    mapping(address addr => uint256 refcount) private _registeredRefcount;

    /// @notice Namehash of the TLD node, `namehash(0, keccak256(bytes(tldLabel)))`.
    bytes32 private _tldNode;

    /// @notice TLD suffix including the leading dot, e.g. `.dot`.
    string private _tld;

    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the protocol registry and fixes the network's TLD.
    /// @dev Callable exactly once via `Initializable`, otherwise
    ///      @custom:reverts InvalidInitialization. Sets the deployer as owner. `tldLabel` is the
    ///      bare label without a dot (e.g. `dot`, `paseo`); it must be a single DNS label,
    ///      otherwise @custom:reverts InvalidTld. The TLD is fixed here because changing it after
    ///      names exist would reroot every node.
    /// @param tldLabel Bare TLD label, without the leading dot.
    function initialize(string calldata tldLabel) external initializer {
        __Ownable_init(msg.sender);

        require(tldLabel.isSingleLabel(), InvalidTld());
        _tldNode = LabelUtils.namehashUnder(bytes32(0), LabelUtils.labelhash(tldLabel));
        _tld = string.concat(".", tldLabel);
    }

    /// @inheritdoc IDotnsProtocolRegistry
    function get(bytes32 key) external view override returns (address addr) {
        return _addresses[key];
    }

    /// @inheritdoc IDotnsProtocolRegistry
    function set(bytes32 key, address addr) external override onlyOwner {
        require(addr != address(0), ZeroAddress());

        address previousAddress = _addresses[key];
        if (previousAddress == addr) return;

        if (previousAddress != address(0)) {
            --_registeredRefcount[previousAddress];
        }
        ++_registeredRefcount[addr];

        _addresses[key] = addr;
        emit AddressUpdated(key, addr);
    }

    /// @inheritdoc IDotnsProtocolRegistry
    function isRegisteredAddress(address addr) external view override returns (bool registered) {
        return addr != address(0) && _registeredRefcount[addr] > 0;
    }

    /// @inheritdoc IDotnsProtocolRegistry
    function tldNode() external view override returns (bytes32 node) {
        return _tldNode;
    }

    /// @inheritdoc IDotnsProtocolRegistry
    function tld() external view override returns (string memory suffix) {
        return _tld;
    }

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.0.0";
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
