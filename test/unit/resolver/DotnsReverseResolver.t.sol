// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsReverseResolver} from "../../../contracts/resolvers/IDotnsReverseResolver.sol";

/// @title DotnsReverseResolverTests
/// @notice Unit tests for the address-to-name reverse record on @custom:contract
///         DotnsReverseResolver. Covers the controller-only seeder, the self-service
///         @custom:function claimReverseRecord path, and the fail-closed
///         @custom:function nameOf read.
contract DotnsReverseResolverTests is BaseDotns {
    /// @notice Label fixture used by tests that need a labelled, transferable name.
    /// @dev Stem of nine characters with a two-digit suffix; classifies as NoStatus.
    string internal constant CLAIM_LABEL = "claimuser01";
    /// @notice Secondary label fixture used by overwrite and transfer tests.
    /// @dev Stem of nine characters with a two-digit suffix; classifies as NoStatus.
    string internal constant ALT_LABEL = "secondname01";

    function test_nameof_returns_empty_when_unset() public view {
        assertEq(bytes(dotnsReverseResolver.nameOf(ed)).length, 0);
    }

    function test_register_sets_reverse_record_for_owner() public {
        _commitAndRegister("reverserecord01", ed, true);
        assertEq(dotnsReverseResolver.nameOf(ed), "reverserecord01.dot");
    }

    function test_register_preserves_existing_reverse_record() public {
        // Subsequent reserved registrations must not silently overwrite the primary.
        _commitAndRegister("reverseone01", ed, true);
        _commitAndRegister("reversetwo01", ed, true);
        assertEq(dotnsReverseResolver.nameOf(ed), "reverseone01.dot");
    }

    function test_protocol_registry_bound_at_init() public view {
        assertEq(address(dotnsReverseResolver.protocolRegistry()), address(protocolRegistry));
    }

    function test_claim_reverse_record_sets_for_current_owner() public {
        _grantNoStatus(ed);
        _commitAndRegister(CLAIM_LABEL, ed, true);

        // Auto-set already pointed ed at the first name; claiming the same name
        // is a no-op overwrite that still emits the event with the same payload.
        vm.prank(ed);
        dotnsReverseResolver.claimReverseRecord(CLAIM_LABEL);

        assertEq(dotnsReverseResolver.nameOf(ed), string.concat(CLAIM_LABEL, ".dot"));
    }

    function test_claim_reverse_record_overwrites_existing_primary() public {
        _grantNoStatus(ed);
        _commitAndRegister(CLAIM_LABEL, ed, true);
        // Second reserved registration leaves the primary at CLAIM_LABEL because
        // the controller skips auto-set when a primary already exists.
        _commitAndRegister(ALT_LABEL, ed, true);
        assertEq(dotnsReverseResolver.nameOf(ed), string.concat(CLAIM_LABEL, ".dot"));

        vm.prank(ed);
        dotnsReverseResolver.claimReverseRecord(ALT_LABEL);

        assertEq(dotnsReverseResolver.nameOf(ed), string.concat(ALT_LABEL, ".dot"));
    }

    function test_revert_claim_reverse_record_when_caller_does_not_own() public {
        _grantNoStatus(ed);
        _commitAndRegister(CLAIM_LABEL, ed, true);

        uint256 tokenId = _tokenIdForLabel(CLAIM_LABEL);

        vm.prank(leonardo);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsReverseResolver.NotNameOwner.selector, leonardo, tokenId)
        );
        dotnsReverseResolver.claimReverseRecord(CLAIM_LABEL);
    }

    function test_claim_reverse_record_emits_event() public {
        _grantNoStatus(ed);
        _commitAndRegister(CLAIM_LABEL, ed, true);

        // First registration's auto-set already wrote the same value, but the
        // explicit claim must still emit a fresh ReverseNameSet event so wallets
        // can observe the user-initiated intent.
        vm.expectEmit(true, true, false, true, address(dotnsReverseResolver));
        emit IDotnsReverseResolver.ReverseNameSet(ed, string.concat(CLAIM_LABEL, ".dot"));

        vm.prank(ed);
        dotnsReverseResolver.claimReverseRecord(CLAIM_LABEL);
    }

    function test_claim_reverse_record_after_receiving_transfer() public {
        // Setup: ed registers, then transfers to leonardo. The transfer must not
        // auto-set leonardo's reverse; leonardo claims explicitly afterwards.
        _grantNoStatus(ed);
        _grantNoStatus(leonardo);
        _commitAndRegister(CLAIM_LABEL, ed, true);

        uint256 tokenId = _tokenIdForLabel(CLAIM_LABEL);

        // Same-tier NoStatus transfer is free; the eager-clear path wipes ed's
        // stored reverse because the labelhash matches the transferring name.
        vm.prank(ed);
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);

        assertEq(
            dotnsReverseResolver.nameOf(leonardo),
            "",
            "recipient must not auto-receive a reverse record on transfer"
        );

        vm.prank(leonardo);
        dotnsReverseResolver.claimReverseRecord(CLAIM_LABEL);

        assertEq(dotnsReverseResolver.nameOf(leonardo), string.concat(CLAIM_LABEL, ".dot"));
    }

    function test_nameof_fails_closed_when_caller_no_longer_owns_stored_name() public {
        // Bypass the registrar's eager-clear path by writing the reverse record
        // for an address that does not own the underlying name. The fail-closed
        // read must then reject it independently.
        _grantNoStatus(ed);
        _commitAndRegister(CLAIM_LABEL, ed, true);

        // ed is the owner; force a stale-looking primary onto leonardo via the
        // registrar-only seeder so the read-time check has to do the work.
        vm.prank(address(dotnsRegistrar));
        dotnsReverseResolver.setReverseName(leonardo, string.concat(CLAIM_LABEL, ".dot"));

        assertEq(
            dotnsReverseResolver.nameOf(leonardo),
            "",
            "stored record pointing to a name leonardo does not own must read as empty"
        );
    }

    function test_nameof_fails_closed_for_unminted_label() public {
        // Stored name points at a label that was never minted; ownerOf reverts
        // and the read falls back to the empty string via the try/catch arm.
        vm.prank(address(dotnsRegistrar));
        dotnsReverseResolver.setReverseName(ed, "ghostlabel001.dot");

        assertEq(
            dotnsReverseResolver.nameOf(ed), "", "lookup for an unminted name must read as empty"
        );
    }

    function test_nameof_fails_closed_when_stored_lacks_tld_suffix() public {
        // Defensive: a malformed legacy stored value (no .dot suffix) must not
        // resolve to anything. The fail-closed read strips the TLD; if the
        // suffix is missing, _stripTld returns the empty string and we bail.
        vm.prank(address(dotnsRegistrar));
        dotnsReverseResolver.setReverseName(ed, "no-tld-suffix");

        assertEq(
            dotnsReverseResolver.nameOf(ed),
            "",
            "stored record without the .dot suffix must read as empty"
        );
    }
}
