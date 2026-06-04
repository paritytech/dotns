// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {DotnsNameEscrow} from "../../../contracts/escrow/DotnsNameEscrow.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DotnsNameEscrowRefundHarness
/// @notice Test-only subclass exposing internal refund-ledger primitives so the unit suite can
///         drive `_creditRefund` and `_removeRefundEntry` directly without standing up the full
///         transfer-fee pipeline.
contract DotnsNameEscrowRefundHarness is DotnsNameEscrow {
    function exposeCreditRefund(
        address recipient,
        uint256 amount,
        uint256 tokenId
    )
        external
        payable
        returns (uint256 entryId)
    {
        entryId = _creditRefund(recipient, amount, tokenId);
    }

    function exposeRemoveRefundEntry(uint256 entryId, address recipient) external {
        _removeRefundEntry(entryId, recipient);
    }

    function exposeEntryIndexPlusOne(uint256 entryId) external view returns (uint256) {
        // Cannot access private storage directly across contracts, so derive from the public view.
        IDotnsNameEscrow.RefundEntry memory entry = this.refundEntry(entryId);
        if (entry.amount == 0) return 0;
        uint256[] memory ids = this.pendingRefundIds(entry.recipient, 0, MAX_REFUND_PAGE_SIZE);
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ids[i] == entryId) return i + 1;
        }
        return 0;
    }
}

contract RejectingReceiver {
    // No receive(), no fallback(): any incoming value reverts.
    function marker() external pure returns (bool) {
        return true;
    }
}

