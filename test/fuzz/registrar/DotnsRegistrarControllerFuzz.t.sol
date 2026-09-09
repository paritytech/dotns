// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns, IDotnsRegistrarController} from "../../base/BaseDotns.t.sol";
import {ILabelStore} from "../../../contracts/store/ILabelStore.sol";
import {IDotnsNameEscrow} from "../../../contracts/escrow/IDotnsNameEscrow.sol";

/// @title DotnsRegistrarControllerFuzzTest
/// @notice Property-based tests for @custom:contract DotnsRegistrarController role administration,
///         payment handling and reverse-record behaviour.
contract DotnsRegistrarControllerFuzzTest is BaseDotns {
    /// @notice The controller supports no roles of its own; operators live on the whitelist.
    function testFuzz_register_pushes_overpayment_back_to_eoa_payer(
        uint256 extra,
        uint256 salt
    )
        public
    {
        address registrant = ed;
        string memory nameLabel = _labelNoStatusPriced(bound(salt, 0, 64));

        _grantNoStatus(registrant);

        IDotnsRegistrarController.Registration memory registration =
            _commitFor(nameLabel, registrant, true);

        uint256 requiredPrice = popRules.priceWithCheck(nameLabel, registrant).price;
        assertGt(requiredPrice, 0);

        extra = bound(extra, 0, 5 ether);

        uint256 balanceBefore = registrant.balance;

        vm.startPrank(registrant);
        dotnsRegistrarController.register{value: requiredPrice + extra}(registration);
        vm.stopPrank();

        // EOA receivers accept the push, so the surplus lands back in the
        // wallet directly and the pull-payment ledger stays at zero.
        assertEq(
            balanceBefore - registrant.balance,
            requiredPrice,
            "EOA payer is only debited the priced cost; overpayment is refunded inline"
        );
        assertEq(
            dotnsNameEscrow.pendingWithdrawal(registrant),
            0,
            "EOA payer must not be routed through the pull ledger"
        );

        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelhash);
        uint256 tokenId = uint256(node);

        assertEq(dotnsRegistrar.ownerOf(tokenId), registrant);
    }

    function testFuzz_register_refunds_overpayment_inline(uint256 extra, uint256 salt) public {
        address registrant = tiago;
        string memory nameLabel = _labelPopFullPriced(bound(salt, 0, 64));

        _grantPopFull(registrant);

        IDotnsRegistrarController.Registration memory registration =
            _commitFor(nameLabel, registrant, false);

        uint256 requiredPrice = popRules.priceWithCheck(nameLabel, registrant).price;
        assertGt(requiredPrice, 0);

        extra = bound(extra, 0, 5 ether);

        uint256 balanceBefore = registrant.balance;

        vm.startPrank(registrant);
        dotnsRegistrarController.register{value: requiredPrice + extra}(registration);
        vm.stopPrank();

        // Overpayment is refunded inline to the EOA payer, leaving the pull ledger untouched.
        assertEq(
            registrant.balance,
            balanceBefore - requiredPrice,
            "payer nets out to exactly the price when overpaid"
        );
        assertEq(
            dotnsNameEscrow.pendingWithdrawal(registrant),
            0,
            "EOA mint must not credit the pull ledger"
        );

        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelhash);
        uint256 tokenId = uint256(node);

        assertEq(dotnsRegistrar.ownerOf(tokenId), registrant);
    }

    function testFuzz_register_refunds_overpayment_to_payer_not_owner(
        uint256 extra,
        uint256 salt
    )
        public
    {
        address nameOwner = ed;
        address payer = leonardo;
        string memory nameLabel = _labelPopfull(bound(salt, 0, 64));

        _grantPopFull(nameOwner);
        _grantPopFull(payer);

        IDotnsRegistrarController.Registration memory registration =
            _commitFor(nameLabel, nameOwner, true, payer);

        uint256 requiredPrice = popRules.priceWithCheck(nameLabel, nameOwner).price;
        assertGt(requiredPrice, 0);

        extra = bound(extra, 0, 5 ether);

        uint256 ownerBalanceBefore = nameOwner.balance;
        uint256 payerBalanceBefore = payer.balance;

        vm.startPrank(payer);
        dotnsRegistrarController.register{value: requiredPrice + extra}(registration);
        vm.stopPrank();

        // EOA payers receive the overpayment refund inline. Owner's wallet stays untouched
        // and the pull ledger is bypassed for both parties.
        assertEq(
            payer.balance, payerBalanceBefore - requiredPrice, "EOA payer pays exactly the price"
        );
        assertEq(
            dotnsNameEscrow.pendingWithdrawal(payer),
            0,
            "EOA payer must not be routed through the pull ledger"
        );
        assertEq(
            dotnsNameEscrow.pendingWithdrawal(nameOwner),
            0,
            "owner must not be credited the payer's refund"
        );
        assertEq(nameOwner.balance, ownerBalanceBefore, "owner wallet is not touched");

        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelhash);
        uint256 tokenId = uint256(node);

        assertEq(dotnsRegistrar.ownerOf(tokenId), nameOwner);
    }

    function testFuzz_transfer_writes_label_to_recipient_store(uint256 salt) public {
        address sender = ed;
        address recipient = leonardo;
        string memory nameLabel = _labelPopfull(bound(salt, 0, 64));

        _grantPopFull(sender);

        IDotnsRegistrarController.Registration memory registration =
            _commitFor(nameLabel, sender, true);

        vm.startPrank(sender);
        dotnsRegistrarController.register{value: popRules.price(nameLabel)}(registration);
        vm.stopPrank();

        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelhash);
        uint256 tokenId = uint256(node);

        uint256 _xferFee = dotnsRegistrar.quoteTransferFee(tokenId, recipient);
        vm.prank(sender);
        dotnsRegistrar.transferFrom{value: _xferFee}(sender, recipient, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), recipient);

        ILabelStore recipientStore = ILabelStore(storeFactory.getLabelStore(recipient));
        assertTrue(address(recipientStore) != address(0));

        assertEq(recipientStore.getLabel(node), string.concat(nameLabel, ".dot"));
        assertTrue(recipientStore.isLocked(node));
    }

    function testFuzz_third_party_registration_does_not_overwrite_owner_reverse(uint256 salt)
        public
    {
        address payer = leonardo;
        address nameOwner = ed;
        uint256 primarySalt = bound(salt, 0, 63);
        string memory primaryName = _labelPopfull(primarySalt);

        _grantPopFull(nameOwner);

        IDotnsRegistrarController.Registration memory primaryRegistration =
            _commitFor(primaryName, nameOwner, true);

        uint256 primaryPrice = popRules.price(primaryName);
        vm.prank(nameOwner);
        dotnsRegistrarController.register{value: primaryPrice}(primaryRegistration);

        assertEq(dotnsReverseResolver.nameOf(nameOwner), string.concat(primaryName, ".dot"));

        string memory giftedName = _labelNoStatusPriced(primarySalt + 1);

        _grantPopFull(payer);

        IDotnsRegistrarController.Registration memory giftedRegistration =
            _commitFor(giftedName, nameOwner, true, payer);

        uint256 giftedPrice = popRules.price(giftedName);
        vm.prank(payer);
        dotnsRegistrarController.register{value: giftedPrice}(giftedRegistration);

        assertEq(dotnsReverseResolver.nameOf(nameOwner), string.concat(primaryName, ".dot"));
    }

    /// @notice For an arbitrary non-depositor NoStatus recipient, a transfer must
    ///         rebind the escrow position to the new holder without crediting any
    ///         refund entry, so the deposit follows the NFT.
    /// @dev Exercises the deposit-follows-name invariant: the deposit is for personhood
    ///      friction on the live holder; it travels with the NFT and only the current
    ///      holder can release into escrow to recover it. No transfer-time refund
    ///      fires, the per-asset reserves stay put, and the recycle that would
    ///      otherwise let one D underwrite an unbounded number of NoStatus names is
    ///      closed off.
    function testFuzz_NoStatus_transfer_rebinds_position_to_new_holder(
        uint256 salt,
        address recipientSeed
    )
        public
    {
        address depositor = ed;
        vm.assume(recipientSeed != address(0));
        vm.assume(recipientSeed != depositor);
        // Recipient must be an EOA so ERC721 transferFrom accepts it without an
        // onERC721Received hook; fuzzing in contract-receivers is out of scope here.
        vm.assume(recipientSeed.code.length == 0);
        // Avoid precompile-style addresses whose transfer behaviour is not modelled
        // by foundry's default cheats.
        vm.assume(uint160(recipientSeed) > 0xffff);

        string memory nameLabel = _labelNoStatusPriced(bound(salt, 0, 64));

        _grantNoStatus(depositor);
        _grantNoStatus(recipientSeed);

        IDotnsRegistrarController.Registration memory registration =
            _commitFor(nameLabel, depositor, false);

        uint256 ownerPrice = popRules.priceWithCheck(nameLabel, depositor).price;
        assertEq(ownerPrice, BASE_DEPOSIT, "NoStatus price baseline must match BASE_DEPOSIT");

        vm.prank(depositor);
        dotnsRegistrarController.register{value: ownerPrice}(registration);

        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelhash);
        uint256 tokenId = uint256(node);

        IDotnsNameEscrow.ReleasePosition memory atMint = dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(atMint.amount, BASE_DEPOSIT, "position must hold full deposit after register");
        assertEq(atMint.recipient, depositor, "position recipient must be the depositor at mint");

        uint256 reservesBefore = dotnsNameEscrow.reserves(address(0));
        uint256 depositorRefundsBefore = dotnsNameEscrow.pendingRefundCount(depositor);
        uint256 recipientRefundsBefore = dotnsNameEscrow.pendingRefundCount(recipientSeed);

        uint256 transferFee = dotnsRegistrar.quoteTransferFee(tokenId, recipientSeed);

        vm.prank(depositor);
        dotnsRegistrar.transferFrom{value: transferFee}(depositor, recipientSeed, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), recipientSeed, "NFT must move to the recipient");

        IDotnsNameEscrow.ReleasePosition memory afterTransfer =
            dotnsNameEscrow.getReleasePosition(tokenId);
        assertEq(afterTransfer.amount, BASE_DEPOSIT, "deposit amount must travel with the NFT");
        assertEq(
            afterTransfer.recipient,
            recipientSeed,
            "position must rebind to the new holder when the NFT leaves the depositor"
        );

        assertEq(
            dotnsNameEscrow.reserves(address(0)),
            reservesBefore,
            "per-asset reserves must not move when the deposit follows the NFT"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(depositor),
            depositorRefundsBefore,
            "no refund entry may be credited to the prior depositor at transfer time"
        );
        assertEq(
            dotnsNameEscrow.pendingRefundCount(recipientSeed),
            recipientRefundsBefore,
            "no refund entry may be credited to the new holder at transfer time"
        );
    }

    function testFuzz_transfer_clears_sender_primary_reverse(uint256 salt) public {
        address sender = ed;
        address recipient = leonardo;
        string memory nameLabel = _labelPopfull(bound(salt, 0, 64));

        _grantPopFull(sender);

        IDotnsRegistrarController.Registration memory registration =
            _commitFor(nameLabel, sender, true);

        uint256 registrationPrice = popRules.price(nameLabel);
        vm.prank(sender);
        dotnsRegistrarController.register{value: registrationPrice}(registration);

        bytes32 labelhash = keccak256(bytes(nameLabel));
        bytes32 node = _namehash(dotNode, labelhash);
        uint256 tokenId = uint256(node);

        assertEq(dotnsReverseResolver.nameOf(sender), string.concat(nameLabel, ".dot"));

        uint256 _xferFee = dotnsRegistrar.quoteTransferFee(tokenId, recipient);
        vm.prank(sender);
        dotnsRegistrar.transferFrom{value: _xferFee}(sender, recipient, tokenId);

        assertEq(dotnsReverseResolver.nameOf(sender), "");
    }

    /// @notice Build, commit and warp past the minimum commitment age, with `nameOwner` as the
    ///         commitment sender.
    function _commitFor(
        string memory nameLabel,
        address nameOwner,
        bool reserved
    )
        internal
        returns (IDotnsRegistrarController.Registration memory registration)
    {
        return _commitFor(nameLabel, nameOwner, reserved, nameOwner);
    }

    /// @notice Build, commit and warp past the minimum commitment age, with an explicit
    ///         `commitmentSender` distinct from `nameOwner`.
    function _commitFor(
        string memory nameLabel,
        address nameOwner,
        bool reserved,
        address commitmentSender
    )
        internal
        returns (IDotnsRegistrarController.Registration memory registration)
    {
        bytes32 secret =
            keccak256(abi.encodePacked(nameLabel, nameOwner, block.timestamp, address(this)));

        registration = IDotnsRegistrarController.Registration({
            label: nameLabel,
            owner: nameOwner,
            secret: secret,
            reserved: reserved,
            maxPrice: type(uint256).max,
            pricingVersion: popRules.pricingVersion()
        });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);

        vm.startPrank(commitmentSender);
        dotnsRegistrarController.commit(commitment);
        vm.stopPrank();

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
    }

    /// @notice Generate a label that classifies as PopFull (baselength 8, no trailing digits).
    function _labelPopfull(uint256 salt) internal pure returns (string memory label) {
        return string(abi.encodePacked("popful", _uintToAlphaFixed(salt, 2)));
    }

    /// @notice Generate an 11-character NoStatus label, measured whole, so it prices at the
    ///         base fee D on the curve.
    function _labelNoStatusPriced(uint256 salt) internal pure returns (string memory label) {
        return string(abi.encodePacked("nostatu", _uintToAlphaFixed(salt, 2), "01"));
    }

    /// @notice Generate an 8-character PopFull-tier label, measured whole, that prices above
    ///         the floor so the amount is non-zero. A public fixture cannot be PopLite: that is
    ///         the gateway's separated form and this path rejects a separator.
    function _labelPopFullPriced(uint256 salt) internal pure returns (string memory label) {
        return string(abi.encodePacked("free", _uintToAlphaFixed(salt, 2), "01"));
    }

    /// @notice Render `value` as a fixed-length lowercase ASCII alphabetic string.
    function _uintToAlphaFixed(
        uint256 value,
        uint256 length
    )
        internal
        pure
        returns (string memory output)
    {
        bytes memory buffer = new bytes(length);
        uint256 remaining = value;

        for (uint256 index = 0; index < length; index++) {
            buffer[index] = bytes1(uint8(97 + (remaining % 26)));
            remaining /= 26;
        }

        return string(buffer);
    }

    // Reserved registration: grant-gated, relayer-submittable, single use, reverse-record silent.

    /// @notice Without a grant naming the owner, no submitter can drive a reserved mint.
    function testFuzz_reserved_mint_requires_a_grant(uint256 salt, address submitter) public {
        vm.assume(submitter != address(0) && submitter.code.length == 0);
        string memory nameLabel = _grantLabel(salt);

        IDotnsRegistrarController.Registration memory registration = _reservedFor(nameLabel, ed);
        vm.startPrank(submitter);
        dotnsRegistrarController.commit(dotnsRegistrarController.makeCommitment(registration));
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrarController.NameNotGranted.selector, nameLabel, ed)
        );
        dotnsRegistrarController.registerReserved(registration);
        vm.stopPrank();
    }

    /// @notice A live grant admits only the address it names, over any pair of distinct actors.
    function testFuzz_a_grant_admits_only_its_beneficiary(uint256 salt, uint256 seed) public {
        address[3] memory pool = [ed, leonardo, tiago];
        address beneficiary = pool[seed % 3];
        address impostor = pool[(seed % 3 + 1) % 3];

        string memory nameLabel = _grantLabel(salt);
        _grantName(nameLabel, beneficiary);

        IDotnsRegistrarController.Registration memory registration =
            _reservedFor(nameLabel, impostor);
        vm.startPrank(impostor);
        dotnsRegistrarController.commit(dotnsRegistrarController.makeCommitment(registration));
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDotnsRegistrarController.NameNotGranted.selector, nameLabel, impostor
            )
        );
        dotnsRegistrarController.registerReserved(registration);
        vm.stopPrank();

        assertTrue(dotnsNameWhitelist.isGrantedTo(nameLabel, beneficiary));
    }

    /// @notice The gate reads `registration.owner`, so whoever submits, the name lands on the
    /// beneficiary and never on the submitter.
    function testFuzz_granted_name_mints_to_the_beneficiary(uint256 salt, uint256 seed) public {
        address[3] memory pool = [ed, leonardo, tiago];
        address submitter = pool[seed % 3];
        address beneficiary = pool[(seed % 3 + 1) % 3];

        string memory nameLabel = _grantLabel(salt);
        _grantName(nameLabel, beneficiary);
        _revealReserved(_reservedFor(nameLabel, beneficiary), submitter);

        assertEq(dotnsRegistrar.ownerOf(_tokenIdForLabel(nameLabel)), beneficiary);
    }

    /// @notice A grant is spent by the mint, so the same label cannot be issued twice.
    function testFuzz_grant_is_single_use(uint256 salt) public {
        string memory nameLabel = _grantLabel(salt);
        _grantName(nameLabel, ed);
        _revealReserved(_reservedFor(nameLabel, ed), ed);

        assertFalse(dotnsNameWhitelist.isGrantedTo(nameLabel, ed));
    }

    /// @notice The reserved path never writes the beneficiary's reverse record: the submitter is
    /// not necessarily the beneficiary, and `setReverseName` overwrites unconditionally.
    function testFuzz_reserved_mint_leaves_the_reverse_record_untouched(
        uint256 salt,
        uint256 seed
    )
        public
    {
        address[3] memory pool = [ed, leonardo, tiago];
        address submitter = pool[seed % 3];
        address beneficiary = pool[(seed % 3 + 1) % 3];

        string memory nameLabel = _grantLabel(salt);
        _grantName(nameLabel, beneficiary);
        _revealReserved(_reservedFor(nameLabel, beneficiary), submitter);

        assertEq(dotnsReverseResolver.nameOf(beneficiary), "");
    }

    /// @notice A Root dispatch mints a label that was never granted. That an unrelated live grant
    /// survives a Root mint is asserted in the unit suite, which seeds one.
    function testFuzz_root_mints_without_a_grant(uint256 salt) public {
        string memory nameLabel = _grantLabel(salt);

        _mockOriginIsRoot(true);
        _revealReserved(_reservedFor(nameLabel, ed), tiago);
        _mockOriginIsRoot(false);

        assertEq(dotnsRegistrar.ownerOf(_tokenIdForLabel(nameLabel)), ed);
    }

    /// @notice Distinct, always-valid label per fuzz run.
    function _grantLabel(uint256 salt) private pure returns (string memory nameLabel) {
        nameLabel = string.concat("granted", vm.toString(salt % 1_000_000));
    }

    function _reservedFor(
        string memory nameLabel,
        address nameOwner
    )
        private
        view
        returns (IDotnsRegistrarController.Registration memory registration)
    {
        registration = IDotnsRegistrarController.Registration({
            label: nameLabel,
            owner: nameOwner,
            secret: keccak256(abi.encodePacked(nameLabel, nameOwner)),
            reserved: true,
            maxPrice: type(uint256).max,
            pricingVersion: popRules.pricingVersion()
        });
    }

    function _revealReserved(
        IDotnsRegistrarController.Registration memory registration,
        address submitter
    )
        private
    {
        vm.startPrank(submitter);
        dotnsRegistrarController.commit(dotnsRegistrarController.makeCommitment(registration));
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
        dotnsRegistrarController.registerReserved(registration);
        vm.stopPrank();
    }
}
