// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IDotnsStore} from "./IDotnsStore.sol";
import {IUserStore} from "./IUserStore.sol";

/// @title UserStore
/// @notice Permanent per-user generic key/value store with per-key history.
/// @dev One instance per user, deployed as a `BeaconProxy` by `StoreFactory.claimUserStore`.
///      Bound to its claimer forever: `_owner` is set once at `initialize` and only that
///      address may write. History is append-only; every `setValue` that supersedes a
///      non-empty prior value records the supersession with `block.timestamp`.
/// @dev Cost isolation: each user's writes bill their own contract, keeping shared
///      resolvers from being polluted by one user's blob usage.
/// @dev Storage collision: the `BeaconProxy` stores the beacon address at EIP-1967 slot
///      `keccak256("eip1967.proxy.beacon") - 1`, which is non-sequential and cannot collide
///      with this contract's sequential storage slots.
/// @custom:security-contact admin@parity.io
contract UserStore is Initializable, IUserStore {
    /// @dev Permanent user this store belongs to. Set in `initialize`.
    address private _owner;

    /// @dev key => current value bytes.
    mapping(bytes32 key => bytes value) private _current;

    /// @dev key => insertion-order list of prior non-empty values and their supersession
    /// timestamps.
    mapping(bytes32 key => Entry[] entries) private _history;

    /// @dev Insertion-order list of all keys ever written. Append-only (never pruned).
    bytes32[] private _keyList;

    /// @dev key => 1-indexed position in `_keyList` (zero means "never written").
    mapping(bytes32 key => uint256 indexPlusOne) private _keyIndex;

    /// @dev Reserved storage space to allow for layout changes in future beacon upgrades.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[50] private __gap;

    /// @notice Restricts writes to the bound owner.
    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IUserStore
    function initialize(address user_) external override initializer {
        require(user_ != address(0), InvalidUser(user_));
        _owner = user_;
    }

    /// @inheritdoc IUserStore
    function setValue(bytes32 key, bytes calldata value) external override onlyOwner {
        require(key != bytes32(0), InvalidKey());

        bytes storage prev = _current[key];
        if (prev.length != 0) {
            _history[key].push(Entry({value: prev, timestamp: block.timestamp}));
        }

        _current[key] = value;

        if (_keyIndex[key] == 0) {
            uint256 newIndex = _keyList.length + 1;
            _keyList.push(key);
            _keyIndex[key] = newIndex;
        }

        emit ValueSet(_owner, key, value);
    }

    /// @inheritdoc IDotnsStore
    function owner() external view override returns (address owner_) {
        return _owner;
    }

    /// @inheritdoc IUserStore
    function getValue(bytes32 key) external view override returns (bytes memory value) {
        return _current[key];
    }

    /// @inheritdoc IUserStore
    function hasValue(bytes32 key) external view override returns (bool present) {
        return _current[key].length != 0;
    }

    /// @inheritdoc IUserStore
    function getHistoryCount(bytes32 key) external view override returns (uint256 count) {
        return _history[key].length;
    }

    /// @inheritdoc IUserStore
    function getHistoryAt(
        bytes32 key,
        uint256 index
    )
        external
        view
        override
        returns (Entry memory entry)
    {
        return _history[key][index];
    }

    /// @inheritdoc IUserStore
    function getHistory(
        bytes32 key,
        uint256 offset,
        uint256 limit
    )
        external
        view
        override
        returns (Entry[] memory entries)
    {
        Entry[] storage full = _history[key];
        uint256 total = full.length;
        if (offset >= total) {
            return new Entry[](0);
        }

        uint256 available = total - offset;
        uint256 count = limit < available ? limit : available;

        entries = new Entry[](count);
        for (uint256 i; i < count; ++i) {
            entries[i] = full[offset + i];
        }
    }

    /// @inheritdoc IUserStore
    function getKeyCount() external view override returns (uint256 count) {
        return _keyList.length;
    }

    /// @inheritdoc IUserStore
    function getKeyAt(uint256 index) external view override returns (bytes32 key) {
        return _keyList[index];
    }

    /// @inheritdoc IUserStore
    function getKeys(
        uint256 offset,
        uint256 limit
    )
        external
        view
        override
        returns (bytes32[] memory keys)
    {
        uint256 total = _keyList.length;
        if (offset >= total) {
            return new bytes32[](0);
        }

        uint256 available = total - offset;
        uint256 count = limit < available ? limit : available;

        keys = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            keys[i] = _keyList[offset + i];
        }
    }

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.0.0";
    }

    /// @notice Internal owner check deferred from the `onlyOwner` modifier.
    function _onlyOwner() internal view {
        require(msg.sender == _owner, NotOwner(msg.sender));
    }
}