/// @title DotnsNameEscrowRefundsTest
/// @notice Unit tests for the time-locked refund ledger added to @custom:contract DotnsNameEscrow.
contract DotnsNameEscrowRefundsTest is BaseDotns {
    DotnsNameEscrowRefundHarness internal harness;

    uint64 internal constant DEFAULT_COOLDOWN = 1 hours;
    uint256 internal constant TOKEN_ID = 1;

    address internal recipient;
    address internal otherRecipient;

    function setUp() public override {
        super.setUp();

        // Deploy the harness behind its own ERC1967 proxy so the production proxy used by the
        // rest of the suite is untouched. Initialise via the proxy because the implementation's
        // constructor disables initialisers.
        DotnsNameEscrowRefundHarness impl = new DotnsNameEscrowRefundHarness();
        bytes memory initData = abi.encodeCall(
            DotnsNameEscrow.initialize, (IDotnsProtocolRegistry(address(protocolRegistry)), 1 hours)
        );
        address proxy = address(new ERC1967Proxy(address(impl), initData));
        harness = DotnsNameEscrowRefundHarness(payable(proxy));
        vm.deal(address(harness), 100 ether);

        recipient = makeAddr("refundRecipient");
        otherRecipient = makeAddr("otherRefundRecipient");
    }

    function _credit(
        address to,
        uint256 amount,
        uint256 tokenId
    )
        internal
        returns (uint256 entryId)
    {
        entryId = harness.exposeCreditRefund(to, amount, tokenId);
    }

    function _warpPast(uint64 availableAt) internal {
        vm.warp(availableAt + 1);
    }

    function _assertEntryDeleted(uint256 entryId) internal view {
        IDotnsNameEscrow.RefundEntry memory entry = harness.refundEntry(entryId);
        assertEq(entry.recipient, address(0), "entry recipient should be zeroed");
        assertEq(entry.amount, 0, "entry amount should be zero");
        assertEq(entry.availableAt, 0, "entry availableAt should be zero");
        assertEq(entry.tokenId, 0, "entry tokenId should be zero");
    }

    function test_creditRefund_allocatesMonotonicEntryIds() public {
        uint256 first = _credit(recipient, 1 ether, TOKEN_ID);
        uint256 second = _credit(recipient, 2 ether, TOKEN_ID);
        uint256 third = _credit(recipient, 3 ether, TOKEN_ID);

        assertGt(second, first, "second entry id should exceed first");
        assertGt(third, second, "third entry id should exceed second");
    }

    function test_creditRefund_independentCooldowns() public {
        uint256 firstId = _credit(recipient, 1 ether, TOKEN_ID);
        uint64 firstAvailableAt = harness.refundEntry(firstId).availableAt;

        vm.warp(block.timestamp + 30 minutes);

        uint256 secondId = _credit(recipient, 2 ether, TOKEN_ID);
        uint64 secondAvailableAt = harness.refundEntry(secondId).availableAt;

        assertEq(
            harness.refundEntry(firstId).availableAt,
            firstAvailableAt,
            "first entry cooldown must not move when second is credited"
        );
        assertGt(
            secondAvailableAt, firstAvailableAt, "later entry's clock starts at its credit time"
        );
    }

    function test_creditRefund_revertsOnZeroRecipient() public {
        vm.expectRevert(IDotnsNameEscrow.InvalidRecipient.selector);
        harness.exposeCreditRefund(address(0), 1 ether, TOKEN_ID);
    }

    function test_creditRefund_revertsOnZeroAmount() public {
        vm.expectRevert(IDotnsNameEscrow.InvalidAmount.selector);
        harness.exposeCreditRefund(recipient, 0, TOKEN_ID);
    }

    function test_creditRefund_emitsRefundCredited() public {
        uint64 expectedAvailableAt = uint64(block.timestamp + DEFAULT_COOLDOWN);
        vm.expectEmit(true, true, true, true, address(harness));
        emit IDotnsNameEscrow.RefundCredited(recipient, 1, 1 ether, expectedAvailableAt, TOKEN_ID);
        _credit(recipient, 1 ether, TOKEN_ID);
    }

    function test_claimRefund_transfersAndDeletes() public {
        uint256 entryId = _credit(recipient, 1 ether, TOKEN_ID);
        _warpPast(harness.refundEntry(entryId).availableAt);

        uint256 before = recipient.balance;
        vm.prank(recipient);
        uint256 amount = harness.claimRefund(entryId);

        assertEq(amount, 1 ether, "claim returns the credited amount");
        assertEq(recipient.balance - before, 1 ether, "recipient receives the credited amount");
        assertEq(harness.pendingRefundCount(recipient), 0, "entry is removed from enumeration");
        _assertEntryDeleted(entryId);
    }

    function test_claimRefund_revertsWhenCallerIsNotRecipient() public {
        uint256 entryId = _credit(recipient, 1 ether, TOKEN_ID);
        _warpPast(harness.refundEntry(entryId).availableAt);

        vm.prank(otherRecipient);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsNameEscrow.NotRefundRecipient.selector, otherRecipient, TOKEN_ID
            )
        );
        harness.claimRefund(entryId);
    }

    function test_claimRefund_revertsBeforeCooldown() public {
        uint256 entryId = _credit(recipient, 1 ether, TOKEN_ID);
        uint64 availableAt = harness.refundEntry(entryId).availableAt;

        vm.prank(recipient);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameEscrow.RefundLocked.selector, entryId, availableAt)
        );
        harness.claimRefund(entryId);
    }

    function test_claimRefund_emitsRefundClaimed() public {
        uint256 entryId = _credit(recipient, 1 ether, TOKEN_ID);
        _warpPast(harness.refundEntry(entryId).availableAt);

        vm.expectEmit(true, true, false, true, address(harness));
        emit IDotnsNameEscrow.RefundClaimed(recipient, entryId, 1 ether);
        vm.prank(recipient);
        harness.claimRefund(entryId);
    }

    function test_claimRefund_revertsOnTransferFailure() public {
        RejectingReceiver rejecter = new RejectingReceiver();
        uint256 entryId = _credit(address(rejecter), 1 ether, TOKEN_ID);
        _warpPast(harness.refundEntry(entryId).availableAt);

        vm.prank(address(rejecter));
        vm.expectRevert(abi.encodeWithSelector(IDotnsNameEscrow.RefundFailed.selector, TOKEN_ID));
        harness.claimRefund(entryId);
    }

    function test_claimRefundsBatch_aggregatesAndTransfers() public {
        uint256 a = _credit(recipient, 1 ether, TOKEN_ID);
        uint256 b = _credit(recipient, 2 ether, TOKEN_ID);
        uint256 c = _credit(recipient, 3 ether, TOKEN_ID);
        _warpPast(harness.refundEntry(c).availableAt);

        uint256[] memory ids = new uint256[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;

        uint256 before = recipient.balance;
        vm.prank(recipient);
        uint256 total = harness.claimRefundsBatch(ids);

        assertEq(total, 6 ether, "batch returns the aggregate amount");
        assertEq(recipient.balance - before, 6 ether, "recipient receives the aggregate");
        assertEq(harness.pendingRefundCount(recipient), 0, "all entries removed");
    }

    function test_claimRefundsBatch_atomicOnLockedEntry() public {
        uint256 a = _credit(recipient, 1 ether, TOKEN_ID);
        // Warp between credits so entry B's cooldown clock starts late enough that the batch
        // claim straddles it: A and C are claimable, B is not.
        vm.warp(block.timestamp + DEFAULT_COOLDOWN);
        uint256 b = _credit(recipient, 2 ether, TOKEN_ID);
        uint256 c = _credit(recipient, 3 ether, TOKEN_ID);
        uint64 aAvailableAt = harness.refundEntry(a).availableAt;
        vm.warp(aAvailableAt + 1);
        uint64 bAvailableAt = harness.refundEntry(b).availableAt;

        uint256[] memory ids = new uint256[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;

        uint256 before = recipient.balance;
        vm.prank(recipient);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameEscrow.RefundLocked.selector, b, bAvailableAt)
        );
        harness.claimRefundsBatch(ids);

        assertEq(recipient.balance, before, "no partial transfer occurred");
        assertEq(harness.pendingRefundCount(recipient), 3, "no entry was removed");
        assertEq(harness.refundEntry(a).amount, 1 ether, "A still credited");
        assertEq(harness.refundEntry(b).amount, 2 ether, "B still credited");
        assertEq(harness.refundEntry(c).amount, 3 ether, "C still credited");
    }

    function test_claimRefundsBatch_revertsOnEmpty() public {
        uint256[] memory empty = new uint256[](0);
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(IDotnsNameEscrow.InvalidPageSize.selector, 0));
        harness.claimRefundsBatch(empty);
    }

    function test_pendingRefundIds_paginates() public {
        uint256 a = _credit(recipient, 1 ether, TOKEN_ID);
        uint256 b = _credit(recipient, 2 ether, TOKEN_ID);
        uint256 c = _credit(recipient, 3 ether, TOKEN_ID);

        uint256[] memory firstPage = harness.pendingRefundIds(recipient, 0, 2);
        assertEq(firstPage.length, 2);
        assertEq(firstPage[0], a);
        assertEq(firstPage[1], b);

        uint256[] memory secondPage = harness.pendingRefundIds(recipient, 2, 2);
        assertEq(secondPage.length, 1, "tail page is clamped to length");
        assertEq(secondPage[0], c);

        uint256[] memory beyond = harness.pendingRefundIds(recipient, 10, 5);
        assertEq(beyond.length, 0, "offset beyond length returns empty");
    }

    function test_removeRefundEntry_swapPopMiddlePreservesIndices() public {
        uint256 a = _credit(recipient, 1 ether, TOKEN_ID);
        uint256 b = _credit(recipient, 2 ether, TOKEN_ID);
        uint256 c = _credit(recipient, 3 ether, TOKEN_ID);

        _warpPast(harness.refundEntry(b).availableAt);
        vm.prank(recipient);
        harness.claimRefund(b);

        assertEq(harness.pendingRefundCount(recipient), 2);
        uint256[] memory ids = harness.pendingRefundIds(recipient, 0, 200);
        assertEq(ids.length, 2);
        assertEq(ids[0], a, "A retains its position");
        assertEq(ids[1], c, "C is swapped into B's slot");

        // C must be reachable as the new tail and must claim cleanly.
        vm.prank(recipient);
        harness.claimRefund(c);
        assertEq(harness.pendingRefundCount(recipient), 1);
        assertEq(harness.pendingRefundIds(recipient, 0, 200)[0], a);
    }
}
