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

/// @title StoreFactoryMigrator
/// @notice The shipped `StoreFactory`, with the per-user bindings reachable and a one-shot import
///         that copies them from the factory a network used before this one.
/// @dev PR-scoped migration tooling, upgraded into the proxy for a single transaction and
///      upgraded straight back out. It exists because a `StoreFactory` cannot be moved: the
///      bindings are proxy storage and the shipped contract offers no way to write one except by
///      deploying a new store, so a network that re-points `STORE_FACTORY` at a fresh factory
///      starts with an empty directory and hands every existing user a second, empty store the
///      next time one is needed.
///
///      The contract body is the shipped factory verbatim, with four fields widened from
///      `private` to `internal` and `importStores` added. Keeping it a copy rather than a
///      subclass or a set of raw slot writes is what makes the layout identical by construction:
///      the upgrade in and the upgrade back both diff against a layout that cannot have drifted.
///
///      What it does not do: the imported stores stay on the beacons the old factory minted, and
///      those beacons answer to the old factory. Their implementations remain upgradeable there,
///      by the same owner, and are not reachable from this factory's beacons. A `BeaconProxy`
///      holds its beacon address in an immutable, so no migration can change that.
/// @custom:security-contact admin@parity.io
contract StoreFactoryMigrator is Initializable, UUPSUpgradeable, OwnableUpgradeable, IStoreFactory {
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
    mapping(address user => address store) internal _labelStores;

    /// @dev user => their permanent `UserStore`. Set once per user, forever.
    mapping(address user => address store) internal _userStores;

    /// @dev Insertion-order list of every `LabelStore` proxy ever deployed. Append-only.
    address[] internal _labelStoreList;

    /// @dev Insertion-order list of every `UserStore` proxy ever claimed. Append-only.
    address[] internal _userStoreList;

    /// @dev Reserved storage space to allow for layout changes in future upgrades.
    uint256[50] private __gap;

    /// @notice A binding was adopted from the previous factory.
    /// @param user Address the store belongs to.
    /// @param store The `LabelStore` now bound to `user` on this factory.
    event StoresImported(address indexed user, address indexed store);

    /// @notice The old factory's store list does not have the length the factory reports.
    /// @dev Reading the count and the list are two calls, so they can disagree: a truncated
    ///      enumeration would import a prefix and leave the rest unbound, and unbound users are
    ///      handed an empty store on their next registration rather than the one they have.
    /// @param expected Count the old factory reports.
    /// @param actual Number of entries actually seen.
    error ImportCountMismatch(uint256 expected, uint256 actual);

    /// @notice A store's owner is not the user the old factory has it bound to.
    /// @dev The store list and the per-user mapping are separate state. Importing on the store's
    ///      word alone would let a store whose owner no longer matches the mapping bind a user
    ///      the old factory does not consider its holder.
    /// @param user Owner the store reports.
    /// @param store The store in the old factory's list.
    error ImportBindingMismatch(address user, address store);

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

        bytes memory initData =
            abi.encodeCall(IUserStore.initialize, (msg.sender, protocolRegistry));
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
        IUserStore(newImplementation).protocolRegistry();
        UpgradeableBeacon(userStoreBeacon).upgradeTo(newImplementation);
        emit UserStoreImplementationUpgraded(newImplementation);
    }

    /// @notice Returns the release this network declares it runs, read live from the protocol
    ///         registry so every DotNS contract reports one synchronised value.
    /// @dev Mirror of `IDotnsProtocolRegistry.protocolVersion`, kept under the historical
    ///      `version()` selector for ABI compatibility. It reports the network's declaration,
    ///      not this contract's build; per-contract identity is the codehash declared on the
    ///      registry.
    /// @return versionString Declared release as bare semver, empty when never declared.
    function version() external view virtual returns (string memory versionString) {
        versionString = IDotnsProtocolRegistry(protocolRegistry).protocolVersion();
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Internal authorisation check deferred from the `onlyOwnerOrProtocol` modifier.
    function _onlyOwnerOrProtocol() internal view {
        if (msg.sender == owner()) return;
        require(StoreAuth.isStoreWriter(protocolRegistry, msg.sender), NotAuthorised(msg.sender));
    }

    /// @notice Copies the per-user `LabelStore` bindings of `oldFactory` into this factory.
    /// @dev Owner-only, and reads everything it needs from `oldFactory` itself: the count, the
    ///      store list, and each store's owner. Nothing is supplied by the caller, so there is no
    ///      window between an operator reading the set and this executing. That window is not
    ///      hypothetical: the count on the network being migrated moved while this was being
    ///      written, and a list captured a moment early imports every entry it holds, rewires,
    ///      and leaves the newest holder to be handed a second empty store on their next
    ///      registration.
    ///
    ///      Each binding is checked back through `getLabelStore` before it is written. A store's
    ///      `owner` is the user it was deployed for, and the factory's mapping is the authority
    ///      on that pairing; requiring the two to agree rejects a store whose owner has been
    ///      changed out from under the mapping, which is the one shape that would bind a user to
    ///      a store the old factory does not consider theirs.
    ///
    ///      Bindings are permanent here as everywhere else in the factory, so a user already
    ///      bound is rejected instead of repointed. That makes a second call over an overlapping
    ///      set fail loudly instead of rewriting history.
    ///
    ///      `UserStore` bindings are deliberately not imported. They are claimed by users
    ///      themselves and the network being migrated from has none; a migration that does have
    ///      them needs this extended, not reused.
    /// @param oldFactory Factory whose bindings are being adopted.
    function importStores(address oldFactory) external onlyOwner {
        require(oldFactory != address(0), InvalidUser(oldFactory));

        uint256 total = IStoreFactory(oldFactory).getLabelStoreCount();
        address[] memory stores = IStoreFactory(oldFactory).getLabelStores(0, total);
        require(stores.length == total, ImportCountMismatch(total, stores.length));

        for (uint256 i; i < total; ++i) {
            address store = stores[i];
            require(store != address(0), InvalidImplementation(store));

            address user = IDotnsStore(store).owner();
            require(user != address(0), InvalidUser(user));
            require(
                IStoreFactory(oldFactory).getLabelStore(user) == store,
                ImportBindingMismatch(user, store)
            );

            address existing = _labelStores[user];
            require(existing == address(0), AlreadyDeployed(user, existing));

            _labelStores[user] = store;
            _labelStoreList.push(store);

            emit StoresImported(user, store);
        }

        // Every binding the old factory reports is now held here. Asserted after the loop as
        // well as before it, because the two counts are read from different places: a mismatch
        // means a store appeared in the list twice, or the list disagreed with the mapping.
        require(_labelStoreList.length == total, ImportCountMismatch(total, _labelStoreList.length));
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
