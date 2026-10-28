// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns, IDotnsRegistrarController} from "../base/BaseDotns.t.sol";
import {IDotnsNameWhitelist} from "../../contracts/whitelist/IDotnsNameWhitelist.sol";
import {IDotnsPopController} from "../../contracts/registrars/IDotnsPopController.sol";
import {IPopRules} from "../../contracts/pop/IPopRules.sol";
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

    // a live grant binds its name on every registration path

    /// @dev The paid path refuses a granted name for everyone. The grantee is refused too: their
    ///      path is `registerReserved`, which spends the grant, so no path leaves a grant
    ///      unspent on a registered name.
    function test_register_refuses_a_granted_name_for_every_caller() public {
        string memory nameLabel = "grantedname";
        _grantName(nameLabel, ed);

        address[2] memory callers = [tiago, ed];
        for (uint256 i; i < callers.length; ++i) {
            (IDotnsRegistrarController.Registration memory registration, uint256 price) =
                _commitPaidRegistration(nameLabel, callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IDotnsRegistrarController.NameGranted.selector, nameLabel)
            );
            vm.prank(callers[i]);
            dotnsRegistrarController.register{value: price}(registration);
        }

        _registerReserved(nameLabel, ed, ed);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(_tokenIdForLabel(nameLabel)), ed);
    }

    /// @dev The gateway neither issues nor reserves a granted name, for any user.
    function test_the_gateway_refuses_a_granted_name_for_every_user() public {
        string memory nameLabel = "grantedname";
        _grantName(nameLabel, ed);

        address[2] memory users = [tiago, ed];
        for (uint256 i; i < users.length; ++i) {
            vm.expectRevert(IDotnsPopController.PersonhoodNameUnavailable.selector);
            _rootIssuePersonhoodName(
                IDotnsPopController.PersonhoodNameIssuance({
                    label: nameLabel, user: users[i], link: _linkFresh(_validChatKey(0x55))
                })
            );

            vm.expectRevert(IDotnsPopController.PersonhoodNameUnavailable.selector);
            _rootReservePersonhoodName(
                IDotnsPopController.PersonhoodNameReservation({label: nameLabel, user: users[i]})
            );
        }

        // The reservation is validated before the issuance, so the device name is not issued
        // either.
        vm.expectRevert(IDotnsPopController.PersonhoodNameUnavailable.selector);
        _rootIssueDeviceNameWithReservation(
            IDotnsPopController.DeviceNameIssuanceWithReservation({
                issuance: IDotnsPopController.DeviceNameIssuance({
                    label: "candidate.07", user: tiago, chatKey: _validChatKey(0x56)
                }),
                reservedLabel: nameLabel
            })
        );
    }

    /// @dev `Reserved` is a whitelist-only status: it closes a name to requests and grants and
    ///      leaves every registration path as it was.
    function test_a_whitelist_reservation_leaves_the_other_paths_open() public {
        string memory nameLabel = "withheldname";
        _mockOriginIsRoot(true);
        dotnsNameWhitelist.setReserved(nameLabel, true);
        _mockOriginIsRoot(false);

        _commitAndRegister(nameLabel, tiago, false);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(_tokenIdForLabel(nameLabel)), tiago);
    }

    /// @dev Once the grant expires, the grantee loses the free path and everyone else regains the
    ///      paid one.
    function test_an_expired_grant_frees_the_name() public {
        string memory nameLabel = "lapsedgrant";
        _grantName(nameLabel, ed);

        IDotnsRegistrarController.Registration memory reserved =
            IDotnsRegistrarController.Registration({
                label: nameLabel,
                owner: ed,
                secret: keccak256(abi.encodePacked(nameLabel, "lapsed")),
                reserved: true,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
            });
        vm.prank(ed);
        dotnsRegistrarController.commit(dotnsRegistrarController.makeCommitment(reserved));

        vm.warp(block.timestamp + dotnsNameWhitelist.grantDuration());

        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrarController.NameNotGranted.selector, nameLabel, ed)
        );
        vm.prank(ed);
        dotnsRegistrarController.registerReserved(reserved);

        _commitAndRegister(nameLabel, tiago, false);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(_tokenIdForLabel(nameLabel)), tiago);
    }

    /// @dev The gateway takes a lapsed grant's name back too, both as a reservation and as an
    ///      issuance.
    function test_the_gateway_accepts_a_name_once_its_grant_expires() public {
        string memory reservedName = "lapsedreserve";
        string memory issuedName = "lapsedissue";
        _grantName(reservedName, ed);
        _grantName(issuedName, ed);
        vm.warp(block.timestamp + dotnsNameWhitelist.grantDuration());

        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({label: reservedName, user: tiago})
        );
        assertEq(
            dotnsPopController.userReservation(tiago).labelhash,
            keccak256(bytes(reservedName)),
            "the lapsed name is reservable"
        );

        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: issuedName, user: leonardo, link: _linkFresh(_validChatKey(0x57))
            })
        );
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(_tokenIdForLabel(issuedName)), leonardo);
    }

    /// @dev A whitelist reservation leaves the gateway as it was, like the paid path, for both
    ///      issuance and reservation.
    function test_a_whitelist_reservation_leaves_the_gateway_open() public {
        string memory issuedName = "withheldgate";
        string memory queuedName = "withheldqueue";
        _mockOriginIsRoot(true);
        dotnsNameWhitelist.setReserved(issuedName, true);
        dotnsNameWhitelist.setReserved(queuedName, true);
        _mockOriginIsRoot(false);

        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: issuedName, user: tiago, link: _linkFresh(_validChatKey(0x58))
            })
        );
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(_tokenIdForLabel(issuedName)), tiago);

        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({label: queuedName, user: leonardo})
        );
        assertEq(
            dotnsPopController.userReservation(leonardo).labelhash, keccak256(bytes(queuedName))
        );
    }

    /// @dev The case the grant has to protect most: a 6 to 8 letter name, which a verified person
    ///      can take through the gateway and, with short names enabled, through the paid path.
    function test_a_short_granted_name_is_refused_on_both_paths() public {
        string memory nameLabel = "michael";
        _grantName(nameLabel, ed);
        _setShortNames(true);
        _setUserPopStatus(tiago, IPopRules.PopStatus.Personhood);

        (IDotnsRegistrarController.Registration memory registration, uint256 price) =
            _commitPaidRegistration(nameLabel, tiago);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrarController.NameGranted.selector, nameLabel)
        );
        vm.prank(tiago);
        dotnsRegistrarController.register{value: price}(registration);

        vm.expectRevert(IDotnsPopController.PersonhoodNameUnavailable.selector);
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: nameLabel, user: tiago, link: _linkFresh(_validChatKey(0x59))
            })
        );

        _registerReserved(nameLabel, ed, ed);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(_tokenIdForLabel(nameLabel)), ed);
    }

    /// @dev Governance grants a lapsed name afresh without revoking the old grant first.
    function test_an_expired_grant_can_be_granted_again() public {
        string memory nameLabel = "regrantname";
        _grantName(nameLabel, ed);
        vm.warp(block.timestamp + dotnsNameWhitelist.grantDuration());

        _grantName(nameLabel, tiago);
        _registerReserved(nameLabel, tiago, tiago);
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(_tokenIdForLabel(nameLabel)), tiago);
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

    /// @dev A Root dispatch takes no grant, but the released token still exists, so it has to
    ///      reclaim rather than mint, the same as the grant path.
    function test_a_root_dispatch_reclaims_a_released_grant() public {
        string memory nameLabel = "rgov";
        uint256 tokenId = _tokenIdForLabel(nameLabel);

        _grantName(nameLabel, ed);
        _registerReserved(nameLabel, ed, ed);
        _releaseAndWaitOutRedeemWindow(ed, tokenId);

        _registerReservedAsRoot(nameLabel, tiago);

        assertEq(
            IERC721(address(dotnsRegistrar)).ownerOf(tokenId), tiago, "Root reclaimed the name"
        );
        assertEq(dotnsRegistry.owner(_nodeOf(nameLabel)), tiago, "the registry follows the holder");

        IDotnsNameEscrow.ReleasePosition memory position =
            dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(position.recipient, tiago, "the reclaim seeds a fresh position for the new holder");
        assertEq(position.amount, 0, "a Root mint is free, so nothing is refundable");
        assertFalse(position.released, "the new position starts outside the released phase");
    }

    /// @dev A long label can come back from a paid registration that still holds its deposit. The
    ///      reclaim must settle that deposit to the previous holder, not drop it or hand it on.
    function test_a_granted_reclaim_credits_the_previous_holders_deposit() public {
        string memory nameLabel = "depositbacked01";
        uint256 tokenId = _tokenIdForLabel(nameLabel);

        _commitAndRegister(nameLabel, ed, false);
        uint256 deposit = dotnsNameEscrow.getReleasePosition(tokenId).amount;
        assertGt(deposit, 0, "a direct registration locks a deposit");

        _releaseAndWaitOutRedeemWindow(ed, tokenId);
        uint256 pendingBefore = dotnsNameEscrow.pendingWithdrawal(ed);

        _grantName(nameLabel, tiago);
        _registerReserved(nameLabel, tiago, tiago);

        assertEq(
            dotnsNameEscrow.pendingWithdrawal(ed) - pendingBefore,
            deposit,
            "the previous holder can pull their unwithdrawn deposit"
        );
        IDotnsNameEscrow.ReleasePosition memory position =
            dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(position.recipient, tiago, "the new holder gets a fresh position");
        assertEq(position.amount, 0, "the old deposit does not carry over to a free grant");
    }

    /// @dev A reservation the previous holder still owns on the name's base name is garbage once
    ///      the name moves on. Left alone, it blocks the base name for everyone else until it
    ///      expires.
    function test_a_granted_reclaim_clears_the_previous_holders_reservation() public {
        _assertReclaimClearsStaleReservation("staleslotgrant", false);
    }

    /// @dev Same clean-up under Root. Root only rules out reading `msg.sender` in this frame;
    ///      `PopRules` still sees the controller as its caller.
    function test_a_root_reclaim_clears_the_previous_holders_reservation() public {
        _assertReclaimClearsStaleReservation("staleslotroot", true);
    }

    /// @dev Only the previous holder's slot is garbage. A slot someone else holds is still theirs.
    function test_a_reclaim_keeps_a_reservation_held_by_someone_else() public {
        string memory nameLabel = "otherslotgrant";
        uint256 tokenId = _tokenIdForLabel(nameLabel);

        _grantName(nameLabel, ed);
        _registerReserved(nameLabel, ed, ed);
        _plantReservation(nameLabel, leonardo);
        _releaseAndWaitOutRedeemWindow(ed, tokenId);

        _grantName(nameLabel, tiago);
        _registerReserved(nameLabel, tiago, tiago);

        (address holder,) = popRules.getBaseNameReservation(nameLabel);
        assertEq(holder, leonardo, "a reservation the previous holder did not own survives");
    }

    /// @notice Reclaims `nameLabel` through `registerReserved` while the previous holder still
    ///         owns a reservation on its base name, and asserts the reservation is gone.
    function _assertReclaimClearsStaleReservation(string memory nameLabel, bool asRoot) private {
        uint256 tokenId = _tokenIdForLabel(nameLabel);

        _grantName(nameLabel, ed);
        _registerReserved(nameLabel, ed, ed);
        _plantReservation(nameLabel, ed);
        _releaseAndWaitOutRedeemWindow(ed, tokenId);

        (address holder,) = popRules.getBaseNameReservation(nameLabel);
        assertEq(holder, ed, "the previous holder still owns a live reservation");

        if (asRoot) {
            _registerReservedAsRoot(nameLabel, tiago);
        } else {
            _grantName(nameLabel, tiago);
            _registerReserved(nameLabel, tiago, tiago);
        }

        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(tokenId), tiago, "the name was reclaimed");
        (holder,) = popRules.getBaseNameReservation(nameLabel);
        assertEq(holder, address(0), "the previous holder's reservation is cleared");
    }

    /// @notice Writes a base-name reservation for `user`, standing in for a sibling controller
    ///         such as the PoP queue head.
    function _plantReservation(string memory baseName, address user) private {
        _authoriseTestAsController();
        popRules.reserveBaseNameForPop(baseName, user);
    }

    /// @notice Releases `tokenId` from `holder` into escrow and waits until it is reclaimable.
    function _releaseAndWaitOutRedeemWindow(address holder, uint256 tokenId) private {
        vm.startPrank(holder);
        dotnsRegistrar.approve(address(dotnsNameEscrow), tokenId);
        dotnsNameEscrow.release(tokenId);
        vm.stopPrank();

        vm.warp(dotnsNameEscrow.getReleasePosition(tokenId).redeemableUntil);
    }

    /// @notice Commits a paid registration of `nameLabel` for `nameOwner` and waits out the
    ///         commitment delay, leaving the reveal to the caller.
    function _commitPaidRegistration(
        string memory nameLabel,
        address nameOwner
    )
        private
        returns (IDotnsRegistrarController.Registration memory registration, uint256 price)
    {
        registration = IDotnsRegistrarController.Registration({
            label: nameLabel,
            owner: nameOwner,
            secret: keccak256(abi.encodePacked(nameLabel, nameOwner, "paid")),
            reserved: false,
            maxPrice: type(uint256).max,
            pricingVersion: popRules.pricingVersion()
        });
        vm.prank(nameOwner);
        dotnsRegistrarController.commit(dotnsRegistrarController.makeCommitment(registration));
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
        price = popRules.priceWithCheck(nameLabel, nameOwner).price;
        vm.deal(nameOwner, nameOwner.balance + price);
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
