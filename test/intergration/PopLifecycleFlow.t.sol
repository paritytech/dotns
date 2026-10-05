// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../base/BaseDotns.t.sol";

import {IDotnsPopController} from "../../contracts/registrars/IDotnsPopController.sol";
import {IDotnsRegistrar} from "../../contracts/registrars/IDotnsRegistrar.sol";
import {IDotnsRegistry} from "../../contracts/registry/IDotnsRegistry.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ILabelStore} from "../../contracts/store/ILabelStore.sol";
import {LabelUtils} from "../../contracts/utils/LabelUtils.sol";

/// @title PopLifecycleFlow
/// @notice Integration coverage for a PoP-gateway-minted personhood name across
///         its full on-chain lifecycle: reservation, claim, record writes,
///         subname issuance, transfer, and cross-contract lookup paths a
///         downstream consumer walks starting from the device name string.
contract PopLifecycleFlow is BaseDotns {
    /// @notice Device name fixture. Baselength 7 with 2 trailing digits classifies as Devicehood.
    string internal constant DEVICE_LABEL = "michael.01";
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

    function test_recover_personhood_name_from_device_name() public {
        _issueDeviceThenClaimPersonhood(ed);

        bytes32 deviceLabelhash = LabelUtils.labelhashMemory(DEVICE_LABEL);
        bytes32 personhoodNode = dotnsPopResolver.personhoodNodeOf(deviceLabelhash);
        assertTrue(personhoodNode != bytes32(0), "device name has no personhood claim");

        address owner = IERC721(address(dotnsRegistrar)).ownerOf(uint256(personhoodNode));
        assertEq(owner, ed);
        assertEq(dotnsRegistrar.labelOf(uint256(personhoodNode)), PERSONHOOD_LABEL_A);
        assertEq(dotnsPopResolver.chatKey(personhoodNode), CHAT_KEY);
        // Same label mirrored in the owner's Store under the canonical store key.
        ILabelStore ownerStore = ILabelStore(storeFactory.getLabelStore(owner));
        assertEq(
            ownerStore.getLabel(personhoodNode),
            string.concat(PERSONHOOD_LABEL_A, protocolRegistry.tld())
        );
    }

    function test_personhood_name_is_soulbound_but_fully_usable() public {
        _issueDeviceThenClaimPersonhood(ed);

        bytes32 personhoodNode = _nodeOf(PERSONHOOD_LABEL_A);
        uint256 personhoodTokenId = uint256(personhoodNode);
        bytes32 deviceLabelhash = LabelUtils.labelhashMemory(DEVICE_LABEL);

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(personhoodTokenId), ed);
        assertEq(dotnsRegistry.owner(personhoodNode), ed);
        assertEq(dotnsRegistrar.labelOf(personhoodTokenId), PERSONHOOD_LABEL_A);
        assertEq(dotnsPopResolver.chatKey(personhoodNode), CHAT_KEY);
        assertEq(dotnsPopResolver.deviceLabelhashOf(personhoodNode), deviceLabelhash);
        assertEq(dotnsPopResolver.personhoodNodeOf(deviceLabelhash), personhoodNode);
        assertTrue(dotnsRegistrar.isSoulbound(personhoodTokenId));

        // The name is fully usable by its owner: records and subnames work.
        vm.prank(ed);
        dotnsContentResolver.setContenthash(personhoodNode, CONTENT_HASH_A);
        assertEq(dotnsContentResolver.contenthash(personhoodNode), CONTENT_HASH_A);

        bytes32 subnode = _setSubnode(ed, personhoodNode, SUB_LABEL, PERSONHOOD_LABEL_A, leonardo);
        assertEq(dotnsRegistry.owner(subnode), leonardo);

        // It is soulbound: quoting a transfer and attempting one both revert, and ownership
        // does not move.
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrar.NameSoulbound.selector, personhoodTokenId)
        );
        dotnsRegistrar.quoteTransferFee(personhoodTokenId, tiago);

        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrar.NameSoulbound.selector, personhoodTokenId)
        );
        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, tiago, personhoodTokenId);

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(personhoodTokenId), ed);
        assertEq(dotnsRegistry.owner(personhoodNode), ed);
        // PoP-layer records and the owner's continued control are untouched by the blocked move.
        assertEq(dotnsPopResolver.chatKey(personhoodNode), CHAT_KEY);
        assertEq(dotnsPopResolver.personhoodNodeOf(deviceLabelhash), personhoodNode);
        assertEq(dotnsContentResolver.contenthash(personhoodNode), CONTENT_HASH_A);
        assertEq(dotnsRegistry.owner(subnode), leonardo);

        vm.prank(ed);
        dotnsContentResolver.setContenthash(personhoodNode, CONTENT_HASH_B);
        assertEq(dotnsContentResolver.contenthash(personhoodNode), CONTENT_HASH_B);

        bytes32 reassignedSubnode =
            _setSubnode(ed, personhoodNode, SUB_LABEL, PERSONHOOD_LABEL_A, tiago);
        assertEq(reassignedSubnode, subnode);
        assertEq(dotnsRegistry.owner(subnode), tiago);
        // The device name is a subname owned in the registry, not a transferable token.
        assertEq(dotnsRegistry.owner(_deviceNodeOf(DEVICE_LABEL)), ed);
        assertFalse(dotnsRegistrar.exists(uint256(_deviceNodeOf(DEVICE_LABEL))));
    }

    function test_cold_gateway_reserve_then_user_settles_pending_claim() public {
        _grantPersonhood(ed);

        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL, user: ed, chatKey: CHAT_KEY
            })
        );

        bytes32 deviceNode = _deviceNodeOf(DEVICE_LABEL);
        assertEq(dotnsRegistry.owner(deviceNode), ed);
        assertEq(dotnsRegistry.owner(deviceNode), ed);
        assertEq(storeFactory.getLabelStore(ed), address(0));
        // Chat key is persisted eagerly on the resolver at reserve time; only the
        // LabelStore write is deferred for cold-path users.
        assertEq(dotnsPopResolver.chatKey(deviceNode), CHAT_KEY);

        IDotnsPopController.PendingClaim[] memory pending =
            dotnsPopController.pendingClaims(ed, 0, type(uint256).max);
        assertEq(pending[0].label, DEVICE_LABEL);
        assertGt(pending[0].mintedAt, 0);

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(deviceNode),
            string.concat(DEVICE_LABEL, protocolRegistry.tld())
        );
        assertEq(dotnsPopResolver.chatKey(deviceNode), CHAT_KEY);
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
        assertEq(dotnsPopController.pendingClaimUserCount(), 0);
    }

    function test_reserve_settle_reserve_cycle_for_same_user() public {
        _grantPersonhood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL, user: ed, chatKey: CHAT_KEY
            })
        );
        uint64 firstMintedAt = dotnsPopController.pendingClaims(ed, 0, 1)[0].mintedAt;

        vm.warp(block.timestamp + DEFAULT_RESERVATION_DURATION + 1);
        // Age never drops a claim: settling deploys the store and writes the first label rather
        // than discarding it.
        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
        assertEq(dotnsPopController.pendingClaimUserCount(), 0);

        address store = storeFactory.getLabelStore(ed);
        assertEq(
            ILabelStore(store).getLabel(_deviceNodeOf(DEVICE_LABEL)),
            string.concat(DEVICE_LABEL, protocolRegistry.tld())
        );

        string memory secondLabel = "michael.02";
        bytes memory secondKey =
            hex"04beefcafedeadbeefcafedeadbeefcafedeadbeefcafedeadbeefcafedeadbeefcafedeadbeefcafedeadbeefcafedeadbeefcafedeadbeefcafedeadbeefcafe";
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: secondLabel, user: ed, chatKey: secondKey
            })
        );

        // The user is warm now, so the second reservation writes straight into the store.
        assertEq(
            ILabelStore(store).getLabel(_deviceNodeOf(secondLabel)),
            string.concat(secondLabel, protocolRegistry.tld())
        );
        assertEq(dotnsPopResolver.chatKey(_deviceNodeOf(secondLabel)), secondKey);
        assertGt(firstMintedAt, 0);
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
        assertEq(dotnsPopController.pendingClaimUserCount(), 0);
    }

    function test_gateway_name_with_live_pending_claim_is_soulbound_and_settles_for_owner() public {
        _grantPersonhood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL, user: ed, chatKey: CHAT_KEY
            })
        );

        // The device name is a subname owned in the registry, not a transferable ERC-721 token, so
        // it cannot be moved out of the beneficiary's wallet before settlement: there is no token
        // to transfer and the owner holds no reassignment primitive. This is the path the issue
        // closes: a pre-claim transfer previously escaped tier pricing entirely.
        bytes32 deviceNode = _deviceNodeOf(DEVICE_LABEL);
        assertEq(dotnsRegistry.owner(deviceNode), ed);
        assertFalse(dotnsRegistrar.exists(uint256(deviceNode)));

        // The pending claim is keyed by the original user and still settles into their store.
        IDotnsPopController.PendingClaim[] memory pending =
            dotnsPopController.pendingClaims(ed, 0, type(uint256).max);
        assertEq(pending[0].label, DEVICE_LABEL);
        assertGt(pending[0].mintedAt, 0);

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);
        address edStore = storeFactory.getLabelStore(ed);
        assertTrue(edStore != address(0));
        bytes32 node = _deviceNodeOf(DEVICE_LABEL);
        assertEq(
            ILabelStore(edStore).getLabel(node), string.concat(DEVICE_LABEL, protocolRegistry.tld())
        );
    }

    function test_lapsed_pending_claim_settles_and_deploys_store() public {
        _grantPersonhood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL, user: ed, chatKey: CHAT_KEY
            })
        );

        vm.warp(block.timestamp + DEFAULT_RESERVATION_DURATION + 1);

        // Permissionless settlement from a stranger address: age never drops the claim, so the
        // store is deployed for the beneficiary and the label is written and readable.
        bytes32 deviceNode = _deviceNodeOf(DEVICE_LABEL);
        vm.prank(makeAddr("settler"));
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0));
        assertEq(
            ILabelStore(store).getLabel(deviceNode),
            string.concat(DEVICE_LABEL, protocolRegistry.tld())
        );
        assertEq(dotnsPopController.pendingClaimCountOf(ed), 0);
        assertEq(dotnsPopController.pendingClaimUserCount(), 0);
    }

    function test_device_name_via_gateway_then_personhood_name_via_public_after_upgrade() public {
        _grantDevicehood(ed);
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({
                label: DEVICE_LABEL, user: ed, chatKey: CHAT_KEY
            })
        );

        bytes32 deviceNode = _deviceNodeOf(DEVICE_LABEL);
        assertEq(dotnsRegistry.owner(deviceNode), ed);

        _grantPersonhood(ed);

        string memory popfullLabel = "alicedef";
        _commitAndRegister(popfullLabel, ed, false);

        bytes32 personhoodNode = _nodeOf(popfullLabel);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(personhoodNode)), ed);
        assertEq(dotnsRegistry.owner(deviceNode), ed);
    }

    /// @notice Mints the device name for `user` then claims the personhood label against it.
    /// @dev Grants Personhood up front so both the device-name reservation leg and the
    ///      reservedLabel leg pass `priceWithCheck`.
    function _issueDeviceThenClaimPersonhood(address user) internal {
        // The reservedLabel leg of reserveBaseName now runs
        // priceWithCheck on PERSONHOOD_LABEL_A too, and PERSONHOOD_LABEL_A classifies as
        // Personhood. Granting Personhood up front satisfies classification/tier
        // on both the device-name issuance (Devicehood classification, admitted by the
        // Personhood superset) and the personhood claim.
        _grantPersonhood(user);
        _reservePop(user, DEVICE_LABEL, CHAT_KEY, PERSONHOOD_LABEL_A);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: user, link: _linkWithDeviceName(DEVICE_LABEL)
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
            parentNode: parentNode,
            subLabel: subLabel,
            parentLabel: parentLabel,
            owner: subOwner,
            persist: true
        });

        vm.prank(parentOwner);
        subnode = dotnsRegistry.setSubnodeOwner(record);
    }
}
