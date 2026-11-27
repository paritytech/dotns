// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ProtocolOwnedUpgradeable} from "../utils/ProtocolOwnedUpgradeable.sol";
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
///      no event indexing is required. A name holds at most `maxClaimants` live claims. Claims
///      are kept per round: resolving a name starts its next round, which leaves the previous
///      round's claims unreachable in one write, so resolution costs the same however many
///      claims a name holds. Grants,
///      revocations, acceptances, rejections and reservations are substrate Root only: those
///      gates check `SystemUtils.callerIsRoot`, true through the proxy's delegatecall frame, and
///      read no `msg.sender`. The request window and the caps are also open to the maintainer
///      account, within the rules each setter enforces; that gate reads `msg.sender` only after
///      the Root check fails. The owner's authority is upgrade only. The public and PoP controllers
/// hold only the `consume` hook. Entries are keyed by the node under the active TLD, which the
/// deployment holds immutable
///      for the whitelist's lifetime.
/// @custom:security-contact admin@parity.io
contract DotnsNameWhitelist is
    Initializable,
    UUPSUpgradeable,
    ProtocolOwnedUpgradeable,
    ERC165Upgradeable,
    IDotnsNameWhitelist
{
    using StringUtils for string;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Protocol-level address registry for all dotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @notice Live-claim cap per name, tunable by Root or the maintainer account within
    ///         `DotnsConstants.WHITELIST_MAX_CLAIMANTS_LIMIT`.
    uint16 public maxClaimants;

    /// @notice Cap on labels per `grantNames` call, tunable by Root or the maintainer account
    /// within `DotnsConstants.WHITELIST_MAX_GRANT_BATCH_LIMIT`.
    uint16 public maxGrantBatch;

    /// @notice Reason byte cap, tunable by Root or the maintainer account within
    ///         `DotnsConstants.WHITELIST_MAX_REASON_LIMIT`.
    uint256 public maxReasonBytes;

    /// @notice Resolved state per name.
    mapping(bytes32 node => NameRecord record) private _names;

    /// @notice Claims per round of a name, keyed by beneficiary.
    /// @dev Keyed by @custom:function _roundKey, never by the bare node.
    mapping(bytes32 roundKey => mapping(address user => Claim claim)) private _claims;

    /// @notice Beneficiaries with a live claim per round of a name.
    /// @dev Keyed by @custom:function _roundKey, never by the bare node.
    mapping(bytes32 roundKey => EnumerableSet.AddressSet claimants) private _claimants;

    /// @notice Names holding reserved, claimed or claim-holding state, kept enumerable for review.
    EnumerableSet.Bytes32Set private _activeNodes;

    /// @notice Timestamp requests start being accepted.
    uint64 private _requestOpen;

    /// @notice Timestamp requests stop being accepted.
    uint64 private _requestClose;

    /// @notice Period a grant binds its name, tunable by Root or the maintainer account within
    ///         `DotnsConstants.WHITELIST_MIN_GRANT_DURATION` and
    ///         `DotnsConstants.WHITELIST_MAX_GRANT_DURATION`.
    uint64 public grantDuration;

    /// @notice Expiry of every grant recorded before grant expiry was initialised.
    /// @dev Fixed when grant expiry is initialised, to that moment plus the grant period then in
    ///      force. Such a grant has no `expiresAt` of its own. Zero until then, while those grants
    ///      keep binding.
    uint64 private _legacyGrantExpiresAt;

    /// @notice Round of claims each name is on.
    /// @dev Resolving a name moves it to the next round, so the previous round's claims become
    ///      unreachable without a write per claim. Zero until a name is first resolved, and round
    ///      zero keys claims by the bare node, so claims made before rounds existed stay live.
    mapping(bytes32 node => uint256 round) private _claimRounds;

    /// @dev Reserved storage space to allow for layout changes in the future.
    uint256[49] private __gap;

    /// @notice Restricts a call to a substrate Root dispatch.
    /// @dev Every decision about who holds a name is governance-only: no key grants, revokes or
    ///      reserves. The bootstrap owner configures and upgrades until Root renounces it,
    ///      and never allocates, so no signed account can hand out a name. `msg.sender` is never
    ///      read here, which is also what keeps every gated entry point callable under a Root
    ///      origin, since Root has no account.
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
        require(SystemUtils.callerIsRoot(), NotGovernance());
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the whitelist.
    /// @dev Callable once through the UUPS proxy; direct calls on the implementation
    ///      @custom:reverts InvalidInitialization. Wires the protocol registry, which holds
    ///      the bootstrap owner and the TLD the node derivation reads.
    /// @param registry Protocol registry all dotNS contracts resolve through.
    function initialize(IDotnsProtocolRegistry registry) external initializer {
        __ERC165_init();
        _requireProtocolRegistry(address(registry));
        protocolRegistry = registry;
        maxClaimants = DotnsConstants.WHITELIST_DEFAULT_MAX_CLAIMANTS;
        maxGrantBatch = DotnsConstants.WHITELIST_DEFAULT_MAX_GRANT_BATCH;
        maxReasonBytes = DotnsConstants.WHITELIST_DEFAULT_MAX_REASON_BYTES;
        _initializeGrantExpiry();
    }

    /// @notice Starts grant expiry on a whitelist initialised without it.
    /// @dev Called once through `upgradeToAndCall`, so the upgrade and the expiry start land in
    ///      one call. Sets the default grant period unless governance already set one, and fixes
    ///      the expiry of grants made before it, which have no `expiresAt`, at the period from now.
    ///      A whitelist whose expiry already runs @custom:reverts InvalidInitialization.
    function initializeGrantExpiry() external reinitializer(2) onlyRootOrOwner {
        require(_legacyGrantExpiresAt == 0, InvalidInitialization());
        _initializeGrantExpiry();
    }

    /// @notice Sets the default grant period when none is set, and fixes the expiry of grants
    ///         recorded before grant expiry.
    function _initializeGrantExpiry() internal {
        if (grantDuration == 0) {
            grantDuration = DotnsConstants.WHITELIST_DEFAULT_GRANT_DURATION;
            emit GrantDurationSet(DotnsConstants.WHITELIST_DEFAULT_GRANT_DURATION);
        }
        _legacyGrantExpiresAt = uint64(block.timestamp) + grantDuration;
    }

    /// @inheritdoc IDotnsNameWhitelist
    function setMaxClaimants(uint16 newMax) external override {
        // While requests are being taken, a lower cap would lock out claimants on a name another
        // claimant just reached: the maintainer can only raise it then.
        require(
            _checkRootOrMaintainer() || !_windowLive() || newMax >= maxClaimants,
            MaintainerNotAllowed()
        );
        require(
            newMax > 0 && newMax <= DotnsConstants.WHITELIST_MAX_CLAIMANTS_LIMIT,
            MaxClaimantsOutOfRange()
        );
        maxClaimants = newMax;
        emit MaxClaimantsSet(newMax);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function setMaxReasonBytes(uint256 newMax) external override {
        // While requests are being taken, a lower cap would cut short the reasons claimants are
        // writing: the maintainer can only raise it then.
        require(
            _checkRootOrMaintainer() || !_windowLive() || newMax >= maxReasonBytes,
            MaintainerNotAllowed()
        );
        require(
            newMax > 0 && newMax <= DotnsConstants.WHITELIST_MAX_REASON_LIMIT,
            MaxReasonBytesOutOfRange()
        );
        maxReasonBytes = newMax;
        emit MaxReasonBytesSet(newMax);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function setMaxGrantBatch(uint16 newMax) external override {
        // The cap limits Root's own grant batches, so lowering it could fail a pending
        // referendum: the maintainer can only raise it.
        require(_checkRootOrMaintainer() || newMax >= maxGrantBatch, MaintainerNotAllowed());
        require(
            newMax > 0 && newMax <= DotnsConstants.WHITELIST_MAX_GRANT_BATCH_LIMIT,
            MaxGrantBatchOutOfRange()
        );
        maxGrantBatch = newMax;
        emit MaxGrantBatchSet(newMax);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function setGrantDuration(uint64 newDuration) external override {
        // A shorter period would cut the grants a pending referendum makes: the maintainer can
        // only raise it.
        require(_checkRootOrMaintainer() || newDuration >= grantDuration, MaintainerNotAllowed());
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
        _requireMintableLabel(label);

        bytes32 node = _nodeOf(label);
        require(_clearExpiredGrant(_names[node]) == NameStatus.Open, NameNotOpen(node));
        bytes32 key = _roundKey(node);
        require(_claims[key][user].status == ClaimStatus.None, AlreadyClaimed(node, user));
        require(_claimants[key].length() < maxClaimants, TooManyClaimants(node));

        _claims[key][user] = Claim({
            user: user,
            status: ClaimStatus.Requested,
            requestedAt: uint64(block.timestamp),
            submitter: msg.sender,
            reason: reason
        });
        _claimants[key].add(user);
        _activate(node, label);
        emit NameRequested(node, user, msg.sender, label, reason);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function withdrawClaim(string calldata label) external override {
        bytes32 node = _nodeOf(label);
        bytes32 key = _roundKey(node);
        require(
            _claims[key][msg.sender].status == ClaimStatus.Requested, NotRequested(node, msg.sender)
        );
        delete _claims[key][msg.sender];
        _claimants[key].remove(msg.sender);
        emit ClaimWithdrawn(node, msg.sender, label);
        _deactivate(node);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function accept(string calldata label, address user) external override onlyGovernance {
        bytes32 node = _nodeOf(label);
        require(
            _claims[_roundKey(node)][user].status == ClaimStatus.Requested, NotRequested(node, user)
        );
        emit NameAccepted(node, user, label);
        _settle(node, user, label);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function reject(string calldata label, address user) external override onlyGovernance {
        bytes32 node = _nodeOf(label);
        bytes32 key = _roundKey(node);
        Claim storage claim = _claims[key][user];
        require(claim.status == ClaimStatus.Requested, NotRequested(node, user));
        // Free the claimant slot either way. Keep a sticky Rejected record only for a self-filed
        // claim, so the beneficiary cannot re-request in this round; a claim filed on their
        // behalf is deleted and never binds them.
        _claimants[key].remove(user);
        if (claim.submitter == user) {
            claim.status = ClaimStatus.Rejected;
        } else {
            delete _claims[key][user];
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
            record.status == NameStatus.Claimed || _claimants[_roundKey(node)].length() != 0,
            NothingToRevoke(node)
        );
        address winner = record.winner;
        _closeRound(node, label);
        record.status = NameStatus.Open;
        record.winner = address(0);
        record.expiresAt = 0;
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
            _closeRound(node, label);
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
        record.expiresAt = 0;
        emit NameConsumed(node, registrant, label);
        _deactivate(node);
    }

    /// @inheritdoc IDotnsNameWhitelist
    function setWindow(uint64 startsIn, uint64 duration) external override {
        bool root = _checkRootOrMaintainer();
        require(duration > 0, BadWindow());
        uint64 openAt = uint64(block.timestamp) + startsIn;
        if (!root) {
            // Opening intake is Root's decision. The maintainer only lengthens a window Root
            // opened or scheduled: it keeps its opening, and closing it early or moving it would
            // cut off requests people planned around.
            require(_windowLive() && startsIn == 0, MaintainerNotAllowed());
            openAt = _requestOpen;
            require(openAt + duration >= _requestClose, MaintainerNotAllowed());
            require(
                duration <= DotnsConstants.WHITELIST_MAINTAINER_MAX_WINDOW,
                MaintainerWindowOutOfBounds()
            );
        }
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
        return _granteeOf(_nodeOf(label));
    }

    /// @inheritdoc IDotnsNameWhitelist
    function granteeOfNode(bytes32 node) external view override returns (address winner) {
        return _granteeOf(node);
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
        return _claims[_roundKey(_nodeOf(label))][user];
    }

    /// @inheritdoc IDotnsNameWhitelist
    function claimantCount(string calldata label) external view override returns (uint256 count) {
        return _claimants[_roundKey(_nodeOf(label))].length();
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
        bytes32 key = _roundKey(_nodeOf(label));
        EnumerableSet.AddressSet storage set = _claimants[key];
        uint256 total = set.length();
        if (offset >= total) {
            return new Claim[](0);
        }
        uint256 available = total - offset;
        uint256 count = limit < available ? limit : available;
        page = new Claim[](count);
        for (uint256 i; i < count; ++i) {
            page[i] = _claims[key][set.at(offset + i)];
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
        _requireMintableLabel(label);
        bytes32 node = _nodeOf(label);
        require(_clearExpiredGrant(_names[node]) == NameStatus.Open, NameNotOpen(node));
        emit NameAccepted(node, user, label);
        _settle(node, user, label);
    }

    /// @notice Marks a name claimed for `winner` and ends its round of claims.
    /// @param node Namehash of the label under the active TLD.
    /// @param winner Beneficiary the name binds to.
    /// @param label Bare label, stored for review.
    function _settle(bytes32 node, address winner, string calldata label) internal {
        NameRecord storage record = _names[node];
        record.status = NameStatus.Claimed;
        record.winner = winner;
        // Without a grant period the record takes no expiry of its own, so the grant binds until
        // `initializeGrantExpiry` sets the shared legacy expiry.
        record.expiresAt = grantDuration == 0 ? 0 : uint64(block.timestamp) + grantDuration;
        _activate(node, label);
        _closeRound(node, label);
    }

    /// @notice Returns the live winner of the name at `node`, or the zero address.
    /// @param node Namehash of the label under the active TLD.
    /// @return winner Winning beneficiary while the grant binds.
    function _granteeOf(bytes32 node) internal view returns (address winner) {
        NameRecord storage record = _names[node];
        return _statusOf(record) == NameStatus.Claimed ? record.winner : address(0);
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
    /// @dev A grant keeps the expiry fixed when it was made, so a later `setGrantDuration` never
    ///      moves it. A grant recorded before grant expiry was initialised shares
    ///      `_legacyGrantExpiresAt`; until that is set, on a whitelist upgraded without
    ///      `initializeGrantExpiry`, such a grant keeps binding.
    /// @param record Stored record of a `Claimed` name.
    /// @return expiresAt Timestamp the grant expires at; `type(uint64).max` for a grant recorded
    ///         before grant expiry while it is not yet initialised.
    function _expiryOf(NameRecord storage record) internal view returns (uint64 expiresAt) {
        expiresAt = record.expiresAt;
        if (expiresAt != 0) return expiresAt;
        expiresAt = _legacyGrantExpiresAt;
        if (expiresAt == 0) return type(uint64).max;
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
            record.expiresAt = 0;
        }
    }

    /// @notice Ends the current round of claims on a name and starts the next.
    /// @dev One write, however many claims the round holds: its claims stay in storage, where no
    ///      view or gate reads them again. A rejection kept for a self-filed claim holds for the
    ///      round it was made in. @custom:emits ClaimsCleared when the round held live claims.
    /// @param node Namehash of the label under the active TLD.
    /// @param label Bare label emitted with the event.
    function _closeRound(bytes32 node, string calldata label) internal {
        uint256 live = _claimants[_roundKey(node)].length();
        uint256 round = _claimRounds[node] + 1;
        _claimRounds[node] = round;
        if (live != 0) {
            emit ClaimsCleared(node, label, round - 1, live);
        }
    }

    /// @notice Returns the key the current round of claims on `node` is stored under.
    /// @dev Round zero uses the bare node, which keeps claims made before rounds existed live.
    /// @param node Namehash of the label under the active TLD.
    /// @return key Storage key for `_claims` and `_claimants`.
    function _roundKey(bytes32 node) internal view returns (bytes32 key) {
        uint256 round = _claimRounds[node];
        return round == 0 ? node : keccak256(abi.encode(node, round));
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
        if (record.status == NameStatus.Open && _claimants[_roundKey(node)].length() == 0) {
            _activeNodes.remove(node);
            delete record.label;
        }
    }

    /// @notice Reverts unless `label` is a canonical single label `registerReserved` can mint.
    /// @dev Applies the controller's minimum length, so a request or grant never names a label
    ///      that can never be registered. @custom:reverts InvalidLabel otherwise.
    /// @param label Bare label to check.
    function _requireMintableLabel(string calldata label) internal pure {
        require(
            label.isSingleLabel() && bytes(label).length >= DotnsConstants.MIN_LABEL_LENGTH,
            InvalidLabel()
        );
    }

    /// @notice Derives the namehash of `label` under the active TLD read from the registry.
    /// @param label Bare label to hash.
    /// @return node Namehash of the label under the active TLD.
    function _nodeOf(string calldata label) internal view returns (bytes32 node) {
        (, node) = LabelUtils.deriveNode(protocolRegistry.tldNode(), label);
    }

    /// @notice Returns whether a request window is open or scheduled.
    /// @return live True until the current window closes.
    function _windowLive() internal view returns (bool live) {
        return block.timestamp < _requestClose;
    }

    /// @notice Returns whether the current time is within the open window.
    /// @return open True when the current time is within the window.
    function _isWindowOpen() internal view returns (bool open) {
        return block.timestamp >= _requestOpen && block.timestamp < _requestClose;
    }

    /// @inheritdoc ProtocolOwnedUpgradeable
    function _protocolRegistryAddress() internal view override returns (address registry) {
        return address(protocolRegistry);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyRootOrOwner {}
}
