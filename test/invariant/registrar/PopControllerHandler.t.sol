// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {
    DotnsPopController,
    IDotnsPopController
} from "../../../contracts/registrars/DotnsPopController.sol";
import {PopRules, IPopRules} from "../../../contracts/pop/PopRules.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {LabelUtils} from "../../../contracts/utils/LabelUtils.sol";
import {ISystem} from "../../../contracts/external/revive/ISystem.sol";

// @title PopControllerHandler
// @notice Bounded random-action handler for {DotnsPopController} invariant tests.
// @dev Cycles through an actor set and a fixed base-label set so the fuzzer
//      explores combinations deterministically. Tracks every labelhash that has
//      hosted a reservation, every minted lite token, and every successful
//      claim so invariants can iterate over just what exists.
contract PopControllerHandler is Test {
    using stdStorage for StdStorage;

    StdStorage internal stdstorage;

    DotnsPopController public immutable CONTROLLER;
    uint16 public constant MAX_QUEUE = 64;

    address[] public actors;
    string[] public baseLabels;
    bytes32[] public reservedLabelsSeen;
    mapping(bytes32 labelhash => bool) internal _tracked;
    mapping(address actor => uint64 suffix) internal _liteSuffix;

    // Lite tokens minted through the handler. Every successful `reserve` push.
    // Used by the labelOf-non-empty invariant to enumerate the token space
    // without scanning the full uint256 id range.
    uint256[] public mintedLiteTokenIds;

    // Full nodes minted through successful claims, captured alongside the lite
    // labelhash they were linked against. Used by the fullClaim/liteLink
    // inverse invariant: for each entry, fullClaim(liteHash) == node.
    bytes32[] public claimedFullNodes;
    bytes32[] public claimedLiteLabelhashes;

    // Prior lite labels reserved by the handler. Used by reLink actions so
    // the fuzzer can re-use an existing lite label against a fresh base
    // claim, driving the resolver overwrite paths (M-03). Kept as the raw
    // string because the controller re-hashes internally on every call.
    string[] public priorLiteLabels;

    constructor(DotnsPopController controller_, address[] memory actors_, PopRules popRules_) {
        CONTROLLER = controller_;
        actors = actors_;
        // baselength 8, no trailing digits: PopFull classification.
        baseLabels.push("alicebob");
        // baselength 10, 2 trailing digits: NoStatus classification.
        baseLabels.push("wonderland01");
        // baselength 10, no trailing digits: PopFull classification.
        baseLabels.push("carolcarol");

        // Every actor needs PopFull status on the PoP rules oracle so the
        // classification/tier guard in PopRules.priceWithCheck admits every
        // label the handler can generate: PopLite lite labels (PopFull is a
        // superset of PopLite), PopFull base labels, and NoStatus base labels
        // (which merely require userStatus != PopLite).
        for (uint256 i = 0; i < actors_.length; i++) {
            stdstorage.target(address(popRules_)).sig("userPopStatus(address)").with_key(actors_[i])
                .checked_write(uint256(IPopRules.PopStatus.PopFull));
        }
    }

    function actorsCount() external view returns (uint256) {
        return actors.length;
    }

    function reservedLabelsSeenCount() external view returns (uint256) {
        return reservedLabelsSeen.length;
    }

    function baseLabelCount() external view returns (uint256) {
        return baseLabels.length;
    }

    function baseLabelAt(uint256 index) external view returns (string memory) {
        return baseLabels[index];
    }

    function mintedLiteTokenCount() external view returns (uint256) {
        return mintedLiteTokenIds.length;
    }

    function claimedCount() external view returns (uint256) {
        return claimedFullNodes.length;
    }

    function priorLiteLabelCount() external view returns (uint256) {
        return priorLiteLabels.length;
    }

    function reserve(
        uint256 actorIndex,
        uint256 baseIndex,
        bool attachReservation,
        bool useBytes
    )
        external
    {
        // Reserves a lite label for an actor, optionally enqueuing on a base
        // label. Swallows known-good reverts (QueueFull, AlreadyReserved,
        // ERC721 collision) so the runner keeps exploring. `useBytes` chooses
        // between the typed and bytes overloads so existing invariants run
        // against mixed dispatch paths; the only thing the dispatch path
        // should change is the call shape, not the resulting state.
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
            bytes32 node = LabelUtils.namehashUnder(
                DotnsConstants.DOT_NODE, LabelUtils.labelhashMemory(liteLabel)
            );
            mintedLiteTokenIds.push(uint256(node));
            priorLiteLabels.push(liteLabel);
        }
    }

    function claim(uint256 actorIndex, uint256 baseIndex, bool useBytes) external {
        // Drives the claim path end-to-end when the actor happens to hold the
        // live head of the queue for the picked base label. Missing preconditions
        // (wrong actor, expired head, empty queue) surface as a revert and are
        // swallowed so the runner keeps exploring. `useBytes` selects the
        // dispatch path for both the lite leg and the full register leg.
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

        IDotnsPopController.Link memory link = IDotnsPopController.Link({
            kind: IDotnsPopController.LinkKind.LiteUsername, liteLabel: liteLabel, chatKey: ""
        });
        IDotnsPopController.FullRegistration memory fullParams =
            IDotnsPopController.FullRegistration({label: baseLabel, user: actor, link: link});
        if (!_callRegisterBaseName(fullParams, useBytes)) return;

        bytes32 liteLabelhash = LabelUtils.labelhashMemory(liteLabel);
        bytes32 fullNode = LabelUtils.namehashUnder(
            DotnsConstants.DOT_NODE, LabelUtils.labelhashMemory(baseLabel)
        );
        claimedLiteLabelhashes.push(liteLabelhash);
        claimedFullNodes.push(fullNode);
        mintedLiteTokenIds.push(
            uint256(LabelUtils.namehashUnder(DotnsConstants.DOT_NODE, liteLabelhash))
        );
        mintedLiteTokenIds.push(uint256(fullNode));
        priorLiteLabels.push(liteLabel);
    }

    function reLink(
        uint256 actorIndex,
        uint256 baseIndex,
        uint256 liteIndex,
        bool useBytes
    )
        external
    {
        // Drives the resolver overwrite paths (M-03). Picks an already-used
        // lite label and re-registers it against a fresh base-label claim,
        // so the same liteHash ends up mapped to a new fullNode. When the
        // handler re-uses the same (baseLabel, actor) pair later, we also
        // exercise the symmetric case: same fullNode mapped to a new
        // liteHash. `useBytes` selects the dispatch path for the register
        // call.
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
        bytes32 fullNode = LabelUtils.namehashUnder(
            DotnsConstants.DOT_NODE, LabelUtils.labelhashMemory(baseLabel)
        );
        claimedLiteLabelhashes.push(liteLabelhash);
        claimedFullNodes.push(fullNode);
        mintedLiteTokenIds.push(uint256(fullNode));
    }

    function relinquish(uint256 actorIndex) external {
        // Caller-sovereign: drops whichever reservation the actor holds.
        vm.prank(_actor(actorIndex));
        try CONTROLLER.relinquishReservation() {} catch {}
    }

    function expire(uint256 baseIndex) external {
        // Permissionless: advances the head past expired entries on one queue.
        try CONTROLLER.expireReservation(_baseLabel(baseIndex)) {} catch {}
    }

    function warp(uint256 secondsForward) external {
        // Exercises expiry paths. Bounded so state doesn't drift off a cliff.
        vm.warp(block.timestamp + (secondsForward % (30 days)));
    }

    function _callReserveBaseName(
        IDotnsPopController.BaseReservation memory params,
        bool useBytes
    )
        internal
        returns (bool ok)
    {
        // Routes through the typed or bytes overload depending on `useBytes`. Returns
        // true on success, false on revert so the caller's bookkeeping (ghost arrays)
        // stays consistent with on-chain state regardless of dispatch path.
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

    function _callRegisterBaseName(
        IDotnsPopController.FullRegistration memory params,
        bool useBytes
    )
        internal
        returns (bool ok)
    {
        // Mirror of `_callReserveBaseName` for the `registerBaseName` overloads.
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

    function _mockCallerIsRoot(bool returnValue) internal {
        vm.mockCall(
            DotnsConstants.REVIVE_SYSTEM,
            abi.encodeWithSelector(ISystem.callerIsRoot.selector),
            abi.encode(returnValue)
        );
    }

    // @notice Builds a classification-valid PoP lite label.
    // @dev Shape: `<tag><4 letters from actor><2 digits>`. Total baselength
    //      is 7 with exactly 2 trailing digits, which classifies as PopLite
    //      under PopRules. Tag disambiguates the reserve vs claim call sites
    //      so neither collides with the other in the ERC721 namespace. The
    //      letter block is derived from the actor address via keccak so each
    //      actor lives in its own lite namespace. Suffix wraps modulo 100 so
    //      the label stays within the 2-trailing-digit rule; collisions past
    //      100 reuses are swallowed by the caller's try/catch.
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
            letters[i] = bytes1(uint8(seed[i]) % 26 + 0x61);
        }
        uint256 twoDigit = uint256(suffix) % 100;
        string memory digits =
            twoDigit < 10 ? string.concat("0", vm.toString(twoDigit)) : vm.toString(twoDigit);
        label = string.concat(tag, string(letters), digits);
    }

    function _actor(uint256 index) internal view returns (address) {
        return actors[index % actors.length];
    }

    function _baseLabel(uint256 index) internal view returns (string memory) {
        return baseLabels[index % baseLabels.length];
    }

    function _track(bytes32 labelhash) internal {
        if (!_tracked[labelhash]) {
            _tracked[labelhash] = true;
            reservedLabelsSeen.push(labelhash);
        }
    }
}
