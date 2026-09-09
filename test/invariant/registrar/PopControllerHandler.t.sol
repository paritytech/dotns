// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {
    DotnsPopController,
    IDotnsPopController
} from "../../../contracts/registrars/DotnsPopController.sol";
import {
    DotnsRegistrarController,
    IDotnsRegistrarController
} from "../../../contracts/registrars/DotnsRegistrarController.sol";
import {DotnsRegistrar} from "../../../contracts/registrars/DotnsRegistrar.sol";
import {IDotnsRegistry} from "../../../contracts/registry/IDotnsRegistry.sol";
import {StringUtils} from "../../../contracts/utils/StringUtils.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
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
    /// @notice The public commit-reveal controller, the gateway's rival for a free label.
    DotnsRegistrarController public immutable PUBLIC_CONTROLLER;
    /// @notice The ERC-721 registrar both controllers mint through.
    DotnsRegistrar public immutable REGISTRAR;
    /// @notice Pricing and classification, read to quote a public registration.
    IPopRules public immutable POP_RULES;
    /// @notice The hierarchical registry, where a subname is the rival reading of a dotted text.
    IDotnsRegistry public immutable REGISTRY;
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

    /// @notice Every label the gateway has issued, deduplicated.
    /// @dev Provenance is written once at mint, so this set only grows. The monotonicity
    ///      invariant reads it back to catch a `_popIssued` entry that stopped answering.
    string[] public gatewayLabelsSeen;
    mapping(string label => bool seen) internal _gatewayLabelTracked;

    /// @notice Every label a public registration took, deduplicated.
    string[] public publicLabelsRegistered;
    mapping(string label => bool taken) public isPublicLabel;

    /// @notice Accounts driving the public path, disjoint from `actors`.
    /// @dev A public registration deploys the registrant's `LabelStore`, which would put a
    ///      gateway actor mid-queue into a state the store-exclusivity invariant reads as
    ///      corruption even though the claim stays settleable. Contention is over labels, not
    ///      accounts, so a separate pool exercises the race without weakening that invariant.
    address[] public publicActors;

    /// @notice Subnodes the registry created under a gateway-issued parent.
    bytes32[] public subnodesCreated;
    /// @notice Parent label that accepted each subnode (same index).
    string[] public subnameParents;
    /// @notice Count of subname attempts the registry rejected.
    uint256 public subnameRejectedCount;

    /// @notice Subnodes built as the rival reading of a lite name: its stem under its suffix.
    /// @dev `michael.01` is one label to the gateway and `michael` beneath `01` here. Both
    ///      display as the same text, so this is the shape a subname holder would use to pass
    ///      for a person.
    bytes32[] public rivalSubnodes;
    /// @notice The lite label each rival subnode displays as (same index).
    string[] public rivalTexts;
    /// @notice Count of rival-hierarchy attempts the registry rejected.
    uint256 public rivalRejectedCount;

    /// @notice Nodes minted through the public path, for the transfer action to move.
    uint256[] public publicTokenIds;

    /// @notice Count of public registrations that beat the gateway to a label.
    uint256 public publicRegisterCount;
    /// @notice Monotonic counter feeding the public path's own label names.
    uint256 public publicLabelNonce;
    /// @notice Count of transfer attempts against a tracked token.
    uint256 public transferAttemptCount;
    /// @notice Count of transfers that moved a name, all of them public: a gateway name is
    ///         soulbound, so its attempt always reverts.
    uint256 public transferSuccessCount;

    /// @notice Every actor that has ever held a pending claim, deduplicated.
    /// @dev The mirror invariant iterates this set to assert that any address
    ///      with a live `mintedAt` appears in `pendingClaimUsers()` and vice
    ///      versa.
    address[] public pendingClaimActorsSeen;
    mapping(address actor => bool) internal _pendingActorTracked;

    /// @notice Seeds the actor pool, base-label set, and personhood mocks so
    ///         every action call admits both lite and base classifications.
    /// @param controller_ The PoP controller under test.
    /// @param publicController_ The public commit-reveal controller.
    /// @param registrar_ The ERC-721 registrar both controllers mint through.
    /// @param popRules_ Pricing and classification.
    /// @param registry_ The hierarchical registry.
    /// @param actors_ Pool of accounts the handler cycles through.
    /// @param tldNode_ Node hash of the suite's TLD, from the deployed protocol registry.
    constructor(
        DotnsPopController controller_,
        DotnsRegistrarController publicController_,
        DotnsRegistrar registrar_,
        IPopRules popRules_,
        IDotnsRegistry registry_,
        address[] memory actors_,
        bytes32 tldNode_
    ) {
        CONTROLLER = controller_;
        PUBLIC_CONTROLLER = publicController_;
        REGISTRAR = registrar_;
        POP_RULES = popRules_;
        REGISTRY = registry_;
        TLD_NODE = tldNode_;
        actors = actors_;
        // baselength 8, no trailing digits: PopFull classification.
        baseLabels.push("alicebob");
        // length 12, no trailing digits: NoStatus classification. A reservable base label
        // keys the reservation queue, which only ever holds a digit-free stem.
        baseLabels.push("wonderlandxy");
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

        // Public registrants need the same tier for `priceWithCheck` to quote them a price on
        // every band the base-label set spans.
        for (uint256 i = 0; i < 8; i++) {
            address publicActor = makeAddr(string.concat("popPublicActor", vm.toString(i)));
            publicActors.push(publicActor);
            _mockPersonhoodTier(publicActor, 2);
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
    ///      collision) so the runner keeps exploring.
    function reserve(uint256 actorIndex, uint256 baseIndex, bool attachReservation) external {
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

        if (_callReserveBaseName(params)) {
            if (attachReservation) _track(keccak256(bytes(reservedBase)));
            bytes32 node = LabelUtils.namehashUnder(TLD_NODE, LabelUtils.labelhashMemory(liteLabel));
            mintedLiteTokenIds.push(uint256(node));
            priorLiteLabels.push(liteLabel);
            _trackGatewayLabel(liteLabel);
            _trackPendingActor(actor);
        }
    }

    /// @notice Drives the claim path end-to-end when the actor holds the live
    ///         head of the queue for the picked base label.
    /// @dev Missing preconditions (wrong actor, expired head, empty queue)
    ///      surface as a revert and are swallowed so the runner keeps
    ///      leg and the full register leg.
    function claim(uint256 actorIndex, uint256 baseIndex) external {
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
        if (!_callReserveBaseName(liteParams)) return;
        // Recorded here rather than after the full leg below: the token exists from this point,
        // and a full leg that reverts would otherwise leave it outside every invariant's reach.
        bytes32 liteLabelhash = LabelUtils.labelhashMemory(liteLabel);
        mintedLiteTokenIds.push(uint256(LabelUtils.namehashUnder(TLD_NODE, liteLabelhash)));
        priorLiteLabels.push(liteLabel);
        _trackGatewayLabel(liteLabel);
        _trackPendingActor(actor);

        // The lite leg stashed a pending claim. Settle it now so the base
        // registration below takes the warm path; the pending-claim mechanism
        // forbids a second stash for the same user.
        vm.prank(actor);
        try CONTROLLER.settlePendingClaims(actor, type(uint256).max) {} catch {}

        IDotnsPopController.Link memory link = IDotnsPopController.Link({
            kind: IDotnsPopController.LinkKind.LiteUsername, liteLabel: liteLabel, chatKey: ""
        });
        IDotnsPopController.FullRegistration memory fullParams =
            IDotnsPopController.FullRegistration({label: baseLabel, user: actor, link: link});
        if (!_callRegisterBaseName(fullParams)) return;

        bytes32 fullNode = LabelUtils.namehashUnder(TLD_NODE, LabelUtils.labelhashMemory(baseLabel));
        claimedLiteLabelhashes.push(liteLabelhash);
        claimedFullNodes.push(fullNode);
        mintedLiteTokenIds.push(uint256(fullNode));
        _trackGatewayLabel(baseLabel);
    }

    /// @notice Re-registers an already-used lite label against a fresh
    ///         base-label claim so the same liteHash maps to a new fullNode.
    /// @dev Drives the resolver overwrite paths. When the handler
    ///      re-uses the same (baseLabel, actor) pair later it also exercises
    ///      the symmetric case: same fullNode mapped to a new liteHash.
    function reLink(uint256 actorIndex, uint256 baseIndex, uint256 liteIndex) external {
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
        if (!_callRegisterBaseName(params)) return;

        bytes32 liteLabelhash = LabelUtils.labelhashMemory(liteLabel);
        bytes32 fullNode = LabelUtils.namehashUnder(TLD_NODE, LabelUtils.labelhashMemory(baseLabel));
        claimedLiteLabelhashes.push(liteLabelhash);
        claimedFullNodes.push(fullNode);
        mintedLiteTokenIds.push(uint256(fullNode));
        _trackGatewayLabel(baseLabel);
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

    /// @notice Settles the picked actor's own pending claims.
    /// @dev The actor signs the call; `pallet-revive` charges the storage
    ///      deposit against their balance in production. Settlement never reverts
    ///      on an empty or lapsed queue, so no branch needs swallowing; the
    ///      try/catch guards only against unrelated dispatch reverts.
    function settlePendingClaim(uint256 actorIndex) external {
        address actor = _actor(actorIndex);
        vm.prank(actor);
        try CONTROLLER.settlePendingClaims(actor, type(uint256).max) {} catch {}
    }

    /// @notice Settles the picked actor's pending claims from a different actor.
    /// @dev Settlement is permissionless: any account may settle another user's
    ///      claims and bears the cost. The settler is a distinct actor from the
    ///      beneficiary so the third-party path is exercised alongside the
    ///      self-settlement path above.
    function settlePendingClaimByThirdParty(uint256 actorIndex, uint256 settlerIndex) external {
        address actor = _actor(actorIndex);
        address settler = _actor(settlerIndex);
        if (settler == actor) settler = _actor(settlerIndex + 1);
        vm.prank(settler);
        try CONTROLLER.settlePendingClaims(actor, type(uint256).max) {} catch {}
    }

    /// @notice Registers a base label through the public commit-reveal path.
    /// @dev The two paths race for the same free label, and the registrar's availability check
    ///      arbitrates: whichever arrives second reverts, so no label can carry both
    ///      provenances. Registrants come from `publicActors` for the reason given there.
    function publicRegister(uint256 actorIndex, uint256 baseIndex) external {
        address registrant = publicActors[actorIndex % publicActors.length];
        // Alternate between a contested base label and one of the public path's own. The
        // contested half exercises the race; the fresh half keeps the public side populated
        // even in a run where the gateway holds every shared stem, so the provenance
        // invariant always has a public label to check. Ten characters classifies NoStatus.
        string memory label = baseIndex % 2 == 0
            ? _baseLabel(baseIndex)
            : string.concat("publicname", vm.toString(publicLabelNonce++));

        uint256 price;
        try POP_RULES.priceWithCheck(label, registrant) returns (
            IPopRules.PriceWithMeta memory quote
        ) {
            price = quote.price;
        } catch {
            // A stem the gateway queue holds for someone else, or a tier the registrant does
            // not meet, is priced nowhere. Both are ordinary contention.
            return;
        }

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label,
                owner: registrant,
                secret: keccak256(abi.encode(label, registrant, publicRegisterCount)),
                reserved: false,
                maxPrice: type(uint256).max,
                pricingVersion: POP_RULES.pricingVersion()
            });

        bytes32 commitment = PUBLIC_CONTROLLER.makeCommitment(registration);
        vm.prank(registrant);
        try PUBLIC_CONTROLLER.commit(commitment) {}
        catch {
            return;
        }
        vm.warp(block.timestamp + PUBLIC_CONTROLLER.minCommitmentAge() + 1);

        vm.deal(registrant, price);
        vm.prank(registrant);
        try PUBLIC_CONTROLLER.register{value: price}(registration) {
            ++publicRegisterCount;
            publicTokenIds.push(
                uint256(LabelUtils.namehashUnder(TLD_NODE, LabelUtils.labelhashMemory(label)))
            );
            if (!isPublicLabel[label]) {
                isPublicLabel[label] = true;
                publicLabelsRegistered.push(label);
            }
        } catch {}
    }

    /// @notice Attempts to move a tracked token to another account.
    /// @dev Provenance is not a transfer rule, so it has to answer the same after a token
    ///      changes hands. A gateway name is soulbound and the attempt reverts; a publicly
    ///      registered one moves once the fee is paid. The recipient is a public actor either
    ///      way, so a moved name never deposits a `LabelStore` on a gateway actor.
    function attemptTransfer(uint256 tokenIndex, uint256 toIndex) external {
        uint256 gatewayCount = mintedLiteTokenIds.length;
        uint256 total = gatewayCount + publicTokenIds.length;
        if (total == 0) return;

        uint256 pick = tokenIndex % total;
        uint256 tokenId =
            pick < gatewayCount ? mintedLiteTokenIds[pick] : publicTokenIds[pick - gatewayCount];
        if (!REGISTRAR.exists(tokenId)) return;

        address from = REGISTRAR.ownerOf(tokenId);
        address to = publicActors[toIndex % publicActors.length];
        if (to == from) return;

        ++transferAttemptCount;
        uint256 fee;
        try REGISTRAR.quoteTransferFee(tokenId, to) returns (uint256 quoted) {
            fee = quoted;
        } catch {
            // Soulbound names have no transfer price. Send nothing and let the transfer revert.
            fee = 0;
        }

        vm.deal(from, fee);
        vm.prank(from);
        try REGISTRAR.transferFrom{value: fee}(from, to, tokenId) {
            ++transferSuccessCount;
        } catch {}
    }

    /// @notice Creates an arbitrary subname under a gateway-issued name.
    /// @dev Interleaves subname creation with gateway mints so no subnode can quietly land on an
    ///      issued name. A lite parent never gets this far: the registry derives a parent's node
    ///      by splitting the path on the separator, so `joseph.42` as a parent label resolves to
    ///      the hierarchy rather than to the node the gateway minted, and the call reverts. The
    ///      rival reading of a lite name is built by @custom:function createRivalSubname. The
    ///      subnode owner comes from `publicActors` so a subname never deposits a `LabelStore`
    ///      on a gateway actor.
    function createSubname(uint256 parentIndex, uint256 subLabelSeed, uint256 toIndex) external {
        uint256 n = gatewayLabelsSeen.length;
        if (n == 0) return;

        string memory parentLabel = gatewayLabelsSeen[parentIndex % n];
        bytes32 parentNode =
            LabelUtils.namehashUnder(TLD_NODE, LabelUtils.labelhashMemory(parentLabel));
        if (!REGISTRAR.exists(uint256(parentNode))) return;

        address parentOwner = REGISTRAR.ownerOf(uint256(parentNode));
        IDotnsRegistry.SubnodeRecord memory record = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode,
            subLabel: _buildSubLabel(subLabelSeed),
            parentLabel: parentLabel,
            owner: publicActors[toIndex % publicActors.length]
        });

        vm.prank(parentOwner);
        try REGISTRY.setSubnodeOwner(record) returns (bytes32 created) {
            subnodesCreated.push(created);
            subnameParents.push(parentLabel);
        } catch {
            ++subnameRejectedCount;
        }
    }

    /// @notice Builds the rival hierarchy for a lite name: its stem as a subname of its suffix.
    /// @dev The two readings of `michael.01` are a single label and `michael` under `01`, and
    ///      they display identically once the TLD is appended. The suffix parent is
    ///      governance-only on every production entry point, so it is minted straight from an
    ///      authorised controller: the point is to stand the rival hierarchy up and let the
    ///      invariant show that the two nodes never converge, and that the text-keyed answer
    ///      belongs to the whole-label reading rather than to whichever object shares its
    ///      text.
    function createRivalSubname(uint256 liteIndex, uint256 toIndex) external {
        uint256 n = priorLiteLabels.length;
        if (n == 0) return;

        string memory liteLabel = priorLiteLabels[liteIndex % n];
        (string memory stem, string memory suffix) = _splitLite(liteLabel);

        bytes32 parentNode = LabelUtils.namehashUnder(TLD_NODE, LabelUtils.labelhashMemory(suffix));
        address parentOwner = publicActors[toIndex % publicActors.length];
        if (REGISTRAR.exists(uint256(parentNode))) {
            parentOwner = REGISTRAR.ownerOf(uint256(parentNode));
        } else {
            vm.startPrank(address(PUBLIC_CONTROLLER));
            REGISTRAR.register(uint256(parentNode), parentOwner, "");
            REGISTRY.setOwner(parentNode, parentOwner);
            vm.stopPrank();
        }

        IDotnsRegistry.SubnodeRecord memory record = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode,
            subLabel: stem,
            parentLabel: suffix,
            owner: publicActors[(toIndex + 1) % publicActors.length]
        });

        vm.prank(parentOwner);
        try REGISTRY.setSubnodeOwner(record) returns (bytes32 created) {
            rivalSubnodes.push(created);
            rivalTexts.push(liteLabel);
        } catch {
            ++rivalRejectedCount;
        }
    }

    /// @notice Splits a lite label into its stem and its allocated suffix.
    function _splitLite(string memory liteLabel)
        internal
        pure
        returns (string memory stem, string memory suffix)
    {
        bytes memory raw = bytes(liteLabel);
        uint256 separator = raw.length - StringUtils.LITE_SUFFIX_DIGITS - 1;

        bytes memory stemBytes = new bytes(separator);
        for (uint256 i; i < separator; ++i) {
            stemBytes[i] = raw[i];
        }

        bytes memory suffixBytes = new bytes(StringUtils.LITE_SUFFIX_DIGITS);
        for (uint256 i; i < StringUtils.LITE_SUFFIX_DIGITS; ++i) {
            suffixBytes[i] = raw[separator + 1 + i];
        }

        return (string(stemBytes), string(suffixBytes));
    }

    /// @notice Number of rival-hierarchy subnodes created.
    function rivalSubnodeCount() external view returns (uint256) {
        return rivalSubnodes.length;
    }

    /// @notice Builds a sub-label from an alphabet that includes the separator and digits.
    /// @dev Lengths of one to eight cover a plain label, one carrying a separator, an all-digit
    ///      label, and a hyphen in any position.
    function _buildSubLabel(uint256 seed) internal pure returns (string memory subLabel) {
        bytes memory alphabet = "abcdefghijklmnopqrstuvwxyz0123456789-.";
        uint256 length = 1 + (seed % 8);
        bytes memory out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            out[i] = alphabet[seed % alphabet.length];
        }
        return string(out);
    }

    /// @notice Number of subnodes created under a gateway-issued parent.
    function subnodeCreatedCount() external view returns (uint256) {
        return subnodesCreated.length;
    }

    /// @notice Records `label` as gateway-issued, once.
    function _trackGatewayLabel(string memory label) internal {
        if (_gatewayLabelTracked[label]) return;
        _gatewayLabelTracked[label] = true;
        gatewayLabelsSeen.push(label);
    }

    /// @notice Number of distinct labels the gateway has issued.
    function gatewayLabelCount() external view returns (uint256) {
        return gatewayLabelsSeen.length;
    }

    /// @notice Number of distinct labels taken through the public path.
    function publicLabelCount() external view returns (uint256) {
        return publicLabelsRegistered.length;
    }

    /// @notice Calls `reserveBaseName`.
    /// @dev Returns true on success and false on revert so the caller's
    ///      bookkeeping (ghost arrays) stays consistent with on-chain state.
    /// @return ok Whether the underlying call succeeded.
    function _callReserveBaseName(IDotnsPopController.BaseReservation memory params)
        internal
        returns (bool ok)
    {
        _mockOriginIsRoot(true);
        try CONTROLLER.reserveBaseName(params) {
            ok = true;
        } catch {
            ok = false;
        }
        // Restore before returning. The mock is campaign-scoped in an invariant run, and
        // `DotnsRegistrarController.registerReserved` reads `originIsRoot` too, so leaving it
        // `true` would put any later reserved registration on the Root branch.
        _mockOriginIsRoot(false);
    }

    /// @notice Mirror of `_callReserveBaseName` for `registerBaseName`.
    /// @return ok Whether the underlying call succeeded.
    function _callRegisterBaseName(IDotnsPopController.FullRegistration memory params)
        internal
        returns (bool ok)
    {
        _mockOriginIsRoot(true);
        try CONTROLLER.registerBaseName(params) {
            ok = true;
        } catch {
            ok = false;
        }
        _mockOriginIsRoot(false);
    }

    /// @notice Mocks the revive `originIsRoot()` query to return `returnValue`.
    function _mockOriginIsRoot(bool returnValue) internal {
        vm.mockCall(
            DotnsConstants.REVIVE_SYSTEM,
            abi.encodeWithSelector(ISystem.originIsRoot.selector),
            abi.encode(returnValue)
        );
    }

    /// @notice Builds a classification-valid PoP lite label.
    /// @dev Shape: `<tag><4 letters from actor>.<2 digits>`, the separated form the gateway
    ///      accepts. The stem is 7 characters, which classifies as PopLite under PopRules, and
    ///      the separator and digits are the suffix. Tag disambiguates the reserve vs claim call
    ///      sites so neither collides with the other in the ERC721 namespace. The letter block
    ///      is derived from the actor address via keccak so each actor lives in its own lite
    ///      namespace. Suffix wraps modulo 100 so the label keeps exactly two digits;
    ///      collisions past 100 reuses are swallowed by the caller's try/catch.
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
        label = string.concat(tag, string(letters), ".", digits);
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
