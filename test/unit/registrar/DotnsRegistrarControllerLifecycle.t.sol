// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns, IDotnsRegistrarController} from "../../base/BaseDotns.t.sol";

import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {AcceptingReceiver} from "../../helpers/AcceptingReceiver.sol";
import {RegistrationProbe} from "../../helpers/RegistrationProbe.sol";
import {RefundRejecter} from "../../helpers/RefundRejecter.sol";
import {ReentrantOwner} from "../../helpers/ReentrantOwner.sol";
import {ReentrantOverpaymentAttacker} from "../../helpers/ReentrantOverpaymentAttacker.sol";

/// @title DotnsRegistrarControllerLifecycleTest
/// @notice Coverage for the post-mint lifecycle on the public commit-reveal
///         controller: reclaim of a released name, cross-payer routing,
///         escrow-position seeding, callback ordering, pull-payment refunds,
///         and reentrancy guarding.
contract DotnsRegistrarControllerLifecycleTest is BaseDotns {
    function test_register_reclaim_succeeds_for_new_poplite_owner() public {
        string memory label = "lights01";

        address originalOwner = ed;
        address newOwner = leonardo;
        _grantPopLite(originalOwner);
        _grantPopLite(newOwner);

        _commitAndRegister(label, originalOwner, true);

        uint256 tokenId = _tokenIdForLabel(label);

        vm.startPrank(originalOwner);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();

        vm.warp(block.timestamp + ESCROW_COOLDOWN + 1);

        vm.prank(originalOwner);
        dotnsNameEscrow.withdraw(tokenId);

        // Inline the new owner's commit-reveal because BaseDotns helpers quote
        // priceWithCheck up-front, which reverts against the stale reservation.
        // The controller's reclaim path is what garbage-collects the slot.
        bytes32 secret = keccak256("new-owner-reclaim");
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label, owner: newOwner, secret: secret, reserved: true
            });
        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        vm.prank(newOwner);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        vm.prank(newOwner);
        dotnsRegistrarController.register{value: 0}(registration);

        assertEq(dotnsRegistrar.ownerOf(tokenId), newOwner);
        (bool isReserved, address reservationOwner,) = popRules.isBaseNameReserved("lights");
        assertTrue(isReserved, "new owner's reservation must take over");
        assertEq(reservationOwner, newOwner, "stale reservation must not block reclaim");
    }

    function test_register_cross_payer_charges_max_not_sum_of_price_and_reach() public {
        string memory label = NOSTATUS_LABEL_A;
        address payer = leonardo;
        address nameOwner = ed;

        _grantPopFull(payer);
        _grantNoStatus(nameOwner);

        uint256 ownerPrice = popRules.priceWithoutCheck(label, nameOwner).price;
        uint256 friction = popRules.transferFloor(label, payer, nameOwner);
        assertGt(ownerPrice, 0, "scenario requires non-zero owner price");
        assertGt(friction, 0, "scenario requires non-zero payer-to-owner friction");

        uint256 expectedCharge = ownerPrice > friction ? ownerPrice : friction;

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label,
                owner: nameOwner,
                secret: keccak256(abi.encodePacked(label, nameOwner, payer)),
                reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        vm.prank(payer);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 insuranceBefore = dotnsNameEscrow.insuranceFund();

        vm.prank(payer);
        dotnsRegistrarController.register{value: expectedCharge}(registration);

        // Cross-payer charge is the greater of owner-side price and reach-floor friction,
        // never their sum. The whole charge routes to the insurance fund; the refundable
        // deposit branch is reserved for direct registrants.
        assertEq(
            dotnsNameEscrow.insuranceFund() - insuranceBefore,
            expectedCharge,
            "cross-payer must credit max(ownerPrice, reachFloor) to insurance"
        );
    }

    function test_revert_register_cross_payer_when_msg_value_below_max_of_price_and_reach() public {
        string memory label = NOSTATUS_LABEL_A;
        address payer = leonardo;
        address nameOwner = ed;

        _grantPopFull(payer);
        _grantNoStatus(nameOwner);

        uint256 ownerPrice = popRules.priceWithoutCheck(label, nameOwner).price;
        uint256 friction = popRules.transferFloor(label, payer, nameOwner);
        assertGt(ownerPrice, 0);
        assertGt(friction, 0);

        uint256 expectedCharge = ownerPrice > friction ? ownerPrice : friction;

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label,
                owner: nameOwner,
                secret: keccak256(abi.encodePacked(label, nameOwner, payer, "short")),
                reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        vm.prank(payer);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        vm.prank(payer);
        vm.expectRevert(IDotnsRegistrarController.InsufficientValue.selector);
        dotnsRegistrarController.register{value: expectedCharge - 1}(registration);
    }

    function test_register_cross_payer_routes_owner_price_to_insurance() public {
        string memory label = NOSTATUS_LABEL_A;
        address payer = leonardo;
        address nameOwner = ed;

        _grantNoStatus(payer);
        _grantNoStatus(nameOwner);

        uint256 ownerPrice = popRules.priceWithoutCheck(label, nameOwner).price;
        assertGt(ownerPrice, 0, "scenario requires priced label");

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label,
                owner: nameOwner,
                secret: keccak256(abi.encodePacked(label, nameOwner, payer, "ins")),
                reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        vm.prank(payer);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 insuranceBefore = dotnsNameEscrow.insuranceFund();

        vm.prank(payer);
        dotnsRegistrarController.register{value: ownerPrice}(registration);

        uint256 tokenId = _tokenIdForLabel(label);
        IDotnsNameEscrow.ReleasePosition memory position =
            dotnsNameEscrow.getReleasePosition(tokenId);

        assertEq(position.amount, 0, "cross-payer must not seed a refundable position");
        assertEq(
            dotnsNameEscrow.insuranceFund() - insuranceBefore,
            ownerPrice,
            "cross-payer price must accrue to insurance"
        );
    }

    function test_register_creates_escrow_position_for_zero_priced_registration() public {
        string memory label = BASE_LABEL_A;
        address nameOwner = ed;
        _grantPopFull(nameOwner);

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label,
                owner: nameOwner,
                secret: keccak256(abi.encodePacked(label, nameOwner, "popfull")),
                reserved: true
            });
        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        vm.prank(nameOwner);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        vm.prank(nameOwner);
        dotnsRegistrarController.register{value: 0}(registration);

        uint256 tokenId = _tokenIdForLabel(label);

        IDotnsNameEscrow.ReleasePosition memory atMint = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(atMint.recipient, nameOwner, "position must bind the registrant at mint");
        assertEq(atMint.amount, 0, "zero-priced mint seeds a zero-amount position");
        assertFalse(atMint.released, "fresh position is not yet released");
        assertFalse(atMint.claimed, "fresh position is not yet claimed");

        vm.startPrank(nameOwner);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();

        IDotnsNameEscrow.ReleasePosition memory atRelease =
            dotnsNameEscrow.getReleasePosition(tokenId);
        assertTrue(atRelease.released, "zero-priced registration must still be releasable");
        assertEq(atRelease.recipient, nameOwner, "release recipient must be the registrant");
    }

    function test_register_reclaim_state_consistent_during_safe_transfer_callback() public {
        string memory label = NOSTATUS_LABEL_A;

        _register(label, ed, IPopRules.PopStatus.NoStatus);
        uint256 tokenId = _tokenIdForLabel(label);

        vm.startPrank(ed);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();
        vm.warp(block.timestamp + ESCROW_COOLDOWN + 1);
        vm.prank(ed);
        dotnsNameEscrow.withdraw(tokenId);

        RegistrationProbe probe =
            new RegistrationProbe(address(dotnsRegistry), address(dotnsReverseResolver));
        vm.deal(address(probe), DEFAULT_BALANCE);

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label,
                owner: address(probe),
                secret: keccak256("probe-reclaim"),
                reserved: true
            });
        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        vm.prank(address(probe));
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 ownerPrice = popRules.priceWithCheck(label, address(probe)).price;
        vm.prank(address(probe));
        dotnsRegistrarController.register{value: ownerPrice}(registration);

        assertTrue(probe.callbackFired(), "reclaim must run through onERC721Received");
        bytes32 node = bytes32(tokenId);
        assertEq(
            probe.observedRegistryOwner(),
            address(probe),
            "registry owner must resolve to the new owner during the callback"
        );
        assertEq(
            probe.observedReverseName(),
            string.concat(label, ".dot"),
            "reverse record must be wired before custody moves"
        );
        assertEq(dotnsRegistry.owner(node), address(probe));
    }

    function test_revert_registerreserved_for_already_seeded_label() public {
        string memory label = "hello1234";
        address nameOwner = ed;

        vm.startPrank(owner);
        bytes32 secret = keccak256("seed-reserved");
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label, owner: nameOwner, secret: secret, reserved: true
            });
        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
        dotnsRegistrarController.registerReserved(registration);
        vm.stopPrank();

        bytes32 secondSecret = keccak256("seed-reserved-2");
        IDotnsRegistrarController.Registration memory secondRegistration =
            IDotnsRegistrarController.Registration({
                label: label, owner: nameOwner, secret: secondSecret, reserved: true
            });

        vm.startPrank(owner);
        bytes32 secondCommitment = dotnsRegistrarController.makeCommitment(secondRegistration);
        dotnsRegistrarController.commit(secondCommitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrarController.NameNotAvailable.selector, label)
        );
        dotnsRegistrarController.registerReserved(secondRegistration);
        vm.stopPrank();
    }

    function test_register_second_reserved_name_preserves_prior_primary_reverse_record() public {
        string memory firstLabel = "primary01";
        string memory secondLabel = "secondary01";

        _grantPopLite(ed);

        _commitAndRegister(firstLabel, ed, true);
        assertEq(dotnsReverseResolver.nameOf(ed), string.concat(firstLabel, ".dot"));

        _commitAndRegister(secondLabel, ed, true);

        assertEq(
            dotnsReverseResolver.nameOf(ed),
            string.concat(firstLabel, ".dot"),
            "second reserved registration must not silently rewrite the primary"
        );
    }

    function test_register_overpayment_pushed_directly_to_eoa_payer() public {
        string memory label = NOSTATUS_LABEL_A;
        address registrant = ed;
        _grantNoStatus(registrant);

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label,
                owner: registrant,
                secret: keccak256("eoa-overpay-happy"),
                reserved: true
            });
        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        vm.prank(registrant);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 ownerPrice = popRules.priceWithCheck(label, registrant).price;
        uint256 overpayment = 1 ether;
        uint256 balanceBefore = registrant.balance;

        vm.expectEmit(true, false, false, true, address(dotnsRegistrarController));
        emit IDotnsRegistrarController.OverpaymentRefunded(registrant, overpayment);

        vm.prank(registrant);
        dotnsRegistrarController.register{value: ownerPrice + overpayment}(registration);

        uint256 tokenId = _tokenIdForLabel(label);
        assertEq(dotnsRegistrar.ownerOf(tokenId), registrant);
        assertEq(
            balanceBefore - registrant.balance,
            ownerPrice,
            "EOA payer is only debited the priced cost; overpayment is pushed back inline"
        );
        assertEq(
            dotnsNameEscrow.pendingWithdrawal(registrant),
            0,
            "EOA payer must bypass the pull-payment ledger entirely"
        );
    }

    function test_register_overpayment_pushed_directly_to_accepting_contract() public {
        string memory label = NOSTATUS_LABEL_A;

        AcceptingReceiver receiver = new AcceptingReceiver();
        vm.deal(address(receiver), DEFAULT_BALANCE);
        _grantNoStatus(address(receiver));

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label,
                owner: address(receiver),
                secret: keccak256("accepting-contract-overpay"),
                reserved: true
            });
        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        vm.prank(address(receiver));
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 ownerPrice = popRules.priceWithCheck(label, address(receiver)).price;
        uint256 overpayment = 1 ether;
        uint256 balanceBefore = address(receiver).balance;

        vm.expectEmit(true, false, false, true, address(dotnsRegistrarController));
        emit IDotnsRegistrarController.OverpaymentRefunded(address(receiver), overpayment);

        vm.prank(address(receiver));
        dotnsRegistrarController.register{value: ownerPrice + overpayment}(registration);

        uint256 tokenId = _tokenIdForLabel(label);
        assertEq(dotnsRegistrar.ownerOf(tokenId), address(receiver));
        assertEq(
            balanceBefore - address(receiver).balance,
            ownerPrice,
            "accepting contract is only debited the priced cost"
        );
        assertEq(
            receiver.received(),
            overpayment,
            "receive() must observe the inline push of the surplus"
        );
        assertEq(
            dotnsNameEscrow.pendingWithdrawal(address(receiver)),
            0,
            "accepting contract must bypass the pull-payment ledger"
        );
    }

    function test_register_overpayment_falls_back_to_ledger_on_rejecting_contract() public {
        string memory label = NOSTATUS_LABEL_A;

        RefundRejecter receiver = new RefundRejecter();
        vm.deal(address(receiver), DEFAULT_BALANCE);
        _grantNoStatus(address(receiver));

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label,
                owner: address(receiver),
                secret: keccak256("contract-overpay"),
                reserved: true
            });
        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        vm.prank(address(receiver));
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 ownerPrice = popRules.priceWithCheck(label, address(receiver)).price;
        uint256 overpayment = 1 ether;

        vm.expectEmit(true, false, false, true, address(dotnsNameEscrow));
        emit IDotnsNameEscrow.OverpaymentRefunded(address(receiver), overpayment);

        vm.prank(address(receiver));
        dotnsRegistrarController.register{value: ownerPrice + overpayment}(registration);

        uint256 tokenId = _tokenIdForLabel(label);
        assertEq(dotnsRegistrar.ownerOf(tokenId), address(receiver));

        assertEq(
            dotnsNameEscrow.pendingWithdrawal(address(receiver)),
            overpayment,
            "rejected push must fall back to the pull-payment ledger"
        );
    }

    function test_register_overpayment_reentrant_attacker_falls_back_to_ledger() public {
        string memory label = NOSTATUS_LABEL_A;

        ReentrantOverpaymentAttacker attacker =
            new ReentrantOverpaymentAttacker(dotnsRegistrarController);
        vm.deal(address(attacker), DEFAULT_BALANCE);
        _grantNoStatus(address(attacker));

        // Arm the attacker with a second registration its receive() will try to
        // replay. The payload is never consumed because the transient guard
        // reverts the re-entry inside the push, but the call data must decode.
        string memory replayLabel = "reentrybait02";
        IDotnsRegistrarController.Registration memory replay = IDotnsRegistrarController.Registration({
            label: replayLabel,
            owner: address(attacker),
            secret: keccak256("reentry-replay"),
            reserved: true
        });
        attacker.arm(replay);

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label,
                owner: address(attacker),
                secret: keccak256("reentrant-overpay"),
                reserved: true
            });
        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        vm.prank(address(attacker));
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 ownerPrice = popRules.priceWithCheck(label, address(attacker)).price;
        uint256 overpayment = 1 ether;

        vm.expectEmit(true, false, false, true, address(dotnsNameEscrow));
        emit IDotnsNameEscrow.OverpaymentRefunded(address(attacker), overpayment);

        vm.prank(address(attacker));
        dotnsRegistrarController.register{value: ownerPrice + overpayment}(registration);

        uint256 tokenId = _tokenIdForLabel(label);
        assertEq(dotnsRegistrar.ownerOf(tokenId), address(attacker));
        // The attempted re-entry reverts inside `receive`, so the push
        // call frame rolls back and the attacker's balance is untouched by
        // the surplus. The controller falls back to the pull-payment ledger.
        assertEq(
            dotnsNameEscrow.pendingWithdrawal(address(attacker)),
            overpayment,
            "blocked re-entry must fall back to the pull-payment ledger"
        );
    }

    function test_revert_register_on_reentry_from_onerc721received() public {
        string memory label = NOSTATUS_LABEL_A;

        _register(label, ed, IPopRules.PopStatus.NoStatus);
        uint256 tokenId = _tokenIdForLabel(label);
        vm.startPrank(ed);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();
        vm.warp(block.timestamp + ESCROW_COOLDOWN + 1);
        vm.prank(ed);
        dotnsNameEscrow.withdraw(tokenId);

        ReentrantOwner attacker = new ReentrantOwner(dotnsRegistrarController);
        vm.deal(address(attacker), DEFAULT_BALANCE);

        // Stage a second registration the callback will try to replay.
        string memory replayLabel = "reentrancybait01";
        IDotnsRegistrarController.Registration memory replay = IDotnsRegistrarController.Registration({
            label: replayLabel,
            owner: address(attacker),
            secret: keccak256("reentry"),
            reserved: true
        });
        bytes32 replayCommitment = dotnsRegistrarController.makeCommitment(replay);
        vm.prank(address(attacker));
        dotnsRegistrarController.commit(replayCommitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
        attacker.arm(replay);

        IDotnsRegistrarController.Registration memory outer = IDotnsRegistrarController.Registration({
            label: label,
            owner: address(attacker),
            secret: keccak256("outer-reclaim"),
            reserved: true
        });
        bytes32 outerCommitment = dotnsRegistrarController.makeCommitment(outer);
        vm.prank(address(attacker));
        dotnsRegistrarController.commit(outerCommitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 outerPrice = popRules.priceWithCheck(label, address(attacker)).price;

        vm.prank(address(attacker));
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        dotnsRegistrarController.register{value: outerPrice}(outer);
    }
}
