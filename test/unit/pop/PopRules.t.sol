// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";

contract PopRulesTests is BaseDotns {
    function test_classify_governance() public view {
        (IPopRules.PopStatus classificationStatus, string memory classificationMessage) =
            popRules.classifyName("hello");

        assertEq(uint256(classificationStatus), uint256(IPopRules.PopStatus.Reserved));
        assertEq(classificationMessage, "Reserved for Governance");
    }

    function test_classify_governance_suffix() public view {
        (IPopRules.PopStatus classificationStatus, string memory classificationMessage) =
            popRules.classifyName("hello01");

        assertEq(uint256(classificationStatus), uint256(IPopRules.PopStatus.Reserved));
        assertEq(classificationMessage, "Reserved for Governance");
    }

    function test_classify_lite_requires() public view {
        (IPopRules.PopStatus classificationStatus, string memory classificationMessage) =
            popRules.classifyName("lights01");

        assertEq(uint256(classificationStatus), uint256(IPopRules.PopStatus.PopLite));
        assertEq(classificationMessage, "Requires Light personhood verification");
    }

    function test_classify_full_requires() public view {
        (IPopRules.PopStatus classificationStatus, string memory classificationMessage) =
            popRules.classifyName("alicebob");

        assertEq(uint256(classificationStatus), uint256(IPopRules.PopStatus.PopFull));
        assertEq(classificationMessage, "Requires Full personhood verification");
    }

    function test_classify_full_suffix() public view {
        (IPopRules.PopStatus classificationStatus, string memory classificationMessage) =
            popRules.classifyName("alicebo1");

        assertEq(uint256(classificationStatus), uint256(IPopRules.PopStatus.PopFull));
        assertEq(classificationMessage, "Requires Full personhood verification");
    }

    function test_classify_nostatus_available() public view {
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

    function test_price_with_check_full_allowed_for_lite() public {
        vm.prank(ed);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);

        IPopRules.PriceWithMeta memory priceMetadata = popRules.priceWithCheck("lights01", ed);

        assertEq(uint256(priceMetadata.status), uint256(IPopRules.PopStatus.PopLite));
        assertEq(uint256(priceMetadata.userStatus), uint256(IPopRules.PopStatus.PopFull));
    }

    function test_base_reservation_blocks_others() public {
        vm.prank(owner);
        popRules.updateEthRegistry(address(this));

        popRules.reserveBaseName("lights01", leonardo);

        (bool isReservedInitial, address reservationOwnerInitial, uint64 expiryTimestampInitial) =
            popRules.isBaseNameReserved("lights");

        assertTrue(isReservedInitial);
        assertEq(reservationOwnerInitial, leonardo);
        assertEq(expiryTimestampInitial, uint64(block.timestamp + 12 weeks));

        popRules.reserveBaseName("lights01", tiago);

        (bool isReservedAfter, address reservationOwnerAfter, uint64 expiryTimestampAfter) =
            popRules.isBaseNameReserved("lights");

        assertTrue(isReservedAfter);
        assertEq(reservationOwnerAfter, leonardo);
        assertEq(expiryTimestampAfter, expiryTimestampInitial);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPopRules.PopError.selector, "Base name reserved for original Lite registrant"
            )
        );
        popRules.priceWithCheck("lights", tiago);
    }

    function test_price_without_check_reserved() public {
        vm.prank(owner);
        popRules.updateEthRegistry(address(this));

        popRules.reserveBaseName("lights01", leonardo);

        IPopRules.PriceWithMeta memory priceMetadata = popRules.priceWithoutCheck("lights", tiago);

        assertEq(uint256(priceMetadata.status), uint256(IPopRules.PopStatus.Reserved));
        assertEq(priceMetadata.message, "Base name reserved for original Lite registrant");

        assertEq(priceMetadata.price, popRules.price("lights"));
    }
}
