// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {DotnsNameWhitelist} from "../../../contracts/whitelist/DotnsNameWhitelist.sol";
import {IDotnsNameWhitelist} from "../../../contracts/whitelist/IDotnsNameWhitelist.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @title DotnsNameWhitelist unit tests
/// @notice Covers claiming, competing claims and resolution, the request window, reservation, the
///         controller-only consume hook, and the review views.
/// @dev No test here pranks a caller for a governance action. The admin surface is Root-only and
///      the gates read no `msg.sender`, so who submits is irrelevant and a prank would imply an
///      owner authority that does not exist. The negative cases mock a signed origin instead and
///      assert `NotGovernance`.
contract DotnsNameWhitelistTests is BaseDotns {
    DotnsNameWhitelist internal whitelist;

    string internal constant REASON = "the rightful owner of this name";

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);
        whitelist = DotnsNameWhitelist(
            Upgrades.deployUUPSProxy(
                "DotnsNameWhitelist.sol:DotnsNameWhitelist",
                abi.encodeCall(
                    DotnsNameWhitelist.initialize,
                    (IDotnsProtocolRegistry(address(protocolRegistry)))
                )
            )
        );
        vm.stopPrank();

        // The whitelist's admin surface is Root-only, so the suite runs under a Root origin and
        // the unauthorised-caller tests flip it back with `_mockOriginIsRoot(false)`.
        _mockOriginIsRoot(true);
        whitelist.setWindow(0, 30 days);

        vm.label(address(whitelist), "DotnsNameWhitelist");
    }

    function _request(address user, string memory label) internal {
        vm.prank(user);
        whitelist.requestName(label, REASON, user);
    }

    function _grant(address user, string memory label) internal {
        whitelist.grantName(label, user);
    }

    function test_requestName_records_and_emits() public {
        bytes32 node = _nodeOf(BASE_LABEL_A);
        vm.expectEmit(true, true, false, true, address(whitelist));
        emit IDotnsNameWhitelist.NameRequested(node, ed, BASE_LABEL_A, REASON);
        _request(ed, BASE_LABEL_A);

        IDotnsNameWhitelist.Claim memory claim = whitelist.claimOf(BASE_LABEL_A, ed);
        assertEq(uint256(claim.status), uint256(IDotnsNameWhitelist.ClaimStatus.Requested));
        assertEq(claim.user, ed);
        assertEq(claim.submitter, ed);
        assertEq(claim.requestedAt, uint64(block.timestamp));
        assertEq(claim.reason, REASON);
        assertEq(whitelist.claimantCount(BASE_LABEL_A), 1);
        assertEq(
            uint256(whitelist.statusOf(BASE_LABEL_A)), uint256(IDotnsNameWhitelist.NameStatus.Open)
        );
        assertEq(whitelist.granteeOf(BASE_LABEL_A), address(0));
    }

    function test_requestName_allows_competing_claims() public {
        _request(ed, BASE_LABEL_A);
        vm.prank(tiago);
        whitelist.requestName(BASE_LABEL_A, "also me", tiago);
        assertEq(whitelist.claimantCount(BASE_LABEL_A), 2);
    }

    function test_requestName_submitter_may_differ_from_user() public {
        vm.prank(tiago);
        whitelist.requestName(BASE_LABEL_A, REASON, ed);
        assertEq(whitelist.claimOf(BASE_LABEL_A, ed).user, ed);
        assertEq(whitelist.claimantCount(BASE_LABEL_A), 1);
    }

    function test_requestName_reverts_for_same_user_twice() public {
        _request(ed, BASE_LABEL_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsNameWhitelist.AlreadyClaimed.selector, _nodeOf(BASE_LABEL_A), ed
            )
        );
        _request(ed, BASE_LABEL_A);
    }

    function test_requestName_reverts_for_zero_user() public {
        vm.expectRevert(IDotnsNameWhitelist.ZeroUser.selector);
        vm.prank(ed);
        whitelist.requestName(BASE_LABEL_A, REASON, address(0));
    }

    function test_requestName_reverts_for_reason_too_long() public {
        string memory long = string(new bytes(whitelist.maxReasonBytes() + 1));
        vm.expectRevert(IDotnsNameWhitelist.ReasonTooLong.selector);
        vm.prank(ed);
        whitelist.requestName(BASE_LABEL_A, long, ed);
    }

    function test_requestName_reverts_for_non_canonical_label() public {
        vm.expectRevert(IDotnsNameWhitelist.InvalidLabel.selector);
        vm.prank(ed);
        whitelist.requestName("bad.label", REASON, ed);
    }

    function test_requestName_reverts_when_reserved() public {
        whitelist.setReserved(BASE_LABEL_A, true);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameWhitelist.NameNotOpen.selector, _nodeOf(BASE_LABEL_A))
        );
        _request(ed, BASE_LABEL_A);
    }

    function test_requestName_reverts_outside_window() public {
        whitelist.setWindow(1 days, 1 days);
        vm.expectRevert(IDotnsNameWhitelist.WindowClosed.selector);
        _request(ed, BASE_LABEL_A);
    }

    function test_accept_picks_winner_and_rejects_losers() public {
        _request(ed, BASE_LABEL_A);
        vm.prank(tiago);
        whitelist.requestName(BASE_LABEL_A, "also me", tiago);
        bytes32 node = _nodeOf(BASE_LABEL_A);

        vm.expectEmit(true, true, false, true, address(whitelist));
        emit IDotnsNameWhitelist.NameAccepted(node, ed, BASE_LABEL_A);
        vm.expectEmit(true, true, false, true, address(whitelist));
        emit IDotnsNameWhitelist.NameRejected(node, tiago, BASE_LABEL_A);
        whitelist.accept(BASE_LABEL_A, ed);

        assertEq(whitelist.granteeOf(BASE_LABEL_A), ed);
        assertTrue(whitelist.isGrantedTo(BASE_LABEL_A, ed));
        assertEq(
            uint256(whitelist.statusOf(BASE_LABEL_A)),
            uint256(IDotnsNameWhitelist.NameStatus.Claimed)
        );
        assertEq(whitelist.claimantCount(BASE_LABEL_A), 0);
        assertEq(
            uint256(whitelist.claimOf(BASE_LABEL_A, tiago).status),
            uint256(IDotnsNameWhitelist.ClaimStatus.None)
        );
    }

    function test_accept_reverts_when_not_requested() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsNameWhitelist.NotRequested.selector, _nodeOf(BASE_LABEL_A), ed
            )
        );
        whitelist.accept(BASE_LABEL_A, ed);
    }

    function test_accept_reverts_for_a_signed_caller() public {
        _request(ed, BASE_LABEL_A);
        _mockOriginIsRoot(false);
        vm.expectRevert(IDotnsNameWhitelist.NotGovernance.selector);
        vm.prank(tiago);
        whitelist.accept(BASE_LABEL_A, ed);
    }

    function test_reject_clears_single_claim() public {
        _request(ed, BASE_LABEL_A);
        bytes32 node = _nodeOf(BASE_LABEL_A);
        vm.expectEmit(true, true, false, true, address(whitelist));
        emit IDotnsNameWhitelist.NameRejected(node, ed, BASE_LABEL_A);
        whitelist.reject(BASE_LABEL_A, ed);

        assertEq(whitelist.claimantCount(BASE_LABEL_A), 0);
        assertEq(whitelist.nameCount(), 0);
        assertEq(
            uint256(whitelist.statusOf(BASE_LABEL_A)), uint256(IDotnsNameWhitelist.NameStatus.Open)
        );
    }

    function test_reject_self_filed_is_sticky() public {
        _request(ed, BASE_LABEL_A);
        whitelist.reject(BASE_LABEL_A, ed);

        assertEq(
            uint256(whitelist.claimOf(BASE_LABEL_A, ed).status),
            uint256(IDotnsNameWhitelist.ClaimStatus.Rejected)
        );
        assertEq(whitelist.claimantCount(BASE_LABEL_A), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsNameWhitelist.AlreadyClaimed.selector, _nodeOf(BASE_LABEL_A), ed
            )
        );
        _request(ed, BASE_LABEL_A);
    }

    function test_reject_on_behalf_does_not_bind() public {
        vm.prank(tiago);
        whitelist.requestName(BASE_LABEL_A, REASON, ed);
        assertEq(whitelist.claimOf(BASE_LABEL_A, ed).submitter, tiago);

        whitelist.reject(BASE_LABEL_A, ed);
        assertEq(
            uint256(whitelist.claimOf(BASE_LABEL_A, ed).status),
            uint256(IDotnsNameWhitelist.ClaimStatus.None)
        );

        _request(ed, BASE_LABEL_A);
        assertEq(
            uint256(whitelist.claimOf(BASE_LABEL_A, ed).status),
            uint256(IDotnsNameWhitelist.ClaimStatus.Requested)
        );
    }

    /// @dev Exhaustive over the governance surface rather than a sample. Every `onlyGovernance`
    /// entry point must refuse a signed origin; a per-method test set would silently miss any
    /// method that later lost its gate, which is how the four spot checks below left `reject`,
    /// `grantNames`, `setWindow` and two caps uncovered.
    function test_every_admin_entry_point_requires_root() public {
        _mockOriginIsRoot(false);

        string[] memory batch = new string[](1);
        batch[0] = BASE_LABEL_B;

        bytes[] memory calls = new bytes[](10);
        calls[0] = abi.encodeCall(IDotnsNameWhitelist.grantName, (BASE_LABEL_A, ed));
        calls[1] = abi.encodeCall(IDotnsNameWhitelist.grantNames, (batch, ed));
        calls[2] = abi.encodeCall(IDotnsNameWhitelist.accept, (BASE_LABEL_A, ed));
        calls[3] = abi.encodeCall(IDotnsNameWhitelist.reject, (BASE_LABEL_A, ed));
        calls[4] = abi.encodeCall(IDotnsNameWhitelist.revokeName, (BASE_LABEL_A));
        calls[5] = abi.encodeCall(IDotnsNameWhitelist.setReserved, (BASE_LABEL_A, true));
        calls[6] = abi.encodeCall(IDotnsNameWhitelist.setWindow, (0, 1 days));
        calls[7] = abi.encodeCall(IDotnsNameWhitelist.setMaxClaimants, (4));
        calls[8] = abi.encodeCall(IDotnsNameWhitelist.setMaxReasonBytes, (64));
        calls[9] = abi.encodeCall(IDotnsNameWhitelist.setMaxGrantBatch, (4));

        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(ed);
            (bool ok, bytes memory ret) = address(whitelist).call(calls[i]);
            assertFalse(ok, "a signed caller reached a governance entry point");
            // Truncating to the leading four bytes is the point: `ret` is revert data and the
            // selector is its first word.
            assertEq(
                // forge-lint: disable-next-line(unsafe-typecast)
                bytes4(ret),
                IDotnsNameWhitelist.NotGovernance.selector,
                "governance gate reverted with something other than NotGovernance"
            );
        }
    }

    function test_grantName_direct() public {
        bytes32 node = _nodeOf(BASE_LABEL_A);
        vm.expectEmit(true, true, false, true, address(whitelist));
        emit IDotnsNameWhitelist.NameAccepted(node, ed, BASE_LABEL_A);
        whitelist.grantName(BASE_LABEL_A, ed);

        assertEq(whitelist.granteeOf(BASE_LABEL_A), ed);
        assertEq(
            uint256(whitelist.statusOf(BASE_LABEL_A)),
            uint256(IDotnsNameWhitelist.NameStatus.Claimed)
        );
    }

    function test_grantName_clears_pending_claims() public {
        _request(tiago, BASE_LABEL_A);
        bytes32 node = _nodeOf(BASE_LABEL_A);
        vm.expectEmit(true, true, false, true, address(whitelist));
        emit IDotnsNameWhitelist.NameRejected(node, tiago, BASE_LABEL_A);
        whitelist.grantName(BASE_LABEL_A, ed);
        assertEq(whitelist.granteeOf(BASE_LABEL_A), ed);
        assertEq(whitelist.claimantCount(BASE_LABEL_A), 0);
    }

    function test_grantName_reverts_for_zero_user() public {
        vm.expectRevert(IDotnsNameWhitelist.ZeroUser.selector);
        whitelist.grantName(BASE_LABEL_A, address(0));
    }

    function test_grantName_reverts_when_not_open() public {
        whitelist.grantName(BASE_LABEL_A, ed);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameWhitelist.NameNotOpen.selector, _nodeOf(BASE_LABEL_A))
        );
        whitelist.grantName(BASE_LABEL_A, tiago);
    }

    function test_grantNames_batch() public {
        string[] memory labels = new string[](2);
        labels[0] = BASE_LABEL_A;
        labels[1] = BASE_LABEL_B;
        whitelist.grantNames(labels, ed);
        assertEq(whitelist.granteeOf(BASE_LABEL_A), ed);
        assertEq(whitelist.granteeOf(BASE_LABEL_B), ed);
        assertEq(whitelist.nameCount(), 2);
    }

    function test_grantNames_reverts_above_batch_limit() public {
        uint256 aboveBatch = uint256(whitelist.maxGrantBatch()) + 1;
        string[] memory labels = new string[](aboveBatch);
        vm.expectRevert(IDotnsNameWhitelist.TooManyLabels.selector);
        whitelist.grantNames(labels, ed);
    }

    function test_revokeName_resets_claimed() public {
        _grant(ed, BASE_LABEL_A);
        bytes32 node = _nodeOf(BASE_LABEL_A);
        vm.expectEmit(true, true, false, true, address(whitelist));
        emit IDotnsNameWhitelist.NameRevoked(node, ed, BASE_LABEL_A);
        whitelist.revokeName(BASE_LABEL_A);
        assertEq(
            uint256(whitelist.statusOf(BASE_LABEL_A)), uint256(IDotnsNameWhitelist.NameStatus.Open)
        );
        assertEq(whitelist.nameCount(), 0);
    }

    /// @dev Not even the owner revokes: the admin surface is Root-only.
    function test_revokeName_rejects_the_owner() public {
        _grant(ed, BASE_LABEL_A);
        _mockOriginIsRoot(false);
        vm.expectRevert(IDotnsNameWhitelist.NotGovernance.selector);
        whitelist.revokeName(BASE_LABEL_A);
    }

    function test_revokeName_reverts_when_nothing_to_revoke() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsNameWhitelist.NothingToRevoke.selector, _nodeOf(BASE_LABEL_A)
            )
        );
        whitelist.revokeName(BASE_LABEL_A);
    }

    function test_revokeName_clears_open_name_with_claims() public {
        _request(ed, BASE_LABEL_A);
        _request(tiago, BASE_LABEL_A);
        whitelist.revokeName(BASE_LABEL_A);
        assertEq(whitelist.claimantCount(BASE_LABEL_A), 0);
        assertEq(whitelist.nameCount(), 0);
    }

    function test_revokeName_reverts_on_reserved_name() public {
        whitelist.setReserved(BASE_LABEL_A, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsNameWhitelist.NothingToRevoke.selector, _nodeOf(BASE_LABEL_A)
            )
        );
        whitelist.revokeName(BASE_LABEL_A);
        assertTrue(whitelist.isReserved(BASE_LABEL_A));
    }

    function test_setReserved_reserve_and_release() public {
        bytes32 node = _nodeOf(BASE_LABEL_A);
        vm.expectEmit(true, false, false, true, address(whitelist));
        emit IDotnsNameWhitelist.NameReserved(node, BASE_LABEL_A);
        whitelist.setReserved(BASE_LABEL_A, true);
        assertTrue(whitelist.isReserved(BASE_LABEL_A));

        vm.expectEmit(true, false, false, true, address(whitelist));
        emit IDotnsNameWhitelist.NameUnreserved(node, BASE_LABEL_A);
        whitelist.setReserved(BASE_LABEL_A, false);
        assertFalse(whitelist.isReserved(BASE_LABEL_A));
        assertEq(whitelist.nameCount(), 0);
    }

    function test_setReserved_clears_pending_claims() public {
        bytes32 node = _nodeOf(BASE_LABEL_A);
        _request(ed, BASE_LABEL_A);
        vm.expectEmit(true, true, false, true, address(whitelist));
        emit IDotnsNameWhitelist.NameRejected(node, ed, BASE_LABEL_A);
        whitelist.setReserved(BASE_LABEL_A, true);

        assertTrue(whitelist.isReserved(BASE_LABEL_A));
        assertEq(whitelist.claimantCount(BASE_LABEL_A), 0);
        assertEq(
            uint256(whitelist.claimOf(BASE_LABEL_A, ed).status),
            uint256(IDotnsNameWhitelist.ClaimStatus.None)
        );
    }

    function test_setReserved_release_reverts_when_not_reserved() public {
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameWhitelist.NotReserved.selector, _nodeOf(BASE_LABEL_A))
        );
        whitelist.setReserved(BASE_LABEL_A, false);
    }

    function test_setReserved_reverts_for_a_signed_caller() public {
        _mockOriginIsRoot(false);
        vm.expectRevert(IDotnsNameWhitelist.NotGovernance.selector);
        vm.prank(tiago);
        whitelist.setReserved(BASE_LABEL_A, true);
    }

    function test_consume_by_public_controller() public {
        _grant(ed, BASE_LABEL_A);
        bytes32 node = _nodeOf(BASE_LABEL_A);
        vm.expectEmit(true, true, false, true, address(whitelist));
        emit IDotnsNameWhitelist.NameConsumed(node, ed, BASE_LABEL_A);
        vm.prank(address(dotnsRegistrarController));
        whitelist.consume(BASE_LABEL_A, ed);
        assertEq(
            uint256(whitelist.statusOf(BASE_LABEL_A)), uint256(IDotnsNameWhitelist.NameStatus.Open)
        );
        assertEq(whitelist.nameCount(), 0);
    }

    function test_consume_by_pop_controller() public {
        _grant(ed, BASE_LABEL_A);
        vm.prank(address(dotnsPopController));
        whitelist.consume(BASE_LABEL_A, ed);
        assertEq(whitelist.granteeOf(BASE_LABEL_A), address(0));
    }

    function test_consume_reverts_for_non_controller() public {
        _grant(ed, BASE_LABEL_A);
        vm.expectRevert(abi.encodeWithSelector(IDotnsNameWhitelist.NotController.selector, ed));
        vm.prank(ed);
        whitelist.consume(BASE_LABEL_A, ed);
    }

    function test_consume_reverts_for_wrong_registrant() public {
        _grant(ed, BASE_LABEL_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsNameWhitelist.NotWinner.selector, tiago, _nodeOf(BASE_LABEL_A)
            )
        );
        vm.prank(address(dotnsRegistrarController));
        whitelist.consume(BASE_LABEL_A, tiago);
    }

    function test_full_lifecycle_request_accept_consume() public {
        _request(ed, BASE_LABEL_A);
        whitelist.accept(BASE_LABEL_A, ed);
        assertTrue(whitelist.isGrantedTo(BASE_LABEL_A, ed));
        vm.prank(address(dotnsRegistrarController));
        whitelist.consume(BASE_LABEL_A, ed);
        assertEq(whitelist.nameCount(), 0);
        assertEq(
            uint256(whitelist.statusOf(BASE_LABEL_A)), uint256(IDotnsNameWhitelist.NameStatus.Open)
        );
    }

    function test_setWindow_sets_and_emits() public {
        uint64 openAt = uint64(block.timestamp) + 1 days;
        uint64 closeAt = openAt + 5 days;
        vm.expectEmit(false, false, false, true, address(whitelist));
        emit IDotnsNameWhitelist.WindowSet(openAt, closeAt);
        whitelist.setWindow(1 days, 5 days);
        (uint64 gotOpen, uint64 gotClose) = whitelist.window();
        assertEq(gotOpen, openAt);
        assertEq(gotClose, closeAt);
    }

    function test_isWindowOpen_tracks_the_window() public {
        uint64 openAt = uint64(block.timestamp) + 1 days;
        uint64 closeAt = openAt + 1 days;
        whitelist.setWindow(1 days, 1 days);
        assertFalse(whitelist.isWindowOpen());
        vm.warp(openAt);
        assertTrue(whitelist.isWindowOpen());
        vm.warp(closeAt);
        assertFalse(whitelist.isWindowOpen());
    }

    function test_setWindow_reverts_for_zero_duration() public {
        vm.expectRevert(IDotnsNameWhitelist.BadWindow.selector);
        whitelist.setWindow(1 days, 0);
    }

    function test_initialize_reverts_on_second_call() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        whitelist.initialize(IDotnsProtocolRegistry(address(protocolRegistry)));
    }

    function test_claims_pagination() public {
        _request(ed, BASE_LABEL_A);
        vm.prank(tiago);
        whitelist.requestName(BASE_LABEL_A, "b", tiago);
        vm.prank(leonardo);
        whitelist.requestName(BASE_LABEL_A, "c", leonardo);

        assertEq(whitelist.claimantCount(BASE_LABEL_A), 3);
        assertEq(whitelist.claims(BASE_LABEL_A, 3, 10).length, 0);
        assertEq(whitelist.claims(BASE_LABEL_A, 2, 10).length, 1);
        assertEq(whitelist.claims(BASE_LABEL_A, 0, 0).length, 0);
        assertEq(whitelist.claims(BASE_LABEL_A, 0, 100).length, 3);
    }

    function test_names_pagination_lists_active() public {
        vm.startPrank(owner);
        whitelist.grantName(BASE_LABEL_A, ed);
        whitelist.setReserved(BASE_LABEL_B, true);
        vm.stopPrank();

        assertEq(whitelist.nameCount(), 2);
        IDotnsNameWhitelist.NameView[] memory page = whitelist.names(0, 10);
        assertEq(page.length, 2);
    }

    function test_initial_caps_are_the_defaults() public view {
        assertEq(whitelist.maxClaimants(), DotnsConstants.WHITELIST_DEFAULT_MAX_CLAIMANTS);
        assertEq(whitelist.maxReasonBytes(), DotnsConstants.WHITELIST_DEFAULT_MAX_REASON_BYTES);
        assertEq(whitelist.maxGrantBatch(), DotnsConstants.WHITELIST_DEFAULT_MAX_GRANT_BATCH);
    }

    function test_setMaxClaimants_enforced() public {
        vm.expectEmit(false, false, false, true, address(whitelist));
        emit IDotnsNameWhitelist.MaxClaimantsSet(1);
        whitelist.setMaxClaimants(1);
        assertEq(whitelist.maxClaimants(), 1);

        _request(ed, BASE_LABEL_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsNameWhitelist.TooManyClaimants.selector, _nodeOf(BASE_LABEL_A)
            )
        );
        vm.prank(tiago);
        whitelist.requestName(BASE_LABEL_A, REASON, tiago);
    }

    function test_setMaxClaimants_reverts_out_of_range() public {
        uint16 aboveLimit = DotnsConstants.WHITELIST_MAX_CLAIMANTS_LIMIT + 1;

        vm.expectRevert(IDotnsNameWhitelist.MaxClaimantsOutOfRange.selector);
        whitelist.setMaxClaimants(0);

        vm.expectRevert(IDotnsNameWhitelist.MaxClaimantsOutOfRange.selector);
        whitelist.setMaxClaimants(aboveLimit);
    }

    function test_setMaxReasonBytes_enforced() public {
        vm.expectEmit(false, false, false, true, address(whitelist));
        emit IDotnsNameWhitelist.MaxReasonBytesSet(4);
        whitelist.setMaxReasonBytes(4);
        assertEq(whitelist.maxReasonBytes(), 4);

        vm.expectRevert(IDotnsNameWhitelist.ReasonTooLong.selector);
        vm.prank(ed);
        whitelist.requestName(BASE_LABEL_A, "toolong", ed);
    }

    function test_setMaxReasonBytes_reverts_out_of_range() public {
        uint256 aboveLimit = DotnsConstants.WHITELIST_MAX_REASON_LIMIT + 1;

        vm.expectRevert(IDotnsNameWhitelist.MaxReasonBytesOutOfRange.selector);
        whitelist.setMaxReasonBytes(0);

        vm.expectRevert(IDotnsNameWhitelist.MaxReasonBytesOutOfRange.selector);
        whitelist.setMaxReasonBytes(aboveLimit);
    }

    function test_setMaxGrantBatch_enforced() public {
        vm.expectEmit(false, false, false, true, address(whitelist));
        emit IDotnsNameWhitelist.MaxGrantBatchSet(1);
        whitelist.setMaxGrantBatch(1);
        assertEq(whitelist.maxGrantBatch(), 1);

        string[] memory labels = new string[](2);
        labels[0] = BASE_LABEL_A;
        labels[1] = BASE_LABEL_B;
        vm.expectRevert(IDotnsNameWhitelist.TooManyLabels.selector);
        whitelist.grantNames(labels, ed);
    }

    function test_setMaxGrantBatch_reverts_out_of_range() public {
        uint16 aboveLimit = DotnsConstants.WHITELIST_MAX_GRANT_BATCH_LIMIT + 1;

        vm.expectRevert(IDotnsNameWhitelist.MaxGrantBatchOutOfRange.selector);
        whitelist.setMaxGrantBatch(0);

        vm.expectRevert(IDotnsNameWhitelist.MaxGrantBatchOutOfRange.selector);
        whitelist.setMaxGrantBatch(aboveLimit);
    }

    /// @dev Caps are configuration, and configuration is Root-only too: the owner cannot retune.
    function test_setMaxClaimants_reverts_for_a_signed_caller() public {
        _mockOriginIsRoot(false);
        vm.expectRevert(IDotnsNameWhitelist.NotGovernance.selector);
        whitelist.setMaxClaimants(10);
    }

    function test_governance_root_grants_from_any_caller() public {
        // Root has no address, so the gate admits the call regardless of who submits it.
        _mockOriginIsRoot(true);
        vm.prank(leonardo);
        whitelist.grantName(BASE_LABEL_A, ed);
        assertEq(whitelist.granteeOf(BASE_LABEL_A), ed);
    }

    function test_governance_root_reserves_from_any_caller() public {
        _mockOriginIsRoot(true);
        vm.prank(leonardo);
        whitelist.setReserved(BASE_LABEL_A, true);
        assertTrue(whitelist.isReserved(BASE_LABEL_A));
    }

    /// @dev Configuration is Root-only as well, so a referendum retunes the caps.
    function test_governance_root_sets_a_cap_from_any_caller() public {
        _mockOriginIsRoot(true);
        vm.prank(leonardo);
        whitelist.setMaxClaimants(7);
        assertEq(whitelist.maxClaimants(), 7);
    }
}
