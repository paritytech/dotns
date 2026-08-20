// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {StoreFactory} from "../../../contracts/store/StoreFactory.sol";
import {ILabelStore} from "../../../contracts/store/ILabelStore.sol";
import {IUserStore} from "../../../contracts/store/IUserStore.sol";
import {DotnsProtocolRegistry} from "../../../contracts/registry/DotnsProtocolRegistry.sol";

/// @title Store Invariant Handler
/// @notice Handler that drives randomised actions against `StoreFactory`, the label and
///         user stores it deploys, and the labels it locks, tracking ghost state for the
///         immutability and ownership invariants asserted by `StoreInvariantTest`.
contract StoreInvariantHandler is Test {
    /// @notice The store factory deploying label and user stores.
    StoreFactory public immutable FACTORY;

    /// @notice The protocol registry the factory is registered against.
    DotnsProtocolRegistry public immutable REGISTRY;

    /// @notice Address authorised to deploy label stores via the factory.
    address public immutable OWNER;

    /// @notice Address authorised to write labels into label stores.
    address public immutable PROTOCOL_WRITER;

    /// @notice Synthetic user addresses driving claim and write actions.
    address[] public users;

    /// @notice Label stores deployed by the handler.
    address[] public labelStores;

    /// @notice User stores claimed by the handler.
    address[] public userStores;

    /// @notice Labelhashes written into each store, used to check the immutability invariant.
    mapping(address store => bytes32[]) internal _writtenLabelhashes;

    /// @notice Marker tracking whether a labelhash has been observed locked in `store`.
    mapping(address store => mapping(bytes32 labelhash => bool)) public sawLocked;

    /// @notice Frozen label text first observed when a labelhash was written.
    mapping(address store => mapping(bytes32 labelhash => string)) public frozenLabel;

    /// @notice User who claimed a given user store.
    mapping(address store => address) public userStoreOwnerOf;

    /// @notice Initialises the handler with the factory and authorised addresses.
    /// @param _factory The store factory under test.
    /// @param _registry The protocol registry the factory is registered against.
    /// @param _owner Address allowed to deploy label stores.
    /// @param _protocolWriter Address allowed to write labels.
    constructor(
        StoreFactory _factory,
        DotnsProtocolRegistry _registry,
        address _owner,
        address _protocolWriter
    ) {
        FACTORY = _factory;
        REGISTRY = _registry;
        OWNER = _owner;
        PROTOCOL_WRITER = _protocolWriter;
    }

    /// @notice Adds a deterministic synthetic user derived from `seed`.
    /// @param seed Seed used to derive the user address.
    function addUser(uint8 seed) external {
        address user = address(uint160(uint256(keccak256(abi.encode("user", seed)))));
        if (user == address(0)) return;
        users.push(user);
    }

    /// @notice Deploys a label store for the selected user via the factory.
    /// @dev No-op if the user already has a label store; the factory enforces one-per-user.
    /// @param userSeed Seed selecting the user.
    function deployLabelStore(uint8 userSeed) external {
        if (users.length == 0) return;
        address user = users[userSeed % users.length];
        if (FACTORY.getLabelStore(user) != address(0)) return;

        vm.prank(OWNER);
        address store = FACTORY.deployLabelStoreFor(user);
        labelStores.push(store);
    }

    /// @notice Writes a label into the selected label store and freezes it in ghost state.
    /// @dev No-op when no label store exists, the labelhash is zero, or the store has already
    ///      locked that labelhash.
    /// @param storeSeed Seed selecting which label store to write to.
    /// @param labelhash Labelhash to lock.
    /// @param label Label text to associate with `labelhash`.
    function storeLabel(uint8 storeSeed, bytes32 labelhash, string calldata label) external {
        if (labelStores.length == 0) return;
        if (labelhash == bytes32(0)) return;
        address store = labelStores[storeSeed % labelStores.length];
        if (ILabelStore(store).isLocked(labelhash)) return;

        vm.prank(PROTOCOL_WRITER);
        ILabelStore(store).storeLabel(labelhash, label);

        _writtenLabelhashes[store].push(labelhash);
        sawLocked[store][labelhash] = true;
        frozenLabel[store][labelhash] = label;
    }

    /// @notice Claims a user store for the selected user via the factory.
    /// @dev No-op when the user already owns a user store.
    /// @param userSeed Seed selecting the user.
    function claimUserStore(uint8 userSeed) external {
        if (users.length == 0) return;
        address user = users[userSeed % users.length];
        if (FACTORY.getUserStore(user) != address(0)) return;

        vm.prank(user);
        address store = FACTORY.claimUserStore();
        userStores.push(store);
        userStoreOwnerOf[store] = user;
    }

    /// @notice Writes a key-value pair into the selected user store from its owner.
    /// @param storeSeed Seed selecting which user store to write to.
    /// @param key Key under which `value` is stored.
    /// @param value Value to associate with `key`.
    function setValue(uint8 storeSeed, bytes32 key, bytes calldata value) external {
        if (userStores.length == 0) return;
        if (key == bytes32(0)) return;
        address store = userStores[storeSeed % userStores.length];
        address user = userStoreOwnerOf[store];

        vm.prank(user);
        IUserStore(store).setValue(key, value);
    }

    /// @notice Returns the number of label stores deployed by the handler.
    function labelStoreCount() external view returns (uint256) {
        return labelStores.length;
    }

    /// @notice Returns the number of user stores claimed by the handler.
    function userStoreCount() external view returns (uint256) {
        return userStores.length;
    }

    /// @notice Returns the number of synthetic users registered with the handler.
    function userCount() external view returns (uint256) {
        return users.length;
    }

    /// @notice Returns the number of labelhashes written into `store`.
    /// @param store Label store under inspection.
    function writtenLabelhashCount(address store) external view returns (uint256) {
        return _writtenLabelhashes[store].length;
    }

    /// @notice Returns the labelhash written into `store` at `index`.
    /// @param store Label store under inspection.
    /// @param index Position within the recorded labelhash array.
    function writtenLabelhashAt(address store, uint256 index) external view returns (bytes32) {
        return _writtenLabelhashes[store][index];
    }
}
