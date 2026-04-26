// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {IDotnsController} from "../../../contracts/registrars/IDotnsController.sol";

contract PopRulesTests is BaseDotns {
    function test_classify_governance() public view {
        (IPopRules.PopStatus classificationStatus, string memory classificationMessage) =
            popRules.classifyName("hello");

        assertEq(uint256(classificationStatus), uint256(IPopRules.PopStatus.Reserved));
        assertEq(classificationMessage, "Reserved for Governance");
    }

    function test_classify_poplite() public view {
        (IPopRules.PopStatus classificationStatus, string memory classificationMessage) =
            popRules.classifyName("lights01");

        assertEq(uint256(classificationStatus), uint256(IPopRules.PopStatus.PopLite));
        assertEq(classificationMessage, "Requires Light personhood verification");
    }

    function test_classify_popfull() public view {
        (IPopRules.PopStatus classificationStatus, string memory classificationMessage) =
            popRules.classifyName("alicebob");

        assertEq(uint256(classificationStatus), uint256(IPopRules.PopStatus.PopFull));
        assertEq(classificationMessage, "Requires Full personhood verification");
    }

    function test_classify_nostatus() public view {
        (IPopRules.PopStatus classificationStatus, string memory classificationMessage) =
            popRules.classifyName("longnamehere01");

        assertEq(uint256(classificationStatus), uint256(IPopRules.PopStatus.NoStatus));
        assertEq(classificationMessage, "Available to all");
    }

    function test_price_with_check_revert_governance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IPopRules.PopError.selector, "Reserved for Governance")
        );
        popRules.priceWithCheck("hello", ed);
    }

    function test_price_with_check_revert_full_needed() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IPopRules.PopError.selector, "Requires Full Personhood verification"
            )
        );
        popRules.priceWithCheck("alicebob", ed);
    }

    function test_popfull_user_can_access_poplite_name() public {
        vm.prank(ed);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);

        IPopRules.PriceWithMeta memory priceMetadata = popRules.priceWithCheck("lights01", ed);

        assertEq(uint256(priceMetadata.status), uint256(IPopRules.PopStatus.PopLite));
        assertEq(uint256(priceMetadata.userStatus), uint256(IPopRules.PopStatus.PopFull));
    }

    function test_base_reservation_blocks_others() public {
        // Authorise this test contract as a registrar controller so it may call
        // reserveBaseName (gated by DotnsRegistrar.controllers).
        _authoriseTestAsController();

        popRules.reserveBaseName("lights01", leonardo);

        (bool isReserved, address reservationOwner, uint64 expiryTimestamp) =
            popRules.isBaseNameReserved("lights");

        assertTrue(isReserved);
        assertEq(reservationOwner, leonardo);
        assertEq(expiryTimestamp, uint64(block.timestamp + 12 weeks));

        vm.expectRevert(
            abi.encodeWithSelector(
                IPopRules.PopError.selector, "Base name reserved for original Lite registrant"
            )
        );
        popRules.priceWithCheck("lights", tiago);
    }

    function test_price_without_check_returns_price_for_reserved() public {
        _authoriseTestAsController();

        popRules.reserveBaseName("lights01", leonardo);

        IPopRules.PriceWithMeta memory priceMetadata = popRules.priceWithoutCheck("lights", tiago);

        assertEq(uint256(priceMetadata.status), uint256(IPopRules.PopStatus.Reserved));
        assertEq(priceMetadata.price, popRules.price("lights"));
    }

    // `reserveBaseNameForPop` must be gated by registrar-controller authorisation.
    // An address that is not registered as a controller cannot write reservations.
    function test_reserveBaseNameForPop_reverts_for_non_controller() public {
        vm.prank(ed);
        vm.expectRevert(IPopRules.NotRegistry.selector);
        popRules.reserveBaseNameForPop("longnamebob", ed);
    }

    // Same gating for `releaseBaseName`.
    function test_releaseBaseName_reverts_for_non_controller() public {
        vm.prank(ed);
        vm.expectRevert(IPopRules.NotRegistry.selector);
        popRules.releaseBaseName("longnamebob");
    }

    // When the slot is already live for user A, a second call for user B from
    // any authorised controller reverts. Silent no-op would let the caller's
    // local queue bookkeeping diverge from PopRules; reverting propagates the
    // collision back to the caller so both sides stay in lockstep. The existing
    // holder keeps priority either way.
    function test_reserveBaseNameForPop_reverts_when_slot_held_by_other_user() public {
        _authoriseTestAsController();

        popRules.reserveBaseNameForPop("longnamebob", leonardo);

        vm.expectRevert(
            abi.encodeWithSelector(IPopRules.PopError.selector, "Base name held by another user")
        );
        popRules.reserveBaseNameForPop("longnamebob", tiago);

        (address holder,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, leonardo);
    }

    // Same-owner re-reservation refreshes the expiry timestamp forward.
    function test_reserveBaseNameForPop_refreshes_expiry_for_same_owner() public {
        _authoriseTestAsController();

        popRules.reserveBaseNameForPop("longnamebob", leonardo);
        (, uint64 firstExpiry) = popRules.getBaseNameReservation("longnamebob");

        vm.warp(block.timestamp + 1 days);

        popRules.reserveBaseNameForPop("longnamebob", leonardo);
        (address holder, uint64 refreshedExpiry) = popRules.getBaseNameReservation("longnamebob");

        assertEq(holder, leonardo);
        assertGt(refreshedExpiry, firstExpiry);
    }

    function test_releaseBaseName_reverts_for_non_reserving_controller() public {
        _authoriseTestAsController();
        popRules.reserveBaseNameForPop("longnamebob", leonardo);

        address otherController = makeAddr("otherController");
        vm.prank(owner);
        dotnsRegistrar.addController(IDotnsController(otherController));

        vm.prank(otherController);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPopRules.PopError.selector, "Only reserving controller can release"
            )
        );
        popRules.releaseBaseName("longnamebob");

        (address holder,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, leonardo);
    }

    function test_releaseBaseName_succeeds_for_reserving_controller() public {
        _authoriseTestAsController();
        popRules.reserveBaseNameForPop("longnamebob", leonardo);

        popRules.releaseBaseName("longnamebob");

        (address holder,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, address(0));
    }

    function test_releaseBaseName_expired_slot_cleared_by_any_controller() public {
        _authoriseTestAsController();
        popRules.reserveBaseNameForPop("longnamebob", leonardo);

        vm.warp(block.timestamp + popRules.MAX_RESERVATION_TIME() + 1);

        address otherController = makeAddr("otherController");
        vm.prank(owner);
        dotnsRegistrar.addController(IDotnsController(otherController));

        vm.prank(otherController);
        popRules.releaseBaseName("longnamebob");

        (address holder,) = popRules.getBaseNameReservation("longnamebob");
        assertEq(holder, address(0));
    }

    function test_reachFee_NoStatus_label_returns_zero_for_any_status() public {
        // The open tier has no verification gate to bypass, so reachFee returns zero
        // regardless of the account's status.
        assertEq(popRules.reachFee("longnamehere01", ed), 0);

        vm.prank(ed);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopLite);
        assertEq(popRules.reachFee("longnamehere01", ed), 0);

        vm.prank(ed);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);
        assertEq(popRules.reachFee("longnamehere01", ed), 0);
    }

    function test_reachFee_PopLite_label_charges_NoStatus_user() public {
        // "alicebo42" is a 7-char base + 2 trailing digits, classifying as PopLite at
        // total length 9 so the reach-fee curve matches the NoStatus price curve.
        uint256 expected = popRules.price("alicebo42");
        assertGt(expected, 0);
        assertEq(popRules.reachFee("alicebo42", ed), expected);
    }

    function test_reachFee_PopLite_label_zero_for_verified() public {
        // A PopLite or PopFull account meets the reach for a PopLite-tier label, so
        // the friction is zero in both cases.
        vm.prank(ed);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopLite);
        assertEq(popRules.reachFee("alicebo42", ed), 0);

        vm.prank(leonardo);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);
        assertEq(popRules.reachFee("alicebo42", leonardo), 0);
    }

    function test_reachFee_PopFull_label_charges_below_full() public {
        // Both unverified and lite-verified accounts owe friction on a PopFull-tier
        // (base name) label. Only PopFull reaches it for free.
        // 13-char base-name label classifies as PopFull and has a non-zero NoStatus rate.
        uint256 expected = popRules.price("alicelongname");
        assertGt(expected, 0);
        assertEq(popRules.reachFee("alicelongname", ed), expected);

        vm.prank(ed);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopLite);
        assertEq(popRules.reachFee("alicelongname", ed), expected);

        vm.prank(leonardo);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);
        assertEq(popRules.reachFee("alicelongname", leonardo), 0);
    }

    function test_reachFee_short_PopFull_label_extends_length_curve() public view {
        // "alicebob" is an 8-char base name, so the shared length curve charges
        // one extra startingPrice step above a 9-char label.
        uint256 expected = RENT_PRICE * (15 - bytes("alicebob").length);

        assertEq(popRules.price("alicebob"), expected);
        assertEq(popRules.reachFee("alicebob", ed), expected);
    }

    function test_reachFee_short_PopLite_label_extends_length_curve() public view {
        // "lights01" is PopLite-tier and 8 chars total, so it follows the same
        // length-based price as any other 8-char label.
        uint256 expected = RENT_PRICE * (15 - bytes("lights01").length);

        assertEq(popRules.price("lights01"), expected);
        assertEq(popRules.reachFee("lights01", ed), expected);
    }
}
