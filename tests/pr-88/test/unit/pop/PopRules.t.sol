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
        vm.prank(owner);
        /// casting to 'bytes32' is safe because this is safe
        /// forge-lint: disable-next-line(unsafe-typecast)
        protocolRegistry.set(bytes32("controller"), address(this));

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
        vm.prank(owner);
        /// casting to 'bytes32' is safe because this is safe
        /// forge-lint: disable-next-line(unsafe-typecast)
        protocolRegistry.set(bytes32("controller"), address(this));

        popRules.reserveBaseName("lights01", leonardo);

        IPopRules.PriceWithMeta memory priceMetadata = popRules.priceWithoutCheck("lights", tiago);

        assertEq(uint256(priceMetadata.status), uint256(IPopRules.PopStatus.Reserved));
        assertEq(priceMetadata.price, popRules.price("lights"));
    }

    function test_base_reservation_rolls_forward_after_expiry() public {
        vm.prank(owner);
        /// casting to 'bytes32' is safe because this is safe
        /// forge-lint: disable-next-line(unsafe-typecast)
        protocolRegistry.set(bytes32("controller"), address(this));

        popRules.reserveBaseName("lights01", leonardo);

        (bool isReserved, address reservationOwner, uint64 expiryTimestamp) =
            popRules.isBaseNameReserved("lights");

        assertTrue(isReserved);
        assertEq(reservationOwner, leonardo);

        vm.warp(uint256(expiryTimestamp) + 1);

        popRules.reserveBaseName("lights02", tiago);

        (bool rolledReserved, address rolledOwner, uint64 rolledExpiry) =
            popRules.isBaseNameReserved("lights");

        assertTrue(rolledReserved);
        assertEq(rolledOwner, tiago);
        assertGt(rolledExpiry, expiryTimestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPopRules.PopError.selector, "Base name reserved for original Lite registrant"
            )
        );
        popRules.priceWithCheck("lights", leonardo);
    }
}
