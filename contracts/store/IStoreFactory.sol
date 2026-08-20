// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title IStoreFactory
/// @notice Interface for the DotNS per-user store factory.
/// @dev Owns two `UpgradeableBeacon` instances; one for `LabelStore` (protocol-managed),
///      one for `UserStore` (user-claimed). Each user may acquire at most one of each,
///      forever. There is no transfer, no redeploy, no additional store type.
/// @custom:security-contact admin@parity.io
interface IStoreFactory {
    /// @notice Emitted when a `LabelStore` beacon-proxy is deployed for `user`.
    /// @param user The user the store is bound to.
    /// @param store The deployed store address.
    event LabelStoreDeployed(address indexed user, address indexed store);

    /// @notice Emitted when `user` claims their `UserStore` beacon-proxy.
    /// @param user The user the store is bound to.
    /// @param store The deployed store address.
    event UserStoreClaimed(address indexed user, address indexed store);

    /// @notice Emitted when the `LabelStore` implementation behind the label beacon is upgraded.
    /// @param newImplementation The new implementation address.
    event LabelStoreImplementationUpgraded(address indexed newImplementation);

    /// @notice Emitted when the `UserStore` implementation behind the user beacon is upgraded.
    /// @param newImplementation The new implementation address.
    event UserStoreImplementationUpgraded(address indexed newImplementation);

    /// @notice Thrown when attempting to deploy or claim a store that already exists.
    /// @param user The user for whom the store exists.
    /// @param existingStore The already-deployed store address.
    error AlreadyDeployed(address user, address existingStore);

    /// @notice Thrown when a zero user address is supplied.
    /// @param user The invalid user argument.
    error InvalidUser(address user);

    /// @notice Thrown when a zero protocol registry address is supplied to the constructor.
    /// @param protocolRegistry The invalid registry argument.
    error InvalidProtocolRegistry(address protocolRegistry);

    /// @notice Thrown when a zero implementation address is supplied to the constructor or an
    /// upgrade. @param implementation The invalid implementation argument.
    error InvalidImplementation(address implementation);

    /// @notice Thrown when an unauthorised address attempts to deploy a label store.
    /// @param caller The unauthorised msg.sender.
    error NotAuthorised(address caller);

    /// @notice Thrown when a freshly deployed proxy does not report the expected owner.
    error ImplementationBindingMismatch();

    /// @notice Returns the `UpgradeableBeacon` address backing all `LabelStore` proxies.
    /// @return beacon Address of the beacon contract.
    function labelStoreBeacon() external view returns (address beacon);

    /// @notice Returns the `UpgradeableBeacon` address backing all `UserStore` proxies.
    /// @return beacon Address of the beacon contract.
    function userStoreBeacon() external view returns (address beacon);

    /// @notice Returns the protocol registry address used for writer authorisation.
    /// @return registry Address of the protocol registry.
    function protocolRegistry() external view returns (address registry);

    /// @notice Deploys a `LabelStore` beacon-proxy bound to `user`.
    /// @dev Callable by the factory owner or any address currently registered in the protocol
    ///      registry; any other caller @custom:reverts NotAuthorised. `user` must be non-zero,
    ///      otherwise @custom:reverts InvalidUser. The user must not already have a
    ///      `LabelStore`, otherwise @custom:reverts AlreadyDeployed. After deployment the
    ///      freshly initialised proxy must report `user` as its owner, otherwise
    ///      @custom:reverts ImplementationBindingMismatch. Emits
    ///      @custom:emits LabelStoreDeployed on success.
    /// @param user The user the store is bound to forever.
    /// @return store The deployed store address.
    function deployLabelStoreFor(address user) external returns (address store);

    /// @notice Returns the `LabelStore` address bound to `user`, or the zero address if none.
    /// @param user The user to look up.
    /// @return store The bound store address, or zero.
    function getLabelStore(address user) external view returns (address store);

    /// @notice Returns the total number of `LabelStore` proxies ever deployed.
    /// @return count Length of the deployment list.
    function getLabelStoreCount() external view returns (uint256 count);

    /// @notice Paginated enumeration over every `LabelStore` proxy ever deployed.
    /// @dev Insertion order of `deployLabelStoreFor` calls. `offset >= getLabelStoreCount()`
    ///      returns an empty array; result length is `min(limit, count - offset)`.
    /// @param offset Start index.
    /// @param limit Maximum entries to return.
    /// @return stores Slice of label-store addresses.
    function getLabelStores(
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (address[] memory stores);

    /// @notice Upgrades the `LabelStore` implementation for every existing and future proxy.
    /// @dev Callable by the factory owner only, otherwise
    ///      @custom:reverts OwnableUnauthorizedAccount. `newImplementation` must be non-zero,
    ///      otherwise @custom:reverts InvalidImplementation. The candidate is sentinel-probed by
    ///      calling `ILabelStore.protocolRegistry` on it before the beacon is rotated; if the
    ///      address does not implement that selector the probe reverts and the upgrade does not
    ///      land (deliberate fail-fast guard, no named error). Delegates to
    ///      `UpgradeableBeacon.upgradeTo` and emits
    ///      @custom:emits LabelStoreImplementationUpgraded on success.
    /// @param newImplementation The new implementation address.
    function upgradeLabelStoreImplementation(address newImplementation) external;

    /// @notice Caller claims their `UserStore` beacon-proxy.
    /// @dev Self-claim only; `_owner` on the resulting store is always `msg.sender`,
    ///      regardless of who pays gas. One store per caller, forever: a caller who already
    ///      has a `UserStore` @custom:reverts AlreadyDeployed. After deployment the freshly
    ///      initialised proxy must report `msg.sender` as its owner, otherwise
    ///      @custom:reverts ImplementationBindingMismatch. Emits
    ///      @custom:emits UserStoreClaimed on success.
    /// @return store The deployed store address.
    function claimUserStore() external returns (address store);

    /// @notice Returns the `UserStore` address bound to `user`, or the zero address if none.
    /// @param user The user to look up.
    /// @return store The bound store address, or zero.
    function getUserStore(address user) external view returns (address store);

    /// @notice Returns the total number of `UserStore` proxies ever claimed.
    /// @return count Length of the claim list.
    function getUserStoreCount() external view returns (uint256 count);

    /// @notice Paginated enumeration over every `UserStore` proxy ever claimed.
    /// @dev Insertion order of `claimUserStore` calls. `offset >= getUserStoreCount()`
    ///      returns an empty array; result length is `min(limit, count - offset)`.
    /// @param offset Start index.
    /// @param limit Maximum entries to return.
    /// @return stores Slice of user-store addresses.
    function getUserStores(
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (address[] memory stores);

    /// @notice Upgrades the `UserStore` implementation for every existing and future proxy.
    /// @dev Callable by the factory owner only, otherwise
    ///      @custom:reverts OwnableUnauthorizedAccount. `newImplementation` must be non-zero,
    ///      otherwise @custom:reverts InvalidImplementation. The candidate is sentinel-probed by
    ///      calling `IUserStore.getKeyCount` on it before the beacon is rotated; if the address
    ///      does not implement that selector the probe reverts and the upgrade does not land
    ///      (deliberate fail-fast guard, no named error). Delegates to
    ///      `UpgradeableBeacon.upgradeTo` and emits
    ///      @custom:emits UserStoreImplementationUpgraded on success.
    /// @param newImplementation The new implementation address.
    function upgradeUserStoreImplementation(address newImplementation) external;
}
