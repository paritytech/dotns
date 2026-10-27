// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsRegistry} from "../../../contracts/registry/IDotnsRegistry.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";
import {IDotnsResolver} from "../../../contracts/resolvers/IDotnsResolver.sol";
import {IDotnsContentResolver} from "../../../contracts/resolvers/IDotnsContentResolver.sol";
import {Vm} from "forge-std/Vm.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {DotnsNameEscrow} from "../../../contracts/escrow/DotnsNameEscrow.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title DotnsRecordClearingTest
/// @notice Clearing a name's records and subnames: on release, on demand by the owner, and when a
///         parent deletes a subname. A transfer clears nothing.
/// @dev The lifecycle cases check all three resolver record types (address, content hash, text)
///      and a subname two levels deep, because each record type is stamped separately and a
///      subname only stops resolving through the walk over its ancestors.
contract DotnsRecordClearingTest is BaseDotns {
    /// @notice 13-char label, NoStatus, so registration seeds a funded release position.
    string internal constant LABEL = "clearablename";

    string internal constant CHILD = "child";
    string internal constant GRANDCHILD = "grand";
    string internal constant TEXT_KEY = "avatar";

    address internal constant PAY_TO = address(0xBEEF);
    bytes internal constant HASH = hex"e301017012201234";

    bytes32 internal node;
    uint256 internal tokenId;
    bytes32 internal childNode;
    bytes32 internal grandchildNode;

    function setUp() public override {
        super.setUp();
        node = _register(LABEL, ed, IPopRules.PopStatus.NoStatus);
        tokenId = uint256(node);

        childNode = _createSubname(node, CHILD, LABEL, tiago, ed);
        string memory childPath = string.concat(CHILD, ".", LABEL);
        grandchildNode = _createSubname(childNode, GRANDCHILD, childPath, leonardo, tiago);

        _writeRecords(node, ed);
        _writeRecords(childNode, tiago);
        _writeRecords(grandchildNode, leonardo);
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
        dotnsContentResolver.setContenthash(target, HASH);
        dotnsContentResolver.setText(target, TEXT_KEY, "ipfs://avatar");
        vm.stopPrank();
    }

    function _assertRecordsSet(bytes32 target, string memory what) internal view {
        assertEq(dotnsResolver.addressOf(target), PAY_TO, string.concat(what, ": address"));
        assertEq(
            dotnsContentResolver.contenthash(target), HASH, string.concat(what, ": content hash")
        );
        assertEq(
            dotnsContentResolver.text(target, TEXT_KEY),
            "ipfs://avatar",
            string.concat(what, ": text")
        );
    }

    function _assertRecordsUnset(bytes32 target, string memory what) internal view {
        assertEq(dotnsResolver.addressOf(target), address(0), string.concat(what, ": address"));
        assertEq(
            dotnsContentResolver.contenthash(target), "", string.concat(what, ": content hash")
        );
        assertEq(dotnsContentResolver.text(target, TEXT_KEY), "", string.concat(what, ": text"));
    }

    function _assertSubnameGone(bytes32 subnode, string memory what) internal view {
        assertEq(dotnsRegistry.owner(subnode), address(0), string.concat(what, ": owner"));
        assertFalse(dotnsRegistry.recordExists(subnode), string.concat(what, ": exists"));
        assertEq(dotnsRegistry.resolver(subnode), address(0), string.concat(what, ": resolver"));
        _assertRecordsUnset(subnode, what);
    }

    function _assertTreeIntact() internal view {
        _assertRecordsSet(node, "name");
        assertEq(dotnsRegistry.owner(childNode), tiago, "child owner");
        assertEq(dotnsRegistry.owner(grandchildNode), leonardo, "grandchild owner");
        _assertRecordsSet(childNode, "child");
        _assertRecordsSet(grandchildNode, "grandchild");
    }

    function _release() internal {
        vm.startPrank(ed);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();
    }

    // release

    function test_release_clears_every_record_and_every_subname() public {
        _assertTreeIntact();

        _release();

        _assertRecordsUnset(node, "name");
        assertEq(
            dotnsRegistry.resolver(node),
            address(dotnsReverseResolver),
            "the resolver pointer is back to the default"
        );
        _assertSubnameGone(childNode, "child");
        _assertSubnameGone(grandchildNode, "grandchild");
    }

    function test_redeem_returns_the_name_clean() public {
        _release();
        vm.prank(ed);
        dotnsNameEscrow.redeem(tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), ed);
        _assertRecordsUnset(node, "name");
        _assertSubnameGone(childNode, "child");
        _assertSubnameGone(grandchildNode, "grandchild");

        // The holder writes again from scratch, and only the new values read back.
        vm.prank(ed);
        dotnsResolver.setAddress(node, leonardo);
        assertEq(dotnsResolver.addressOf(node), leonardo);
        assertEq(dotnsContentResolver.text(node, TEXT_KEY), "", "an unwritten key stays unset");
    }

    function test_reclaim_hands_the_new_owner_a_clean_name() public {
        _release();
        vm.warp(dotnsNameEscrow.getReleasePosition(tokenId).redeemableUntil);

        _register(LABEL, leonardo, IPopRules.PopStatus.NoStatus);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo);
        _assertRecordsUnset(node, "name");
        _assertSubnameGone(childNode, "child");
        _assertSubnameGone(grandchildNode, "grandchild");
    }

    function test_recreated_subname_starts_clean_even_for_the_same_holder() public {
        _release();
        vm.prank(ed);
        dotnsNameEscrow.redeem(tokenId);

        bytes32 again = _createSubname(node, CHILD, LABEL, tiago, ed);

        assertEq(again, childNode);
        assertEq(dotnsRegistry.owner(childNode), tiago);
        _assertRecordsUnset(childNode, "recreated child");
        _assertSubnameGone(grandchildNode, "grandchild of the recreated child");
    }

    // transfer

    function test_transfer_keeps_every_record_and_subname() public {
        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo);
        _assertTreeIntact();
    }

    // owner clears

    function test_owner_clearRecords_keeps_subnames() public {
        vm.prank(ed);
        dotnsRegistry.clearRecords(node);

        _assertRecordsUnset(node, "name");
        assertEq(dotnsRegistry.owner(childNode), tiago);
        _assertRecordsSet(childNode, "child");
        _assertRecordsSet(grandchildNode, "grandchild");
    }

    function test_owner_clearSubnames_keeps_own_records() public {
        vm.prank(ed);
        dotnsRegistry.clearSubnames(node);

        _assertRecordsSet(node, "name");
        _assertSubnameGone(childNode, "child");
        _assertSubnameGone(grandchildNode, "grandchild");
    }

    function test_subname_holder_can_clear_its_own_subtree() public {
        vm.prank(tiago);
        dotnsRegistry.clear(childNode);

        _assertRecordsSet(node, "name");
        assertEq(dotnsRegistry.owner(childNode), tiago, "clearing does not give the subname up");
        _assertRecordsUnset(childNode, "child");
        _assertSubnameGone(grandchildNode, "grandchild");
    }

    function test_revert_clear_by_someone_without_authority() public {
        vm.prank(leonardo);
        vm.expectRevert(IDotnsRegistry.NotAuthorised.selector);
        dotnsRegistry.clear(node);
    }

    function test_operator_approved_on_the_registrar_can_clear() public {
        vm.prank(ed);
        dotnsRegistrar.setApprovalForAll(leonardo, true);
        vm.prank(leonardo);
        dotnsRegistry.clearRecords(node);
        _assertRecordsUnset(node, "name");
    }

    // delete

    function test_parent_deletes_a_subname_and_everything_beneath_it() public {
        bytes32 labelhash = keccak256(bytes(CHILD));
        vm.expectEmit(true, false, false, true, address(dotnsRegistry));
        emit IDotnsRegistry.RecordsCleared(childNode, 1);
        vm.expectEmit(true, false, false, true, address(dotnsRegistry));
        emit IDotnsRegistry.SubnamesCleared(childNode, 1);
        vm.expectEmit(true, true, false, true, address(dotnsRegistry));
        emit IDotnsRegistry.NewOwner(node, labelhash, address(0));

        vm.prank(ed);
        dotnsRegistry.deleteSubname(node, labelhash);

        _assertRecordsSet(node, "name");
        _assertSubnameGone(childNode, "child");
        _assertSubnameGone(grandchildNode, "grandchild");
    }

    function test_revert_subname_holder_cannot_delete_its_own_subname() public {
        vm.prank(tiago);
        vm.expectRevert(IDotnsRegistry.NotAuthorised.selector);
        dotnsRegistry.deleteSubname(node, keccak256(bytes(CHILD)));
    }

    function test_parent_deletes_a_subname_a_clear_cut_off_and_frees_its_storage() public {
        vm.prank(ed);
        dotnsRegistry.clearSubnames(node);

        vm.prank(ed);
        dotnsRegistry.deleteSubname(node, keccak256(bytes(CHILD)));

        bytes32 base = keccak256(abi.encode(childNode, RECORDS_SLOT));
        _assertZero(address(dotnsRegistry), base, "record owner slot");
        _assertZero(address(dotnsRegistry), bytes32(uint256(base) + 1), "record resolver slot");
        _assertZero(
            address(dotnsRegistry), keccak256(abi.encode(childNode, PARENT_OF_SLOT)), "parent link"
        );
    }

    function test_revert_delete_below_a_subname_a_clear_cut_off() public {
        vm.prank(ed);
        dotnsRegistry.clearSubnames(node);

        // The grandchild's parent no longer resolves, so nobody holds authority to delete it.
        vm.prank(tiago);
        vm.expectRevert(IDotnsRegistry.NotAuthorised.selector);
        dotnsRegistry.deleteSubname(childNode, keccak256(bytes(GRANDCHILD)));
    }

    function test_new_owner_deletes_subnames_the_previous_owner_cleared() public {
        vm.prank(ed);
        dotnsRegistry.clearSubnames(node);
        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);

        vm.prank(ed);
        vm.expectRevert(IDotnsRegistry.NotAuthorised.selector);
        dotnsRegistry.deleteSubname(node, keccak256(bytes(CHILD)));

        vm.prank(leonardo);
        dotnsRegistry.deleteSubname(node, keccak256(bytes(CHILD)));
        assertFalse(dotnsRegistry.recordExists(childNode));
    }

    function test_revert_delete_of_a_subname_that_does_not_exist() public {
        bytes32 labelhash = keccak256("nobody");
        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistry.SubnameNotFound.selector, _namehash(node, labelhash)
            )
        );
        dotnsRegistry.deleteSubname(node, labelhash);
    }

    function test_new_subname_under_a_parent_never_cleared_writes_no_version_slot() public view {
        // Its parent's subname version is zero, which is what the slot already holds, so the
        // registry skips that write.
        assertEq(
            vm.load(address(dotnsRegistry), keccak256(abi.encode(childNode, VERSIONS_SLOT))),
            bytes32(0)
        );
    }

    function test_deleted_subname_can_be_created_again_clean() public {
        vm.prank(ed);
        dotnsRegistry.deleteSubname(node, keccak256(bytes(CHILD)));

        _createSubname(node, CHILD, LABEL, leonardo, ed);
        assertEq(dotnsRegistry.owner(childNode), leonardo);
        _assertRecordsUnset(childNode, "recreated child");
        _assertSubnameGone(grandchildNode, "grandchild");
    }

    function test_cleared_subname_has_no_authority() public {
        vm.prank(ed);
        dotnsRegistry.clearSubnames(node);

        assertFalse(dotnsRegistry.isAuthorised(childNode, tiago));
        vm.prank(tiago);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsResolver.NotAuthorised.selector, childNode, tiago)
        );
        dotnsResolver.setAddress(childNode, tiago);
    }

    function test_revert_setSubnodeResolver_on_a_cleared_subname() public {
        vm.prank(ed);
        dotnsRegistry.clearSubnames(node);

        vm.prank(ed);
        vm.expectRevert(IDotnsRegistry.NotAuthorised.selector);
        dotnsRegistry.setSubnodeResolver(
            IDotnsRegistry.SubnodeResolverRecord({
                parentNode: node, subLabel: CHILD, parentLabel: LABEL, resolver: address(1)
            })
        );
    }

    function test_clearRecords_emits_the_new_version_and_resets_the_resolver_pointer() public {
        vm.prank(ed);
        dotnsRegistry.setResolver(node, address(0xCAFE));

        vm.expectEmit(true, false, false, true, address(dotnsRegistry));
        emit IDotnsRegistry.RecordsCleared(node, 1);
        vm.expectEmit(true, false, false, true, address(dotnsRegistry));
        emit IDotnsRegistry.NewResolver(node, address(dotnsReverseResolver));
        vm.prank(ed);
        dotnsRegistry.clearRecords(node);

        assertEq(dotnsRegistry.resolver(node), address(dotnsReverseResolver));
        (, uint64 version) = dotnsRegistry.recordVersion(node);
        assertEq(version, 1);
    }

    function test_release_redeem_and_release_again_clears_again() public {
        _release();
        vm.prank(ed);
        dotnsNameEscrow.redeem(tokenId);

        _writeRecords(node, ed);
        _createSubname(node, CHILD, LABEL, tiago, ed);
        _assertRecordsSet(node, "rewritten name");

        _release();

        _assertRecordsUnset(node, "name released twice");
        _assertSubnameGone(childNode, "recreated child");
        (, uint64 version) = dotnsRegistry.recordVersion(node);
        assertEq(version, 2);
    }

    function test_release_still_clears_with_no_resolver_wired() public {
        vm.startPrank(owner);
        protocolRegistry.remove(DotnsConstants.RESOLVER);
        protocolRegistry.remove(DotnsConstants.CONTENT_RESOLVER);
        vm.stopPrank();

        _release();

        _assertSubnameGone(childNode, "child");
        (, uint64 version) = dotnsRegistry.recordVersion(node);
        assertEq(version, 1, "the registry clear still runs");
    }

    // subnames with no recorded parent

    /// @dev Storage slot of `DotnsRegistry._parentOf`. Clearing an entry reproduces a subname
    ///      whose parent was never recorded.
    uint256 internal constant PARENT_OF_SLOT = 3;

    function _unlink(bytes32 subnode) internal {
        vm.store(address(dotnsRegistry), keccak256(abi.encode(subnode, PARENT_OF_SLOT)), bytes32(0));
    }

    function test_parent_slot_constant_points_at_the_parent_mapping() public view {
        assertEq(
            vm.load(address(dotnsRegistry), keccak256(abi.encode(childNode, PARENT_OF_SLOT))), node
        );
    }

    function test_unlinked_subname_is_cleared_once_linked() public {
        _unlink(childNode);
        _unlink(grandchildNode);

        vm.prank(ed);
        dotnsRegistry.clearSubnames(node);

        // Without a recorded parent the walk cannot reach the cleared name yet.
        assertEq(dotnsRegistry.owner(childNode), tiago, "unlinked child still resolves");

        dotnsRegistry.linkSubname(node, keccak256(bytes(CHILD)));
        _assertSubnameGone(childNode, "linked child");

        // Each level is linked on its own: an unlinked subname cannot name its parent, so the
        // backfill has to reach every subname, not only the first level.
        assertEq(dotnsRegistry.owner(grandchildNode), leonardo, "unlinked grandchild");
        dotnsRegistry.linkSubname(childNode, keccak256(bytes(GRANDCHILD)));
        _assertSubnameGone(grandchildNode, "linked grandchild");
    }

    function test_unlinked_subname_linked_before_a_clear_is_cleared_by_it() public {
        _unlink(childNode);
        dotnsRegistry.linkSubname(node, keccak256(bytes(CHILD)));
        _assertTreeIntact();

        _release();

        _assertSubnameGone(childNode, "child");
        _assertSubnameGone(grandchildNode, "grandchild");
    }

    function test_revert_linkSubname_where_no_subname_exists() public {
        bytes32 labelhash = keccak256("nobody");
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistry.SubnameNotFound.selector, _namehash(node, labelhash)
            )
        );
        dotnsRegistry.linkSubname(node, labelhash);
    }

    function test_revert_linkSubname_on_a_tokenised_name() public {
        bytes32 labelhash = keccak256(bytes(LABEL));
        vm.expectRevert(abi.encodeWithSelector(IDotnsRegistry.SubnameNotFound.selector, node));
        dotnsRegistry.linkSubname(_tldNode(), labelhash);
    }

    function test_linkSubname_on_a_linked_subname_changes_nothing() public {
        vm.recordLogs();
        dotnsRegistry.linkSubname(node, keccak256(bytes(CHILD)));
        assertEq(vm.getRecordedLogs().length, 0, "no SubnameLinked for a subname already linked");
        assertEq(dotnsRegistry.parentOf(childNode), node);
    }

    function test_linkSubname_emits_when_it_links() public {
        _unlink(childNode);
        vm.expectEmit(true, true, false, true, address(dotnsRegistry));
        emit IDotnsRegistry.SubnameLinked(childNode, node);
        dotnsRegistry.linkSubname(node, keccak256(bytes(CHILD)));
    }

    function test_a_write_through_the_parent_links_an_unlinked_subname() public {
        _unlink(childNode);
        vm.prank(ed);
        dotnsRegistry.clearSubnames(node);
        assertEq(dotnsRegistry.owner(childNode), tiago, "unlinked child still resolves");

        // Reassigning it through its parent links it first, so it is seen as cleared and is
        // created again from nothing.
        _createSubname(node, CHILD, LABEL, leonardo, ed);

        assertEq(dotnsRegistry.parentOf(childNode), node);
        assertEq(dotnsRegistry.owner(childNode), leonardo);
        _assertRecordsUnset(childNode, "child created again");
    }

    function test_records_written_before_any_clear_stay_readable() public view {
        // Every node starts at record version zero, which is also the stamp of a record written
        // while its node was never cleared, so such a record needs no migrating to stay readable.
        (bool live, uint64 version) = dotnsRegistry.recordVersion(node);
        assertTrue(live);
        assertEq(version, 0);
        _assertTreeIntact();
    }

    // depth

    /// @dev Builds a chain of subnames under the name, `levels` deep, each owned by `ed`, and
    ///      returns the deepest node and its parent path.
    function _chain(uint256 levels) internal returns (bytes32 deepest, string memory deepestPath) {
        bytes32 parentNode = node;
        string memory parentPath = LABEL;
        for (uint256 i; i < levels; ++i) {
            parentNode = _createSubname(parentNode, "l", parentPath, ed, ed);
            deepestPath = parentPath;
            parentPath = string.concat("l.", parentPath);
        }
        deepest = parentNode;
    }

    function test_subname_at_the_maximum_depth_is_created_and_cleared_from_the_top() public {
        uint256 maxDepth = dotnsRegistry.MAX_SUBNAME_DEPTH();
        (bytes32 deepest,) = _chain(maxDepth);
        assertEq(dotnsRegistry.owner(deepest), ed);

        vm.prank(ed);
        dotnsRegistry.clearSubnames(node);

        assertEq(dotnsRegistry.owner(deepest), address(0), "the deepest subname is cleared too");
    }

    function test_revert_subname_one_level_past_the_maximum_depth() public {
        uint256 maxDepth = dotnsRegistry.MAX_SUBNAME_DEPTH();
        (bytes32 deepest, string memory deepestPath) = _chain(maxDepth);

        vm.prank(ed);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistry.SubnameTooDeep.selector, maxDepth + 1, maxDepth)
        );
        dotnsRegistry.setSubnodeOwner(
            IDotnsRegistry.SubnodeRecord({
                parentNode: deepest,
                subLabel: "l",
                parentLabel: string.concat("l.", deepestPath),
                owner: ed,
                persist: true
            })
        );
    }

    function test_parentOf_reports_the_recorded_parent() public view {
        assertEq(dotnsRegistry.parentOf(childNode), node);
        assertEq(dotnsRegistry.parentOf(grandchildNode), childNode);
        assertEq(dotnsRegistry.parentOf(node), bytes32(0), "a tokenised name has no parent");
    }

    // names that entered custody without being cleared, and names with no registry record

    /// @dev Storage slot of `DotnsRegistry.records`.
    uint256 internal constant RECORDS_SLOT = 0;

    /// @dev Storage slot of `DotnsRegistry._versions`.
    uint256 internal constant VERSIONS_SLOT = 2;

    /// @dev Releases the name while the registry reports no record for it, which makes release
    ///      skip the clear, the way an escrow that did not clear on release left it.
    function _releaseWithoutClearing() internal {
        vm.mockCall(
            address(dotnsRegistry),
            abi.encodeCall(IDotnsRegistry.recordExists, (node)),
            abi.encode(false)
        );
        _release();
        // Answer as the registry would from here on. `clearMockedCalls` would also drop the
        // personhood mocks the base suite relies on for later registrations.
        vm.mockCall(
            address(dotnsRegistry),
            abi.encodeCall(IDotnsRegistry.recordExists, (node)),
            abi.encode(true)
        );
        _assertRecordsSet(node, "uncleared name in custody");
        assertEq(dotnsRegistry.owner(childNode), tiago, "uncleared subname in custody");
    }

    function test_version_slot_constant_points_at_the_versions_mapping() public {
        _release();
        assertTrue(
            vm.load(address(dotnsRegistry), keccak256(abi.encode(node, VERSIONS_SLOT)))
                != bytes32(0)
        );
    }

    function test_only_release_clears_redeem_hands_back_what_custody_holds() public {
        _releaseWithoutClearing();

        vm.prank(ed);
        dotnsNameEscrow.redeem(tokenId);

        // Nothing clears on the way out, which is why names already in custody at the upgrade
        // are cleared by `clearCustodyOnUpgrade` before anyone can redeem them.
        _assertRecordsSet(node, "name");
    }

    function test_clearCustodyOnUpgrade_clears_every_name_in_custody_as_the_upgrade_call() public {
        _releaseWithoutClearing();

        // A second name in custody, released with no registry record, which the upgrade call
        // skips rather than failing on.
        string memory other = "othernameheld";
        uint256 otherToken = uint256(_register(other, leonardo, IPopRules.PopStatus.NoStatus));
        bytes32 recordSlot = keccak256(abi.encode(bytes32(otherToken), RECORDS_SLOT));
        vm.store(address(dotnsRegistry), recordSlot, bytes32(0));
        vm.store(address(dotnsRegistry), bytes32(uint256(recordSlot) + 1), bytes32(0));
        vm.startPrank(leonardo);
        dotnsRegistrar.approve(address(dotnsNameEscrow), otherToken);
        dotnsNameEscrow.release(otherToken);
        vm.stopPrank();
        assertEq(dotnsNameEscrow.releasedTokenCount(), 2);

        DotnsNameEscrow implementation = new DotnsNameEscrow();
        vm.prank(owner);
        dotnsNameEscrow.upgradeToAndCall(
            address(implementation), abi.encodeCall(DotnsNameEscrow.clearCustodyOnUpgrade, ())
        );

        _assertRecordsUnset(node, "name");
        _assertSubnameGone(childNode, "child");
        _assertSubnameGone(grandchildNode, "grandchild");

        // Redeem and reclaim hand back what the upgrade call cleared.
        vm.prank(ed);
        dotnsNameEscrow.redeem(tokenId);
        _assertRecordsUnset(node, "redeemed name");

        vm.warp(dotnsNameEscrow.getReleasePosition(otherToken).redeemableUntil);
        _register(other, tiago, IPopRules.PopStatus.NoStatus);
        assertEq(dotnsRegistrar.ownerOf(otherToken), tiago);
    }

    function test_clearCustodyOnUpgrade_clears_lazily_and_deletes_nothing() public {
        _releaseWithoutClearing();

        vm.prank(owner);
        dotnsNameEscrow.clearCustodyOnUpgrade();

        // The deposit for these slots was paid by the holder; deleting them here would release it
        // to the signer of this call instead.
        assertTrue(vm.load(address(dotnsResolver), _addressSlot(node)) != bytes32(0));
        assertTrue(vm.load(address(dotnsContentResolver), _contenthashSlot(node)) != bytes32(0));
    }

    function test_revert_clearCustodyOnUpgrade_a_second_time() public {
        vm.prank(owner);
        dotnsNameEscrow.clearCustodyOnUpgrade();

        vm.prank(owner);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        dotnsNameEscrow.clearCustodyOnUpgrade();
    }

    function test_revert_clearCustodyOnUpgrade_from_anyone_but_the_owner() public {
        vm.prank(leonardo);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, leonardo)
        );
        dotnsNameEscrow.clearCustodyOnUpgrade();
    }

    // storage that a delete actually frees

    /// @dev Storage slots of the resolver mappings, checked by
    ///      `test_resolver_slot_constants_point_at_the_record_mappings`.
    uint256 internal constant ADDRESSES_SLOT = 51;
    uint256 internal constant ADDRESS_VERSIONS_SLOT = 52;
    uint256 internal constant CONTENTHASHES_SLOT = 0;
    uint256 internal constant TEXT_RECORDS_SLOT = 1;
    uint256 internal constant CONTENTHASH_VERSIONS_SLOT = 54;
    uint256 internal constant TEXT_VERSIONS_SLOT = 55;

    function _addressSlot(bytes32 target) internal pure returns (bytes32) {
        return keccak256(abi.encode(target, ADDRESSES_SLOT));
    }

    function _addressStampSlot(bytes32 target) internal pure returns (bytes32) {
        return keccak256(abi.encode(target, ADDRESS_VERSIONS_SLOT));
    }

    function _contenthashSlot(bytes32 target) internal pure returns (bytes32) {
        return keccak256(abi.encode(target, CONTENTHASHES_SLOT));
    }

    function _contenthashStampSlot(bytes32 target) internal pure returns (bytes32) {
        return keccak256(abi.encode(target, CONTENTHASH_VERSIONS_SLOT));
    }

    function _textSlot(bytes32 target, string memory key) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(key, keccak256(abi.encode(target, TEXT_RECORDS_SLOT))));
    }

    function _textStampSlot(bytes32 target, string memory key) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(key, keccak256(abi.encode(target, TEXT_VERSIONS_SLOT))));
    }

    function _assertZero(address target, bytes32 slot, string memory what) internal view {
        assertEq(vm.load(target, slot), bytes32(0), what);
    }

    /// @dev Writes every record type under a non-zero record version, so both the values and
    ///      their stamps occupy storage.
    function _writeStampedRecords() internal {
        vm.prank(ed);
        dotnsRegistry.clearRecords(node);
        _writeRecords(node, ed);
    }

    function test_resolver_slot_constants_point_at_the_record_mappings() public {
        _writeStampedRecords();
        assertTrue(vm.load(address(dotnsResolver), _addressSlot(node)) != bytes32(0));
        assertTrue(vm.load(address(dotnsResolver), _addressStampSlot(node)) != bytes32(0));
        assertTrue(vm.load(address(dotnsContentResolver), _contenthashSlot(node)) != bytes32(0));
        assertTrue(
            vm.load(address(dotnsContentResolver), _contenthashStampSlot(node)) != bytes32(0)
        );
        assertTrue(vm.load(address(dotnsContentResolver), _textSlot(node, TEXT_KEY)) != bytes32(0));
        assertTrue(
            vm.load(address(dotnsContentResolver), _textStampSlot(node, TEXT_KEY)) != bytes32(0)
        );
    }

    function test_writing_empty_deletes_each_record_and_its_stamp() public {
        _writeStampedRecords();

        vm.startPrank(ed);
        dotnsResolver.setAddress(node, address(0));
        dotnsContentResolver.setContenthash(node, "");
        dotnsContentResolver.setText(node, TEXT_KEY, "");
        vm.stopPrank();

        _assertRecordsUnset(node, "deleted");
        _assertZero(address(dotnsResolver), _addressSlot(node), "address");
        _assertZero(address(dotnsResolver), _addressStampSlot(node), "address stamp");
        _assertZero(address(dotnsContentResolver), _contenthashSlot(node), "content hash");
        _assertZero(address(dotnsContentResolver), _contenthashStampSlot(node), "hash stamp");
        _assertZero(address(dotnsContentResolver), _textSlot(node, TEXT_KEY), "text");
        _assertZero(address(dotnsContentResolver), _textStampSlot(node, TEXT_KEY), "text stamp");
    }

    function test_deleting_a_text_record_emits_both_text_events() public {
        vm.recordLogs();
        vm.prank(ed);
        dotnsContentResolver.setText(node, TEXT_KEY, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].topics[0], IDotnsContentResolver.TextUpdated.selector);
        assertEq(logs[1].topics[0], IDotnsContentResolver.TextChanged.selector);
    }

    function test_deleting_deepest_first_frees_every_subname_record() public {
        vm.prank(tiago);
        dotnsRegistry.deleteSubname(childNode, keccak256(bytes(GRANDCHILD)));
        vm.prank(ed);
        dotnsRegistry.deleteSubname(node, keccak256(bytes(CHILD)));

        bytes32[2] memory subnodes = [childNode, grandchildNode];
        for (uint256 i; i < 2; ++i) {
            bytes32 base = keccak256(abi.encode(subnodes[i], RECORDS_SLOT));
            _assertZero(address(dotnsRegistry), base, "record owner slot");
            _assertZero(address(dotnsRegistry), bytes32(uint256(base) + 1), "record resolver slot");
            _assertZero(
                address(dotnsRegistry),
                keccak256(abi.encode(subnodes[i], PARENT_OF_SLOT)),
                "parent link"
            );
        }
    }

    function test_writing_empty_frees_a_text_key_a_clear_left_behind() public {
        vm.prank(ed);
        dotnsRegistry.clearRecords(node);
        assertTrue(vm.load(address(dotnsContentResolver), _textSlot(node, TEXT_KEY)) != bytes32(0));

        vm.prank(ed);
        dotnsContentResolver.setText(node, TEXT_KEY, "");

        _assertZero(address(dotnsContentResolver), _textSlot(node, TEXT_KEY), "stale text");
    }

    function test_release_deletes_address_and_content_hash_and_hides_text() public {
        _writeStampedRecords();
        _release();

        _assertZero(address(dotnsResolver), _addressSlot(node), "address");
        _assertZero(address(dotnsResolver), _addressStampSlot(node), "address stamp");
        _assertZero(address(dotnsContentResolver), _contenthashSlot(node), "content hash");
        _assertZero(address(dotnsContentResolver), _contenthashStampSlot(node), "hash stamp");

        // Text keys cannot be listed, so release hides them and their storage stays.
        assertEq(dotnsContentResolver.text(node, TEXT_KEY), "");
        assertTrue(vm.load(address(dotnsContentResolver), _textSlot(node, TEXT_KEY)) != bytes32(0));
    }

    function test_deleteSubname_zeroes_the_record_and_the_parent_link() public {
        vm.prank(ed);
        dotnsRegistry.deleteSubname(node, keccak256(bytes(CHILD)));

        bytes32 base = keccak256(abi.encode(childNode, RECORDS_SLOT));
        _assertZero(address(dotnsRegistry), base, "record owner slot");
        _assertZero(address(dotnsRegistry), bytes32(uint256(base) + 1), "record resolver slot");
        _assertZero(
            address(dotnsRegistry), keccak256(abi.encode(childNode, PARENT_OF_SLOT)), "parent link"
        );
        assertTrue(
            vm.load(address(dotnsRegistry), keccak256(abi.encode(childNode, VERSIONS_SLOT)))
                != bytes32(0),
            "the versions stay, so a subname created here again starts empty"
        );
    }

    function test_release_redeem_and_reclaim_still_work_for_a_name_with_no_registry_record()
        public
    {
        // A token whose registry record is missing: owner, resolver and the exists flag zeroed.
        bytes32 base = keccak256(abi.encode(node, RECORDS_SLOT));
        vm.store(address(dotnsRegistry), base, bytes32(0));
        vm.store(address(dotnsRegistry), bytes32(uint256(base) + 1), bytes32(0));
        assertFalse(dotnsRegistry.recordExists(node));

        _release();
        assertEq(dotnsRegistrar.ownerOf(tokenId), address(dotnsNameEscrow));

        vm.prank(ed);
        dotnsNameEscrow.redeem(tokenId);
        assertEq(dotnsRegistrar.ownerOf(tokenId), ed);

        _release();
        vm.warp(dotnsNameEscrow.getReleasePosition(tokenId).redeemableUntil);
        _register(LABEL, leonardo, IPopRules.PopStatus.NoStatus);
        assertEq(dotnsRegistrar.ownerOf(tokenId), leonardo);
    }
}
