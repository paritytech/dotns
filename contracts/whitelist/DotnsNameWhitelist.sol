// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ERC165Upgradeable
} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IDotnsNameWhitelist} from "./IDotnsNameWhitelist.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {LabelUtils} from "../utils/LabelUtils.sol";
import {StringUtils} from "../utils/StringUtils.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";
import {SystemUtils} from "../utils/SystemUtils.sol";

/// @title DotnsNameWhitelist
/// @notice Pre-launch name whitelist. A name is Open until governance reserves it or a claim is
///         accepted for it. Several beneficiaries may claim the same Open name, each with a
///         reason, and governance accepts one as the winner. A grant binds its name for
///         `grantDuration`; once that passes, the name reads Open again.
/// @dev Lives behind its own UUPS proxy with its own storage. Callers pass bare labels only; the
///      contract derives the node from the label and the TLD in the protocol registry, so a
///      caller cannot supply a mismatched hash. Claims are keyed by the beneficiary `user`, not
///      the submitter, so a relayer or a cross-chain sovereign account can submit on a user's
///      behalf and the name binds to that user. All state is on-chain and queryable through views;
///      no event indexing is required. A name holds at most `maxClaimants` live claims, which
///      bounds the loop that clears them on resolution. Resolving a name deletes its claims,
///      refunding their storage deposit, so only reserved or won names persist. The entire admin
///      surface is substrate Root: `SystemUtils.originIsRoot` is true through the proxy's
///      delegatecall frame, and no gate reads `msg.sender`, so Root's lack of an address is not a
///      problem. No signed account grants, revokes, reserves, or retunes a cap; the owner's
///      authority is upgrade only. The public and PoP controllers hold only the `consume` hook.
///      Entries are keyed by the node under the active TLD, which the deployment holds immutable
///      for the whitelist's lifetime.
/// @custom:security-contact admin@parity.io
contract DotnsNameWhitelist is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IDotnsNameWhitelist
{
    using StringUtils for string;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Protocol-level address registry for all dotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @notice Live-claim cap per name, tunable by governance within
    ///         `DotnsConstants.WHITELIST_MAX_CLAIMANTS_LIMIT`.
    uint16 public maxClaimants;

    /// @notice Cap on labels per `grantNames` call, tunable by governance within
    ///         `DotnsConstants.WHITELIST_MAX_GRANT_BATCH_LIMIT`.
    uint16 public maxGrantBatch;

    /// @notice Reason byte cap, tunable by governance within
    ///         `DotnsConstants.WHITELIST_MAX_REASON_LIMIT`.
    uint256 public maxReasonBytes;

    /// @notice Resolved state per name.
    mapping(bytes32 node => NameRecord record) private _names;

    /// @notice Claims per name, keyed by beneficiary.
    mapping(bytes32 node => mapping(address user => Claim claim)) private _claims;

    /// @notice Beneficiaries with a live claim per name.
    mapping(bytes32 node => EnumerableSet.AddressSet claimants) private _claimants;

    /// @notice Names holding reserved, claimed or claim-holding state, kept enumerable for review.
    EnumerableSet.Bytes32Set private _activeNodes;

    /// @notice Timestamp requests start being accepted.
    uint64 private _requestOpen;

    /// @notice Timestamp requests stop being accepted.
    uint64 private _requestClose;

    /// @notice Period a grant binds its name, tunable by governance within
    ///         `DotnsConstants.WHITELIST_MIN_GRANT_DURATION` and
    ///         `DotnsConstants.WHITELIST_MAX_GRANT_DURATION`.
    uint64 public grantDuration;

    /// @notice Earliest timestamp a grant period runs from.
    /// @dev Set when grant expiry is initialised. A grant recorded before then has no `grantedAt`,
    ///      so its period runs from here.
    uint64 private _grantClockStart;

    /// @dev Reserved storage space to allow for layout changes in the future.
    uint256[50] private __gap;

    /// @notice Restricts a call to a substrate Root dispatch.
    /// @dev The whole admin surface is governance-only: no key grants, revokes, reserves, or
    ///      retunes a cap. The owner's authority is deployment and upgrade, not allocation, so no
    ///      signed account can hand out a name. `msg.sender` is never read here, which is also what
    ///      keeps every gated entry point callable under a Root origin, since Root has no account.
    modifier onlyGovernance() {
        _onlyGovernance();
        _;
    }

    /// @notice Restricts a call to a registrar controller resolved through the registry.
    modifier onlyController() {
        require(
            msg.sender == protocolRegistry.get(DotnsConstants.CONTROLLER)
                || msg.sender == protocolRegistry.get(DotnsConstants.POP_CONTROLLER),
            NotController(msg.sender)
        );
        _;
    }

    /// @notice Internal check enforcing the substrate Root gate.
    function _onlyGovernance() internal view {
        require(SystemUtils.originIsRoot(), NotGovernance());
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the whitelist.
    /// @dev Callable once through the UUPS proxy; direct calls on the implementation
    ///      @custom:reverts InvalidInitialization. Sets `initialOwner` as owner and wires the
    ///      protocol registry the node derivation reads the TLD from.
    /// @param initialOwner Address that owns the contract once initialised.
    /// @param registry Protocol registry all dotNS contracts resolve through.
    function initialize(
        address initialOwner,
        IDotnsProtocolRegistry registry
    )
        external
        initializer
    {
        __ERC165_init();
        __Ownable_init(initialOwner);
        protocolRegistry = registry;
        maxClaimants = DotnsConstants.WHITELIST_DEFAULT_MAX_CLAIMANTS;
        maxGrantBatch = DotnsConstants.WHITELIST_DEFAULT_MAX_GRANT_BATCH;
        maxReasonBytes = DotnsConstants.WHITELIST_DEFAULT_MAX_REASON_BYTES;
        _initializeGrantExpiry();
    }

    /// @notice Starts grant expiry on a whitelist initialised without it.
    /// @dev Called once by the owner through `upgradeToAndCall`, so the upgrade and the clock
    ///      start land in one call. Sets the default grant period and starts the clock for grants
    ///      made before it, which have no `grantedAt`. A whitelist that `initialize` already set
    ///      up @custom:reverts InvalidInitialization.
    function initializeGrantExpiry() external reinitializer(2) onlyOwner {
        require(grantDuration == 0, InvalidInitialization());
        _initializeGrantExpiry();
    }

    /// @notice Sets the default grant period and starts the grant clock.
    function _initializeGrantExpiry() internal {
        grantDuration = DotnsConstants.WHITELIST_DEFAULT_GRANT_DURATION;
        _grantClockStart = uint64(block.timestamp);
        emit GrantDurationSet(DotnsConstants.WHITELIST_DEFAULT_GRANT_DURATION);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function setMaxClaimants(uint16 newMax) external override onlyGovernance {
        require(
            newMax > 0 && newMax <= DotnsConstants.WHITELIST_MAX_CLAIMANTS_LIMIT,
            MaxClaimantsOutOfRange()
        );
        maxClaimants = newMax;
        emit MaxClaimantsSet(newMax);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function setMaxReasonBytes(uint256 newMax) external override onlyGovernance {
        require(
            newMax > 0 && newMax <= DotnsConstants.WHITELIST_MAX_REASON_LIMIT,
            MaxReasonBytesOutOfRange()
        );
        maxReasonBytes = newMax;
        emit MaxReasonBytesSet(newMax);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function setMaxGrantBatch(uint16 newMax) external override onlyGovernance {
        require(
            newMax > 0 && newMax <= DotnsConstants.WHITELIST_MAX_GRANT_BATCH_LIMIT,
            MaxGrantBatchOutOfRange()
        );
        maxGrantBatch = newMax;
        emit MaxGrantBatchSet(newMax);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function setGrantDuration(uint64 newDuration) external override onlyGovernance {
        require(
            newDuration >= DotnsConstants.WHITELIST_MIN_GRANT_DURATION
                && newDuration <= DotnsConstants.WHITELIST_MAX_GRANT_DURATION,
            GrantDurationOutOfRange()
        );
        grantDuration = newDuration;
        emit GrantDurationSet(newDuration);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function requestName(
        string calldata label,
        string calldata reason,
        address user
    )
        external
        override
    {
        require(_isWindowOpen(), WindowClosed());
        require(user != address(0), ZeroUser());
        require(bytes(reason).length <= maxReasonBytes, ReasonTooLong());
        require(label.isSingleLabel(), InvalidLabel());

        bytes32 node = _nodeOf(label);
        require(_clearExpiredGrant(_names[node]) == NameStatus.Open, NameNotOpen(node));
        require(_claims[node][user].status == ClaimStatus.None, AlreadyClaimed(node, user));
        require(_claimants[node].length() < maxClaimants, TooManyClaimants(node));

        _claims[node][user] = Claim({
            user: user,
            status: ClaimStatus.Requested,
            requestedAt: uint64(block.timestamp),
            submitter: msg.sender,
            reason: reason
        });
        _claimants[node].add(user);
        _activate(node, label);
        emit NameRequested(node, user, label, reason);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function accept(string calldata label, address user) external override onlyGovernance {
        bytes32 node = _nodeOf(label);
        require(_claims[node][user].status == ClaimStatus.Requested, NotRequested(node, user));
        emit NameAccepted(node, user, label);
        _settle(node, user, label);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function reject(string calldata label, address user) external override onlyGovernance {
        bytes32 node = _nodeOf(label);
        Claim storage claim = _claims[node][user];
        require(claim.status == ClaimStatus.Requested, NotRequested(node, user));
        // Free the claimant slot either way. Keep a sticky Rejected record only for a self-filed
        // claim, so the beneficiary cannot re-request; a claim filed on their behalf is
        // deleted and never binds them.
        _claimants[node].remove(user);
        if (claim.submitter == user) {
            claim.status = ClaimStatus.Rejected;
        } else {
            delete _claims[node][user];
        }
        emit NameRejected(node, user, label);
        _deactivate(node);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function grantName(string calldata label, address user) external override onlyGovernance {
        _grant(label, user);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function grantNames(string[] calldata labels, address user) external override onlyGovernance {
        require(labels.length <= maxGrantBatch, TooManyLabels());
        for (uint256 i = 0; i < labels.length; i++) {
            _grant(labels[i], user);
        }
    }

    /// @inheritdoc IDotnsNameWhitelist
    function revokeName(string calldata label) external override onlyGovernance {
        bytes32 node = _nodeOf(label);
        NameRecord storage record = _names[node];
        require(
            record.status == NameStatus.Claimed || _claimants[node].length() != 0,
            NothingToRevoke(node)
        );
        address winner = record.winner;
        _clearClaimants(node, address(0), label);
        record.status = NameStatus.Open;
        record.winner = address(0);
        record.grantedAt = 0;
        emit NameRevoked(node, winner, label);
        _deactivate(node);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function setReserved(string calldata label, bool reserved) external override onlyGovernance {
        require(label.isSingleLabel(), InvalidLabel());
        bytes32 node = _nodeOf(label);
        NameRecord storage record = _names[node];
        if (reserved) {
            require(_clearExpiredGrant(record) == NameStatus.Open, NameNotOpen(node));
            // Clear any pending claims the way a grant does, so a permissionless requestName
            // cannot force governance to revokeName before it can reserve.
            _clearClaimants(node, address(0), label);
            record.status = NameStatus.Reserved;
            _activate(node, label);
            emit NameReserved(node, label);
        } else {
            require(record.status == NameStatus.Reserved, NotReserved(node));
            record.status = NameStatus.Open;
            emit NameUnreserved(node, label);
            _deactivate(node);
        }
    }

    /// @inheritdoc IDotnsNameWhitelist
    function consume(string calldata label, address registrant) external override onlyController {
        bytes32 node = _nodeOf(label);
        NameRecord storage record = _names[node];
        require(
            _statusOf(record) == NameStatus.Claimed && record.winner == registrant,
            NotWinner(registrant, node)
        );
        record.status = NameStatus.Open;
        record.winner = address(0);
        record.grantedAt = 0;
        emit NameConsumed(node, registrant, label);
        _deactivate(node);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function setWindow(uint64 startsIn, uint64 duration) external override onlyGovernance {
        require(duration > 0, BadWindow());
        uint64 openAt = uint64(block.timestamp) + startsIn;
        uint64 closeAt = openAt + duration;
        _requestOpen = openAt;
        _requestClose = closeAt;
        emit WindowSet(openAt, closeAt);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function statusOf(string calldata label) external view override returns (NameStatus status) {
        return _statusOf(_names[_nodeOf(label)]);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function isReserved(string calldata label) external view override returns (bool reserved) {
        return _names[_nodeOf(label)].status == NameStatus.Reserved;
    }

    /// @inheritdoc IDotnsNameWhitelist
    function granteeOf(string calldata label) external view override returns (address winner) {
        NameRecord storage record = _names[_nodeOf(label)];
        return _statusOf(record) == NameStatus.Claimed ? record.winner : address(0);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function grantExpiresAt(string calldata label)
        external
        view
        override
        returns (uint64 expiresAt)
    {
        NameRecord storage record = _names[_nodeOf(label)];
        return _statusOf(record) == NameStatus.Claimed ? _expiryOf(record) : 0;
    }

    /// @inheritdoc IDotnsNameWhitelist
    function isGrantedTo(
        string calldata label,
        address account
    )
        external
        view
        override
        returns (bool granted)
    {
        NameRecord storage record = _names[_nodeOf(label)];
        return account != address(0) && _statusOf(record) == NameStatus.Claimed
            && record.winner == account;
    }

    /// @inheritdoc IDotnsNameWhitelist
    function claimOf(
        string calldata label,
        address user
    )
        external
        view
        override
        returns (Claim memory claim)
    {
        return _claims[_nodeOf(label)][user];
    }

    /// @inheritdoc IDotnsNameWhitelist
    function claimantCount(string calldata label) external view override returns (uint256 count) {
        return _claimants[_nodeOf(label)].length();
    }

    /// @inheritdoc IDotnsNameWhitelist
    function claims(
        string calldata label,
        uint256 offset,
        uint256 limit
    )
        external
        view
        override
        returns (Claim[] memory page)
    {
        bytes32 node = _nodeOf(label);
        EnumerableSet.AddressSet storage set = _claimants[node];
        uint256 total = set.length();
        if (offset >= total) {
            return new Claim[](0);
        }
        uint256 available = total - offset;
        uint256 count = limit < available ? limit : available;
        page = new Claim[](count);
        for (uint256 i; i < count; ++i) {
            page[i] = _claims[node][set.at(offset + i)];
        }
    }

    /// @inheritdoc IDotnsNameWhitelist
    function nameCount() external view override returns (uint256 count) {
        return _activeNodes.length();
    }

    /// @inheritdoc IDotnsNameWhitelist
    function names(
        uint256 offset,
        uint256 limit
    )
        external
        view
        override
        returns (NameView[] memory page)
    {
        uint256 total = _activeNodes.length();
        if (offset >= total) {
            return new NameView[](0);
        }
        uint256 available = total - offset;
        uint256 count = limit < available ? limit : available;
        page = new NameView[](count);
        for (uint256 i; i < count; ++i) {
            bytes32 node = _activeNodes.at(offset + i);
            NameRecord storage record = _names[node];
            NameStatus status = _statusOf(record);
            page[i] = NameView({
                node: node,
                label: record.label,
                status: status,
                winner: status == NameStatus.Claimed ? record.winner : address(0)
            });
        }
    }

    /// @inheritdoc IDotnsNameWhitelist
    function window() external view override returns (uint64 openAt, uint64 closeAt) {
        return (_requestOpen, _requestClose);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function isWindowOpen() external view override returns (bool open) {
        return _isWindowOpen();
    }

    /// @inheritdoc ERC165Upgradeable
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165Upgradeable)
        returns (bool supported)
    {
        return interfaceId == type(IDotnsNameWhitelist).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice Grants `label` to `user` directly, clearing any pending claims.
    /// @param label Bare label to grant.
    /// @param user Beneficiary the name binds to.
    function _grant(string calldata label, address user) internal {
        require(user != address(0), ZeroUser());
        require(label.isSingleLabel(), InvalidLabel());
        bytes32 node = _nodeOf(label);
        require(_clearExpiredGrant(_names[node]) == NameStatus.Open, NameNotOpen(node));
        emit NameAccepted(node, user, label);
        _settle(node, user, label);
    }

    /// @notice Marks a name claimed for `winner` and clears its claims, rejecting the losers.
    /// @param node Namehash of the label under the active TLD.
    /// @param winner Beneficiary the name binds to.
    /// @param label Bare label, stored for review.
    function _settle(bytes32 node, address winner, string calldata label) internal {
        NameRecord storage record = _names[node];
        record.status = NameStatus.Claimed;
        record.winner = winner;
        record.grantedAt = uint64(block.timestamp);
        _activate(node, label);
        _clearClaimants(node, winner, label);
    }

    /// @notice Returns the status of `record`, reading an expired grant as Open.
    /// @param record Stored record of the name.
    /// @return status Effective name status.
    function _statusOf(NameRecord storage record) internal view returns (NameStatus status) {
        status = record.status;
        if (status == NameStatus.Claimed && block.timestamp >= _expiryOf(record)) {
            status = NameStatus.Open;
        }
    }

    /// @notice Returns when the grant held in `record` expires.
    /// @dev The period runs from `grantedAt`, or from the grant clock start for a grant made
    ///      before expiry was initialised. A zero `grantDuration` exists only on a whitelist
    ///      upgraded without `initializeGrantExpiry`, since `setGrantDuration` refuses it; every
    ///      grant then keeps binding, so a separate upgrade call cannot open granted names.
    /// @param record Stored record of a `Claimed` name.
    /// @return expiresAt Timestamp the grant expires at; `type(uint64).max` while the period is
    ///         unset.
    function _expiryOf(NameRecord storage record) internal view returns (uint64 expiresAt) {
        if (grantDuration == 0) return type(uint64).max;
        uint64 start = record.grantedAt;
        if (start < _grantClockStart) start = _grantClockStart;
        return start + grantDuration;
    }

    /// @notice Resets an expired grant in `record` to Open and returns the resulting status.
    /// @dev Run by the writes that need an Open name, so a lapsed grant is never carried into a
    ///      new state.
    /// @param record Stored record of the name.
    /// @return status Status of the name after the reset.
    function _clearExpiredGrant(NameRecord storage record) internal returns (NameStatus status) {
        status = _statusOf(record);
        if (status != record.status) {
            record.status = NameStatus.Open;
            record.winner = address(0);
            record.grantedAt = 0;
        }
    }

    /// @notice Deletes every claim on a name, rejecting each claimant that is not `winner`.
    /// @param node Namehash of the label under the active TLD.
    /// @param winner Claimant spared a rejection event; the zero address rejects every claimant.
    /// @param label Bare label emitted with each rejection.
    function _clearClaimants(bytes32 node, address winner, string calldata label) internal {
        address[] memory current = _claimants[node].values();
        for (uint256 i; i < current.length; ++i) {
            address claimant = current[i];
            delete _claims[node][claimant];
            _claimants[node].remove(claimant);
            if (claimant != winner) {
                emit NameRejected(node, claimant, label);
            }
        }
    }

    /// @notice Records a name as active and stores its label the first time it is seen.
    /// @param node Namehash of the label under the active TLD.
    /// @param label Bare label stored on first activation.
    function _activate(bytes32 node, string calldata label) internal {
        NameRecord storage record = _names[node];
        if (bytes(record.label).length == 0) {
            record.label = label;
        }
        _activeNodes.add(node);
    }

    /// @notice Drops a name from the active set once it is Open with no claims.
    /// @param node Namehash of the label under the active TLD.
    function _deactivate(bytes32 node) internal {
        NameRecord storage record = _names[node];
        if (record.status == NameStatus.Open && _claimants[node].length() == 0) {
            _activeNodes.remove(node);
            delete record.label;
        }
    }

    /// @notice Derives the namehash of `label` under the active TLD read from the registry.
    /// @param label Bare label to hash.
    /// @return node Namehash of the label under the active TLD.
    function _nodeOf(string calldata label) internal view returns (bytes32 node) {
        (, node) = LabelUtils.deriveNode(protocolRegistry.tldNode(), label);
    }

    /// @notice Returns whether the current time is within the open window.
    /// @return open True when the current time is within the window.
    function _isWindowOpen() internal view returns (bool open) {
        return block.timestamp >= _requestOpen && block.timestamp < _requestClose;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
