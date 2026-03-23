// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IStore} from "./IStore.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Store
/// @notice Key-value storage for IPFS URIs, isolated per user address with authorization support.
/// @dev Each address manages its own mapping of bytes32 keys to string values.
///      Authorized contracts can write on behalf of users to enable atomic multi-contract operations.
/// @dev This contract is not upgradeable.
///
/// @dev Permanent locking:
///      - A `(user, key)` can be locked permanently.
///      - Locked keys cannot be overwritten or deleted by any caller, including `owner`.
///      - Keys are locked automatically when written via `setValueFor` by an address marked as a DotNS controller.
/// @custom:security-contact admin@parity.io
contract Store is IStore, Ownable {
    /// @dev Primary data structure: user address => (key => value)
    mapping(address user => mapping(bytes32 key => string value)) private store;

    /// @dev Secondary structure tracking all values per user in insertion order.
    /// @dev This is append-only and not pruned on delete.
    mapping(address user => string[] userValues) private values;

    /// @dev Tracks which addresses are authorized to call `setValueFor`.
    mapping(address storeAddress => bool isAuthorized) private authorizedStores;

    /// @dev Tracks which addresses are treated as DotNS controllers for locking semantics.
    mapping(address controllerAddress => bool isDotnsController) private dotnsControllers;

    /// @dev Tracks whether a `(user, key)` is permanently locked.
    mapping(address user => mapping(bytes32 key => bool isLocked)) private lockedKeys;

    /// @notice Restricts function access to authorized contracts only.
    /// @dev DotNS controllers are implicitly authorized.
    modifier onlyAuthorizedStore() {
        _onlyAuthorizedStore();
        _;
    }

    constructor() Ownable(msg.sender) {}

    /// @inheritdoc IStore
    function isAuthorized(address storeAddress) external view override returns (bool authorized) {
        return authorizedStores[storeAddress];
    }

    /// @inheritdoc IStore
    function isDotnsController(address controllerAddress)
        public
        view
        override
        returns (bool isController)
    {
        return dotnsControllers[controllerAddress];
    }

    /// @inheritdoc IStore
    function isLocked(address user, bytes32 key) external view override returns (bool locked) {
        return lockedKeys[user][key];
    }

    /// @inheritdoc IStore
    function setValue(bytes32 key, string calldata value) external override {
        _ensureUnlocked(msg.sender, key);

        store[msg.sender][key] = value;
        values[msg.sender].push(value);

        emit ValueStored(msg.sender, key, value);
    }

    /// @inheritdoc IStore
    function setValueFor(
        address user,
        bytes32 key,
        string calldata value
    )
        external
        override
        onlyAuthorizedStore
    {
        _ensureUnlocked(user, key);

        store[user][key] = value;
        values[user].push(value);

        emit ValueStored(user, key, value);

        if (dotnsControllers[msg.sender]) {
            lockedKeys[user][key] = true;
            emit KeyLockedPermanently(user, key, msg.sender);
        }
    }

    /// @inheritdoc IStore
    function getValue(bytes32 key) external view override returns (string memory) {
        return store[msg.sender][key];
    }

    /// @inheritdoc IStore
    function getValueFor(address user, bytes32 key) external view override returns (string memory) {
        return store[user][key];
    }

    /// @inheritdoc IStore
    function deleteValue(bytes32 key) external override {
        _ensureUnlocked(msg.sender, key);

        delete store[msg.sender][key];
        emit ValueDeleted(msg.sender, key);
    }

    /// @inheritdoc IStore
    function hasValue(bytes32 key) external view override returns (bool exists) {
        return bytes(store[msg.sender][key]).length > 0;
    }

    /// @inheritdoc IStore
    function getValues() external view override returns (string[] memory) {
        return values[msg.sender];
    }

    /// @inheritdoc IStore
    function authorizeStore(address storeAddress) external override onlyOwner {
        authorizedStores[storeAddress] = true;
        emit StoreAuthorized(storeAddress);
    }

    /// @inheritdoc IStore
    function unauthorizeStore(address storeAddress) external override onlyOwner {
        authorizedStores[storeAddress] = false;
        emit StoreUnauthorized(storeAddress);
    }

    /// @inheritdoc IStore
    function authorizeDotnsController(address controllerAddress) external override onlyOwner {
        dotnsControllers[controllerAddress] = true;
        emit DotnsControllerAuthorized(controllerAddress);
    }

    /// @inheritdoc IStore
    function unauthorizeDotnsController(address controllerAddress) external override onlyOwner {
        dotnsControllers[controllerAddress] = false;
        emit DotnsControllerUnauthorized(controllerAddress);
    }

    /// @notice Internal authorization check for `setValueFor`
    /// @dev DotNS controllers bypass the authorized store list
    function _onlyAuthorizedStore() internal view {
        if (!dotnsControllers[msg.sender]) {
            require(authorizedStores[msg.sender], NotAuthorised(msg.sender));
        }
    }

    /// @notice Ensures a `(user, key)` pair is not permanently locked
    /// @param user Target user address
    /// @param key Storage key
    function _ensureUnlocked(address user, bytes32 key) internal view {
        require(!lockedKeys[user][key], KeyLocked(user, key));
    }
}
