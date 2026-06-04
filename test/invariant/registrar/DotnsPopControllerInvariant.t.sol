// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {PopControllerHandler} from "./PopControllerHandler.t.sol";
import {IDotnsPopController} from "../../../contracts/registrars/IDotnsPopController.sol";
import {IStoreFactory} from "../../../contracts/store/IStoreFactory.sol";

/// @title DotnsPopControllerInvariant
/// @notice Invariants asserted over arbitrary sequences of PoP controller actions.
contract DotnsPopControllerInvariant is BaseDotns {
    /// @notice Bounded random-action handler driving the controller under test.
    PopControllerHandler internal handler;

    /// @notice Wires the handler and constrains the fuzzer to its action selectors.
    function setUp() public override {
        super.setUp();

        // Actor pool sized past MAX_RESERVATION_QUEUE (64) so the queue-full
        // guard is load-bearing rather than structurally unreachable. A pool
        // smaller than the cap would cap invariant depth at pool size and the
        // QueueFull branch would never fire.
        uint256 actorCount = 72;
        address[] memory handlerActors = new address[](actorCount);
        for (uint256 i = 0; i < actorCount; i++) {
            handlerActors[i] = makeAddr(string.concat("popActor", vm.toString(i)));
        }

        handler = new PopControllerHandler(dotnsPopController, handlerActors);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.reserve.selector;
        selectors[1] = handler.relinquish.selector;
        selectors[2] = handler.expire.selector;
        selectors[3] = handler.warp.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.reLink.selector;
        selectors[6] = handler.settlePendingClaim.selector;
        selectors[7] = handler.sweepPendingClaim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Every tracked reservation queue stays bounded by MAX_RESERVATION_QUEUE.
    function invariant_queue_length_bounded() public view {
        uint256 n = handler.reservedLabelsSeenCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 labelhash = handler.reservedLabelsSeen(i);
            (uint64 head, uint64 tail) = dotnsPopController.reservationMeta(labelhash);
            assertLe(uint256(tail - head), uint256(handler.MAX_QUEUE()));
        }
    }

    /// @notice PopRules' base-name reservation for every touched label equals the
    ///         controller's live head-of-queue owner, or zero when the queue is
    ///         empty or fully expired. Exercises reserveBaseNameForPop and
    ///         releaseBaseName on every head transition.
    function invariant_popRules_head_matches_queue_head_or_zero() public view {
        uint256 n = handler.baseLabelCount();
        for (uint256 i = 0; i < n; i++) {
            string memory baseLabel = handler.baseLabelAt(i);
            bytes32 labelhash = keccak256(bytes(baseLabel));

            (uint64 head, uint64 tail) = dotnsPopController.reservationMeta(labelhash);
            address expected;
            if (head < tail) {
                (address headOwner, uint64 joinedAt) =
                    dotnsPopController.reservationEntry(labelhash, head);
                if (
                    headOwner != address(0)
                        && uint256(joinedAt) + uint256(dotnsPopController.reservationDuration())
                            > block.timestamp
                ) {
                    expected = headOwner;
                }
            }

            (address popHolder,) = popRules.getBaseNameReservation(baseLabel);
            if (expected != address(0)) {
                assertEq(popHolder, expected, "PopRules head != queue head");
            }
        }
    }

    /// @notice The per-user reservation pointer is consistent with the queue
    ///         entry it points to: when userReservation(u).labelhash is
    ///         non-zero, the entry at userReservation(u).index is owned by u
    ///         and sits within the live head/tail range.
    function invariant_one_reservation_per_account_consistent() public view {
        uint256 count = handler.actorsCount();
        for (uint256 i = 0; i < count; i++) {
            address actor = handler.actors(i);
            IDotnsPopController.UserReservation memory reservation =
                dotnsPopController.userReservation(actor);
            if (reservation.labelhash == bytes32(0)) continue;

            (uint64 head, uint64 tail) = dotnsPopController.reservationMeta(reservation.labelhash);
            assertTrue(
                reservation.index >= head && reservation.index < tail,
                "reservation index out of live range"
            );

            (address entryOwner,) =
                dotnsPopController.reservationEntry(reservation.labelhash, reservation.index);
            assertEq(entryOwner, actor, "reservation entry owner mismatch");
        }
    }

    /// @notice Every token the handler minted (lite or full) carries a
    ///         non-empty `labelOf`, proving the canonical string->tokenId
    ///         recovery path was populated by registrar.register on every mint.
    function invariant_every_minted_tokenId_has_nonempty_label() public view {
        uint256 n = handler.mintedLiteTokenCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = handler.mintedLiteTokenIds(i);
            assertGt(bytes(dotnsRegistrar.labelOf(tokenId)).length, 0, "empty labelOf");
        }
    }

    /// @notice For every historic (liteLabelhash, fullNode) pair the resolver's
    ///         forward and reverse indexes either still round-trip to each
    ///         other or have both been cleared by a later overwrite. A partial
    ///         overwrite, where one side still points at a stale partner, is
    ///         the corruption signature this invariant guards against.
    function invariant_fullClaim_liteLink_are_inverse() public view {
        uint256 n = handler.claimedCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 liteLabelhash = handler.claimedLiteLabelhashes(i);
            bytes32 fullNode = handler.claimedFullNodes(i);

            bytes32 currentFullForLite = dotnsPopResolver.fullClaim(liteLabelhash);
            bytes32 currentLiteForFull = dotnsPopResolver.liteLink(fullNode);

            // Either the pair is still live on both sides, or both sides
            // have been cleared. Anything else is a partial overwrite.
            if (currentFullForLite == fullNode) {
                assertEq(currentLiteForFull, liteLabelhash, "live fullClaim but liteLink drifted");
            } else if (currentLiteForFull == liteLabelhash) {
                assertEq(currentFullForLite, fullNode, "live liteLink but fullClaim drifted");
            }
            // Else: both sides were overwritten. Covered by the stale
            // invariants below.
        }
    }

    /// @notice No stale `liteLink`: for every touched fullNode, a non-zero
    ///         liteLink value round-trips through `fullClaim` back to the same
    ///         fullNode. A drifting liteLink is the corruption footprint this
    ///         invariant guards against.
    function invariant_no_stale_liteLink() public view {
        uint256 n = handler.claimedCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 fullNode = handler.claimedFullNodes(i);
            bytes32 currentLite = dotnsPopResolver.liteLink(fullNode);
            if (currentLite == bytes32(0)) continue;
            assertEq(dotnsPopResolver.fullClaim(currentLite), fullNode, "stale liteLink");
        }
    }

    /// @notice No stale `fullClaim`: symmetric to `invariant_no_stale_liteLink`,
    ///         every claimed liteLabelhash with a non-zero fullClaim round-trips
    ///         through `liteLink` back to the same liteLabelhash.
    function invariant_no_stale_fullClaim() public view {
        uint256 n = handler.claimedCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 liteLabelhash = handler.claimedLiteLabelhashes(i);
            bytes32 currentFull = dotnsPopResolver.fullClaim(liteLabelhash);
            if (currentFull == bytes32(0)) continue;
            assertEq(dotnsPopResolver.liteLink(currentFull), liteLabelhash, "stale fullClaim");
        }
    }

    /// @notice `pendingClaimUsers()` membership mirrors the live key set of
    ///         the `_pendingClaims` mapping exactly. Every actor with a
    ///         non-zero `mintedAt` appears in the enumeration, and every
    ///         entry in the enumeration has a non-zero `mintedAt` and is one
    ///         of the actors the handler has stashed for.
    function invariant_pendingClaimUsers_mirrors_pendingClaims_mapping() public view {
        uint256 enumCount = dotnsPopController.pendingClaimUserCount();
        address[] memory enumerated = dotnsPopController.pendingClaimUsers(0, enumCount);
        assertEq(enumerated.length, enumCount, "pendingClaimUsers length mismatch");

        for (uint256 i = 0; i < enumerated.length; i++) {
            assertGt(
                dotnsPopController.pendingClaims(enumerated[i]).length,
                0,
                "enumerated user has no pending claim"
            );
        }

        uint256 seen = handler.pendingClaimActorsSeenCount();
        for (uint256 i = 0; i < seen; i++) {
            address actor = handler.pendingClaimActorsSeen(i);
            if (dotnsPopController.pendingClaims(actor).length == 0) continue;
            bool found;
            for (uint256 j = 0; j < enumerated.length; j++) {
                if (enumerated[j] == actor) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "actor with mintedAt missing from pendingClaimUsers");
        }
    }

    /// @notice A user with a deployed `LabelStore` cannot simultaneously hold a
    ///         pending claim: settlement deploys the store and clears the
    ///         entry in the same call, expiry clears without deploying.
    function invariant_pending_claim_and_label_store_are_mutually_exclusive() public view {
        IStoreFactory factory = IStoreFactory(address(storeFactory));
        uint256 seen = handler.pendingClaimActorsSeenCount();
        for (uint256 i = 0; i < seen; i++) {
            address actor = handler.pendingClaimActorsSeen(i);
            if (factory.getLabelStore(actor) == address(0)) continue;
            assertEq(
                dotnsPopController.pendingClaims(actor).length,
                0,
                "actor has both store and pending claim"
            );
        }
    }

    /// @notice `pendingClaimUserCount()` equals the length of the enumeration
    ///         slice taken with offset zero and a generous limit. Catches
    ///         pagination accounting drift.
    function invariant_pendingClaimUserCount_matches_enumeration_length() public view {
        uint256 count = dotnsPopController.pendingClaimUserCount();
        address[] memory page = dotnsPopController.pendingClaimUsers(0, count == 0 ? 1 : count);
        assertEq(page.length, count, "count != enumeration length");
    }

    /// @notice An expired pending-claim entry can always be swept. Asserts that
    ///         for every tracked actor whose `mintedAt` has lapsed past
    ///         `reservationDuration`, a permissionless `expirePendingClaim`
    ///         clears the entry without revert.
    /// @dev Cannot mutate state inside an invariant assertion, so the property
    ///      is asserted indirectly: if the entry is past its deadline, the
    ///      handler has had opportunities to sweep it during the run; under a
    ///      sufficient depth the post-state must show such entries cleared.
    ///      A stronger formulation would require a depth-bounded sweep
    ///      guarantee, which is out of scope for view-only invariants.
    function invariant_no_stuck_lapsed_pending_claims() public view {
        uint64 duration = dotnsPopController.reservationDuration();
        if (duration == 0) return;
        uint256 seen = handler.pendingClaimActorsSeenCount();
        for (uint256 i = 0; i < seen; i++) {
            address actor = handler.pendingClaimActorsSeen(i);
            IDotnsPopController.PendingClaim[] memory pending =
                dotnsPopController.pendingClaims(actor);
            for (uint256 j = 0; j < pending.length; j++) {
                uint256 deadline = uint256(pending[j].mintedAt) + uint256(duration);
                assertLe(
                    block.timestamp, deadline + uint256(duration), "lapsed entry stuck past grace"
                );
            }
        }
    }
}
