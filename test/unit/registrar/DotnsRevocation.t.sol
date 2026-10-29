// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsRegistrar} from "../../../contracts/registrars/IDotnsRegistrar.sol";
import {IDotnsRegistry} from "../../../contracts/registry/IDotnsRegistry.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";
import {
    IDotnsRegistrarController
} from "../../../contracts/registrars/IDotnsRegistrarController.sol";
import {IDotnsNameEscrowRevocation} from "../../../contracts/escrow/IDotnsNameEscrowRevocation.sol";
import {IDotnsPopController} from "../../../contracts/registrars/IDotnsPopController.sol";
import {
    IDotnsPopControllerLegacy
} from "../../../contracts/registrars/IDotnsPopControllerLegacy.sol";
import {IDotnsPopGovernance} from "../../../contracts/registrars/IDotnsPopGovernance.sol";
import {IDotnsPopResolver} from "../../../contracts/resolvers/IDotnsPopResolver.sol";
import {
    IDotnsPopResolverClearing
} from "../../../contracts/resolvers/IDotnsPopResolverClearing.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DotnsRevocationTest
/// @notice Governance taking back names and reservation queues: Root revocation of a public name,
///         of a subname, and of a name the PoP controller issued, and Root eviction of a
///         personhood name's reservation queue.
/// @dev Every governance call here runs under a mocked Root origin and is restored to non-Root
///      straight after, because other paths (`registerReserved`) read the same precompile. The
///      calls these gates guard must fail for a signed caller, so each one has a signed-caller
///      case.
contract DotnsRevocationTest is BaseDotns {
    /// @notice 13-char NoStatus label, so registration seeds a funded release position.
    string internal constant LABEL = "revocablename";
    string internal constant CHILD = "child";
    string internal constant GRANDCHILD = "grand";
    string internal constant TEXT_KEY = "avatar";
    address internal constant PAY_TO = address(0xBEEF);

    bytes32 internal node;
    uint256 internal tokenId;
    bytes32 internal childNode;
    bytes32 internal grandchildNode;
    uint256 internal deposit;

    function setUp() public override {
        super.setUp();
        node = _register(LABEL, ed, IPopRules.PopStatus.NoStatus);
        tokenId = uint256(node);
        deposit = dotnsNameEscrow.getReleasePosition(tokenId).amount;

        childNode = _createSubname(node, CHILD, LABEL, tiago, ed);
        grandchildNode = _createSubname(
            childNode, GRANDCHILD, string.concat(CHILD, ".", LABEL), leonardo, tiago
        );

        _writeRecords(node, ed);
        _writeRecords(childNode, tiago);
    }

    // helpers

    function _createSubname(
        bytes32 parentNode,
        string memory subLabel,
        string memory parentLabel,
        address holder,
        address caller
    )
        internal
        returns (bytes32 subnode)
    {
        vm.prank(caller);
        subnode = dotnsRegistry.setSubnodeOwner(
            IDotnsRegistry.SubnodeRecord({
                parentNode: parentNode,
                subLabel: subLabel,
                parentLabel: parentLabel,
                owner: holder,
                persist: true
            })
        );
    }

    function _writeRecords(bytes32 target, address writer) internal {
        vm.startPrank(writer);
        dotnsResolver.setAddress(target, PAY_TO);
        dotnsContentResolver.setText(target, TEXT_KEY, "ipfs://avatar");
        vm.stopPrank();
    }

    function _assertRecordsUnset(bytes32 target, string memory what) internal view {
        assertEq(dotnsResolver.addressOf(target), address(0), string.concat(what, ": address"));
        assertEq(dotnsContentResolver.text(target, TEXT_KEY), "", string.concat(what, ": text"));
    }

    function _assertGone(bytes32 target, string memory what) internal view {
        assertEq(dotnsRegistry.owner(target), address(0), string.concat(what, ": owner"));
        assertFalse(dotnsRegistry.recordExists(target), string.concat(what, ": exists"));
        assertEq(dotnsRegistry.resolver(target), address(0), string.concat(what, ": resolver"));
        _assertRecordsUnset(target, what);
    }

    function _rootRevoke(uint256 id) internal {
        _mockOriginIsRoot(true);
        dotnsRegistrar.revoke(id);
        _mockOriginIsRoot(false);
    }

    function _rootRevokeSubname(bytes32 parentNode, string memory subLabel) internal {
        _mockOriginIsRoot(true);
        dotnsRegistry.revokeSubname(parentNode, keccak256(bytes(subLabel)));
        _mockOriginIsRoot(false);
    }

    function _rootRevokeIssued(string memory label) internal {
        _dispatchFromRoot(abi.encodeCall(IDotnsPopGovernance.revokeName, (label)));
    }

    function _rootEvict(string memory label) internal {
        _dispatchFromRoot(abi.encodeCall(IDotnsPopGovernance.evictReservations, (label)));
    }

    function _release() internal {
        vm.startPrank(ed);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();
    }

    /// @notice Registers `label` for `user` on the reserved path through a governance grant.
    function _registerReserved(string memory label, address user) internal returns (uint256 id) {
        _grantName(label, user);
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label,
                owner: user,
                secret: keccak256(abi.encodePacked(label, user, "reserved")),
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
            });
        _commitRegistrationAndWaitMinimumAge(registration);
        vm.prank(user);
        dotnsRegistrarController.registerReserved(registration);
        id = uint256(_nodeOf(label));
    }

    /// @notice Transfers `id` from `from` to `to`.
    function _transfer(address from, address to, uint256 id) internal {
        vm.prank(from);
        dotnsRegistrar.transferFrom(from, to, id);
    }

    function _issuePersonhood(string memory label, address user, bytes memory chatKey) internal {
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: label, user: user, link: _linkFresh(chatKey)
            })
        );
    }

    function _issueDevice(string memory label, address user, bytes memory chatKey) internal {
        _rootIssueDeviceName(
            IDotnsPopController.DeviceNameIssuance({label: label, user: user, chatKey: chatKey})
        );
    }

    // Revoking a public name

    function test_revoke_burns_the_name_and_clears_everything_beneath_it() public {
        assertEq(
            dotnsReverseResolver.nameOf(ed),
            string.concat(LABEL, ".dot"),
            "fixture sets the holder's reverse record"
        );

        vm.expectEmit(true, true, true, true, address(dotnsNameEscrow));
        emit IDotnsNameEscrow.RefundWithdrawn(tokenId, ed, address(0), deposit);
        vm.expectEmit(true, true, false, false, address(dotnsNameEscrow));
        emit IDotnsNameEscrowRevocation.PositionRevoked(tokenId, ed);
        vm.expectEmit(true, false, false, true, address(dotnsRegistry));
        emit IDotnsRegistry.NewResolver(node, address(0));
        vm.expectEmit(true, false, false, true, address(dotnsRegistry));
        emit IDotnsRegistry.NodeTransferred(node, address(0));
        vm.expectEmit(true, true, true, false, address(dotnsRegistrar));
        emit IERC721.Transfer(ed, address(0), tokenId);
        vm.expectEmit(true, true, false, false, address(dotnsRegistrar));
        emit IDotnsRegistrar.NameRevoked(tokenId, ed);
        _rootRevoke(tokenId);

        assertFalse(dotnsRegistrar.exists(tokenId), "token burned");
        assertTrue(dotnsRegistrar.available(tokenId), "name available");
        _assertGone(node, "name");
        _assertGone(childNode, "child");
        _assertGone(grandchildNode, "grandchild");
        assertEq(dotnsReverseResolver.nameOf(ed), "", "reverse record reads empty after revoke");
    }

    function test_revoke_refunds_the_deposit_to_the_holder_at_once() public {
        assertGt(deposit, 0, "fixture seeds a funded position");
        uint256 reservedBefore = dotnsNameEscrow.reserves(address(0));

        _rootRevoke(tokenId);

        assertEq(dotnsNameEscrow.getReleasePosition(tokenId).recipient, address(0), "position gone");
        assertEq(dotnsNameEscrow.pendingWithdrawal(ed), deposit, "deposit credited");
        assertEq(dotnsNameEscrow.reserves(address(0)), reservedBefore - deposit, "reserve debited");

        uint256 balanceBefore = ed.balance;
        vm.prank(ed);
        dotnsNameEscrow.claimWithdrawal();
        assertEq(ed.balance, balanceBefore + deposit, "claimable without waiting");
    }

    function test_a_revoked_name_is_registered_again_clean_and_transferable() public {
        _rootRevoke(tokenId);

        _register(LABEL, tiago, IPopRules.PopStatus.NoStatus);

        assertEq(dotnsRegistrar.ownerOf(tokenId), tiago, "new holder");
        assertEq(dotnsRegistry.owner(node), tiago, "registry follows");
        _assertRecordsUnset(node, "name");
        _assertGone(childNode, "child");
        _assertGone(grandchildNode, "grandchild");
        assertEq(
            dotnsNameEscrow.getReleasePosition(tokenId).recipient, tiago, "fresh position seeded"
        );

        _transfer(tiago, leonardo, tokenId);
        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo, "transferable");
    }

    function test_the_previous_holder_can_register_a_revoked_name_again() public {
        _rootRevoke(tokenId);

        _register(LABEL, ed, IPopRules.PopStatus.NoStatus);

        assertEq(dotnsRegistrar.ownerOf(tokenId), ed, "same holder again");
        assertEq(dotnsRegistrar.labelOf(tokenId), LABEL, "label store entry still matches");
        _assertRecordsUnset(node, "name");
        _assertGone(childNode, "child");
        assertEq(
            dotnsReverseResolver.nameOf(ed),
            string.concat(LABEL, ".dot"),
            "reverse record shows the name again"
        );
    }

    function test_revoke_reaches_a_released_name_and_ends_its_redeem_window() public {
        _release();
        assertFalse(dotnsRegistrar.available(tokenId), "inside the redeem window");

        vm.expectEmit(true, true, false, false, address(dotnsRegistrar));
        emit IDotnsRegistrar.NameRevoked(tokenId, ed);
        _rootRevoke(tokenId);

        assertTrue(dotnsRegistrar.available(tokenId), "available at once");
        assertEq(dotnsNameEscrow.releasedTokenCount(), 0, "left the released set");
        assertEq(dotnsNameEscrow.pendingWithdrawal(ed), deposit, "unwithdrawn deposit credited");

        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameEscrow.NotRefundRecipient.selector, ed, tokenId)
        );
        dotnsNameEscrow.redeem(tokenId);
    }

    function test_revoke_after_withdraw_credits_nothing_more() public {
        _release();
        vm.warp(block.timestamp + ESCROW_COOLDOWN);
        vm.prank(ed);
        dotnsNameEscrow.withdraw(tokenId);
        assertEq(dotnsNameEscrow.pendingWithdrawal(ed), deposit, "withdrawn once");

        uint256 reservedBefore = dotnsNameEscrow.reserves(address(0));

        _rootRevoke(tokenId);

        assertEq(dotnsNameEscrow.pendingWithdrawal(ed), deposit, "not credited twice");
        assertEq(dotnsNameEscrow.reserves(address(0)), reservedBefore, "reserve untouched");
    }

    function test_revoke_credits_the_deposit_to_whoever_holds_the_name() public {
        _transfer(ed, tiago, tokenId);
        uint256 owed = dotnsNameEscrow.getReleasePosition(tokenId).amount;
        assertEq(dotnsNameEscrow.getReleasePosition(tokenId).recipient, tiago, "deposit rebound");

        _rootRevoke(tokenId);

        assertEq(dotnsNameEscrow.pendingWithdrawal(tiago), owed, "current holder credited");
        assertEq(dotnsNameEscrow.pendingWithdrawal(ed), 0, "previous holder not credited");
    }

    function test_revoke_of_a_reserved_name_with_no_deposit_credits_nothing() public {
        uint256 reservedId = _registerReserved("hello", tiago);
        assertEq(dotnsNameEscrow.getReleasePosition(reservedId).amount, 0, "no deposit held");

        vm.recordLogs();
        _rootRevoke(reservedId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(dotnsRegistrar.exists(reservedId), "token burned");
        assertTrue(dotnsRegistrar.available(reservedId), "name available");
        assertEq(dotnsNameEscrow.pendingWithdrawal(tiago), 0, "nothing credited");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != IDotnsNameEscrow.RefundWithdrawn.selector, "no refund event"
            );
        }
    }

    function test_revoke_after_the_redeem_window_then_register_as_a_fresh_mint() public {
        _release();
        vm.warp(dotnsNameEscrow.getReleasePosition(tokenId).redeemableUntil);
        assertTrue(dotnsNameEscrow.isReclaimable(tokenId), "reclaimable before the revoke");

        _rootRevoke(tokenId);
        assertFalse(dotnsNameEscrow.isReclaimable(tokenId), "nothing left to reclaim");

        _register(LABEL, tiago, IPopRules.PopStatus.NoStatus);
        assertEq(dotnsRegistrar.ownerOf(tokenId), tiago, "registered as a fresh mint");
        assertEq(dotnsNameEscrow.pendingWithdrawal(ed), deposit, "previous holder refunded once");
    }

    function test_revoke_reverts_for_a_signed_caller() public {
        vm.prank(ed);
        vm.expectRevert(IDotnsRegistrar.NotRoot.selector);
        dotnsRegistrar.revoke(tokenId);
    }

    function test_revoke_reverts_for_a_name_that_does_not_exist() public {
        uint256 missing = uint256(_nodeOf("neverregistered"));
        _mockOriginIsRoot(true);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, missing)
        );
        dotnsRegistrar.revoke(missing);
        _mockOriginIsRoot(false);
    }

    function test_revoke_refuses_a_soulbound_name() public {
        _issuePersonhood(PERSONHOOD_LABEL_A, ed, _validChatKey(0x01));
        uint256 personhoodId = uint256(_nodeOf(PERSONHOOD_LABEL_A));

        _mockOriginIsRoot(true);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrar.NameSoulbound.selector, personhoodId)
        );
        dotnsRegistrar.revoke(personhoodId);
        _mockOriginIsRoot(false);
    }

    function test_revoke_refuses_a_device_container() public {
        _issueDevice(DEVICE_LABEL_A, ed, _validChatKey(0x01));
        uint256 containerId = uint256(_nodeOf("01"));

        _mockOriginIsRoot(true);
        vm.expectRevert(abi.encodeWithSelector(IDotnsRegistrar.NameSoulbound.selector, containerId));
        dotnsRegistrar.revoke(containerId);
        _mockOriginIsRoot(false);

        vm.expectRevert(
            abi.encodeWithSelector(IDotnsPopGovernance.NotPopIssued.selector, keccak256("01"))
        );
        _rootRevokeIssued("01");
    }

    function test_revokeIssued_refuses_a_name_that_is_not_soulbound() public {
        vm.prank(address(dotnsPopController));
        vm.expectRevert(abi.encodeWithSelector(IDotnsRegistrar.NotSoulbound.selector, tokenId));
        dotnsRegistrar.revokeIssued(tokenId);
    }

    function test_revokeIssued_is_for_the_pop_controller_only() public {
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsRegistrar.NotPopController.selector, ed));
        dotnsRegistrar.revokeIssued(tokenId);
    }

    function test_registry_revokeName_is_for_the_registrar_only() public {
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsRegistry.NotRegistrar.selector, ed));
        dotnsRegistry.revokeName(node);
    }

    function test_escrow_revoke_is_for_the_registrar_only() public {
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsNameEscrow.NotRegistrar.selector, ed));
        IDotnsNameEscrowRevocation(address(dotnsNameEscrow)).revoke(tokenId);
    }

    // Revoking a subname

    function test_revokeSubname_deletes_a_subname_whoever_holds_the_parent() public {
        vm.expectEmit(true, true, false, true, address(dotnsRegistry));
        emit IDotnsRegistry.NewOwner(node, keccak256(bytes(CHILD)), address(0));
        _rootRevokeSubname(node, CHILD);

        _assertGone(childNode, "child");
        _assertGone(grandchildNode, "grandchild");
        assertEq(dotnsRegistry.owner(node), ed, "the parent is untouched");
        assertEq(dotnsResolver.addressOf(node), PAY_TO, "the parent's records are untouched");

        bytes32 again = _createSubname(node, CHILD, LABEL, tiago, ed);
        assertEq(again, childNode, "same node");
        _assertRecordsUnset(childNode, "recreated child");
    }

    function test_revokeSubname_reverts_for_a_signed_caller() public {
        vm.prank(ed);
        vm.expectRevert(IDotnsRegistry.NotRoot.selector);
        dotnsRegistry.revokeSubname(node, keccak256(bytes(CHILD)));
    }

    function test_revokeSubname_reverts_for_a_missing_subname() public {
        bytes32 missing = _namehash(node, keccak256("missing"));
        _mockOriginIsRoot(true);
        vm.expectRevert(abi.encodeWithSelector(IDotnsRegistry.SubnameNotFound.selector, missing));
        dotnsRegistry.revokeSubname(node, keccak256("missing"));
        _mockOriginIsRoot(false);
    }

    function test_revokeSubname_refuses_a_device_name() public {
        _issueDevice(DEVICE_LABEL_A, ed, _validChatKey(0x01));
        // DEVICE_LABEL_A is `michael.01`: the subname `michael` of the container `01`.
        bytes32 container = _nodeOf("01");
        bytes32 stemhash = keccak256("michael");
        assertEq(_namehash(container, stemhash), _deviceNodeOf(DEVICE_LABEL_A), "fixture shape");

        _mockOriginIsRoot(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistry.IssuedByGateway.selector, _deviceNodeOf(DEVICE_LABEL_A)
            )
        );
        dotnsRegistry.revokeSubname(container, stemhash);
        _mockOriginIsRoot(false);
    }

    function test_revokeSubname_cannot_reach_a_second_level_name() public {
        _mockOriginIsRoot(true);
        vm.expectRevert(abi.encodeWithSelector(IDotnsRegistry.SubnameNotFound.selector, node));
        dotnsRegistry.revokeSubname(_tldNode(), keccak256(bytes(LABEL)));
        _mockOriginIsRoot(false);

        assertEq(dotnsRegistry.owner(node), ed, "name untouched");
    }

    function test_revokeSubname_reaches_a_subname_of_a_personhood_name() public {
        _issuePersonhood(PERSONHOOD_LABEL_A, ed, "");
        bytes32 personhoodNode = _nodeOf(PERSONHOOD_LABEL_A);
        bytes32 subnode = _createSubname(personhoodNode, CHILD, PERSONHOOD_LABEL_A, tiago, ed);

        _rootRevokeSubname(personhoodNode, CHILD);

        _assertGone(subnode, "subname");
        assertEq(dotnsRegistry.owner(personhoodNode), ed, "personhood name kept");
    }

    // Revoking a name the PoP controller issued

    function test_revoking_a_personhood_name_clears_the_gateway_state() public {
        _issuePersonhood(PERSONHOOD_LABEL_A, ed, _validChatKey(0x01));
        bytes32 personhoodNode = _nodeOf(PERSONHOOD_LABEL_A);
        uint256 personhoodId = uint256(personhoodNode);

        vm.expectEmit(true, true, false, true, address(dotnsPopController));
        emit IDotnsPopGovernance.IssuedNameRevoked(
            keccak256(bytes(PERSONHOOD_LABEL_A)), ed, PERSONHOOD_LABEL_A
        );
        _rootRevokeIssued(PERSONHOOD_LABEL_A);

        assertFalse(dotnsPopController.isPopIssued(PERSONHOOD_LABEL_A), "issued flag cleared");
        assertEq(dotnsPopResolver.chatKey(personhoodNode), "", "chat key cleared");
        assertFalse(dotnsRegistrar.exists(personhoodId), "token burned");
        assertFalse(dotnsRegistrar.isSoulbound(personhoodId), "soulbound flag cleared");
        assertEq(dotnsRegistry.owner(personhoodNode), address(0), "registry cleared");
    }

    function test_a_revoked_personhood_name_can_be_issued_to_someone_else() public {
        _issuePersonhood(PERSONHOOD_LABEL_A, ed, _validChatKey(0x01));
        _rootRevokeIssued(PERSONHOOD_LABEL_A);

        _issuePersonhood(PERSONHOOD_LABEL_A, tiago, "");

        bytes32 personhoodNode = _nodeOf(PERSONHOOD_LABEL_A);
        assertEq(dotnsRegistry.owner(personhoodNode), tiago, "new holder");
        assertEq(dotnsPopResolver.chatKey(personhoodNode), "", "no inherited chat key");
        assertTrue(dotnsPopController.isPopIssued(PERSONHOOD_LABEL_A), "issued again");
    }

    function test_a_former_personhood_name_registered_publicly_is_transferable() public {
        _issuePersonhood(PERSONHOOD_LABEL_A, ed, _validChatKey(0x01));
        _rootRevokeIssued(PERSONHOOD_LABEL_A);

        _setShortNames(true);
        uint256 personhoodId =
            uint256(_register(PERSONHOOD_LABEL_A, tiago, IPopRules.PopStatus.Personhood));
        assertFalse(dotnsRegistrar.isSoulbound(personhoodId), "not soulbound");
        assertFalse(dotnsPopController.isPopIssued(PERSONHOOD_LABEL_A), "not a gateway identity");

        _transfer(tiago, leonardo, personhoodId);
        assertEq(dotnsRegistrar.ownerOf(personhoodId), leonardo, "transferred");
    }

    function test_a_stale_pending_claim_settles_harmlessly_after_revoke_and_reissue() public {
        address newcomer = _createUser("newcomer");
        _issueDevice(DEVICE_LABEL_A, newcomer, "");
        assertEq(dotnsPopController.pendingClaimCountOf(newcomer), 1, "cold path stashed a claim");

        _rootRevokeIssued(DEVICE_LABEL_A);
        _issueDevice(DEVICE_LABEL_A, tiago, "");

        vm.recordLogs();
        vm.prank(newcomer);
        dotnsPopController.claimLabelStore();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(dotnsPopController.pendingClaimCountOf(newcomer), 0, "entry removed");
        assertEq(logs.length, 0, "no store deployed, no claim or registration logged");
        assertEq(dotnsRegistry.owner(_deviceNodeOf(DEVICE_LABEL_A)), tiago, "holder unaffected");
    }

    function test_a_name_revoked_and_issued_to_the_same_user_settles_once() public {
        address newcomer = _createUser("newcomer");
        _issueDevice(DEVICE_LABEL_A, newcomer, "");
        _rootRevokeIssued(DEVICE_LABEL_A);
        _issueDevice(DEVICE_LABEL_A, newcomer, "");
        assertEq(dotnsPopController.pendingClaimCountOf(newcomer), 2, "two entries, one row");

        vm.recordLogs();
        vm.prank(newcomer);
        dotnsPopController.claimLabelStore();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 registered;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(dotnsPopController)
                    && logs[i].topics[0] == IDotnsPopController.NameRegistered.selector
            ) ++registered;
        }
        assertEq(registered, 1, "registered once");
        assertEq(dotnsPopController.pendingClaimCountOf(newcomer), 0, "both entries removed");
    }

    function test_revoking_a_personhood_name_unlinks_its_device_name_only() public {
        bytes memory deviceKey = _validChatKey(0x02);
        _issueDevice(DEVICE_LABEL_A, ed, deviceKey);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkWithDeviceName(DEVICE_LABEL_A)
            })
        );
        bytes32 personhoodNode = _nodeOf(PERSONHOOD_LABEL_A);
        bytes32 deviceLabelhash = keccak256(bytes(DEVICE_LABEL_A));
        assertEq(dotnsPopResolver.deviceLabelhashOf(personhoodNode), deviceLabelhash, "linked");

        _rootRevokeIssued(PERSONHOOD_LABEL_A);

        assertEq(dotnsPopResolver.deviceLabelhashOf(personhoodNode), bytes32(0), "forward link");
        assertEq(dotnsPopResolver.personhoodNodeOf(deviceLabelhash), bytes32(0), "reverse link");
        bytes32 deviceNode = _deviceNodeOf(DEVICE_LABEL_A);
        assertEq(dotnsRegistry.owner(deviceNode), ed, "device name kept");
        assertEq(dotnsPopResolver.chatKey(deviceNode), deviceKey, "device chat key kept");
        assertTrue(dotnsPopController.isPopIssued(DEVICE_LABEL_A), "device still issued");
    }

    function test_revoking_a_device_name_deletes_it_and_unlinks_its_personhood_name() public {
        _issueDevice(DEVICE_LABEL_A, ed, _validChatKey(0x02));
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: PERSONHOOD_LABEL_A, user: ed, link: _linkWithDeviceName(DEVICE_LABEL_A)
            })
        );
        bytes32 personhoodNode = _nodeOf(PERSONHOOD_LABEL_A);
        bytes32 deviceNode = _deviceNodeOf(DEVICE_LABEL_A);
        bytes32 deviceLabelhash = keccak256(bytes(DEVICE_LABEL_A));

        _rootRevokeIssued(DEVICE_LABEL_A);

        assertFalse(dotnsPopController.isPopIssued(DEVICE_LABEL_A), "issued flag cleared");
        assertEq(dotnsRegistry.owner(deviceNode), address(0), "device name deleted");
        assertEq(dotnsPopResolver.chatKey(deviceNode), "", "device chat key cleared");
        assertEq(dotnsPopResolver.deviceLabelhashOf(personhoodNode), bytes32(0), "forward link");
        assertEq(dotnsPopResolver.personhoodNodeOf(deviceLabelhash), bytes32(0), "reverse link");
        assertEq(dotnsRegistry.owner(personhoodNode), ed, "personhood name kept");
    }

    function test_revoking_a_device_name_deletes_its_subnames() public {
        _issueDevice(DEVICE_LABEL_A, ed, _validChatKey(0x01));
        bytes32 deviceNode = _deviceNodeOf(DEVICE_LABEL_A);
        bytes32 subnode = _createSubname(deviceNode, CHILD, DEVICE_LABEL_A, tiago, ed);
        _writeRecords(subnode, tiago);

        _rootRevokeIssued(DEVICE_LABEL_A);

        _assertGone(subnode, "device subname");
    }

    function test_a_revoked_device_name_can_be_issued_again() public {
        _issueDevice(DEVICE_LABEL_A, ed, _validChatKey(0x01));
        _rootRevokeIssued(DEVICE_LABEL_A);

        _issueDevice(DEVICE_LABEL_A, tiago, "");

        bytes32 deviceNode = _deviceNodeOf(DEVICE_LABEL_A);
        assertEq(dotnsRegistry.owner(deviceNode), tiago, "new holder");
        assertEq(dotnsPopResolver.chatKey(deviceNode), "", "no inherited chat key");
    }

    function test_revokeName_reverts_for_a_label_the_controller_did_not_issue() public {
        bytes32 labelhash = keccak256(bytes(LABEL));
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsPopGovernance.NotPopIssued.selector, labelhash)
        );
        _rootRevokeIssued(LABEL);
    }

    function test_revokeName_reverts_the_second_time() public {
        _issuePersonhood(PERSONHOOD_LABEL_A, ed, "");
        _rootRevokeIssued(PERSONHOOD_LABEL_A);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsPopGovernance.NotPopIssued.selector, keccak256(bytes(PERSONHOOD_LABEL_A))
            )
        );
        _rootRevokeIssued(PERSONHOOD_LABEL_A);
    }

    function test_revokeName_reverts_for_a_signed_caller() public {
        _issuePersonhood(PERSONHOOD_LABEL_A, ed, "");
        vm.prank(ed);
        vm.expectRevert(IDotnsPopController.NotRoot.selector);
        IDotnsPopGovernance(address(dotnsPopController)).revokeName(PERSONHOOD_LABEL_A);
    }

    function test_clearRecords_is_for_the_pop_controller_only() public {
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsPopResolver.NotPopController.selector, ed));
        IDotnsPopResolverClearing(address(dotnsPopResolver)).clearRecords(node, bytes32(0));
    }

    // Evicting a reservation queue

    function _fillQueue(string memory label) internal {
        for (uint256 i; i < dotnsPopController.MAX_RESERVATION_QUEUE(); ++i) {
            _rootReservePersonhoodName(
                IDotnsPopController.PersonhoodNameReservation({
                    user: makeAddr(string.concat("waiter", vm.toString(i))), label: label
                })
            );
        }
    }

    function test_evictReservations_clears_a_full_queue_in_one_call() public {
        _fillQueue(PERSONHOOD_LABEL_A);
        bytes32 labelhash = keccak256(bytes(PERSONHOOD_LABEL_A));
        (bool reserved,,) = popRules.isBaseNameReserved(PERSONHOOD_LABEL_A);
        assertTrue(reserved, "fixture holds the PopRules slot");

        vm.expectEmit(true, false, false, false, address(dotnsPopController));
        emit IDotnsPopGovernance.ReservationsEvicted(labelhash);
        _rootEvict(PERSONHOOD_LABEL_A);

        (uint64 head, uint64 tail) = dotnsPopController.reservationMeta(labelhash);
        assertEq(head, tail, "queue empty");
        (reserved,,) = popRules.isBaseNameReserved(PERSONHOOD_LABEL_A);
        assertFalse(reserved, "PopRules slot released");
        (bool forClaim,) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertFalse(forClaim, "nobody holds it");
        for (uint256 i; i < dotnsPopController.MAX_RESERVATION_QUEUE(); ++i) {
            address waiter = makeAddr(string.concat("waiter", vm.toString(i)));
            assertEq(
                dotnsPopController.userReservation(waiter).labelhash,
                bytes32(0),
                "every reservation ended"
            );
        }
    }

    function test_an_evicted_name_is_reservable_and_registrable() public {
        _fillQueue(PERSONHOOD_LABEL_A);
        _rootEvict(PERSONHOOD_LABEL_A);

        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: ed, label: PERSONHOOD_LABEL_A})
        );
        (bool forClaim, address holder) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertTrue(forClaim && holder == ed, "a new reservation takes the front");

        _issuePersonhood(PERSONHOOD_LABEL_A, ed, "");
        assertEq(dotnsRegistry.owner(_nodeOf(PERSONHOOD_LABEL_A)), ed, "registered");
    }

    function test_an_evicted_user_can_reserve_again() public {
        _fillQueue(PERSONHOOD_LABEL_A);
        address waiter = makeAddr("waiter3");
        _rootEvict(PERSONHOOD_LABEL_A);

        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: waiter, label: PERSONHOOD_LABEL_A})
        );
        (bool forClaim, address holder) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertTrue(forClaim && holder == waiter, "reserved again");
    }

    function test_evictReservations_on_an_empty_queue_does_nothing() public {
        vm.recordLogs();
        _rootEvict(PERSONHOOD_LABEL_A);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no event");
    }

    function test_evictReservations_after_a_claim_does_nothing() public {
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: ed, label: PERSONHOOD_LABEL_A})
        );
        _issuePersonhood(PERSONHOOD_LABEL_A, ed, "");

        vm.recordLogs();
        _rootEvict(PERSONHOOD_LABEL_A);
        assertEq(vm.getRecordedLogs().length, 0, "a racing claim leaves nothing to evict");
        assertEq(dotnsRegistry.owner(_nodeOf(PERSONHOOD_LABEL_A)), ed, "claimed name kept");
    }

    function test_evictReservations_refuses_a_label_that_is_not_a_personhood_name() public {
        vm.expectRevert(IDotnsPopController.InvalidPersonhoodLabel.selector);
        _rootEvict("abc1");
    }

    function _reserve(string memory who, string memory label) internal returns (address user) {
        user = makeAddr(who);
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: user, label: label})
        );
    }

    function _rootEvictUser(address user) internal {
        _dispatchFromRoot(abi.encodeCall(IDotnsPopGovernance.evictReservation, (user)));
    }

    function test_evictReservation_removes_one_user_and_keeps_the_rest_in_place() public {
        address first = _reserve("first", PERSONHOOD_LABEL_A);
        address middle = _reserve("middle", PERSONHOOD_LABEL_A);
        address last = _reserve("last", PERSONHOOD_LABEL_A);
        bytes32 labelhash = keccak256(bytes(PERSONHOOD_LABEL_A));

        vm.expectEmit(true, true, false, false, address(dotnsPopController));
        emit IDotnsPopController.ReservationRelinquished(labelhash, middle);
        _rootEvictUser(middle);

        assertEq(dotnsPopController.userReservation(middle).labelhash, bytes32(0), "evicted");
        assertEq(dotnsPopController.userReservation(first).labelhash, labelhash, "front kept");
        assertEq(dotnsPopController.userReservation(last).labelhash, labelhash, "tail kept");
        (bool forClaim, address holder) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertTrue(forClaim && holder == first, "front unchanged");
    }

    function test_evictReservation_of_the_front_moves_the_slot_to_the_next_user() public {
        address first = _reserve("first", PERSONHOOD_LABEL_A);
        address second = _reserve("second", PERSONHOOD_LABEL_A);

        _rootEvictUser(first);

        (bool forClaim, address holder) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertTrue(forClaim && holder == second, "next user at the front");
        (bool live, address slotOwner,) = popRules.isBaseNameReserved(PERSONHOOD_LABEL_A);
        assertTrue(live && slotOwner == second, "PopRules slot follows");
    }

    function test_evictReservation_of_the_only_user_releases_the_slot() public {
        address only = _reserve("only", PERSONHOOD_LABEL_A);

        _rootEvictUser(only);

        (bool live,,) = popRules.isBaseNameReserved(PERSONHOOD_LABEL_A);
        assertFalse(live, "slot released");
        (bool forClaim,) = dotnsPopController.isReservedForClaim(PERSONHOOD_LABEL_A);
        assertFalse(forClaim, "nobody holds it");
    }

    function test_evictReservation_without_a_reservation_does_nothing() public {
        vm.recordLogs();
        _rootEvictUser(ed);
        assertEq(vm.getRecordedLogs().length, 0, "no event");
    }

    function test_evictReservation_reverts_for_a_signed_caller() public {
        address first = _reserve("first", PERSONHOOD_LABEL_A);
        vm.prank(ed);
        vm.expectRevert(IDotnsPopController.NotRoot.selector);
        IDotnsPopGovernance(address(dotnsPopController)).evictReservation(first);
    }

    function test_evictReservations_reverts_for_a_signed_caller() public {
        vm.prank(ed);
        vm.expectRevert(IDotnsPopController.NotRoot.selector);
        IDotnsPopGovernance(address(dotnsPopController)).evictReservations(PERSONHOOD_LABEL_A);
    }

    // Interface ids

    /// @notice The ids these contracts reported through ERC-165 before revocation existed. They
    ///         are literals, not `type(I).interfaceId`, so a selector added to one of these
    ///         interfaces fails here instead of moving the expected value along with it.
    bytes4 internal constant ESCROW_ID = 0x8c31e16c;
    bytes4 internal constant POP_RESOLVER_ID = 0x1e0c0fee;
    bytes4 internal constant POP_CONTROLLER_ID = 0x5453fcd0;
    bytes4 internal constant POP_CONTROLLER_LEGACY_ID = 0x86d43965;

    function test_interface_ids_are_unchanged_and_still_reported() public view {
        assertEq(type(IDotnsNameEscrow).interfaceId, ESCROW_ID, "escrow id unchanged");
        assertEq(type(IDotnsPopResolver).interfaceId, POP_RESOLVER_ID, "pop resolver id unchanged");
        assertEq(
            type(IDotnsPopController).interfaceId, POP_CONTROLLER_ID, "pop controller id unchanged"
        );
        assertEq(
            type(IDotnsPopControllerLegacy).interfaceId,
            POP_CONTROLLER_LEGACY_ID,
            "pop controller legacy id unchanged"
        );

        assertTrue(dotnsNameEscrow.supportsInterface(ESCROW_ID), "escrow");
        assertTrue(
            dotnsNameEscrow.supportsInterface(type(IDotnsNameEscrowRevocation).interfaceId),
            "escrow revocation"
        );
        assertTrue(dotnsPopResolver.supportsInterface(POP_RESOLVER_ID), "pop resolver");
        assertTrue(
            dotnsPopResolver.supportsInterface(type(IDotnsPopResolverClearing).interfaceId),
            "pop resolver clearing"
        );
        assertTrue(dotnsPopController.supportsInterface(POP_CONTROLLER_ID), "pop controller");
        assertTrue(
            dotnsPopController.supportsInterface(POP_CONTROLLER_LEGACY_ID), "pop controller legacy"
        );
        assertTrue(
            dotnsPopController.supportsInterface(type(IDotnsPopGovernance).interfaceId),
            "pop governance"
        );
    }
}
