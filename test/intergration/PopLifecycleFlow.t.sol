// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../base/BaseDotns.t.sol";

import {IDotnsPopController} from "../../contracts/registrars/IDotnsPopController.sol";
import {IDotnsRegistry} from "../../contracts/registry/IDotnsRegistry.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IStore} from "../../contracts/store/IStore.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {StoreUtils} from "../../contracts/utils/StoreUtils.sol";
import {LabelUtils} from "../../contracts/utils/LabelUtils.sol";

/// @title PopLifecycleFlow
/// @notice Integration coverage for a PoP-gateway-minted full username across
///         its full on-chain lifecycle: reservation, claim, record writes,
///         subname issuance, transfer, and cross-contract lookup paths a
///         downstream consumer walks starting from the lite username string.
contract PopLifecycleFlow is BaseDotns {
    // Lite baselength 7 + 2 trailing digits classifies as PopLite.
    string internal constant LITE_LABEL = "aliceli01";
    // Full baselength 9 with no trailing digits classifies as PopFull.
    string internal constant FULL_LABEL = "alicefull";
    string internal constant SUB_LABEL = "app";
    // 65-byte canonical chat-key payload (secp256k1 uncompressed shape).
    bytes internal constant CHAT_KEY =
        hex"04cafebabedeadbeefcafebabedeadbeefcafebabedeadbeefcafebabedeadbeefcafebabedeadbeefcafebabedeadbeefcafebabedeadbeefcafebabedeadbeef";
    bytes internal constant CONTENT_HASH_A =
        hex"e30101701220aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
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
        IStore ownerStore = storeFactory.getDeployedStore(owner);
        assertEq(
            ownerStore.getValueFor(
                owner, StoreUtils.storeKey(LabelUtils.labelhashMemory(FULL_LABEL))
            ),
            string.concat(FULL_LABEL, DotnsConstants.TLD)
        );
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

        // Cross-tier transfer: ed is PopFull, tiago has no status set, so the
        // recipient owes the cross-tier delta. Route through the payable ERC721
        // transfer entrypoint with the priced delta attached.
        uint256 priceForTiago = popRules.priceWithoutCheck(FULL_LABEL, tiago).price;
        vm.prank(ed);
        dotnsRegistrar.transferFrom{value: priceForTiago}(ed, tiago, fullTokenId);

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
        IStore edStore = storeFactory.getDeployedStore(ed);
        assertEq(
            edStore.getValueFor(ed, StoreUtils.storeKey(LabelUtils.labelhashMemory(FULL_LABEL))),
            string.concat(FULL_LABEL, DotnsConstants.TLD)
        );
    }

    function _mintLiteThenClaimFull(address user) internal {
        // The reservedBaseLabel leg of reserveBaseName now runs
        // priceWithCheck on FULL_LABEL too, and FULL_LABEL classifies as
        // PopFull. Granting PopFull up front satisfies classification/tier
        // on both the lite leg (PopLite classification, admitted by the
        // PopFull superset) and the full-person claim.
        _grantPopFull(user);
        _reservePop(user, LITE_LABEL, CHAT_KEY, FULL_LABEL);
        vm.prank(popGateway);
        dotnsPopController.registerBaseName(
            IDotnsPopController.FullRegistration({
                label: FULL_LABEL, user: user, link: _linkWithLite(LITE_LABEL)
            })
        );
    }

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
