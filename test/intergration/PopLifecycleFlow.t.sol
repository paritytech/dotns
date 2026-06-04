// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../base/BaseDotns.t.sol";

import {IDotnsPopController} from "../../contracts/registrars/IDotnsPopController.sol";
import {IDotnsRegistry} from "../../contracts/registry/IDotnsRegistry.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ILabelStore} from "../../contracts/store/ILabelStore.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {LabelUtils} from "../../contracts/utils/LabelUtils.sol";

/// @title PopLifecycleFlow
/// @notice Integration coverage for a PoP-gateway-minted full username across
///         its full on-chain lifecycle: reservation, claim, record writes,
///         subname issuance, transfer, and cross-contract lookup paths a
///         downstream consumer walks starting from the lite username string.
contract PopLifecycleFlow is BaseDotns {
    /// @notice Lite label fixture. Baselength 7 with 2 trailing digits classifies as PopLite.
    string internal constant LITE_LABEL = "aliceli01";
    /// @notice Full label fixture. Baselength 9 with no trailing digits classifies as PopFull.
    string internal constant FULL_LABEL = "alicefull";
    /// @notice Subname label used for the subnode portion of the flow.
    string internal constant SUB_LABEL = "app";
    /// @notice 65-byte canonical chat-key payload (secp256k1 uncompressed shape).
    bytes internal constant CHAT_KEY =
        hex"04cafebabedeadbeefcafebabedeadbeefcafebabedeadbeefcafebabedeadbeefcafebabedeadbeefcafebabedeadbeefcafebabedeadbeefcafebabedeadbeef";
    /// @notice First content hash used in record-write assertions.
    bytes internal constant CONTENT_HASH_A =
        hex"e30101701220aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    /// @notice Second content hash used to verify record overwrites.
    bytes internal constant CONTENT_HASH_B =
        hex"e30101701220bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    function test_recover_full_username_from_lite_label() public {
        _mintLiteThenClaimFull(ed);

        bytes32 liteLabelhash = LabelUtils.labelhashMemory(LITE_LABEL);
        bytes32 fullNode = dotnsPopResolver.fullClaim(liteLabelhash);
        assertTrue(fullNode != bytes32(0), "lite label has no full claim");

        address owner = IERC721(address(dotnsRegistrar)).ownerOf(uint256(fullNode));
        assertEq(owner, ed);
        assertEq(dotnsRegistrar.labelOf(uint256(fullNode)), FULL_LABEL);
        assertEq(dotnsPopResolver.chatKey(fullNode), CHAT_KEY);
        // Same label mirrored in the owner's Store under the canonical store key.
        ILabelStore ownerStore = ILabelStore(storeFactory.getLabelStore(owner));
        assertEq(ownerStore.getLabel(fullNode), string.concat(FULL_LABEL, DotnsConstants.TLD));
    }

    function test_pop_full_name_is_first_class_erc721_name() public {
        _mintLiteThenClaimFull(ed);

        bytes32 fullNode = _nodeOf(FULL_LABEL);
        uint256 fullTokenId = uint256(fullNode);
        bytes32 liteLabelhash = LabelUtils.labelhashMemory(LITE_LABEL);

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(fullTokenId), ed);
        assertEq(dotnsRegistry.owner(fullNode), ed);
        assertEq(dotnsRegistrar.labelOf(fullTokenId), FULL_LABEL);
        assertEq(dotnsPopResolver.chatKey(fullNode), CHAT_KEY);
        assertEq(dotnsPopResolver.liteLink(fullNode), liteLabelhash);
        assertEq(dotnsPopResolver.fullClaim(liteLabelhash), fullNode);

        vm.prank(ed);
        dotnsContentResolver.setContenthash(fullNode, CONTENT_HASH_A);
        assertEq(dotnsContentResolver.contenthash(fullNode), CONTENT_HASH_A);

        bytes32 subnode = _setSubnode(ed, fullNode, SUB_LABEL, FULL_LABEL, leonardo);
        assertEq(dotnsRegistry.owner(subnode), leonardo);

        uint256 _xferFee = dotnsRegistrar.quoteTransferFee(fullTokenId, tiago);
        vm.prank(ed);
        dotnsRegistrar.transferFrom{value: _xferFee}(ed, tiago, fullTokenId);
        // Post-transfer invariants. Only ownership fields change; PoP-layer
        // records are keyed by node and survive intact.
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(fullTokenId), tiago);
        assertEq(dotnsRegistry.owner(fullNode), tiago);
        assertEq(dotnsRegistrar.labelOf(fullTokenId), FULL_LABEL);
        assertEq(dotnsPopResolver.chatKey(fullNode), CHAT_KEY);
        assertEq(dotnsPopResolver.liteLink(fullNode), liteLabelhash);
        assertEq(dotnsPopResolver.fullClaim(liteLabelhash), fullNode);
        assertEq(dotnsContentResolver.contenthash(fullNode), CONTENT_HASH_A);
        assertEq(dotnsRegistry.owner(subnode), leonardo);
        // The new owner drives node writes and subname reassignments.
        vm.prank(tiago);
        dotnsContentResolver.setContenthash(fullNode, CONTENT_HASH_B);
        assertEq(dotnsContentResolver.contenthash(fullNode), CONTENT_HASH_B);

        bytes32 reassignedSubnode = _setSubnode(tiago, fullNode, SUB_LABEL, FULL_LABEL, ed);
        assertEq(reassignedSubnode, subnode);
        assertEq(dotnsRegistry.owner(subnode), ed);
        // The lite token is not transferred alongside the full token.
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(LITE_LABEL))), ed);
        // Store writes are one-shot-locked at registration time, so the label
        // stays under the original owner's Store even after transfer.
        ILabelStore edStore = ILabelStore(storeFactory.getLabelStore(ed));
        assertEq(
            edStore.getLabel(_nodeOf(FULL_LABEL)), string.concat(FULL_LABEL, DotnsConstants.TLD)
        );
    }

    function test_cold_gateway_reserve_then_user_settles_pending_claim() public {
        _grantPopFull(ed);

        _gatewayReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL, user: ed, chatKey: CHAT_KEY
            })
        );

        bytes32 liteNode = _nodeOf(LITE_LABEL);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(liteNode)), ed);
        assertEq(dotnsRegistry.owner(liteNode), ed);
        assertEq(storeFactory.getLabelStore(ed), address(0));
        // Chat key is persisted eagerly on the resolver at reserve time; only the
        // LabelStore write is deferred for cold-path users.
        assertEq(dotnsPopResolver.chatKey(liteNode), CHAT_KEY);

        IDotnsPopController.PendingClaim[] memory pending = dotnsPopController.pendingClaims(ed);
        assertEq(pending[0].label, LITE_LABEL);
        assertGt(pending[0].mintedAt, 0);

        vm.prank(ed);
        dotnsPopController.claimLabelStore();

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(liteNode), string.concat(LITE_LABEL, DotnsConstants.TLD)
        );
        assertEq(dotnsPopResolver.chatKey(liteNode), CHAT_KEY);
        assertEq(dotnsPopController.pendingClaims(ed).length, 0);
        assertEq(dotnsPopController.pendingClaimUserCount(), 0);
    }

    function test_reserve_expire_reserve_cycle_for_same_user() public {
        _grantPopFull(ed);
        _gatewayReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL, user: ed, chatKey: CHAT_KEY
            })
        );
        uint64 firstMintedAt = dotnsPopController.pendingClaims(ed)[0].mintedAt;

        vm.warp(block.timestamp + DEFAULT_RESERVATION_DURATION + 1);
        dotnsPopController.expirePendingClaim(ed);
        assertEq(dotnsPopController.pendingClaims(ed).length, 0);
        assertEq(dotnsPopController.pendingClaimUserCount(), 0);

        string memory secondLabel = "aliceli02";
        bytes memory secondKey =
            hex"04beefcafedeadbeefcafedeadbeefcafedeadbeefcafedeadbeefcafedeadbeefcafedeadbeefcafedeadbeefcafedeadbeefcafedeadbeefcafedeadbeefcafe";
        _gatewayReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: secondLabel, user: ed, chatKey: secondKey
            })
        );

        IDotnsPopController.PendingClaim[] memory second = dotnsPopController.pendingClaims(ed);
        assertEq(second[0].label, secondLabel);
        assertEq(dotnsPopResolver.chatKey(_nodeOf(secondLabel)), secondKey);
        assertGt(second[0].mintedAt, firstMintedAt);
        assertEq(dotnsPopController.pendingClaimUserCount(), 1);
    }

    function test_transfer_of_token_with_live_pending_claim_does_not_move_claim() public {
        _grantPopFull(ed);
        _gatewayReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL, user: ed, chatKey: CHAT_KEY
            })
        );

        uint256 tokenId = uint256(_nodeOf(LITE_LABEL));
        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, tiago, tokenId);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(tokenId), tiago);

        // The pending claim is keyed by the original user (`ed`) and stays put
        // when the token transfers. `tiago` receives an empty `LabelStore` via
        // the registrar's transfer-sync path because `ed` has no store yet to
        // copy the label from; this is current `DotnsRegistrar._update`
        // behaviour and is independent of the pending-claim mapping.
        IDotnsPopController.PendingClaim[] memory pending = dotnsPopController.pendingClaims(ed);
        assertEq(pending[0].label, LITE_LABEL);
        assertGt(pending[0].mintedAt, 0);
        assertEq(dotnsPopController.pendingClaims(tiago).length, 0);

        vm.prank(ed);
        dotnsPopController.claimLabelStore();
        address edStore = storeFactory.getLabelStore(ed);
        assertTrue(edStore != address(0));
        bytes32 node = _nodeOf(LITE_LABEL);
        assertEq(ILabelStore(edStore).getLabel(node), string.concat(LITE_LABEL, DotnsConstants.TLD));
    }

    function test_lapsed_pending_claim_is_swept_without_deploying_store() public {
        _grantPopFull(ed);
        _gatewayReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL, user: ed, chatKey: CHAT_KEY
            })
        );

        vm.warp(block.timestamp + DEFAULT_RESERVATION_DURATION + 1);

        // Permissionless sweep from a stranger address.
        vm.prank(makeAddr("sweeper"));
        dotnsPopController.expirePendingClaim(ed);

        assertEq(dotnsPopController.pendingClaims(ed).length, 0);
        assertEq(storeFactory.getLabelStore(ed), address(0));
        assertEq(dotnsPopController.pendingClaimUserCount(), 0);
    }

    function test_lite_via_gateway_then_full_via_public_after_upgrade() public {
        _grantPopLite(ed);
        _gatewayReserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL, user: ed, chatKey: CHAT_KEY
            })
        );

        bytes32 liteNode = _nodeOf(LITE_LABEL);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(liteNode)), ed);

        _grantPopFull(ed);

        string memory popfullLabel = "alicedef";
        _commitAndRegister(popfullLabel, ed, false);

        bytes32 fullNode = _nodeOf(popfullLabel);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(fullNode)), ed);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(liteNode)), ed);
    }

    /// @notice Mints the lite label for `user` then claims the full label against it.
    /// @dev Grants PopFull up front so both the lite reservation leg and the
    ///      reservedBaseLabel leg pass `priceWithCheck`.
    function _mintLiteThenClaimFull(address user) internal {
        // The reservedBaseLabel leg of reserveBaseName now runs
        // priceWithCheck on FULL_LABEL too, and FULL_LABEL classifies as
        // PopFull. Granting PopFull up front satisfies classification/tier
        // on both the lite leg (PopLite classification, admitted by the
        // PopFull superset) and the full-person claim.
        _grantPopFull(user);
        _reservePop(user, LITE_LABEL, CHAT_KEY, FULL_LABEL);
        _gatewayRegisterBaseName(
            IDotnsPopController.FullRegistration({
                label: FULL_LABEL, user: user, link: _linkWithLite(LITE_LABEL)
            })
        );
    }

    /// @notice Creates a subnode under `parentNode` while pranking as `parentOwner`.
    /// @param parentOwner Account authorised to set the subnode.
    /// @param parentNode Node hash of the parent record.
    /// @param subLabel Subname label (without dot suffix).
    /// @param parentLabel Parent label (without dot suffix).
    /// @param subOwner Account that should own the new subnode.
    /// @return subnode Resulting subnode hash.
    function _setSubnode(
        address parentOwner,
        bytes32 parentNode,
        string memory subLabel,
        string memory parentLabel,
        address subOwner
    )
        internal
        returns (bytes32 subnode)
    {
        IDotnsRegistry.SubnodeRecord memory record = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: subLabel, parentLabel: parentLabel, owner: subOwner
        });

        vm.prank(parentOwner);
        subnode = dotnsRegistry.setSubnodeOwner(record);
    }
}
