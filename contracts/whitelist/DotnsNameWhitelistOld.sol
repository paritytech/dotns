// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {DotnsRoleManagerOld} from "../access/DotnsRoleManagerOld.sol";
import {IDotnsNameWhitelistOld} from "./IDotnsNameWhitelistOld.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {LabelUtils} from "../utils/LabelUtils.sol";
import {StringUtils} from "../utils/StringUtils.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";
import {SystemUtils} from "../utils/SystemUtils.sol";

/// @title DotnsNameWhitelist
/// @notice Pre-launch name whitelist. A name is Open until governance reserves it or a claim is
///         accepted for it. Several beneficiaries may claim the same Open name, each with a
///         reason, and governance accepts one as the winner.
/// @dev Lives behind its own UUPS proxy with its own storage. Callers pass bare labels only; the
///      contract derives the node from the label and the TLD in the protocol registry, so a
///      caller cannot supply a mismatched hash. Claims are keyed by the beneficiary `user`, not
///      the submitter, so a relayer or a cross-chain sovereign account can submit on a user's
///      behalf and the name binds to that user. All state is on-chain and queryable through views;
///      no event indexing is required. A name holds at most `maxClaimants` live claims, which
///      bounds the loop that clears them on resolution. Resolving a name deletes its claims,
///      refunding their storage deposit, so only reserved or won names persist. Governance is Root
///      or the owner. Substrate Root has no address, so the governance gates check
///      `SystemUtils.originIsRoot`, which is true through the proxy's delegatecall frame, before
///      reading `msg.sender`. Operators are signed role holders
///      for day-to-day approvals; the public and PoP controllers hold only the `consume` hook.
///      Entries are keyed by the node under the active TLD, which the deployment holds immutable
///      for the whitelist's lifetime.
/// @custom:security-contact admin@parity.io
contract DotnsNameWhitelistOld is
    Initializable,
    UUPSUpgradeable,
    DotnsRoleManagerOld,
    IDotnsNameWhitelistOld
{
    using StringUtils for string;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Operator role identifier this snapshot recognises for its operational gates.
    /// @dev Pinned here so the snapshot compiles against the current `DotnsConstants`, which no
    ///      longer declares the role. The value matches the identifier the deployed proxy stored.
    bytes32 private constant WHITELIST_OPERATOR_ROLE = keccak256("DOTNS_WHITELIST_OPERATOR_ROLE");

    /// @notice Protocol-level address registry for all DotNS contracts.
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

    /// @dev Reserved storage space to allow for layout changes in the future.
    uint256[50] private __gap;

    /// @notice Restricts a call to Root or the owner.
    /// @dev Checks Root first so `msg.sender`, which traps under a Root origin, is read only for a
    ///      signed caller.
    modifier onlyGovernance() {
        if (!SystemUtils.originIsRoot()) {
            _checkOwner();
        }
        _;
    }

    /// @notice Restricts a call to Root, the owner, or an operator.
    modifier onlyOperatorOrGovernance() {
        if (!SystemUtils.originIsRoot()) {
            _checkRoleOrOwner(WHITELIST_OPERATOR_ROLE);
        }
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the whitelist.
    /// @dev Callable once through the UUPS proxy; direct calls on the implementation
    ///      @custom:reverts InvalidInitialization. Sets the deployer as owner and wires the
    ///      protocol registry the node derivation reads the TLD from.
    /// @param registry Protocol registry all DotNS contracts resolve through.
    function initialize(IDotnsProtocolRegistry registry) external initializer {
        __ERC165_init();
        __Ownable_init(msg.sender);
        _dotnsRoleManagerInit();
        protocolRegistry = registry;
        maxClaimants = DotnsConstants.WHITELIST_DEFAULT_MAX_CLAIMANTS;
        maxGrantBatch = DotnsConstants.WHITELIST_DEFAULT_MAX_GRANT_BATCH;
        maxReasonBytes = DotnsConstants.WHITELIST_DEFAULT_MAX_REASON_BYTES;
    }

    /// @inheritdoc IDotnsNameWhitelistOld
    function setOperator(address account, bool enabled) external override onlyGovernance {
        _setRole(WHITELIST_OPERATOR_ROLE, account, enabled);
    }

    /// @inheritdoc IDotnsNameWhitelistOld
    function setMaxClaimants(uint16 newMax) external override onlyGovernance {
        require(
            newMax > 0 && newMax <= DotnsConstants.WHITELIST_MAX_CLAIMANTS_LIMIT,
            MaxClaimantsOutOfRange()
        );
        maxClaimants = newMax;
        emit MaxClaimantsSet(newMax);
    }

    /// @inheritdoc IDotnsNameWhitelistOld
    function setMaxReasonBytes(uint256 newMax) external override onlyGovernance {
        require(
            newMax > 0 && newMax <= DotnsConstants.WHITELIST_MAX_REASON_LIMIT,
            MaxReasonBytesOutOfRange()
        );
        maxReasonBytes = newMax;
        emit MaxReasonBytesSet(newMax);
    }

    /// @inheritdoc IDotnsNameWhitelistOld
    function setMaxGrantBatch(uint16 newMax) external override onlyGovernance {
        require(
            newMax > 0 && newMax <= DotnsConstants.WHITELIST_MAX_GRANT_BATCH_LIMIT,
            MaxGrantBatchOutOfRange()
        );
        maxGrantBatch = newMax;
        emit MaxGrantBatchSet(newMax);
    }

    /// @inheritdoc IDotnsNameWhitelistOld
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
        require(_names[node].status == NameStatus.Open, NameNotOpen(node));
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

    /// @inheritdoc IDotnsNameWhitelistOld
    function accept(
        string calldata label,
        address user
    )
        external
        override
        onlyOperatorOrGovernance
    {
        bytes32 node = _nodeOf(label);
        require(_claims[node][user].status == ClaimStatus.Requested, NotRequested(node, user));
        emit NameAccepted(node, user, label);
        _settle(node, user, label);
    }

    /// @inheritdoc IDotnsNameWhitelistOld
    function reject(
        string calldata label,
        address user
    )
        external
        override
        onlyOperatorOrGovernance
    {
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

    /// @inheritdoc IDotnsNameWhitelistOld
    function grantName(
        string calldata label,
        address user
    )
        external
        override
        onlyOperatorOrGovernance
    {
        _grant(label, user);
    }

    /// @inheritdoc IDotnsNameWhitelistOld
    function grantNames(
        string[] calldata labels,
        address user
    )
        external
        override
        onlyOperatorOrGovernance
    {
        require(labels.length <= maxGrantBatch, TooManyLabels());
        for (uint256 i = 0; i < labels.length; i++) {
            _grant(labels[i], user);
        }
    }

    /// @inheritdoc IDotnsNameWhitelistOld
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
        emit NameRevoked(node, winner, label);
        _deactivate(node);
    }

    /// @inheritdoc IDotnsNameWhitelistOld
    function setReserved(string calldata label, bool reserved) external override onlyGovernance {
        require(label.isSingleLabel(), InvalidLabel());
        bytes32 node = _nodeOf(label);
        NameRecord storage record = _names[node];
        if (reserved) {
            require(record.status == NameStatus.Open, NameNotOpen(node));
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

    /// @inheritdoc IDotnsNameWhitelistOld
    function consume(string calldata label, address registrant) external override onlyController {
        bytes32 node = _nodeOf(label);
        NameRecord storage record = _names[node];
        require(
            record.status == NameStatus.Claimed && record.winner == registrant,
            NotWinner(registrant, node)
        );
        record.status = NameStatus.Open;
        record.winner = address(0);
        emit NameConsumed(node, registrant, label);
        _deactivate(node);
    }

    /// @inheritdoc IDotnsNameWhitelistOld
    function setWindow(uint64 startsIn, uint64 duration) external override onlyGovernance {
        require(duration > 0, BadWindow());
        uint64 openAt = uint64(block.timestamp) + startsIn;
        uint64 closeAt = openAt + duration;
        _requestOpen = openAt;
        _requestClose = closeAt;
        emit WindowSet(openAt, closeAt);
    }

    /// @inheritdoc IDotnsNameWhitelistOld
    function statusOf(string calldata label) external view override returns (NameStatus status) {
        return _names[_nodeOf(label)].status;
    }

    /// @inheritdoc IDotnsNameWhitelistOld
    function isReserved(string calldata label) external view override returns (bool reserved) {
        return _names[_nodeOf(label)].status == NameStatus.Reserved;
    }

    /// @inheritdoc IDotnsNameWhitelistOld
    function granteeOf(string calldata label) external view override returns (address winner) {
        NameRecord storage record = _names[_nodeOf(label)];
        return record.status == NameStatus.Claimed ? record.winner : address(0);
    }

    /// @inheritdoc IDotnsNameWhitelistOld
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
        return
            account != address(0) && record.status == NameStatus.Claimed && record.winner == account;
    }

    /// @inheritdoc IDotnsNameWhitelistOld
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

    /// @inheritdoc IDotnsNameWhitelistOld
    function claimantCount(string calldata label) external view override returns (uint256 count) {
        return _claimants[_nodeOf(label)].length();
    }

    /// @inheritdoc IDotnsNameWhitelistOld
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

    /// @inheritdoc IDotnsNameWhitelistOld
    function nameCount() external view override returns (uint256 count) {
        return _activeNodes.length();
    }

    /// @inheritdoc IDotnsNameWhitelistOld
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
            page[i] = NameView({
                node: node, label: record.label, status: record.status, winner: record.winner
            });
        }
    }

    /// @inheritdoc IDotnsNameWhitelistOld
    function window() external view override returns (uint64 openAt, uint64 closeAt) {
        return (_requestOpen, _requestClose);
    }

    /// @inheritdoc IDotnsNameWhitelistOld
    function isWindowOpen() external view override returns (bool open) {
        return _isWindowOpen();
    }

    /// @inheritdoc DotnsRoleManagerOld
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(DotnsRoleManagerOld)
        returns (bool supported)
    {
        return interfaceId == type(IDotnsNameWhitelistOld).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice Grants `label` to `user` directly, clearing any pending claims.
    /// @param label Bare label to grant.
    /// @param user Beneficiary the name binds to.
    function _grant(string calldata label, address user) internal {
        require(user != address(0), ZeroUser());
        require(label.isSingleLabel(), InvalidLabel());
        bytes32 node = _nodeOf(label);
        require(_names[node].status == NameStatus.Open, NameNotOpen(node));
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
        _activate(node, label);
        _clearClaimants(node, winner, label);
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

    /// @inheritdoc DotnsRoleManagerOld
    function _isSupportedRole(bytes32 role) internal pure override returns (bool supported) {
        return role == WHITELIST_OPERATOR_ROLE;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
