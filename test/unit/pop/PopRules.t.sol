// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {IDotnsController} from "../../../contracts/registrars/IDotnsController.sol";

/// @title PopRulesTests
/// @notice Unit tests for PopRules name classification, pricing checks, and base-name reservation
/// authorisation.
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

    function test_classify_nostatus_no_digits() public view {
        (IPopRules.PopStatus classificationStatus, string memory classificationMessage) =
            popRules.classifyName("longnamehere");

        assertEq(uint256(classificationStatus), uint256(IPopRules.PopStatus.NoStatus));
        assertEq(classificationMessage, "Available to all");
    }

    function test_classify_reverts_for_one_digit_suffix() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IPopRules.PopError.selector,
                "Name must have no digit suffix or exactly 2 digit suffix"
            )
        );
        popRules.classifyName("andrew1");
    }

    function test_classify_reverts_for_three_digit_suffix() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IPopRules.PopError.selector,
                "Name must have no digit suffix or exactly 2 digit suffix"
            )
        );
        popRules.classifyName("andrew123");
    }

    function test_flat_price_does_not_scale_with_length() public view {
        // Three NoStatus labels across the previously-tiered length bands (9, 12, 17 chars)
        // must all price identically under the flat deposit. The prior curve charged
        // `startingPrice * (15 - length)` for lengths 9-14 and `startingPrice / 2` for >=15,
        // so any two of these three would have differed.
        uint256 minLengthPrice = popRules.price("ninechars");
        uint256 midLengthPrice = popRules.price("longnamehere");
        uint256 longLengthPrice = popRules.price("thisisaverylongname");

        assertEq(minLengthPrice, midLengthPrice);
        assertEq(midLengthPrice, longLengthPrice);
        assertGt(minLengthPrice, 0);
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
        _grantPopFull(ed);

        IPopRules.PriceWithMeta memory priceMetadata = popRules.priceWithCheck("lights01", ed);

        assertEq(uint256(priceMetadata.status), uint256(IPopRules.PopStatus.PopLite));
        assertEq(uint256(priceMetadata.userStatus), uint256(IPopRules.PopStatus.PopFull));
    }

    function test_poplite_user_can_access_nostatus_name() public {
        _grantPopLite(ed);

        IPopRules.PriceWithMeta memory priceMetadata = popRules.priceWithCheck("longnamehere01", ed);

        assertEq(uint256(priceMetadata.status), uint256(IPopRules.PopStatus.NoStatus));
        assertEq(uint256(priceMetadata.userStatus), uint256(IPopRules.PopStatus.PopLite));
    }

    function test_base_reservation_blocks_others() public {
        // Authorise this test contract as a registrar controller so it may call
        // reserveBaseName (gated by DotnsRegistrar.controllers). Passes the stem
        // directly per the stems-only public boundary.
        _authoriseTestAsController();

        popRules.reserveBaseName("lights", leonardo);

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

        popRules.reserveBaseName("lights", leonardo);

        IPopRules.PriceWithMeta memory priceMetadata = popRules.priceWithoutCheck("lights", tiago);

        assertEq(uint256(priceMetadata.status), uint256(IPopRules.PopStatus.Reserved));
        assertEq(priceMetadata.price, popRules.price("lights"));
    }

    function test_reserveBaseNameForPop_reverts_for_non_controller() public {
        vm.prank(ed);
        vm.expectRevert(IPopRules.NotRegistry.selector);
        popRules.reserveBaseNameForPop("longnamebob", ed);
    }

    function test_releaseBaseName_reverts_for_non_controller() public {
        vm.prank(ed);
        vm.expectRevert(IPopRules.NotRegistry.selector);
        popRules.releaseBaseName("longnamebob");
    }

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
}
