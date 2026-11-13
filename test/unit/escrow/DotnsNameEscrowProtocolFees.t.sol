// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";
import {IDotnsNameEscrowGovernance} from "../../../contracts/escrow/IDotnsNameEscrowGovernance.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

contract ValueRejector {
    // No receive(), no fallback(): any incoming value reverts.
}

/// @title DotnsNameEscrowProtocolFeesTest
/// @notice Governance spends the protocol fee balance, and only that balance.
contract DotnsNameEscrowProtocolFeesTest is BaseDotns {
    using stdStorage for StdStorage;

    uint256 private constant FEES = 30 ether;

    address private treasury;

    function setUp() public override {
        super.setUp();
        treasury = makeAddr("treasury");
        _seedProtocolFees(FEES);
    }

    function test_root_withdraws_part_of_the_fees() public {
        uint256 escrowBefore = address(dotnsNameEscrow).balance;

        vm.expectEmit(address(dotnsNameEscrow));
        emit IDotnsNameEscrowGovernance.ProtocolFeesWithdrawn(treasury, 10 ether);
        _withdrawAsRoot(treasury, 10 ether);

        assertEq(dotnsNameEscrow.protocolFees(), FEES - 10 ether);
        assertEq(treasury.balance, 10 ether);
        assertEq(address(dotnsNameEscrow).balance, escrowBefore - 10 ether);
    }

    function test_root_withdraws_all_the_fees() public {
        _withdrawAsRoot(treasury, FEES);

        assertEq(dotnsNameEscrow.protocolFees(), 0);
        assertEq(treasury.balance, FEES);
    }

    /// @notice Deposits sit in the same balance, but a withdrawal cannot reach them.
    function test_revert_withdrawal_cannot_reach_deposits() public {
        _register("depositholder", ed, IPopRules.PopStatus.NoStatus);
        uint256 reserved = dotnsNameEscrow.tokenReserved(address(0));
        assertGt(reserved, 0, "a deposit is held");
        assertGe(address(dotnsNameEscrow).balance, FEES + reserved);

        _mockCallerIsRoot(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsNameEscrowGovernance.ProtocolFeesExceeded.selector, FEES + 1, FEES
            )
        );
        dotnsNameEscrow.withdrawProtocolFees(treasury, FEES + 1);
        _mockCallerIsRoot(false);

        _withdrawAsRoot(treasury, FEES);
        assertEq(dotnsNameEscrow.tokenReserved(address(0)), reserved, "deposits untouched");
    }

    function test_revert_signed_caller_cannot_withdraw() public {
        vm.prank(owner);
        vm.expectRevert(IDotnsNameEscrowGovernance.NotRoot.selector);
        dotnsNameEscrow.withdrawProtocolFees(treasury, 1 ether);
    }

    function test_revert_zero_recipient() public {
        _mockCallerIsRoot(true);
        vm.expectRevert(IDotnsNameEscrow.InvalidRecipient.selector);
        dotnsNameEscrow.withdrawProtocolFees(address(0), 1 ether);
    }

    function test_revert_zero_amount() public {
        _mockCallerIsRoot(true);
        vm.expectRevert(IDotnsNameEscrow.InvalidAmount.selector);
        dotnsNameEscrow.withdrawProtocolFees(treasury, 0);
    }

    function test_revert_recipient_rejecting_value_leaves_the_fees() public {
        address rejector = address(new ValueRejector());

        _mockCallerIsRoot(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsNameEscrowGovernance.ProtocolFeesTransferFailed.selector, rejector
            )
        );
        dotnsNameEscrow.withdrawProtocolFees(rejector, 1 ether);
        _mockCallerIsRoot(false);

        assertEq(dotnsNameEscrow.protocolFees(), FEES);
    }

    function test_reports_the_governance_interface() public view {
        assertTrue(dotnsNameEscrow.supportsInterface(type(IDotnsNameEscrowGovernance).interfaceId));
    }

    function _withdrawAsRoot(address to, uint256 amount) private {
        _mockCallerIsRoot(true);
        dotnsNameEscrow.withdrawProtocolFees(to, amount);
        _mockCallerIsRoot(false);
    }

    /// @dev Nothing credits the balance any more, so the test writes it as an earlier release
    ///      left it, together with the native value behind it.
    function _seedProtocolFees(uint256 amount) private {
        stdstore.target(address(dotnsNameEscrow)).sig("protocolFees()").checked_write(amount);
        vm.deal(address(dotnsNameEscrow), address(dotnsNameEscrow).balance + amount);
    }
}
