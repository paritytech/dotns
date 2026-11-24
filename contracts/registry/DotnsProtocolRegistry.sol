// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BootstrapOwnableUpgradeable} from "../utils/BootstrapOwnableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IDotnsProtocolRegistry} from "./IDotnsProtocolRegistry.sol";
import {LabelUtils} from "../utils/LabelUtils.sol";
import {StringUtils} from "../utils/StringUtils.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";

/// @title dotNS Protocol Registry
/// @author Parity
/// @notice Upgradeable address registry for all dotNS protocol contracts, and the authority for
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
    BootstrapOwnableUpgradeable,
    IDotnsProtocolRegistry
{
    using StringUtils for string;
    using EnumerableSet for EnumerableSet.Bytes32Set;

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

    /// @notice Codehash declared for the code that executes for each well-known key.
    mapping(bytes32 key => bytes32 codehash) private _expectedCodehash;

    /// @notice Release tag the network was last declared to run, bare semver (e.g. `0.8.0`).
    string private _protocolVersion;

    /// @notice Every key that holds an address, so the keys can be listed on chain.
    EnumerableSet.Bytes32Set private _keys;

    uint256[48] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the protocol registry and fixes the network's TLD.
    /// @dev Callable exactly once via `Initializable`, otherwise
    ///      @custom:reverts InvalidInitialization. Sets `initialOwner` as owner. `tldLabel` is the
    ///      bare label without a dot (e.g. `dot`, `paseo`); it must be a single DNS label,
    ///      otherwise @custom:reverts InvalidTld. The TLD is fixed here because changing it after
    ///      names exist would reroot every node.
    /// @param initialOwner Bootstrap owner, which governs alongside Root until it renounces.
    /// @param tldLabel Bare TLD label, without the leading dot.
    function initialize(address initialOwner, string calldata tldLabel) external initializer {
        __Ownable_init(initialOwner);

        require(tldLabel.isSingleLabel(), InvalidTld());
        _tldNode = LabelUtils.namehashUnder(bytes32(0), LabelUtils.labelhash(tldLabel));
        _tld = string.concat(".", tldLabel);
    }

    /// @inheritdoc IDotnsProtocolRegistry
    function get(bytes32 key) external view override returns (address addr) {
        return _addresses[key];
    }

    /// @inheritdoc IDotnsProtocolRegistry
    function set(bytes32 key, address addr) external override onlyRootOrOwner {
        require(addr != address(0), ZeroAddress());

        _keys.add(key);
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
    function remove(bytes32 key) external override onlyRootOrOwner {
        address previousAddress = _addresses[key];
        require(previousAddress != address(0), KeyNotRegistered());

        --_registeredRefcount[previousAddress];
        delete _addresses[key];
        _keys.remove(key);
        // A codehash declared for a key nothing resolves any more describes nothing; leaving it
        // would make a later re-registration under this key start out with a stale claim.
        delete _expectedCodehash[key];

        emit AddressRemoved(key, previousAddress);
    }

    /// @inheritdoc IDotnsProtocolRegistry
    function keys() external view override returns (bytes32[] memory registeredKeys) {
        return _keys.values();
    }

    /// @inheritdoc IDotnsProtocolRegistry
    function initializeKeys() external override reinitializer(2) onlyRootOrOwner {
        bytes32[] memory known = DotnsConstants.registryKeys();
        for (uint256 i = 0; i < known.length; ++i) {
            if (_addresses[known[i]] != address(0)) _keys.add(known[i]);
        }
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

    /// @inheritdoc IDotnsProtocolRegistry
    function protocolVersion() external view override returns (string memory semver) {
        return _protocolVersion;
    }

    /// @inheritdoc IDotnsProtocolRegistry
    function setProtocolVersion(string calldata semver) external override onlyRootOrOwner {
        bytes calldata raw = bytes(semver);
        require(raw.length != 0 && raw[0] >= "0" && raw[0] <= "9", InvalidProtocolVersion());
        for (uint256 i = 1; i < raw.length; ++i) {
            bytes1 char = raw[i];
            bool allowed = (char >= "0" && char <= "9") || (char >= "a" && char <= "z")
                || (char >= "A" && char <= "Z") || char == "." || char == "-";
            require(allowed, InvalidProtocolVersion());
        }

        _protocolVersion = semver;
        emit ProtocolVersionSet(semver);
    }

    /// @notice Returns the declared release, mirroring `protocolVersion` under the historical
    ///         `version()` selector every dotNS contract exposes.
    /// @dev Sibling contracts mirror the same stored value by reading it from here, so
    ///      `version()` answers identically network-wide; this contract is where the value
    ///      lives, so it reads its own storage.
    /// @return versionString Declared release as bare semver, empty when never declared.
    function version() external view virtual returns (string memory versionString) {
        versionString = _protocolVersion;
    }

    /// @inheritdoc IDotnsProtocolRegistry
    function expectedCodehash(bytes32 key) external view override returns (bytes32 codehash) {
        return _expectedCodehash[key];
    }

    /// @inheritdoc IDotnsProtocolRegistry
    function setExpectedCodehash(bytes32 key, bytes32 codehash) external override onlyRootOrOwner {
        require(_addresses[key] != address(0), KeyNotRegistered());

        _expectedCodehash[key] = codehash;
        emit ExpectedCodehashSet(key, codehash);
    }

    /// @notice Removes the bootstrap owner of the whole deployment, leaving Root as the only
    ///         governance of every dotNS contract.
    /// @dev Root only, otherwise @custom:reverts RenounceRequiresRoot: a Root call passes the gate
    ///      behind this proxy only on a runtime where Root can govern dotNS. Clears the owner,
    ///      then requires every contract under a known key (`DotnsConstants.registryKeys`) or a
    ///      registered key that answers `owner()` to answer zero, otherwise
    ///      @custom:reverts OwnerStillSet. A contract that reads its owner from this registry
    ///      passes. A contract still running code with an owner of its own, such as a proxy not
    ///      yet upgraded or a superseded cost model registry left under its key, fails the
    ///      renounce. A contract with no `owner()` is skipped. Reads no `msg.sender`.
    function renounceOwnership() public override onlyRoot {
        _transferOwnership(address(0));
        bytes32[] memory known = DotnsConstants.registryKeys();
        for (uint256 i; i < known.length; ++i) {
            _requireNoOwner(known[i]);
        }
        uint256 count = _keys.length();
        for (uint256 i; i < count; ++i) {
            _requireNoOwner(_keys.at(i));
        }
    }

    /// @notice Reverts with OwnerStillSet when the contract under `key` answers a non-zero
    ///         `owner()`.
    /// @dev Skips an unset key and a contract whose `owner()` reverts or answers malformed data.
    /// @param key Registry key to check.
    function _requireNoOwner(bytes32 key) private view {
        address target = _addresses[key];
        if (target == address(0)) return;
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSelector(this.owner.selector));
        if (!ok || ret.length != 32) return;
        address targetOwner = abi.decode(ret, (address));
        require(targetOwner == address(0), OwnerStillSet(key, target, targetOwner));
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyRootOrOwner {}
}
