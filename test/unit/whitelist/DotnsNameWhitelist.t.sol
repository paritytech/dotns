// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {DotnsNameWhitelist} from "../../../contracts/whitelist/DotnsNameWhitelist.sol";
import {IDotnsNameWhitelist} from "../../../contracts/whitelist/IDotnsNameWhitelist.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ProtocolOwnedUpgradeable} from "../../../contracts/utils/ProtocolOwnedUpgradeable.sol";

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
        // the unauthorised-caller tests flip it back with `_mockCallerIsRoot(false)`.
        _mockCallerIsRoot(true);
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

    /// @dev `registerReserved` never mints a label below the minimum length, so a claim on one
    ///      could never be redeemed.
    function test_requestName_reverts_for_a_label_too_short_to_mint() public {
        vm.expectRevert(IDotnsNameWhitelist.InvalidLabel.selector);
        vm.prank(ed);
        whitelist.requestName("ab", REASON, ed);
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
        _mockCallerIsRoot(false);
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
    function test_every_maintenance_entry_point_requires_root_or_the_maintainer() public {
        _mockCallerIsRoot(false);

        bytes[] memory calls = new bytes[](5);
        calls[0] = abi.encodeCall(IDotnsNameWhitelist.setWindow, (0, 1 days));
        calls[1] = abi.encodeCall(IDotnsNameWhitelist.setMaxClaimants, (4));
        calls[2] = abi.encodeCall(IDotnsNameWhitelist.setMaxReasonBytes, (64));
        calls[3] = abi.encodeCall(IDotnsNameWhitelist.setMaxGrantBatch, (4));
        calls[4] = abi.encodeCall(IDotnsNameWhitelist.setGrantDuration, (7 days));

        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(ed);
            (bool ok, bytes memory ret) = address(whitelist).call(calls[i]);
            assertFalse(ok, "a signed caller reached a maintenance entry point");
            assertEq(
                ret,
                abi.encodeWithSelector(ProtocolOwnedUpgradeable.NotRootOrMaintainer.selector, ed),
                "maintenance gate reverted with something other than NotRootOrMaintainer"
            );
        }
    }

    function test_every_decision_entry_point_requires_root() public {
        _mockCallerIsRoot(false);

        string[] memory batch = new string[](1);
        batch[0] = BASE_LABEL_B;

        // Decisions about who holds a name are Root-only.
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeCall(IDotnsNameWhitelist.grantName, (BASE_LABEL_A, ed));
        calls[1] = abi.encodeCall(IDotnsNameWhitelist.grantNames, (batch, ed));
        calls[2] = abi.encodeCall(IDotnsNameWhitelist.accept, (BASE_LABEL_A, ed));
        calls[3] = abi.encodeCall(IDotnsNameWhitelist.reject, (BASE_LABEL_A, ed));
        calls[4] = abi.encodeCall(IDotnsNameWhitelist.revokeName, (BASE_LABEL_A));
        calls[5] = abi.encodeCall(IDotnsNameWhitelist.setReserved, (BASE_LABEL_A, true));

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

    function test_grantName_reverts_for_a_label_too_short_to_mint() public {
        vm.expectRevert(IDotnsNameWhitelist.InvalidLabel.selector);
        whitelist.grantName("ab", ed);
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
        _mockCallerIsRoot(false);
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
        _mockCallerIsRoot(false);
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

    /// @dev Caps are maintenance values: Root or the maintainer account retunes them, and the
    ///      owner cannot.
    function test_setMaxClaimants_reverts_for_a_signed_caller() public {
        _mockCallerIsRoot(false);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolOwnedUpgradeable.NotRootOrMaintainer.selector, address(this)
            )
        );
        whitelist.setMaxClaimants(10);
    }

    function test_governance_root_grants_from_any_caller() public {
        // Root has no address, so the gate admits the call regardless of who submits it.
        _mockCallerIsRoot(true);
        vm.prank(leonardo);
        whitelist.grantName(BASE_LABEL_A, ed);
        assertEq(whitelist.granteeOf(BASE_LABEL_A), ed);
    }

    function test_governance_root_reserves_from_any_caller() public {
        _mockCallerIsRoot(true);
        vm.prank(leonardo);
        whitelist.setReserved(BASE_LABEL_A, true);
        assertTrue(whitelist.isReserved(BASE_LABEL_A));
    }

    /// @dev Root retunes the caps from any submitter, since Root has no address.
    function test_governance_root_sets_a_cap_from_any_caller() public {
        _mockCallerIsRoot(true);
        vm.prank(leonardo);
        whitelist.setMaxClaimants(7);
        assertEq(whitelist.maxClaimants(), 7);
    }

    // grant expiry

    function test_initial_grant_duration_is_the_default() public view {
        assertEq(whitelist.grantDuration(), DotnsConstants.WHITELIST_DEFAULT_GRANT_DURATION);
    }

    function test_grant_binds_until_its_period_ends() public {
        _grant(ed, BASE_LABEL_A);
        uint64 expiresAt = uint64(block.timestamp) + whitelist.grantDuration();
        assertEq(whitelist.grantExpiresAt(BASE_LABEL_A), expiresAt);

        vm.warp(expiresAt - 1);
        assertTrue(whitelist.isGrantedTo(BASE_LABEL_A, ed), "live until the last second");

        vm.warp(expiresAt);
        assertFalse(whitelist.isGrantedTo(BASE_LABEL_A, ed));
        assertEq(whitelist.granteeOf(BASE_LABEL_A), address(0));
        assertEq(whitelist.grantExpiresAt(BASE_LABEL_A), 0);
        assertEq(
            uint256(whitelist.statusOf(BASE_LABEL_A)), uint256(IDotnsNameWhitelist.NameStatus.Open)
        );

        IDotnsNameWhitelist.NameView[] memory page = whitelist.names(0, 10);
        assertEq(page.length, 1, "the lapsed entry stays listed until a write clears it");
        assertEq(uint256(page[0].status), uint256(IDotnsNameWhitelist.NameStatus.Open));
        assertEq(page[0].winner, address(0));
    }

    function test_granteeOfNode_agrees_with_granteeOf() public {
        bytes32 node = _nodeOf(BASE_LABEL_A);
        assertEq(whitelist.granteeOfNode(node), address(0));

        _grant(ed, BASE_LABEL_A);
        assertEq(whitelist.granteeOfNode(node), ed);
        assertEq(whitelist.granteeOfNode(node), whitelist.granteeOf(BASE_LABEL_A));

        vm.warp(block.timestamp + whitelist.grantDuration());
        assertEq(whitelist.granteeOfNode(node), address(0), "zero once the grant expires");
    }

    function test_consume_reverts_after_expiry() public {
        _grant(ed, BASE_LABEL_A);
        vm.warp(block.timestamp + whitelist.grantDuration());
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsNameWhitelist.NotWinner.selector, ed, _nodeOf(BASE_LABEL_A)
            )
        );
        vm.prank(address(dotnsRegistrarController));
        whitelist.consume(BASE_LABEL_A, ed);
    }

    function test_grantName_regrants_an_expired_grant_without_a_revoke() public {
        _grant(ed, BASE_LABEL_A);
        vm.warp(block.timestamp + whitelist.grantDuration());

        _grant(tiago, BASE_LABEL_A);
        assertEq(whitelist.granteeOf(BASE_LABEL_A), tiago);
        assertEq(
            whitelist.grantExpiresAt(BASE_LABEL_A),
            uint64(block.timestamp) + whitelist.grantDuration(),
            "the new grant runs its own period"
        );
        assertEq(whitelist.nameCount(), 1);
    }

    function test_requestName_accepts_an_expired_grant() public {
        _grant(ed, BASE_LABEL_A);
        vm.warp(block.timestamp + whitelist.grantDuration());
        whitelist.setWindow(0, 30 days);

        _request(tiago, BASE_LABEL_A);
        assertEq(whitelist.claimantCount(BASE_LABEL_A), 1);
        assertEq(whitelist.granteeOf(BASE_LABEL_A), address(0));
    }

    function test_setReserved_reserves_an_expired_grant() public {
        _grant(ed, BASE_LABEL_A);
        vm.warp(block.timestamp + whitelist.grantDuration());

        whitelist.setReserved(BASE_LABEL_A, true);
        assertTrue(whitelist.isReserved(BASE_LABEL_A));

        whitelist.setReserved(BASE_LABEL_A, false);
        assertEq(whitelist.granteeOf(BASE_LABEL_A), address(0), "the lapsed winner is gone");
        assertEq(whitelist.nameCount(), 0);
    }

    function test_revokeName_tidies_an_expired_grant() public {
        _grant(ed, BASE_LABEL_A);
        vm.warp(block.timestamp + whitelist.grantDuration());

        vm.expectEmit(true, true, false, true, address(whitelist));
        emit IDotnsNameWhitelist.NameRevoked(_nodeOf(BASE_LABEL_A), ed, BASE_LABEL_A);
        whitelist.revokeName(BASE_LABEL_A);
        assertEq(whitelist.nameCount(), 0);
    }

    function test_a_reserved_name_never_expires() public {
        whitelist.setReserved(BASE_LABEL_A, true);
        vm.warp(block.timestamp + DotnsConstants.WHITELIST_MAX_GRANT_DURATION + 1);
        assertTrue(whitelist.isReserved(BASE_LABEL_A));
    }

    function test_setGrantDuration_applies_to_later_grants_only() public {
        _grant(ed, BASE_LABEL_A);
        uint64 grantedAt = uint64(block.timestamp);
        uint64 firstExpiry = grantedAt + DotnsConstants.WHITELIST_DEFAULT_GRANT_DURATION;

        vm.expectEmit(false, false, false, true, address(whitelist));
        emit IDotnsNameWhitelist.GrantDurationSet(90 days);
        whitelist.setGrantDuration(90 days);
        assertEq(
            whitelist.grantExpiresAt(BASE_LABEL_A), firstExpiry, "a live grant keeps its expiry"
        );

        _grant(leonardo, BASE_LABEL_B);
        assertEq(whitelist.grantExpiresAt(BASE_LABEL_B), grantedAt + 90 days, "a new grant uses it");

        whitelist.setGrantDuration(1 days);
        assertEq(whitelist.grantExpiresAt(BASE_LABEL_A), firstExpiry, "lowering moves no grant");
        vm.warp(firstExpiry - 1);
        assertTrue(whitelist.isGrantedTo(BASE_LABEL_A, ed), "still bound until its own expiry");
    }

    function test_setGrantDuration_reverts_out_of_range() public {
        uint64 belowLimit = DotnsConstants.WHITELIST_MIN_GRANT_DURATION - 1;
        uint64 aboveLimit = DotnsConstants.WHITELIST_MAX_GRANT_DURATION + 1;

        vm.expectRevert(IDotnsNameWhitelist.GrantDurationOutOfRange.selector);
        whitelist.setGrantDuration(belowLimit);

        vm.expectRevert(IDotnsNameWhitelist.GrantDurationOutOfRange.selector);
        whitelist.setGrantDuration(aboveLimit);
    }

    function test_initializeGrantExpiry_reverts_on_an_initialised_whitelist() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(owner);
        whitelist.initializeGrantExpiry();
    }

    /// @dev Stands in for a whitelist upgraded from a version without expiry: the grant period,
    ///      the legacy expiry and the grant's `expiresAt` are zeroed in storage, as they read
    ///      before the upgrade. Such a grant must run its period from the upgrade.
    function test_a_grant_made_before_expiry_runs_its_period_from_the_upgrade() public {
        _grant(ed, BASE_LABEL_A);

        // Slot 7 packs the window (low 128 bits) with `grantDuration` and the legacy expiry.
        bytes32 configSlot = bytes32(uint256(7));
        uint256 config = uint256(vm.load(address(whitelist), configSlot));
        vm.store(address(whitelist), configSlot, bytes32(config & type(uint128).max));

        // A record's first slot packs status (byte 0), winner (bytes 1-20) and expiresAt.
        bytes32 recordSlot = keccak256(abi.encode(_nodeOf(BASE_LABEL_A), uint256(2)));
        uint256 record = uint256(vm.load(address(whitelist), recordSlot));
        vm.store(
            address(whitelist), recordSlot, bytes32(record & ~(uint256(type(uint64).max) << 168))
        );

        // Between an upgrade and `initializeGrantExpiry`, the grant keeps binding however long the
        // gap, so an upgrade without the call cannot open the name to other paths.
        vm.warp(block.timestamp + 400 days);
        assertTrue(whitelist.isGrantedTo(BASE_LABEL_A, ed), "binds before the clock starts");
        assertEq(whitelist.granteeOf(BASE_LABEL_A), ed);
        assertEq(whitelist.grantExpiresAt(BASE_LABEL_A), type(uint64).max);

        uint64 upgradedAt = uint64(block.timestamp);
        vm.prank(owner);
        whitelist.initializeGrantExpiry();

        assertEq(whitelist.grantDuration(), DotnsConstants.WHITELIST_DEFAULT_GRANT_DURATION);
        assertTrue(whitelist.isGrantedTo(BASE_LABEL_A, ed), "still bound right after the upgrade");
        assertEq(
            whitelist.grantExpiresAt(BASE_LABEL_A),
            upgradedAt + DotnsConstants.WHITELIST_DEFAULT_GRANT_DURATION
        );

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(owner);
        whitelist.initializeGrantExpiry();
    }

    /// @dev A grant made after an upgrade and before `initializeGrantExpiry` finds no grant
    ///      period. It takes no expiry of its own, so it binds until the call and then shares the
    ///      legacy expiry, and never lapses at the moment it is made.
    function test_a_grant_made_before_initializeGrantExpiry_binds_until_the_call() public {
        bytes32 configSlot = bytes32(uint256(7));
        uint256 config = uint256(vm.load(address(whitelist), configSlot));
        vm.store(address(whitelist), configSlot, bytes32(config & type(uint128).max));

        _grant(ed, BASE_LABEL_A);
        vm.warp(block.timestamp + 400 days);
        assertTrue(whitelist.isGrantedTo(BASE_LABEL_A, ed), "binds without a grant period");
        assertEq(whitelist.grantExpiresAt(BASE_LABEL_A), type(uint64).max);

        uint64 upgradedAt = uint64(block.timestamp);
        vm.prank(owner);
        whitelist.initializeGrantExpiry();
        assertEq(
            whitelist.grantExpiresAt(BASE_LABEL_A),
            upgradedAt + DotnsConstants.WHITELIST_DEFAULT_GRANT_DURATION
        );
    }

    /// @dev Governance may set a period after an upgrade and before `initializeGrantExpiry`. The
    ///      legacy expiry is still unset, so old grants keep binding, and the later call still
    ///      sets it, keeping the period governance chose.
    function test_an_early_setGrantDuration_keeps_old_grants_binding() public {
        _grant(ed, BASE_LABEL_A);

        bytes32 configSlot = bytes32(uint256(7));
        uint256 config = uint256(vm.load(address(whitelist), configSlot));
        vm.store(address(whitelist), configSlot, bytes32(config & type(uint128).max));
        bytes32 recordSlot = keccak256(abi.encode(_nodeOf(BASE_LABEL_A), uint256(2)));
        uint256 record = uint256(vm.load(address(whitelist), recordSlot));
        vm.store(
            address(whitelist), recordSlot, bytes32(record & ~(uint256(type(uint64).max) << 168))
        );

        vm.warp(block.timestamp + 400 days);
        whitelist.setGrantDuration(90 days);
        assertTrue(whitelist.isGrantedTo(BASE_LABEL_A, ed), "an early period opens nothing");
        assertEq(whitelist.grantExpiresAt(BASE_LABEL_A), type(uint64).max);

        uint64 upgradedAt = uint64(block.timestamp);
        vm.prank(owner);
        whitelist.initializeGrantExpiry();
        assertEq(whitelist.grantDuration(), 90 days, "the governance period is kept");
        assertEq(whitelist.grantExpiresAt(BASE_LABEL_A), upgradedAt + 90 days);
    }

    function test_initializeGrantExpiry_is_root_or_owner_only() public {
        bytes32 configSlot = bytes32(uint256(7));
        uint256 config = uint256(vm.load(address(whitelist), configSlot));
        vm.store(address(whitelist), configSlot, bytes32(config & type(uint128).max));
        _mockCallerIsRoot(false);

        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, ed)
        );
        vm.prank(ed);
        whitelist.initializeGrantExpiry();
    }
}
