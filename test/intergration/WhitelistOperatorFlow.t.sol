// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns, IDotnsRegistrarController} from "../base/BaseDotns.t.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {IDotnsRoleManager} from "../../contracts/access/IDotnsRoleManager.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title WhitelistOperatorFlow
/// @notice End-to-end integration coverage for the whitelist operator role.
/// @dev Asserts the full chain from `setRole` through the public controller
///      whitelist write into a reserved registration. Lives in the integration
///      suite because it spans the role manager, the controller whitelist, and
///      the reserved registration flow rather than any single unit of behaviour.
/// @custom:security-contact admin@parity.io
contract WhitelistOperatorFlow is BaseDotns {
    function test_operator_can_seed_whitelist_for_reserved_registration() public {
        address operator = leonardo;
        address user = ed;
        string memory nameLabel = "operatorseed01";

        _grantWhitelistOperator(operator);

        vm.prank(operator);
        dotnsRegistrarController.whiteListAddress(user, true);
        assertTrue(dotnsRegistrarController.isWhiteListed(user));

        bytes32 secret = keccak256(abi.encodePacked(nameLabel, user, "operator"));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel, owner: user, secret: secret, reserved: true
            });

        vm.startPrank(user);
        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
        dotnsRegistrarController.registerReserved(registration);
        vm.stopPrank();

        bytes32 node = _nodeOf(nameLabel);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(node)), user);
        assertEq(dotnsRegistry.owner(node), user);
        assertEq(dotnsReverseResolver.nameOf(user), string.concat(nameLabel, ".dot"));
    }

    function test_operator_role_revocation_blocks_further_whitelist_writes() public {
        address operator = leonardo;

        _grantWhitelistOperator(operator);

        vm.prank(operator);
        dotnsRegistrarController.whiteListAddress(ed, true);
        assertTrue(dotnsRegistrarController.isWhiteListed(ed));

        _revokeWhitelistOperator(operator);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRoleManager.NotRoleOrOwner.selector,
                operator,
                DotnsConstants.WHITELIST_OPERATOR_ROLE
            )
        );
        dotnsRegistrarController.whiteListAddress(tiago, true);

        assertTrue(dotnsRegistrarController.isWhiteListed(ed));
    }
}
