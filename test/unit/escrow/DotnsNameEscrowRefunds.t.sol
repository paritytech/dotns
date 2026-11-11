// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {DotnsNameEscrow} from "../../../contracts/escrow/DotnsNameEscrow.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DotnsNameEscrowRefundHarness
/// @notice Test-only subclass that seeds refund entries straight into storage and exposes
///         `_removeRefundEntry`. Nothing in the escrow credits entries any more, so seeding is the
///         only way to exercise the claim and view functions that serve entries already on the
///         ledger.
contract DotnsNameEscrowRefundHarness is DotnsNameEscrow {
    uint256 private _seededEntries;

    function seedRefundEntry(
        address recipient,
        uint256 amount,
        uint256 tokenId
    )
        external
        returns (uint256 entryId)
    {
        entryId = ++_seededEntries;
        _refundEntries[entryId] = RefundEntry({
            recipient: recipient,
            amount: amount,
            availableAt: uint64(block.timestamp + cooldown),
            tokenId: tokenId
        });
        uint256[] storage list = _entriesByRecipient[recipient];
        list.push(entryId);
        _entryIndexPlusOne[entryId] = list.length;
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
/// @notice Unit tests for claiming entries on the time-locked refund ledger of
///         @custom:contract DotnsNameEscrow.
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
            DotnsNameEscrow.initialize,
            (
                owner,
                IDotnsProtocolRegistry(address(protocolRegistry)),
                DEFAULT_COOLDOWN,
                ESCROW_REDEEM_WINDOW
            )
        );
        address proxy = address(new ERC1967Proxy(address(impl), initData));
        harness = DotnsNameEscrowRefundHarness(payable(proxy));
        vm.deal(address(harness), 100 ether);

        recipient = makeAddr("refundRecipient");
        otherRecipient = makeAddr("otherRefundRecipient");
    }

    function _seed(address to, uint256 amount, uint256 tokenId) internal returns (uint256 entryId) {
        entryId = harness.seedRefundEntry(to, amount, tokenId);
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

    function test_claimRefund_transfersAndDeletes() public {
        uint256 entryId = _seed(recipient, 1 ether, TOKEN_ID);
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
        uint256 entryId = _seed(recipient, 1 ether, TOKEN_ID);
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
        uint256 entryId = _seed(recipient, 1 ether, TOKEN_ID);
        uint64 availableAt = harness.refundEntry(entryId).availableAt;

        vm.prank(recipient);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsNameEscrow.RefundLocked.selector, entryId, availableAt)
        );
        harness.claimRefund(entryId);
    }

    function test_claimRefund_emitsRefundClaimed() public {
        uint256 entryId = _seed(recipient, 1 ether, TOKEN_ID);
        _warpPast(harness.refundEntry(entryId).availableAt);

        vm.expectEmit(true, true, false, true, address(harness));
        emit IDotnsNameEscrow.RefundClaimed(recipient, entryId, 1 ether);
        vm.prank(recipient);
        harness.claimRefund(entryId);
    }

    function test_claimRefund_revertsOnTransferFailure() public {
        RejectingReceiver rejecter = new RejectingReceiver();
        uint256 entryId = _seed(address(rejecter), 1 ether, TOKEN_ID);
        _warpPast(harness.refundEntry(entryId).availableAt);

        vm.prank(address(rejecter));
        vm.expectRevert(abi.encodeWithSelector(IDotnsNameEscrow.RefundFailed.selector, TOKEN_ID));
        harness.claimRefund(entryId);
    }

    function test_claimRefundsBatch_aggregatesAndTransfers() public {
        uint256 a = _seed(recipient, 1 ether, TOKEN_ID);
        uint256 b = _seed(recipient, 2 ether, TOKEN_ID);
        uint256 c = _seed(recipient, 3 ether, TOKEN_ID);
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
        uint256 a = _seed(recipient, 1 ether, TOKEN_ID);
        // Warp between credits so entry B's cooldown clock starts late enough that the batch
        // claim straddles it: A and C are claimable, B is not.
        vm.warp(block.timestamp + DEFAULT_COOLDOWN);
        uint256 b = _seed(recipient, 2 ether, TOKEN_ID);
        uint256 c = _seed(recipient, 3 ether, TOKEN_ID);
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
        uint256 a = _seed(recipient, 1 ether, TOKEN_ID);
        uint256 b = _seed(recipient, 2 ether, TOKEN_ID);
        uint256 c = _seed(recipient, 3 ether, TOKEN_ID);

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
        uint256 a = _seed(recipient, 1 ether, TOKEN_ID);
        uint256 b = _seed(recipient, 2 ether, TOKEN_ID);
        uint256 c = _seed(recipient, 3 ether, TOKEN_ID);

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
