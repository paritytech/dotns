// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {
    DotnsPopController,
    IDotnsPopController
} from "../../../contracts/registrars/DotnsPopController.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {LabelUtils} from "../../../contracts/utils/LabelUtils.sol";
import {ISystem} from "../../../contracts/external/revive/ISystem.sol";
import {IPersonhood} from "../../../contracts/external/personhood/IPersonhood.sol";

/// @title PopControllerHandler
/// @notice Bounded random-action handler for @custom:contract DotnsPopController invariant tests.
/// @dev Cycles through an actor set and a fixed base-label set so the fuzzer
///      explores combinations deterministically. Tracks every labelhash that has
///      hosted a reservation, every minted lite token, and every successful
///      claim so invariants can iterate over just what exists.
contract PopControllerHandler is Test {
    /// @notice The PoP controller under test.
    DotnsPopController public immutable CONTROLLER;
    /// @notice Node hash of the suite's TLD, injected from the deployed protocol registry.
    /// @dev Keeps the handler rooted at the same TLD the protocol under test uses, without a
    ///      second TLD definition.
    bytes32 private immutable TLD_NODE;
    /// @notice Mirrors the controller's MAX_RESERVATION_QUEUE for queue-bound
    ///         assertions without re-importing the contract constant.
    uint16 public constant MAX_QUEUE = 64;

    /// @notice Actor pool the handler cycles through for every action.
    address[] public actors;
    /// @notice Fixed base-label set selected from on every action.
    string[] public baseLabels;
    /// @notice Every base labelhash that has hosted at least one reservation.
    bytes32[] public reservedLabelsSeen;
    /// @notice Dedup set for `reservedLabelsSeen` to keep iteration cheap.
    mapping(bytes32 labelhash => bool) internal _tracked;
    /// @notice Monotonic per-actor counter feeding the lite-label suffix so
    ///         each generated label is unique inside an actor's namespace.
    mapping(address actor => uint64 suffix) internal _liteSuffix;

    /// @notice Lite tokens minted through the handler (one push per successful
    ///         reserve, plus the lite and full nodes pushed on claim and the
    ///         full node pushed on reLink). Used by the labelOf-non-empty
    ///         invariant to enumerate the token space without scanning the
    ///         full uint256 id range.
    uint256[] public mintedLiteTokenIds;

    /// @notice Full nodes minted through successful claims, captured alongside
    ///         the lite labelhash they were linked against. Used by the
    ///         fullClaim/liteLink inverse invariant: for each entry,
    ///         fullClaim(liteHash) == node.
    bytes32[] public claimedFullNodes;
    /// @notice Lite labelhashes paired index-for-index with `claimedFullNodes`.
    bytes32[] public claimedLiteLabelhashes;

    /// @notice Prior lite labels reserved by the handler. Used by reLink
    ///         actions so the fuzzer can re-use an existing lite label
    ///         against a fresh base claim, driving the resolver overwrite
    ///         paths under repeated `(baseLabel, actor)` reuse. Kept as
    ///         the raw string because the controller re-hashes internally
    ///         on every call.
    string[] public priorLiteLabels;

    /// @notice Every actor that has ever held a pending claim, deduplicated.
    /// @dev The mirror invariant iterates this set to assert that any address
    ///      with a live `mintedAt` appears in `pendingClaimUsers()` and vice
    ///      versa.
    address[] public pendingClaimActorsSeen;
    mapping(address actor => bool) internal _pendingActorTracked;

    /// @notice Seeds the actor pool, base-label set, and personhood mocks so
    ///         every action call admits both lite and base classifications.
    /// @param controller_ The PoP controller under test.
    /// @param actors_ Pool of accounts the handler cycles through.
    /// @param tldNode_ Node hash of the suite's TLD, from the deployed protocol registry.
    constructor(DotnsPopController controller_, address[] memory actors_, bytes32 tldNode_) {
        CONTROLLER = controller_;
        TLD_NODE = tldNode_;
        actors = actors_;
        // baselength 8, no trailing digits: PopFull classification.
        baseLabels.push("alicebob");
        // baselength 10, 2 trailing digits: NoStatus classification.
        baseLabels.push("wonderland01");
        // baselength 10, no trailing digits: NoStatus classification.
        baseLabels.push("carolcarol");

        // Every actor needs PopFull status on the personhood precompile so the
        // classification/tier guard in PopRules.priceWithCheck admits every
        // label the handler can generate: PopLite lite labels (PopFull is a
        // superset of PopLite), PopFull base labels, and NoStatus base labels
        // (which merely require userStatus != PopLite).
        for (uint256 i = 0; i < actors_.length; i++) {
            _mockPersonhoodTier(actors_[i], 2);
        }
    }

    /// @notice Mocks the personhood precompile so `account` reports the given
    ///         status byte for the protocol's personhood context.
    /// @dev Status byte mirrors the precompile's wire format: 0 = NoStatus,
    ///      1 = PopLite, 2 = PopFull. A zero status clears the context alias.
    function _mockPersonhoodTier(address account, uint8 statusByte) internal {
        bytes32 contextAlias =
            statusByte == 0 ? bytes32(0) : keccak256(abi.encode(account, statusByte));
        vm.mockCall(
            DotnsConstants.PERSONHOOD,
            abi.encodeWithSelector(
                IPersonhood.personhoodStatus.selector, account, DotnsConstants.PERSONHOOD_CONTEXT
            ),
            abi.encode(IPersonhood.PersonhoodInfo({status: statusByte, contextAlias: contextAlias}))
        );
    }

    /// @notice Length of the actor pool.
    function actorsCount() external view returns (uint256) {
        return actors.length;
    }

    /// @notice Number of distinct base labelhashes ever reserved against.
    function reservedLabelsSeenCount() external view returns (uint256) {
        return reservedLabelsSeen.length;
    }

    /// @notice Number of base labels in the fixed selection set.
    function baseLabelCount() external view returns (uint256) {
        return baseLabels.length;
    }

    /// @notice Base label at `index` in the fixed selection set.
    function baseLabelAt(uint256 index) external view returns (string memory) {
        return baseLabels[index];
    }

    /// @notice Number of token ids the handler has ever recorded as minted.
    function mintedLiteTokenCount() external view returns (uint256) {
        return mintedLiteTokenIds.length;
    }

    /// @notice Number of successful (lite, full) claim pairs the handler has
    ///         recorded.
    function claimedCount() external view returns (uint256) {
        return claimedFullNodes.length;
    }

    /// @notice Number of prior lite labels available for reLink replay.
    function priorLiteLabelCount() external view returns (uint256) {
        return priorLiteLabels.length;
    }

    /// @notice Number of actors the handler has ever seen with a pending claim.
    function pendingClaimActorsSeenCount() external view returns (uint256) {
        return pendingClaimActorsSeen.length;
    }

    /// @notice Reserves a lite label for an actor, optionally enqueueing on a
    ///         base label.
    /// @dev Swallows known-good reverts (QueueFull, AlreadyReserved, ERC721
    ///      collision) so the runner keeps exploring. `useBytes` chooses
    ///      between the typed and bytes overloads so existing invariants run
    ///      against mixed dispatch paths. The dispatch path should affect call
    ///      shape only, never resulting state.
    function reserve(
        uint256 actorIndex,
        uint256 baseIndex,
        bool attachReservation,
        bool useBytes
    )
        external
    {
        address actor = _actor(actorIndex);
        _liteSuffix[actor]++;
        string memory liteLabel = _buildLiteLabel("rsv", actor, _liteSuffix[actor]);
        string memory reservedBase = attachReservation ? _baseLabel(baseIndex) : "";

        IDotnsPopController.BaseReservation memory params = IDotnsPopController.BaseReservation({
            lite: IDotnsPopController.LiteRegistration({
                liteLabel: liteLabel, user: actor, chatKey: ""
            }),
            reservedBaseLabel: reservedBase
        });

        if (_callReserveBaseName(params, useBytes)) {
            if (attachReservation) _track(keccak256(bytes(reservedBase)));
            bytes32 node = LabelUtils.namehashUnder(TLD_NODE, LabelUtils.labelhashMemory(liteLabel));
            mintedLiteTokenIds.push(uint256(node));
            priorLiteLabels.push(liteLabel);
            _trackPendingActor(actor);
        }
    }

    /// @notice Drives the claim path end-to-end when the actor holds the live
    ///         head of the queue for the picked base label.
    /// @dev Missing preconditions (wrong actor, expired head, empty queue)
    ///      surface as a revert and are swallowed so the runner keeps
    ///      exploring. `useBytes` selects the dispatch path for both the lite
    ///      leg and the full register leg.
    function claim(uint256 actorIndex, uint256 baseIndex, bool useBytes) external {
        address actor = _actor(actorIndex);
        string memory baseLabel = _baseLabel(baseIndex);

        IDotnsPopController.UserReservation memory reservation = CONTROLLER.userReservation(actor);
        if (reservation.labelhash == bytes32(0)) return;
        if (reservation.labelhash != keccak256(bytes(baseLabel))) return;

        _liteSuffix[actor]++;
        string memory liteLabel = _buildLiteLabel("clm", actor, _liteSuffix[actor]);

        IDotnsPopController.BaseReservation memory liteParams = IDotnsPopController.BaseReservation({
            lite: IDotnsPopController.LiteRegistration({
                liteLabel: liteLabel, user: actor, chatKey: ""
            }),
            reservedBaseLabel: ""
        });
        if (!_callReserveBaseName(liteParams, useBytes)) return;
        _trackPendingActor(actor);

        // The lite leg stashed a pending claim. Settle it now so the base
        // registration below takes the warm path; the pending-claim mechanism
        // forbids a second stash for the same user.
        vm.prank(actor);
        try CONTROLLER.claimLabelStore() {} catch {}

        IDotnsPopController.Link memory link = IDotnsPopController.Link({
            kind: IDotnsPopController.LinkKind.LiteUsername, liteLabel: liteLabel, chatKey: ""
        });
        IDotnsPopController.FullRegistration memory fullParams =
            IDotnsPopController.FullRegistration({label: baseLabel, user: actor, link: link});
        if (!_callRegisterBaseName(fullParams, useBytes)) return;

        bytes32 liteLabelhash = LabelUtils.labelhashMemory(liteLabel);
        bytes32 fullNode = LabelUtils.namehashUnder(TLD_NODE, LabelUtils.labelhashMemory(baseLabel));
        claimedLiteLabelhashes.push(liteLabelhash);
        claimedFullNodes.push(fullNode);
        mintedLiteTokenIds.push(uint256(LabelUtils.namehashUnder(TLD_NODE, liteLabelhash)));
        mintedLiteTokenIds.push(uint256(fullNode));
        priorLiteLabels.push(liteLabel);
    }

    /// @notice Re-registers an already-used lite label against a fresh
    ///         base-label claim so the same liteHash maps to a new fullNode.
    /// @dev Drives the resolver overwrite paths. When the handler
    ///      re-uses the same (baseLabel, actor) pair later it also exercises
    ///      the symmetric case: same fullNode mapped to a new liteHash.
    ///      `useBytes` selects the dispatch path for the register call.
    function reLink(
        uint256 actorIndex,
        uint256 baseIndex,
        uint256 liteIndex,
        bool useBytes
    )
        external
    {
        uint256 liteCount = priorLiteLabels.length;
        if (liteCount == 0) return;

        address actor = _actor(actorIndex);
        string memory baseLabel = _baseLabel(baseIndex);
        string memory liteLabel = priorLiteLabels[liteIndex % liteCount];

        IDotnsPopController.UserReservation memory reservation = CONTROLLER.userReservation(actor);
        if (reservation.labelhash == bytes32(0)) return;
        if (reservation.labelhash != keccak256(bytes(baseLabel))) return;

        IDotnsPopController.Link memory link = IDotnsPopController.Link({
            kind: IDotnsPopController.LinkKind.LiteUsername, liteLabel: liteLabel, chatKey: ""
        });
        IDotnsPopController.FullRegistration memory params =
            IDotnsPopController.FullRegistration({label: baseLabel, user: actor, link: link});
        if (!_callRegisterBaseName(params, useBytes)) return;

        bytes32 liteLabelhash = LabelUtils.labelhashMemory(liteLabel);
        bytes32 fullNode = LabelUtils.namehashUnder(TLD_NODE, LabelUtils.labelhashMemory(baseLabel));
        claimedLiteLabelhashes.push(liteLabelhash);
        claimedFullNodes.push(fullNode);
        mintedLiteTokenIds.push(uint256(fullNode));
    }

    /// @notice Caller-sovereign relinquish: drops whichever reservation the
    ///         picked actor currently holds.
    function relinquish(uint256 actorIndex) external {
        vm.prank(_actor(actorIndex));
        try CONTROLLER.relinquishReservation() {} catch {}
    }

    /// @notice Permissionless expiry: advances the head past expired entries
    ///         on a single base-label queue.
    function expire(uint256 baseIndex) external {
        try CONTROLLER.expireReservation(_baseLabel(baseIndex)) {} catch {}
    }

    /// @notice Advances `block.timestamp` to exercise expiry paths.
    /// @dev Bounded to 30 days so state does not drift off a cliff.
    function warp(uint256 secondsForward) external {
        vm.warp(block.timestamp + (secondsForward % (30 days)));
    }

    /// @notice Settles a pending claim for the picked actor.
    /// @dev The actor signs the call; `pallet-revive` charges the storage
    ///      deposit against their balance in production. Swallowed reverts
    ///      cover the no-pending-claim and lapsed-entry branches.
    function settlePendingClaim(uint256 actorIndex) external {
        address actor = _actor(actorIndex);
        vm.prank(actor);
        try CONTROLLER.claimLabelStore() {} catch {}
    }

    /// @notice Permissionlessly sweeps an expired pending claim for the picked actor.
    /// @dev Caller is the handler itself; the entrypoint is permissionless by
    ///      design so any address can clear a stale slot.
    function sweepPendingClaim(uint256 actorIndex) external {
        address actor = _actor(actorIndex);
        try CONTROLLER.expirePendingClaim(actor) {} catch {}
    }

    /// @notice Calls `reserveBaseName` through the typed or bytes overload.
    /// @dev Returns true on success and false on revert so the caller's
    ///      bookkeeping (ghost arrays) stays consistent with on-chain state
    ///      regardless of dispatch path.
    /// @return ok Whether the underlying call succeeded.
    function _callReserveBaseName(
        IDotnsPopController.BaseReservation memory params,
        bool useBytes
    )
        internal
        returns (bool ok)
    {
        _mockCallerIsRoot(true);
        if (useBytes) {
            try CONTROLLER.reserveBaseName(abi.encode(params)) {
                return true;
            } catch {
                return false;
            }
        }
        try CONTROLLER.reserveBaseName(params) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Mirror of `_callReserveBaseName` for the `registerBaseName`
    ///         overloads.
    /// @return ok Whether the underlying call succeeded.
    function _callRegisterBaseName(
        IDotnsPopController.FullRegistration memory params,
        bool useBytes
    )
        internal
        returns (bool ok)
    {
        _mockCallerIsRoot(true);
        if (useBytes) {
            try CONTROLLER.registerBaseName(abi.encode(params)) {
                return true;
            } catch {
                return false;
            }
        }
        try CONTROLLER.registerBaseName(params) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Mocks the revive `callerIsRoot()` query to return `returnValue`.
    function _mockCallerIsRoot(bool returnValue) internal {
        vm.mockCall(
            DotnsConstants.REVIVE_SYSTEM,
            abi.encodeWithSelector(ISystem.callerIsRoot.selector),
            abi.encode(returnValue)
        );
    }

    /// @notice Builds a classification-valid PoP lite label.
    /// @dev Shape: `<tag><4 letters from actor><2 digits>`. Total baselength
    ///      is 7 with exactly 2 trailing digits, which classifies as PopLite
    ///      under PopRules. Tag disambiguates the reserve vs claim call sites
    ///      so neither collides with the other in the ERC721 namespace. The
    ///      letter block is derived from the actor address via keccak so each
    ///      actor lives in its own lite namespace. Suffix wraps modulo 100 so
    ///      the label stays within the 2-trailing-digit rule; collisions past
    ///      100 reuses are swallowed by the caller's try/catch.
    function _buildLiteLabel(
        string memory tag,
        address actor,
        uint64 suffix
    )
        internal
        pure
        returns (string memory label)
    {
        bytes32 seed = keccak256(abi.encode(actor));
        bytes memory letters = new bytes(4);
        for (uint256 i = 0; i < 4; i++) {
            // Map each byte to lowercase a-z.
            letters[i] = bytes1((uint8(seed[i]) % 26) + 0x61);
        }
        uint256 twoDigit = uint256(suffix) % 100;
        string memory digits =
            twoDigit < 10 ? string.concat("0", vm.toString(twoDigit)) : vm.toString(twoDigit);
        label = string.concat(tag, string(letters), digits);
    }

    /// @notice Selects an actor from the pool with wrap-around indexing.
    function _actor(uint256 index) internal view returns (address) {
        return actors[index % actors.length];
    }

    /// @notice Selects a base label from the fixed set with wrap-around indexing.
    function _baseLabel(uint256 index) internal view returns (string memory) {
        return baseLabels[index % baseLabels.length];
    }

    /// @notice Records `labelhash` as a seen reservation queue, deduplicated.
    function _track(bytes32 labelhash) internal {
        if (!_tracked[labelhash]) {
            _tracked[labelhash] = true;
            reservedLabelsSeen.push(labelhash);
        }
    }

    /// @notice Records `actor` as an account the handler has stashed for,
    ///         deduplicated. Iterated by the pending-claim mirror invariants.
    function _trackPendingActor(address actor) internal {
        if (!_pendingActorTracked[actor]) {
            _pendingActorTracked[actor] = true;
            pendingClaimActorsSeen.push(actor);
        }
    }
}
