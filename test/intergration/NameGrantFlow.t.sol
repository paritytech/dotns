// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns, IDotnsRegistrarController} from "../base/BaseDotns.t.sol";
import {IDotnsNameWhitelist} from "../../contracts/whitelist/IDotnsNameWhitelist.sol";
import {IDotnsNameEscrow} from "../../contracts/escrow/IDotnsNameEscrow.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
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

    // release lifecycle: a granted name must not be a one-way exit from circulation

    /// @dev The mint is free, so the position carries no value, but it must exist: `release` gates
    ///      on `position.recipient`, so a granted name minted without one could never be released.
    function test_a_granted_name_seeds_a_zero_amount_release_position() public {
        address user = ed;
        string memory nameLabel = "releasablegrant01";

        _grantName(nameLabel, user);
        _registerReserved(nameLabel, user, user);

        IDotnsNameEscrow.ReleasePosition memory position =
            dotnsNameEscrow.getReleasePosition(_tokenIdForLabel(nameLabel));

        assertEq(position.recipient, user, "the grant must seed a position keyed to the owner");
        assertEq(position.amount, 0, "a free mint must not seed a refundable deposit");
        assertFalse(position.released, "a fresh position is not in the released phase");
    }

    /// @dev A Root dispatch mints without a grant and must seed the same position: the lifecycle
    ///      cannot depend on which of the two authorities issued the name.
    function test_a_root_minted_reserved_name_seeds_the_same_position() public {
        address user = ed;
        string memory nameLabel = "rootmintedgrant01";

        _registerReservedAsRoot(nameLabel, user);

        IDotnsNameEscrow.ReleasePosition memory position =
            dotnsNameEscrow.getReleasePosition(_tokenIdForLabel(nameLabel));

        assertEq(position.recipient, user, "a Root mint must seed a position too");
        assertEq(position.amount, 0, "a Root mint is free, so nothing is refundable");
    }

    /// @dev The defect this covers: a reserved registration that seeds no release position leaves
    ///      its name permanently unreleasable, so the name never becomes reclaimable and never
    ///      comes back. Grants are the only route to a reserved-tier label, which makes that a
    ///      one-way exit for every short name governance issues. Walks the whole loop to prove the
    ///      exit is real: mint, release, wait out the redeem window, grant the label again.
    function test_a_granted_reserved_tier_name_returns_to_circulation() public {
        // Three characters, so the label is governance-reserved and `register` cannot mint it.
        // `registerReserved` is the only way in, which is what makes the exit matter.
        string memory nameLabel = "gov";
        uint256 tokenId = _tokenIdForLabel(nameLabel);

        _grantName(nameLabel, ed);
        _registerReserved(nameLabel, ed, ed);
        assertFalse(dotnsRegistrarController.available(nameLabel), "the name is taken");

        vm.startPrank(ed);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();

        assertEq(
            IERC721(address(dotnsRegistrar)).ownerOf(tokenId),
            address(dotnsNameEscrow),
            "release moves the name into custody"
        );
        assertFalse(
            dotnsRegistrarController.available(nameLabel),
            "inside the redeem window the name still belongs to its previous holder"
        );

        vm.warp(dotnsNameEscrow.getReleasePosition(tokenId).redeemableUntil);
        assertTrue(
            dotnsRegistrarController.available(nameLabel), "the window closed, so the name is free"
        );

        // Reserved-tier labels only mint through `registerReserved`, so a name advertised as
        // available has to be reachable from here or it is not really back in circulation.
        _grantName(nameLabel, tiago);
        _registerReserved(nameLabel, tiago, tiago);

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(tokenId), tiago, "the name was regranted");
        assertEq(dotnsRegistry.owner(_nodeOf(nameLabel)), tiago, "the registry follows the holder");

        IDotnsNameEscrow.ReleasePosition memory position =
            dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(position.recipient, tiago, "the reclaim seeds a fresh position for the new holder");
        assertFalse(position.released, "the new position starts outside the released phase");
    }

    /// @dev The position is the lifecycle marker, so it has to follow the name. A granted name
    ///      whose position stayed behind would be unreleasable in its second holder's hands.
    function test_a_granted_name_keeps_its_position_through_a_transfer() public {
        string memory nameLabel = "transferredgrant01";
        uint256 tokenId = _tokenIdForLabel(nameLabel);

        _grantName(nameLabel, ed);
        _registerReserved(nameLabel, ed, ed);

        vm.prank(ed);
        IERC721(address(dotnsRegistrar)).transferFrom(ed, tiago, tokenId);

        assertEq(
            dotnsNameEscrow.getReleasePosition(tokenId).recipient,
            tiago,
            "the position rebinds to the new holder"
        );

        vm.startPrank(tiago);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();

        assertTrue(
            dotnsNameEscrow.getReleasePosition(tokenId).released,
            "the new holder can release what they were given"
        );
    }

    /// @dev Seeding the release position makes the escrow a hard dependency of this path. Root is
    ///      no exception: it skips the whitelist read, not this one.
    function test_reserved_registration_requires_a_configured_escrow() public {
        string memory nameLabel = "noescrowgrant01";

        vm.prank(owner);
        protocolRegistry.remove(DotnsConstants.NAME_ESCROW);

        _grantName(nameLabel, ed);

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel,
                owner: ed,
                secret: keccak256(abi.encodePacked(nameLabel)),
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
            });

        vm.startPrank(ed);
        dotnsRegistrarController.commit(dotnsRegistrarController.makeCommitment(registration));
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
        vm.expectRevert(IDotnsRegistrarController.EscrowNotConfigured.selector);
        dotnsRegistrarController.registerReserved(registration);
        vm.stopPrank();
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

    /// @notice Commit-reveal a reserved registration for `nameOwner` under a mocked Root origin.
    /// @dev The Root branch takes no grant and consumes none, so this skips `_grantName`. Only the
    ///      reveal runs as Root: the commit does not read the origin, and leaving the mock sticky
    ///      would put later registrations on the Root branch by accident.
    function _registerReservedAsRoot(string memory nameLabel, address nameOwner) private {
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: nameLabel,
                owner: nameOwner,
                secret: keccak256(abi.encodePacked(nameLabel, nameOwner, "root")),
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
            });

        dotnsRegistrarController.commit(dotnsRegistrarController.makeCommitment(registration));
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        _mockOriginIsRoot(true);
        dotnsRegistrarController.registerReserved(registration);
        _mockOriginIsRoot(false);
    }
}
