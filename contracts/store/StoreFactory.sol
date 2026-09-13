// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IStoreFactory} from "./IStoreFactory.sol";
import {IDotnsStore} from "./IDotnsStore.sol";
import {ILabelStore} from "./ILabelStore.sol";
import {IUserStore} from "./IUserStore.sol";
import {LabelStore} from "./LabelStore.sol";
import {UserStore} from "./UserStore.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {StoreAuth} from "../utils/StoreAuth.sol";

/// @title StoreFactory
/// @notice Factory for the two per-user DotNS store types, sharing one factory contract and two
/// beacons. @dev Each user may acquire AT MOST two stores, ever:
///      - a `LabelStore`, deployed via `deployLabelStoreFor` by the owner or a store writer
///        during registration; and
///      - a `UserStore`, claimed via `claimUserStore` by the user themselves.
///      Both are `BeaconProxy` instances pointing at their respective `UpgradeableBeacon`.
///      The factory owns both beacons so the factory owner can upgrade implementations for
///      every proxy atomically. Neither per-user mapping is ever transferred, reassigned, or
///      overwritten after the first write; bindings are permanent.
/// @dev Lives behind its own UUPS proxy. The per-user bindings and both beacon addresses are
///      proxy storage, so the factory is upgraded in place: the bindings cannot be exported, so
///      a replacement reached by re-pointing `STORE_FACTORY` would start with an empty directory.
/// @custom:security-contact admin@parity.io
contract StoreFactory is Initializable, UUPSUpgradeable, OwnableUpgradeable, IStoreFactory {
    /// @notice Beacon backing every `LabelStore` proxy.
    /// @dev Public getter name is interface-constrained by @custom:contract IStoreFactory.
    address public override labelStoreBeacon;

    /// @notice Beacon backing every `UserStore` proxy.
    /// @dev Public getter name is interface-constrained by @custom:contract IStoreFactory.
    address public override userStoreBeacon;

    /// @notice Protocol registry used to authorise `deployLabelStoreFor` callers.
    /// @dev Public getter name is interface-constrained by @custom:contract IStoreFactory.
    address public override protocolRegistry;

    /// @dev user => their permanent `LabelStore`. Set once per user, forever.
    mapping(address user => address store) private _labelStores;

    /// @dev user => their permanent `UserStore`. Set once per user, forever.
    mapping(address user => address store) private _userStores;

    /// @dev Insertion-order list of every `LabelStore` proxy ever deployed. Append-only.
    address[] private _labelStoreList;

    /// @dev Insertion-order list of every `UserStore` proxy ever claimed. Append-only.
    address[] private _userStoreList;

    /// @dev Reserved storage space to allow for layout changes in future upgrades.
    uint256[50] private __gap;

    /// @notice Restricts `deployLabelStoreFor` to the owner or a component named in
    /// @custom:function StoreAuth.isStoreWriter.
    modifier onlyOwnerOrProtocol() {
        _onlyOwnerOrProtocol();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the factory together with both store implementations and beacons.
    /// @dev Callable exactly once via `Initializable`, otherwise
    ///      @custom:reverts InvalidInitialization. A single initialiser call wires everything:
    ///      - Deploys a fresh `LabelStore` implementation.
    ///      - Deploys a fresh `UserStore` implementation.
    ///      - Constructs both `UpgradeableBeacon` instances, owned by `address(this)`, which
    ///        under the proxy is the proxy itself, so `upgrade*Implementation` can delegate to
    ///        `beacon.upgradeTo` and the beacons outlive any implementation swap.
    ///      The implementations are deployed here rather than accepted as parameters, so the call
    ///      carries no ordering dependency on a prior deploy and exposes no argument through which
    ///      a mismatched implementation could reach a beacon. `protocolRegistry_` must be
    ///      non-zero, otherwise @custom:reverts InvalidProtocolRegistry.
    /// @param initialOwner Account that owns this factory and can upgrade it and the store
    ///        implementations.
    /// @param protocolRegistry_ The protocol registry for writer auth on label stores.
    function initialize(address initialOwner, address protocolRegistry_) external initializer {
        __Ownable_init(initialOwner);

        require(protocolRegistry_ != address(0), InvalidProtocolRegistry(protocolRegistry_));
        // Probing the registry rejects a wrong address here rather than at the first store deploy,
        // and is what catches the two address arguments being passed the wrong way round.
        IDotnsProtocolRegistry(protocolRegistry_).isRegisteredAddress(address(0));

        protocolRegistry = protocolRegistry_;
        labelStoreBeacon = address(new UpgradeableBeacon(address(new LabelStore()), address(this)));
        userStoreBeacon = address(new UpgradeableBeacon(address(new UserStore()), address(this)));
    }

    /// @inheritdoc IStoreFactory
    function deployLabelStoreFor(address user)
        external
        override
        onlyOwnerOrProtocol
        returns (address store)
    {
        require(user != address(0), InvalidUser(user));
        require(_labelStores[user] == address(0), AlreadyDeployed(user, _labelStores[user]));

        bytes memory initData = abi.encodeCall(ILabelStore.initialize, (user, protocolRegistry));
        store = address(new BeaconProxy(labelStoreBeacon, initData));
        require(IDotnsStore(store).owner() == user, ImplementationBindingMismatch());
        _labelStores[user] = store;
        _labelStoreList.push(store);

        emit LabelStoreDeployed(user, store);
    }

    /// @inheritdoc IStoreFactory
    function getLabelStore(address user) external view override returns (address store) {
        return _labelStores[user];
    }

    /// @inheritdoc IStoreFactory
    function getLabelStoreCount() external view override returns (uint256 count) {
        return _labelStoreList.length;
    }

    /// @inheritdoc IStoreFactory
    function getLabelStores(
        uint256 offset,
        uint256 limit
    )
        external
        view
        override
        returns (address[] memory stores)
    {
        stores = _paginateAddresses(_labelStoreList, offset, limit);
    }

    /// @inheritdoc IStoreFactory
    function upgradeLabelStoreImplementation(address newImplementation)
        external
        override
        onlyOwner
    {
        require(newImplementation != address(0), InvalidImplementation(newImplementation));
        ILabelStore(newImplementation).protocolRegistry();
        UpgradeableBeacon(labelStoreBeacon).upgradeTo(newImplementation);
        emit LabelStoreImplementationUpgraded(newImplementation);
    }

    /// @inheritdoc IStoreFactory
    function claimUserStore() external override returns (address store) {
        require(
            _userStores[msg.sender] == address(0),
            AlreadyDeployed(msg.sender, _userStores[msg.sender])
        );

        bytes memory initData = abi.encodeCall(IUserStore.initialize, (msg.sender));
        store = address(new BeaconProxy(userStoreBeacon, initData));
        require(IDotnsStore(store).owner() == msg.sender, ImplementationBindingMismatch());
        _userStores[msg.sender] = store;
        _userStoreList.push(store);

        emit UserStoreClaimed(msg.sender, store);
    }

    /// @inheritdoc IStoreFactory
    function getUserStore(address user) external view override returns (address store) {
        return _userStores[user];
    }

    /// @inheritdoc IStoreFactory
    function getUserStoreCount() external view override returns (uint256 count) {
        return _userStoreList.length;
    }

    /// @inheritdoc IStoreFactory
    function getUserStores(
        uint256 offset,
        uint256 limit
    )
        external
        view
        override
        returns (address[] memory stores)
    {
        stores = _paginateAddresses(_userStoreList, offset, limit);
    }

    /// @inheritdoc IStoreFactory
    function upgradeUserStoreImplementation(address newImplementation) external override onlyOwner {
        require(newImplementation != address(0), InvalidImplementation(newImplementation));
        IUserStore(newImplementation).getKeyCount();
        UpgradeableBeacon(userStoreBeacon).upgradeTo(newImplementation);
        emit UserStoreImplementationUpgraded(newImplementation);
    }

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.0.0";
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Internal authorisation check deferred from the `onlyOwnerOrProtocol` modifier.
    function _onlyOwnerOrProtocol() internal view {
        if (msg.sender == owner()) return;
        require(StoreAuth.isStoreWriter(protocolRegistry, msg.sender), NotAuthorised(msg.sender));
    }

    /// @notice Shared pagination helper used by `getLabelStores` and `getUserStores`.
    /// @dev Single canonical slicer so both enumerations bound-check and copy identically.
    /// @param source Storage array to slice.
    /// @param offset Start index.
    /// @param limit Maximum entries to return.
    /// @return slice Result slice; empty when `offset >= source.length`.
    function _paginateAddresses(
        address[] storage source,
        uint256 offset,
        uint256 limit
    )
        internal
        view
        returns (address[] memory slice)
    {
        uint256 total = source.length;
        if (offset >= total) return new address[](0);

        uint256 available = total - offset;
        uint256 count = limit < available ? limit : available;

        slice = new address[](count);
        for (uint256 i; i < count; ++i) {
            slice[i] = source[offset + i];
        }
    }
}
