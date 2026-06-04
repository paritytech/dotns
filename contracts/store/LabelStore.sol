// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IDotnsStore} from "./IDotnsStore.sol";
import {ILabelStore} from "./ILabelStore.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";

/// @title LabelStore
/// @notice Permanent per-user DotNS label store.
/// @dev One instance per user, deployed as a `BeaconProxy` by `StoreFactory` during registration.
///      Bound to its user forever: `_owner` and `_protocolRegistry` are set once at `initialize`
///      and never mutate. Writes are gated to addresses currently registered in
///      `DotnsProtocolRegistry` (`isRegisteredAddress`); every labelhash is single-write and
///      permanently locked on first use.
/// @dev Labels-only by invariant: this store holds registration records only. Every other
///      per-name category (reverse, content, forward address, chat key, lite link) lives on a
///      dedicated resolver, never here.
/// @dev Storage collision: the `BeaconProxy` stores the beacon address at EIP-1967 slot
///      `keccak256("eip1967.proxy.beacon") - 1`, which is non-sequential and cannot collide
///      with this contract's sequential storage slots.
/// @custom:security-contact admin@parity.io
contract LabelStore is Initializable, ILabelStore {
    /// @dev Permanent user this store belongs to. Set in `initialize`.
    address private _owner;

    /// @dev Canonical DotNS protocol registry. Set in `initialize`.
    address private _protocolRegistry;

    /// @dev labelhash => stored label string.
    mapping(bytes32 labelhash => string label) private _labels;

    /// @dev Deprecated. Previously held the `_locked` lock flag per labelhash; the lock state is
    /// now derived from `_labelIndex != 0`. The mapping type and slot are retained verbatim so
    /// the OZ Upgrades validator accepts the storage layout against deployed proxies.
    /// @custom:oz-renamed-from _locked
    // forge-lint: disable-next-line(mixed-case-variable)
    mapping(bytes32 labelhash => bool locked) private __deprecated_locked;

    /// @dev Insertion-order list of all stored labelhashes. Append-only.
    bytes32[] private _labelList;

    /// @dev labelhash => 1-indexed position in `_labelList` (zero means "not present").
    /// Doubles as the permanent-lock sentinel: a non-zero index proves the label was written and
    /// the contract has no deletion path, so the index is also the locked flag.
    mapping(bytes32 labelhash => uint256 indexPlusOne) private _labelIndex;

    /// @dev Reserved storage space to allow for layout changes in future beacon upgrades.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[50] private __gap;

    /// @notice Restricts writes to protocol-registered addresses only.
    modifier onlyAuthorisedProtocol() {
        _onlyAuthorisedProtocol();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ILabelStore
    function initialize(address user_, address protocolRegistry_) external override initializer {
        require(user_ != address(0), InvalidUser(user_));
        require(protocolRegistry_ != address(0), InvalidProtocolRegistry(protocolRegistry_));
        _owner = user_;
        _protocolRegistry = protocolRegistry_;
    }

    /// @inheritdoc ILabelStore
    function storeLabel(
        bytes32 labelhash,
        string calldata label
    )
        external
        override
        onlyAuthorisedProtocol
    {
        require(labelhash != bytes32(0), InvalidLabel(labelhash));
        require(_labelIndex[labelhash] == 0, LabelAlreadyExists(labelhash));

        // Cache `length + 1` before `push` so the post-push length SLOAD is avoided; the value is
        // also the 1-indexed position we are about to write.
        uint256 newIndex = _labelList.length + 1;
        _labels[labelhash] = label;
        _labelList.push(labelhash);
        _labelIndex[labelhash] = newIndex;

        emit LabelStored(_owner, labelhash, label);
    }

    /// @inheritdoc IDotnsStore
    function owner() external view override returns (address owner_) {
        return _owner;
    }

    /// @inheritdoc ILabelStore
    function protocolRegistry() external view override returns (address protocolRegistry_) {
        return _protocolRegistry;
    }

    /// @inheritdoc ILabelStore
    function hasLabel(bytes32 labelhash) external view override returns (bool exists) {
        return _labelIndex[labelhash] != 0;
    }

    /// @inheritdoc ILabelStore
    function isLocked(bytes32 labelhash) external view override returns (bool locked) {
        return _labelIndex[labelhash] != 0;
    }

    /// @inheritdoc ILabelStore
    function getLabel(bytes32 labelhash) external view override returns (string memory label) {
        return _labels[labelhash];
    }

    /// @inheritdoc ILabelStore
    function getLabelCount() external view override returns (uint256 count) {
        return _labelList.length;
    }

    /// @inheritdoc ILabelStore
    function getLabelAt(uint256 index) external view override returns (string memory label) {
        return _labels[_labelList[index]];
    }

    /// @inheritdoc ILabelStore
    function getLabelhashAt(uint256 index) external view override returns (bytes32 labelhash) {
        return _labelList[index];
    }

    /// @inheritdoc ILabelStore
    function getLabels(
        uint256 offset,
        uint256 limit
    )
        external
        view
        override
        returns (string[] memory labels)
    {
        uint256 total = _labelList.length;
        if (offset >= total) return new string[](0);

        uint256 available = total - offset;
        uint256 count = limit < available ? limit : available;

        labels = new string[](count);
        for (uint256 i; i < count; ++i) {
            labels[i] = _labels[_labelList[offset + i]];
        }
    }

    /// @inheritdoc ILabelStore
    function getLabelhashes(
        uint256 offset,
        uint256 limit
    )
        external
        view
        override
        returns (bytes32[] memory labelhashes)
    {
        uint256 total = _labelList.length;
        if (offset >= total) return new bytes32[](0);

        uint256 available = total - offset;
        uint256 count = limit < available ? limit : available;

        labelhashes = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            labelhashes[i] = _labelList[offset + i];
        }
    }

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.0.0";
    }

    /// @notice Internal authorisation check deferred from the `onlyAuthorisedProtocol` modifier.
    function _onlyAuthorisedProtocol() internal view {
        require(
            IDotnsProtocolRegistry(_protocolRegistry).isRegisteredAddress(msg.sender),
            NotAuthorised(msg.sender)
        );
    }
}
