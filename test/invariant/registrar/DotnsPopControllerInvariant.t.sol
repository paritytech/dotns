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

        handler = new PopControllerHandler(
            dotnsPopController,
            dotnsRegistrarController,
            dotnsRegistrar,
            popRules,
            dotnsRegistry,
            handlerActors,
            protocolRegistry.tldNode()
        );
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.reserve.selector;
        selectors[1] = handler.relinquish.selector;
        selectors[2] = handler.expire.selector;
        selectors[3] = handler.warp.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.reLink.selector;
        selectors[6] = handler.settlePendingClaim.selector;
        selectors[7] = handler.settlePendingClaimByThirdParty.selector;
        selectors[8] = handler.publicRegister.selector;
        selectors[9] = handler.attemptTransfer.selector;
        selectors[10] = handler.createSubname.selector;
        selectors[11] = handler.createRivalSubname.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        _seedCoverage();
    }

    /// @notice Drives the actions whose results the coverage assertions read.
    /// @dev Each invariant here iterates a handler list, so a list the campaign never fills
    ///      makes its assertions pass without reading any state. Seeding from `setUp` puts the
    ///      first entry of each such list into the snapshot every run starts from, which makes
    ///      the coverage assertions in @custom:function afterInvariant deterministic rather
    ///      than a bet on the fuzzer's selector order. The other actions (relinquish, expiry,
    ///      warp, relink and the two settlement paths) fill no list of their own and are left
    ///      to the campaign.
    function _seedCoverage() internal {
        // A reserve, then a claim on the same base label, so a lite name and a full-person name
        // both exist and the actor's store is settled.
        handler.reserve(0, 0, true);
        handler.claim(0, 0);

        // An odd base index takes a label of the public path's own, which the gateway cannot
        // have claimed; the transfer then picks the public token that registration minted.
        handler.publicRegister(1, 1);
        handler.attemptTransfer(handler.mintedLiteTokenCount(), 0);

        handler.createRivalSubname(0, 0);

        // Sub-labels come from a seed and most are not valid DNS labels, so walk seeds until
        // one is accepted under a full-person parent.
        for (uint256 seed; seed < 64 && handler.subnodeCreatedCount() == 0; ++seed) {
            handler.createSubname(seed, seed, seed);
        }
    }

    /// @notice Fails the run if any action the invariants read from never happened.
    /// @dev The counterpart to `_seedCoverage`: it catches a seed that stops working, which
    ///      would otherwise leave the assertions above iterating empty lists and passing.
    function afterInvariant() public view {
        assertGt(handler.gatewayLabelCount(), 0, "campaign issued no gateway name");
        assertGt(handler.publicLabelCount(), 0, "campaign took no label publicly");
        assertGt(handler.transferSuccessCount(), 0, "campaign moved no name");
        assertGt(handler.subnodeCreatedCount(), 0, "campaign created no subname");
        assertGt(handler.rivalSubnodeCount(), 0, "campaign built no rival hierarchy");
    }

    /// @notice The two readings of a lite name's text stay distinct, and the text-keyed signal
    ///         answers for the whole-label one.
    /// @dev `michael.01` is one label to the gateway and `michael` under `01` to the registry,
    ///      and both render as the same text. `isPopIssued` is keyed by that text, so a true
    ///      answer proves the whole-label reading was issued and says nothing about the rival
    ///      standing beside it: the two coexist here, which is exactly why the node is what
    ///      names the object. The first assertion pins that the nodes never converge; the
    ///      soulbound flag is node-keyed, so it does discriminate between them, and is asserted
    ///      in both directions.
    function invariant_rival_hierarchy_never_passes_for_a_person() public view {
        uint256 n = handler.rivalSubnodeCount();
        for (uint256 i = 0; i < n; i++) {
            string memory text = handler.rivalTexts(i);
            bytes32 rival = handler.rivalSubnodes(i);
            bytes32 person = _nodeOf(text);

            assertTrue(rival != person, "rival hierarchy reached the person's node");
            assertTrue(dotnsPopController.isPopIssued(text), "person lost their provenance");
            assertTrue(dotnsRegistrar.isSoulbound(uint256(person)), "person's name is unlocked");
            assertFalse(dotnsRegistrar.isSoulbound(uint256(rival)), "rival reads as gateway-minted");
        }
    }

    /// @notice A subname never lands on a name the gateway issued.
    /// @dev The two readings of `joseph.42`, one whole label or `joseph` beneath `42`, are what
    ///      the separated form has to keep apart. The registry derives a parent's node by
    ///      splitting the path on the separator, so a lite name's own node is unreachable as a
    ///      parent and no subname can be created under one at all; the second assertion pins
    ///      that, and the first pins that no subnode collides with an issued name either way.
    function invariant_subnames_never_reach_a_gateway_node() public view {
        uint256 subnodeCount = handler.subnodeCreatedCount();
        uint256 gatewayCount = handler.gatewayLabelCount();

        for (uint256 i = 0; i < subnodeCount; i++) {
            bytes32 subnode = handler.subnodesCreated(i);
            for (uint256 j = 0; j < gatewayCount; j++) {
                assertTrue(
                    subnode != _nodeOf(handler.gatewayLabelsSeen(j)),
                    "subnode collided with a gateway name"
                );
            }
            assertFalse(
                _carriesSeparator(handler.subnameParents(i)), "subname created under a lite name"
            );
        }
    }

    /// @notice Whether `value` carries the label separator.
    function _carriesSeparator(string memory value) internal pure returns (bool carries) {
        bytes memory raw = bytes(value);
        for (uint256 i = 0; i < raw.length; i++) {
            if (raw[i] == bytes1(0x2e)) return true;
        }
        return false;
    }

    /// @notice A label the gateway issued keeps answering `isPopIssued`.
    /// @dev The answer is a person's only proof that the whole-label reading of their name was
    ///      issued. A cleared entry does not create a subname, it removes that proof, leaving
    ///      `joseph.42` indistinguishable from text a hierarchy could also produce. Nothing in
    ///      the contract writes false, and the campaign moves names and settles claims
    ///      underneath it, which is where a clear would come from if one existed.
    function invariant_popIssued_is_never_cleared() public view {
        uint256 n = handler.gatewayLabelCount();
        for (uint256 i = 0; i < n; i++) {
            string memory label = handler.gatewayLabelsSeen(i);
            assertTrue(dotnsPopController.isPopIssued(label), "gateway provenance cleared");
        }
    }

    /// @notice No label carries both provenances, and soulbound agrees with `isPopIssued`.
    /// @dev First to mint holds the name: the loser reverts on the registrar's availability
    ///      check, so a label cannot be both gateway-issued and publicly registered. The second
    ///      half pins the two signals together, because a public name reading as gateway-issued
    ///      is the impersonation this provenance flag exists to prevent.
    function invariant_gateway_and_public_provenance_are_disjoint() public view {
        uint256 publicCount = handler.publicLabelCount();
        for (uint256 i = 0; i < publicCount; i++) {
            string memory label = handler.publicLabelsRegistered(i);
            assertFalse(dotnsPopController.isPopIssued(label), "public label reads as gateway");
            assertFalse(dotnsRegistrar.isSoulbound(uint256(_nodeOf(label))), "public name locked");
        }

        uint256 gatewayCount = handler.gatewayLabelCount();
        for (uint256 i = 0; i < gatewayCount; i++) {
            string memory label = handler.gatewayLabelsSeen(i);
            assertFalse(handler.isPublicLabel(label), "gateway label taken publicly");
            assertTrue(dotnsRegistrar.isSoulbound(uint256(_nodeOf(label))), "gateway name free");
        }
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
                continue;
            }

            // Zero direction. Only a head transition releases the slot, so a slot that outlives
            // its queue reads as free to nobody and blocks the label for everybody, and the
            // equality check above never sees it. Restricted to an empty queue: a queue still
            // holding entries can legitimately have no live head, because expiry alone releases
            // nothing until someone calls `expireReservation`.
            if (head >= tail) {
                (bool slotLive,,) = popRules.isBaseNameReserved(baseLabel);
                assertFalse(slotLive, "PopRules slot outlived an empty queue");
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

    /// @notice `pendingClaimUsers()` membership mirrors the set of users with a
    ///         non-empty pending-claim queue exactly. Every actor with a queued
    ///         entry appears in the enumeration, and every entry in the
    ///         enumeration has a non-empty queue and is one of the actors the
    ///         handler has stashed for.
    function invariant_pendingClaimUsers_mirrors_pendingClaims_mapping() public view {
        uint256 enumCount = dotnsPopController.pendingClaimUserCount();
        address[] memory enumerated = dotnsPopController.pendingClaimUsers(0, enumCount);
        assertEq(enumerated.length, enumCount, "pendingClaimUsers length mismatch");

        for (uint256 i = 0; i < enumerated.length; i++) {
            assertGt(
                dotnsPopController.pendingClaimCountOf(enumerated[i]),
                0,
                "enumerated user has no pending claim"
            );
        }

        uint256 seen = handler.pendingClaimActorsSeenCount();
        for (uint256 i = 0; i < seen; i++) {
            address actor = handler.pendingClaimActorsSeen(i);
            if (dotnsPopController.pendingClaimCountOf(actor) == 0) continue;
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
    ///         pending claim: every settlement in this suite drains the whole
    ///         queue and deploys the store in the same call, and a warm user's
    ///         later gateway mints write straight into the store without stashing.
    function invariant_pending_claim_and_label_store_are_mutually_exclusive() public view {
        IStoreFactory factory = IStoreFactory(address(storeFactory));
        uint256 seen = handler.pendingClaimActorsSeenCount();
        for (uint256 i = 0; i < seen; i++) {
            address actor = handler.pendingClaimActorsSeen(i);
            if (factory.getLabelStore(actor) == address(0)) continue;
            assertEq(
                dotnsPopController.pendingClaimCountOf(actor),
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

    /// @notice Settlement writes labels and never strands a minted name. Every
    ///         minted token is either settled, with its label readable in the
    ///         owner's store, or still staged in the owner's pending queue.
    ///         Age never drops an entry, so a minted name is never left in
    ///         neither place.
    /// @dev The stranded case the old model allowed, a lapsed entry swept out of
    ///      the queue with nothing written, is now unreachable: settlement always
    ///      writes the label regardless of the reservation deadline.
    function invariant_settled_names_written_and_never_stranded() public view {
        uint256 n = handler.mintedLiteTokenCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = handler.mintedLiteTokenIds(i);
            if (!dotnsRegistrar.exists(tokenId)) continue;

            // A settled name reads its label back from the owner's store.
            if (bytes(dotnsRegistrar.labelOf(tokenId)).length != 0) continue;

            // Otherwise the name must still be staged in its owner's pending queue.
            address nameOwner = dotnsRegistrar.ownerOf(tokenId);
            IDotnsPopController.PendingClaim[] memory pending =
                dotnsPopController.pendingClaims(nameOwner, 0, type(uint256).max);
            bool staged;
            for (uint256 j = 0; j < pending.length; j++) {
                if (_nodeOf(pending[j].label) == bytes32(tokenId)) {
                    staged = true;
                    break;
                }
            }
            assertTrue(staged, "minted name neither settled nor staged");
        }
    }
}
