// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns, IDotnsRegistrarController} from "../base/BaseDotns.t.sol";
import {IDotnsNameWhitelist} from "../../contracts/whitelist/IDotnsNameWhitelist.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title NameGrantFlow
/// @notice End-to-end integration coverage for the governance name-grant flow.
/// @dev Asserts the chain from a Root-dispatched grant on `DotnsNameWhitelist` through a reserved
///      registration on the public controller. Lives in the integration suite because it spans the
///      whitelist and the registration flow rather than any single unit of behaviour.
/// @custom:security-contact admin@parity.io
contract NameGrantFlow is BaseDotns {
    function test_root_grant_seeds_a_reserved_registration() public {
        address user = ed;
        string memory nameLabel = "governanceseed01";

        _grantName(nameLabel, user);
        assertTrue(dotnsNameWhitelist.isGrantedTo(nameLabel, user));

        _registerReserved(nameLabel, user, user);

        bytes32 node = _nodeOf(nameLabel);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(node)), user);
        assertEq(dotnsRegistry.owner(node), user);
        // The grant is spent by the mint, so it cannot seed a second registration.
        assertFalse(dotnsNameWhitelist.isGrantedTo(nameLabel, user));
    }

    /// @dev No signed account grants, the owner included. Only a Root dispatch does.
    function test_no_signed_account_can_grant() public {
        address[3] memory callers = [owner, leonardo, ed];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(IDotnsNameWhitelist.NotGovernance.selector);
            dotnsNameWhitelist.grantName("blocked01", tiago);
        }
        assertFalse(dotnsNameWhitelist.isGrantedTo("blocked01", tiago));
    }

    /// @dev The submitter is not necessarily the beneficiary, and `setReverseName` overwrites
    ///      unconditionally, so the reserved path must not touch the owner's reverse record.
    function test_reserved_registration_leaves_the_reverse_record_untouched() public {
        address user = ed;
        string memory nameLabel = "reverseuntouched01";

        _grantName(nameLabel, user);
        assertEq(dotnsReverseResolver.nameOf(user), "");

        _registerReserved(nameLabel, user, user);

        assertEq(dotnsReverseResolver.nameOf(user), "", "reserved mint must not write reverse");

        // The owner claims it themselves, which is ownership-checked.
        vm.prank(user);
        dotnsReverseResolver.claimReverseRecord(nameLabel);
        assertEq(dotnsReverseResolver.nameOf(user), string.concat(nameLabel, ".dot"));
    }

    /// @dev The gate reads `registration.owner`, so a relayer may submit for the beneficiary.
    function test_a_relayer_can_submit_for_the_granted_beneficiary() public {
        address beneficiary = ed;
        address relayer = tiago;
        string memory nameLabel = "relayed01";

        _grantName(nameLabel, beneficiary);
        _registerReserved(nameLabel, beneficiary, relayer);

        bytes32 node = _nodeOf(nameLabel);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(node)), beneficiary);
    }

    /// @notice Commit-reveal a reserved registration for `nameOwner`, submitted by `submitter`.
    function _registerReserved(
        string memory nameLabel,
        address nameOwner,
        address submitter
    )
        private
    {
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel,
                owner: nameOwner,
                secret: keccak256(abi.encodePacked(nameLabel, nameOwner, submitter)),
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
            });

        vm.startPrank(submitter);
        dotnsRegistrarController.commit(dotnsRegistrarController.makeCommitment(registration));
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
        dotnsRegistrarController.registerReserved(registration);
        vm.stopPrank();
    }
}
